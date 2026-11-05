import SwiftUI
import UniformTypeIdentifiers

/// ほかのアプリ（AUDAY など）で録った音声を、ファイルアプリ経由で選んで取り込む画面。
struct ImportView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var picking = false

    var body: some View {
        let importer = pipeline.importer
        let selected = importer.items.filter(\.include).count
        List {
            Section {
                Button("ファイル・フォルダを選ぶ") { picking = true }
                    .disabled(importer.working)
            } footer: {
                Text("ファイルアプリの「ドライブ」から、AUDAY の音声が入っているフォルダ（またはファイル）を選んでください（ファイルアプリにドライブが出ないときは、Google ドライブのアプリを入れてログインしてください）。ファイル名の日時を録音を始めた時刻として読み取り、5分ずつに分けて文字起こしします。いまの録音を先に処理し、取り込んだ分はそのあいだに少しずつ進めます。")
            }
            if !importer.status.isEmpty || importer.working {
                Section {
                    HStack {
                        if importer.working { ProgressView() }
                        Text(importer.status).foregroundStyle(.secondary)
                    }
                }
            }
            if !importer.items.isEmpty {
                Section {
                    Button("選んだ \(selected) 個を取り込む") {
                        Task { await importer.importSelected() }
                    }
                    .disabled(importer.working || selected == 0)
                } footer: {
                    Text("時刻が違っていたら、下の一覧で直してから取り込んでください。取り込み済みのものは外してあります。")
                }
                Section("見つかった音声（\(importer.items.count) 個）") {
                    ForEach(importer.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: Binding(get: { item.include },
                                                 set: { importer.setInclude(item.id, $0) })) {
                                Text(item.name).lineLimit(1)
                                Text(item.alreadyImported ? "取り込み済み" : "時刻: " + item.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            DatePicker("録音を始めた時刻",
                                       selection: Binding(get: { item.start ?? .now },
                                                          set: { importer.setStart(item.id, $0) }))
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importer.load(urls) }
        }
        .navigationTitle("ほかのアプリの音声")
    }
}
