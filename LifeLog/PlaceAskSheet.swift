import MapKit
import SwiftUI

/// 「ここは、どこですか？」の通知を押したときに開く、答える画面（2026-11-23）。
/// 前は通知を押してもアプリが開くだけで、どこに何を入れればいいか分からなかった。
/// 地図でその場所を見せ、候補のボタンか、名前を書いて答える。答えた名前は位置で覚える（PlaceAssist.answered）
struct PlaceAskTarget: Identifiable {
    let id = UUID()
    let candidates: [String]
    let latitude: Double?
    let longitude: Double?
}

struct PlaceAskSheet: View {
    let target: PlaceAskTarget
    let onClose: () -> Void

    @State private var typed = ""
    @State private var saved: String?
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
                    Text("30 分ほどいた所です。名前を選ぶか書くと、次からその名前で見出しに出ます。")
                }
            }
            if let saved {
                Section {
                    Label("「\(saved)」で覚えました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(LL.accent)
                }
            } else {
                if !target.candidates.isEmpty {
                    Section("候補から選ぶ") {
                        ForEach(target.candidates, id: \.self) { name in
                            Button {
                                answer(name)
                            } label: {
                                Label(name, systemImage: "mappin.and.ellipse")
                            }
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
            }
        }
        .navigationTitle(PlaceAssistRules.askTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(saved == nil ? "答えない" : "閉じる") { onClose() }
            }
        }
        .onAppear { Tally.add("placeask.sheet") }
    }

    private func answer(_ raw: String) {
        guard let name = PlaceAssistRules.typedName(raw) else { return }
        typing = false
        PlaceAssist.shared.answered(name: name, latitude: target.latitude, longitude: target.longitude, source: "app")
        Tally.add("placeask.sheet.answered")
        saved = name
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            onClose()
        }
    }
}
