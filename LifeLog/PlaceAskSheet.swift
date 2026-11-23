import MapKit
import SwiftUI
import UIKit

/// 「ここは、どこですか？」の通知を押したときに開く、答える画面（2026-11-23）。
/// 前は通知を押してもアプリが開くだけで、どこに何を入れればいいか分からなかった。
/// 地図でその場所を見せ、候補のボタンか、名前を書いて答える。答えた名前は位置で覚える（PlaceAssist.answered）
/// 2026-11-23（s23）: 休日の「さっきの所は〇〇？」もこの画面で答える（知3）。「ここは覚えなくていい」（場1）・
/// 「あとで」（知12）・そのときの会話の頭の 1 行と写真（場5）・答えたあとの 1 行（知14）
struct PlaceAskTarget: Identifiable {
    let id = UUID()
    let candidates: [String]
    let latitude: Double?
    let longitude: Double?
    /// 休日の「さっきの所は〇〇？」から開いたときの日（はい・いいえを休日の帳にも残す。s23 の 知3）
    var holidayDay: String? = nil
    /// 数えるときの種類（知11）と知らせの名前（知13）
    var kind: String = "placeAsk"
    var noticeID: String = ""
}

struct PlaceAskSheet: View {
    @Environment(Pipeline.self) private var pipeline
    let target: PlaceAskTarget
    let onClose: () -> Void

    @State private var typed = ""
    @State private var saved: String?
    @State private var later = false
    @State private var forgot = false
    @State private var clueLine: String?
    @State private var photos: [UIImage] = []
    @FocusState private var typing: Bool

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = target.latitude, let lon = target.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        Form {
            if let coordinate {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400,
                                                                    longitudinalMeters: 400))) {
                        Marker("ここ", coordinate: coordinate)
                    }
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                    .allowsHitTesting(false)
                } footer: {
                    Text(target.holidayDay == nil ? "30 分ほどいた所です。名前を選ぶか書くと、次からその名前で見出しに出ます。"
                         : "さっきまでいた所です。合っていれば候補を押してください。")
                }
            }
            // 場5 思い出す手がかり（そのとき録れていた会話の頭の 1 行と写真。この iPhone の中だけ）
            if clueLine != nil || !photos.isEmpty {
                Section {
                    if let clueLine {
                        Label(clueLine, systemImage: "text.bubble").font(.callout).foregroundStyle(LL.dim).lineLimit(2)
                    }
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                } header: {
                    Text("そのときの手がかり")
                }
            }
            if let saved {
                Section {
                    Label("「\(saved)」で覚えました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(LL.accent)
                    // 知14 答えで何が変わるか
                    Text(S23AfterRules.place(saved)).font(.caption).foregroundStyle(LL.dim)
                }
            } else if later {
                Section { Label("1 時間後に、もう一度聞きます", systemImage: "clock").foregroundStyle(LL.dim) }
            } else if forgot {
                Section { Label("この近くでは、もう聞きません", systemImage: "nosign").foregroundStyle(LL.dim) }
            } else {
                if !target.candidates.isEmpty {
                    Section(target.holidayDay == nil ? "候補から選ぶ" : "合っていれば押す") {
                        ForEach(target.candidates, id: \.self) { name in
                            Button {
                                answer(name)
                            } label: {
                                Label(name, systemImage: "mappin.and.ellipse")
                            }
                        }
                        if target.holidayDay != nil {
                            Button("違う", role: .destructive) { holidayNo() }
                        }
                    }
                }
                Section {
                    TextField("例: 駅前のカフェ", text: $typed)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { answer(typed) }
                    Button("この名前で覚える") { answer(typed) }
                        .disabled(PlaceAssistRules.typedName(typed) == nil)
                } header: {
                    Text(target.candidates.isEmpty ? "名前を書く" : "候補に無ければ、名前を書く")
                }
                Section {
                    // 知12 あとで（1 時間後にもう一度）
                    if target.holidayDay == nil {
                        Button {
                            PlaceAssist.shared.askAgain(target, after: 3600)
                            later = true
                            close(after: 1.0)
                        } label: {
                            Label("あとで（1 時間後に聞く）", systemImage: "clock")
                        }
                    }
                    // 場1 この場所ではもう聞かない
                    Button(role: .destructive) {
                        forget()
                    } label: {
                        Label("ここは覚えなくていい", systemImage: "nosign")
                    }
                    .disabled(coordinate == nil)
                } footer: {
                    Text("「覚えなくていい」にすると、この近く（150 m）ではもう聞きません。設定の「知らせの棚卸し」から戻せます。")
                }
            }
        }
        .navigationTitle(target.holidayDay == nil ? PlaceAssistRules.askTitle : "さっきの所は？")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(saved == nil ? "答えない" : "閉じる") { onClose() }
            }
        }
        .onAppear {
            Tally.add("placeask.sheet")
            S23Book.shared.noteTap(target.kind, "opened")
        }
        .onDisappear {
            // 知11 押したのに答えずに閉じた
            if saved == nil && !later && !forgot { S23Book.shared.noteTap(target.kind, "closed") }
        }
        .task { await loadClues() }
    }

    private func answer(_ raw: String) {
        guard let name = PlaceAssistRules.typedName(raw) else { return }
        typing = false
        PlaceAssist.shared.answered(name: name, latitude: target.latitude, longitude: target.longitude, source: "app", via: "sheet")
        if let day = target.holidayDay {
            HolidayBook.shared.addPlaceAnswer(day: day, name: name, answer: "yes")
            Tally.add("holiday.place.yes")
        }
        Tally.add("placeask.sheet.answered")
        Tally.add("s23.sheet.answered")
        S23Book.shared.noteTap(target.kind, "answered")
        if !target.noticeID.isEmpty { S23Book.shared.answeredQuestion(id: target.noticeID) }
        saved = name
        close(after: 1.6)
    }

    private func holidayNo() {
        if let day = target.holidayDay, let name = target.candidates.first {
            HolidayBook.shared.addPlaceAnswer(day: day, name: name, answer: "no")
            Tally.add("holiday.place.no")
        }
        S23Book.shared.noteTap(target.kind, "answered")
        if !target.noticeID.isEmpty { S23Book.shared.answeredQuestion(id: target.noticeID) }
        forgot = false
        later = true
        onClose()
    }

    private func forget() {
        guard let lat = target.latitude, let lon = target.longitude else { return }
        S23Places.ignore(latitude: lat, longitude: lon)
        S23Book.shared.noteTap(target.kind, "answered")
        if !target.noticeID.isEmpty { S23Book.shared.answeredQuestion(id: target.noticeID) }
        forgot = true
        close(after: 1.0)
    }

    private func close(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            onClose()
        }
    }

    /// 場5 着いた時刻から今までの会話の頭の 1 行と、その時間の写真（3 枚まで）
    private func loadClues() async {
        guard let arrival = S23Places.arrival(latitude: target.latitude, longitude: target.longitude) else { return }
        let now = Date.now
        let day = ReviewRules.dayKey(arrival)
        let talk = pipeline.conversations(on: day).first { $0.end >= arrival && $0.start <= now && $0.media == nil }
        if let line = talk?.lines.first(where: { !$0.text.isEmpty }) {
            clueLine = String(line.text.prefix(60))
        }
        guard DayPhotos.isShown else { return }
        var images: [UIImage] = []
        for asset in DayPhotos.assets(in: arrival...max(arrival, now), limit: 3) {
            if let image = await DayPhotos.image(asset, size: CGSize(width: 160, height: 160), network: false) { images.append(image) }
        }
        photos = images
    }
}
