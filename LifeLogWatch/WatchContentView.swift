import SwiftUI

struct WatchContentView: View {
    @Environment(WatchRecorder.self) private var recorder
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button {
                    Task { await recorder.toggle() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                Text(recorder.isRecording ? "録音中" : "停止中")
                    .font(.headline)
                if recorder.isRecording {
                    // 指のダブルタップでも押せる
                    Button {
                        recorder.mark()
                    } label: {
                        Label("印", systemImage: "star.fill")
                    }
                    .tint(.yellow)
                    .handGestureShortcut(.primaryAction)
                    // 初めての人と話しているときの印と、会議モード（2026-11-06）
                    HStack(spacing: 6) {
                        Button {
                            recorder.markNewPerson()
                        } label: {
                            Label("初めての人", systemImage: "person.badge.plus")
                                .font(.caption2)
                        }
                        Button {
                            recorder.toggleMeeting()
                        } label: {
                            Label(recorder.meetingOn ? "会議を終える" : "会議", systemImage: "person.3")
                                .font(.caption2)
                        }
                        .tint(recorder.meetingOn ? .orange : nil)
                    }
                }
                // さっき何て言った？（iPhone の記録の直近の3行。2026-11-06）
                Button {
                    recorder.askRecent()
                } label: {
                    if recorder.asking {
                        ProgressView()
                    } else {
                        Label("さっき何て言った？", systemImage: "text.bubble").font(.caption2)
                    }
                }
                if let answer = recorder.recentAnswer {
                    Text(answer)
                        .font(.caption2)
                        .multilineTextAlignment(.leading)
                        .onTapGesture { recorder.clearAnswer() }
                }
                if !recorder.message.isEmpty {
                    Text(recorder.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // iPhone とのつながりと、送れていない録音
                VStack(spacing: 2) {
                    Text(recorder.link)
                    if recorder.unsent > 0 {
                        Text("iPhone に送っていない録音 \(recorder.unsent) 個")
                            .foregroundStyle(recorder.unsent >= 4 ? .orange : .secondary)
                    }
                    if recorder.lowPower {
                        Text("低電力モード: 15分ほどごとにまとめて送ります")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.refreshStatus() }
        }
        .onAppear { recorder.refreshStatus() }
    }
}
