import AVFoundation
import SwiftUI

/// 自分の声を20秒録って登録する画面。
struct VoiceEnrollView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AVAudioRecorder?
    @State private var remaining = 0
    @State private var status = ""

    private static let seconds = 20
    private static let sample = "今日はいい天気ですね。朝は駅まで歩いて、電車の中でニュースを読みました。午後からは打ち合わせが二つあって、そのあと資料をまとめる予定です。夜は家でゆっくり過ごそうと思います。"

    var body: some View {
        Form {
            Section {
                Text(Self.sample)
            } header: {
                Text("この文を、ふだんの声で読んでください")
            } footer: {
                Text("静かな場所で、自分だけが話している状態で録ってください。声の特徴だけをこの iPhone に保存し、録音は登録が終わったら消します。")
            }
            Section {
                if remaining > 0 {
                    Label("録音中… あと \(remaining) 秒", systemImage: "waveform")
                } else {
                    Button(pipeline.hasSelfVoice ? "録り直す" : "録音を始める（\(Self.seconds)秒）") { start() }
                        .disabled(pipeline.isRecording)
                }
                if pipeline.isRecording {
                    Text("ライフログの録音を止めてから登録してください。").foregroundStyle(.secondary)
                }
                if !status.isEmpty {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("自分の声を登録")
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enroll.m4a")
        pipeline.suspendStandby()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ])
            guard r.record(forDuration: TimeInterval(Self.seconds)) else { throw NSError(domain: "Enroll", code: 1) }
            recorder = r
            remaining = Self.seconds
            status = ""
            Task { await countDown(url) }
        } catch {
            status = "録音できませんでした: \(error.localizedDescription)"
            pipeline.resumeStandby()
        }
    }

    private func countDown(_ url: URL) async {
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(1))
            remaining -= 1
        }
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        pipeline.resumeStandby()
        status = "声の特徴を調べています…（初回はモデルのダウンロードがあります）"
        do {
            try await pipeline.enrollSelf(from: url)
            status = "登録しました。これからは文字起こしに「[自分]」と付きます。"
        } catch {
            status = "登録できませんでした: \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// これまでに聞いた、自分以外の声の一覧。名前を付けたり消したりできる。
struct PeopleView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var editing: SpeakerLabeler.Person?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(pipeline.people) { person in
                    Button {
                        newName = person.name.hasPrefix("人物") ? "" : person.name
                        editing = person
                    } label: {
                        LabeledContent(person.name) {
                            Text("\(person.minutes) 分・\(person.lastHeard.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    let ids = offsets.map { pipeline.people[$0].id }
                    Task { for id in ids { await pipeline.removePerson(id) } }
                }
            } footer: {
                Text("文字起こしで「人物3」などと出た人です。タップして名前を付けると、次からその名前で出て、その人の「人物ノート」に会話が書き足されます。名前を付けていない声は、2週間聞かなければ自動で忘れます。")
            }
        }
        .overlay {
            if pipeline.people.isEmpty {
                ContentUnavailableView("まだいません", systemImage: "person.2",
                                       description: Text("話し相手の声を聞くと、ここに出てきます。"))
            }
        }
        .navigationTitle("話した相手")
        .alert("名前を付ける", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("名前", text: $newName)
            Button("保存") {
                if let person = editing, !newName.isEmpty {
                    Task { await pipeline.renamePerson(person.id, to: newName) }
                }
                editing = nil
            }
            Button("キャンセル", role: .cancel) { editing = nil }
        } message: {
            if let person = editing { Text("\(person.name) の名前") }
        }
    }
}
