import SwiftUI
import UIKit

/// 頼まれごとを済みにしたときの、お礼・報告の返事の下書き（2026-11-12）。
/// 決まった文に、その項目の短い題と頼んだ人の名前を入れるだけ（言語モデルは使わない）。
/// 送るのは本人。アプリからは何も送らない（コピーするか、共有シートで渡すだけ）。
enum TaskReply {
    /// 題に使う長さ（これより長いときは「…」で切る）
    static let maxTitle = 24

    /// 画面に出す下書き（シートの中身）
    struct Draft: Identifiable, Equatable {
        let id: String
        let text: String
    }

    /// 返事の下書きを出す項目か。ほかの人から頼まれたもの（asked）で、頼んだ人の名前があるときだけ。
    static func needsReply(_ item: TaskBook.Item) -> Bool {
        item.kindOrDefault == .asked && !cleanName(item.from).isEmpty
    }

    /// 済みにした項目の下書き（出さない項目は nil）
    static func draft(for item: TaskBook.Item) -> Draft? {
        guard needsReply(item) else { return nil }
        return Draft(id: item.id, text: text(what: item.what, from: item.from))
    }

    /// 「〇〇さん、□□の件、終わりました。」（題が空なら「〇〇さん、お願いされていた件、終わりました。」）
    static func text(what: String, from: String?) -> String {
        let name = cleanName(from)
        let title = shortTitle(what)
        let body = (title.isEmpty ? "お願いされていた" : title + "の") + "件、終わりました。"
        return name.isEmpty ? body : name + "さん、" + body
    }

    /// 項目の文から、返事に入れる短い題を作る（1行目・句点を落とす・長ければ「…」）
    static func shortTitle(_ what: String) -> String {
        let firstLine = what.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var title = firstLine
        while let last = title.last, "。．.！!？? 　".contains(last) { title.removeLast() }
        if title.count > maxTitle { title = String(title.prefix(maxTitle)) + "…" }
        return title
    }

    /// 名前の後ろの敬称（さん・様など）は外す（あとで「さん」を付けるため）
    static func cleanName(_ name: String?) -> String {
        var n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for honorific in ["さん", "様", "先生", "くん", "君", "ちゃん"] where n.hasSuffix(honorific) && n.count > honorific.count {
            n = String(n.dropLast(honorific.count))
            break
        }
        return n
    }
}

/// 済みにしたあとに出す、返事の下書き（コピー・共有。自動では送らない）
struct TaskReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: TaskReply.Draft
    @State private var text: String
    @State private var copied = false

    init(draft: TaskReply.Draft) {
        self.draft = draft
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        Form {
            Section {
                TextField("返事", text: $text, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("頼んだ人への返事の下書き")
            } footer: {
                Text("直してから使えます。アプリからは送りません。コピーして、いつもの連絡の道具に貼ってください。")
            }
            Section {
                Button(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                ShareLink(item: text) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("済みにしました")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
        }
    }
}
