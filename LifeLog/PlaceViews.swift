import CoreLocation
import UIKit
import SwiftUI

/// 自宅・会社など、名前で出したい場所の一覧。
struct PlacesView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var adding = false
    @State private var newName = ""
    @State private var status = ""
    /// 名前を直している場所（2026-11-16。強化案 89）
    @State private var renaming: PlaceLog.Place?
    @State private var renameText = ""
    /// 着いたとき 1 回だけ細かく測る・30 分いたら手首で聞く・着いたら知らせる（初めはオン。強化案 88・91・104）
    @AppStorage(PlaceLog.arrivalKey) private var arrivalOn = true
    @AppStorage(PlaceAssistRules.askKey) private var askOn = true
    @AppStorage(PlaceAssistRules.remindKey) private var remindOn = true
    @AppStorage(WifiHint.key) private var wifiOn = true

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
                Toggle("着いたとき、1 回だけ細かく測る", isOn: $arrivalOn)
                Toggle("30 分いたら、手首で名前をたずねる", isOn: $askOn)
                Toggle("着いたら、その場所のやることを知らせる", isOn: $remindOn)
                Toggle("Wi-Fi の名前を手がかりにする", isOn: $wifiOn)
            } header: {
                Text("着いたとき")
            } footer: {
                Text("お店などに立ち寄ったときの知らせで、iPhone が起きたときだけ位置を測ります（続けて測らないので、電池への影響は小さいです）。たずねる知らせは、自宅・職場・名前の決まった場所では出さず、会議のあいだも出しません。1 日に 3 回までです。\n\nWi-Fi の名前は、端末の中で暗号のような文字に変えてから使います（名前そのものは残さず、外にも出しません）。同じ Wi-Fi につながったとき、前に名前を付けた所だと分かります。")
            }
            Section {
                ForEach(places.places) { place in
                    Toggle(isOn: Binding(get: { place.isWork == true },
                                         set: { places.setWork(place.id, $0) })) {
                        Text(place.name)
                        if place.isWork == true {
                            Text("職場").font(.caption).foregroundStyle(.secondary)
                        }
                        if place.pausesRecording == true {
                            Text("ここでは録音を休む").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("名前を変える") {
                            renameText = place.name
                            renaming = place
                        }
                        Button(place.pausesRecording == true ? "ここでも録音する" : "ここでは録音を休む") {
                            places.setPause(place.id, place.pausesRecording != true)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("名前を変える") {
                            renameText = place.name
                            renaming = place
                        }
                        .tint(.blue)
                    }
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
                Text("登録した場所から300 m 以内で話した会話は、見出しにその名前が出ます。それ以外は「〇〇駅近く」「〇〇付近」と出ます。位置は大きく移動したときだけ記録するので、電池はほとんど使いません。\n\n場所を長押しして「ここでは録音を休む」を選ぶと、そこから離れるまで、iPhone と時計は書くのを休みます（マイクは聞き続けるだけで、離れると自動で書き始めます）。家の iPad が録音するときに使います。\n\nスイッチをオンにした場所は「職場」です。職場にいるあいだは職場の人の声を、それ以外では職場以外の人の声を先に照らし合わせるので、聞き分けが正確になります。")
            }
        }
        .onChange(of: arrivalOn) { _, _ in places.refreshVisitMonitoring() }
        .onChange(of: askOn) { _, _ in places.refreshVisitMonitoring() }
        .onChange(of: remindOn) { _, _ in places.refreshVisitMonitoring() }
        .navigationTitle("場所")
        .countsOpen("places")
        .alert("今いる場所の名前", isPresented: $adding) {
            TextField("自宅、会社など", text: $newName)
            Button("登録") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                status = "現在地を調べています…"
                Task {
                    // 「会社」「職場」「オフィス」を含む名前は職場にしておく（あとで切り替えられる）
                    let isWork = ["会社", "職場", "オフィス", "事務所"].contains { name.contains($0) }
                    status = await places.addCurrentPlace(named: name, isWork: isWork)
                        ? "" : "現在地が分かりませんでした。位置情報の許可を確認してください。"
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("場所の名前を変える", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("新しい名前", text: $renameText)
            Button("変える") {
                if let place = renaming { _ = places.rename(place.id, to: renameText) }
                renaming = nil
            }
            Button("キャンセル", role: .cancel) { renaming = nil }
        } message: {
            Text("直した名前は、同じ所で次から使います。")
        }
    }
}
