import CoreLocation
import UIKit
import SwiftUI

/// 自宅・会社など、名前で出したい場所の一覧。
struct PlacesView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var adding = false
    @State private var newName = ""
    @State private var status = ""

    var body: some View {
        let places = pipeline.places
        List {
            if places.authorization != .authorizedAlways {
                Section {
                    Text("画面を閉じているあいだも場所を残すには、設定アプリ →「LifeLog」→「位置情報」を「常に」にしてください。")
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            Section {
                ForEach(places.places) { place in
                    Text(place.name)
                }
                .onDelete { places.removePlaces(at: $0) }
                Button("今いる場所を登録") {
                    newName = ""
                    adding = true
                }
                if !status.isEmpty {
                    Text(status).foregroundStyle(.secondary)
                }
            } footer: {
                Text("登録した場所から300 m 以内で話した会話は、見出しにその名前が出ます。それ以外は「〇〇駅近く」「〇〇付近」と出ます。位置は大きく移動したときだけ記録するので、電池はほとんど使いません。")
            }
        }
        .navigationTitle("場所")
        .alert("今いる場所の名前", isPresented: $adding) {
            TextField("自宅、会社など", text: $newName)
            Button("登録") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                status = "現在地を調べています…"
                Task {
                    status = await places.addCurrentPlace(named: name) ? "" : "現在地が分かりませんでした。位置情報の許可を確認してください。"
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
}
