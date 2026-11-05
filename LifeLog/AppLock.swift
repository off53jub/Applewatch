import LocalAuthentication
import SwiftUI

/// アプリの鍵（2026-11-06）。設定で「開くときに Face ID」をオンにすると、アプリが前に出るたびに
/// Face ID（できなければパスコード）で確かめるまで、記録を隠す。録音・裏の処理・時計からの受け取りは止めない。
/// 初めはオフ（オンにしたあと Face ID が使えなくなっても、iPhone のパスコードで開ける）。
struct AppLock: ViewModifier {
    static let key = "appLock"
    @AppStorage(AppLock.key) private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: AppLock.key)
    @State private var asking = false
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && locked {
                    ZStack {
                        Rectangle().fill(.background).ignoresSafeArea()
                        VStack(spacing: 16) {
                            Image(systemName: "lock.fill").font(.system(size: 44))
                            Text("LifeLog は鍵がかかっています").font(.headline)
                            Button("Face ID で開く") { unlock() }
                                .buttonStyle(.borderedProminent)
                            if let failure {
                                Text(failure).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("録音と文字起こしは、鍵がかかっていても続いています。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    if enabled { locked = true }
                case .active:
                    if enabled && locked { unlock() }
                default:
                    break
                }
            }
            .onAppear { if enabled && locked { unlock() } }
            .onChange(of: enabled) { _, on in if !on { locked = false } }
    }

    private func unlock() {
        guard !asking else { return }
        asking = true
        let context = LAContext()
        context.localizedCancelTitle = "やめる"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "記録を開くために確かめます") { ok, error in
            Task { @MainActor in
                asking = false
                if ok {
                    locked = false
                    failure = nil
                } else {
                    failure = error?.localizedDescription
                }
            }
        }
    }
}
