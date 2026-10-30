import SwiftUI

struct WatchContentView: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
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
            if !recorder.message.isEmpty {
                Text(recorder.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
