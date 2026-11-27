import Foundation
import Observation

// s32（2026-11-27）アプリ担当 S32A の動き。決まりは S32ARules.swift、画面は S32AViews.swift。
// - 知15 1 押しの「違う」（K32-3）: POST /feedback に {"kind":"work_fix","id","what","value","day"} を 1 つためて送る
//   （S27WBook の work_done と同じ道＝MothershipOutbox。家の PC が inbox/app_feedback.jsonl に 1 行足す）。
//   押したものは端末に覚え、仕事タブの見え方をすぐ変える（薄く・済んだ／自分の番でないものは取り消し線・「伝えました」の 1 行）。
//   「戻す」は端末の見え方だけ戻す（母艦に戻しの種類はまだ無いので送らない。S30W の箱から戻すのと同じ）。
// 知らせ・問いは足さない。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S32ABook {
    static let shared = S32ABook()
    static let fixesKey = "s32a.fixes"

    /// 項目の id → 直し
    private(set) var fixes: [String: S32AFix]

    init() {
        let saved: [String: S32AFix] = UserDefaults.standard.data(forKey: Self.fixesKey)
            .flatMap { try? JSONDecoder().decode([String: S32AFix].self, from: $0) } ?? [:]
        let kept = S32ARules.keptFixes(saved, today: ReviewRules.dayKey(.now))
        fixes = kept
        if kept != saved { save() }
    }

    func fix(for id: String) -> S32AFix? { fixes[id] }

    /// 「違う」を 1 つ送り、端末に覚える。送れる形でなければ false
    @discardableResult
    func send(_ item: S27WItem, what: S32AFixKind, value: String? = nil, valueName: String? = nil, now: Date = .now) -> Bool {
        let day = ReviewRules.dayKey(now)
        guard let body = S32ARules.fixBody(id: item.id, what: what, value: value, day: day) else { return false }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        Tally.add("s32a.fix." + what.rawValue)
        if let pipeline = S27WBook.pipeline { Task { await MothershipOutbox.send(pipeline.homePC) } }
        fixes[item.id] = S32AFix(what: what, value: value, valueName: valueName, day: day)
        save()
        return true
    }

    /// 端末の見え方だけ戻す（送らない）
    func undo(_ id: String) {
        guard fixes[id] != nil else { return }
        fixes[id] = nil
        save()
        Tally.add("s32a.fix.undo")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(fixes) { UserDefaults.standard.set(data, forKey: Self.fixesKey) }
    }
}
