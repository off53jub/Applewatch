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
