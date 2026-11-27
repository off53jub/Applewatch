import SwiftUI

// s30 のタブ担当（S30T。2026-11-27）。下のタブを「今日・タスク・仕事・直す・記録」の 5 つにした決まり。
// 本人の言葉: 「記録とふり返りは統合でよい」「タスクの仕事部分も仕事タブに組み込む」「面談の 1 枚はいらない」。
// 画面は ContentView.swift（TabView・記録の上の切り替え）、仕事タブの中身は S30W 担当の `S30WTab`（S30WViews.swift）。
// くわしくは docs/s30-t.md。

enum S30TTabs {
    /// 下のタブの 1 つ
    struct Item: Equatable, Sendable {
        let tab: AppTab
        let title: String
        let symbol: String
    }

    /// 下のタブ（左から。前の「ふり返り」は記録の上の切り替えに入れた）
    static let bar: [Item] = [
        Item(tab: .today, title: "今日", symbol: "waveform"),
        Item(tab: .tasks, title: "タスク", symbol: "checklist"),
        Item(tab: .work, title: "仕事", symbol: "briefcase"),
        Item(tab: .fix, title: "直す", symbol: "tray.full"),
        Item(tab: .records, title: "記録", symbol: "books.vertical"),
    ]

    /// そのタブの名前と絵（下のタブに無い lookBack は記録のもの）
    static func item(_ tab: AppTab) -> Item {
        let shownTab = shown(tab)
        for item in bar where item.tab == shownTab { return item }
        return bar[0]
    }

    /// 下のタブで選ばれて見えるもの（前のふり返り＝ lookBack は記録へ）
    static func shown(_ tab: AppTab) -> AppTab {
        tab == .lookBack ? .records : tab
    }

    // MARK: 記録の上の切り替え

    /// 記録の上の切り替えを覚える名前（@AppStorage。前からの名前のまま）
    static let recordsPageKey = "recordsPage"

    /// 記録の上の切り替え（保存する値は文字のまま。前の 4 つはそのまま、右に「ふり返り」を足した）
    enum RecordsPage: String, CaseIterable, Identifiable {
        case days = "日ごと", people = "人", places = "場所", money = "お金", lookBack = "ふり返り"
        var id: String { rawValue }
    }

    // MARK: 知らせ・リンク・ショートカットから開く

    /// 開き方: 切り替えるタブ（nil は今のまま）・シートで開くもの（nil は閉じる）・記録の上の切り替え（nil は今のまま）
    struct Open: Equatable {
        var tab: AppTab?
        var sheet: NoticeRoute?
        var recordsPage: RecordsPage?
    }

    /// NoticeRoute をどう開くか（Pipeline.openRoute が使う）。
    /// - タブ: そのタブへ（lookBack は記録の「ふり返り」へ）
    /// - 仕事の画面（.work）: 仕事タブへ。仕事の入口（.home）はタブを切り替えるだけ。その先（案件・人・確かめ・お知らせ）は
    ///   仕事タブに切り替えてから、前と同じシート（S27WRootView）で開く。仕事タブにいるときの .home は前の一覧をシートで開く
    ///   （仕事タブの中から「前の一覧」を開く道として残す）
    /// - 仕事のまとめを取り込む（.digestImport）: 仕事タブに切り替えてから、取り込む画面をシートで
    /// - ほか: 今までどおりシートで（タブは変えない）
    static func open(_ route: NoticeRoute, current: AppTab) -> Open {
        switch route {
        case .tab(let tab):
            if tab == .lookBack { return Open(tab: .records, sheet: nil, recordsPage: .lookBack) }
            return Open(tab: tab, sheet: nil, recordsPage: nil)
        case .work(let link):
            if link == .home && current != .work { return Open(tab: .work, sheet: nil, recordsPage: nil) }
            return Open(tab: .work, sheet: route, recordsPage: nil)
        case .digestImport:
            return Open(tab: .work, sheet: route, recordsPage: nil)
        default:
            return Open(tab: nil, sheet: route, recordsPage: nil)
        }
    }

    // MARK: タスクタブ

    /// タスクタブに出す方（仕事のタスクは仕事タブへ。帳はそのまま。今日の三つなどタスクタブ以外の所は変えない）
    static let taskScope: TaskBook.Scope = .life

    /// タスクの知らせ（頼まれごと・期限）を押したとき、下に置くタブ。
    /// 知らせのタスクが全部仕事のものなら仕事タブ、1 つでも仕事以外があるか、見つからないときはタスクタブ
    static func tab(forTasks ids: [String], in items: [TaskBook.Item]) -> AppTab {
        var found = 0
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if !item.isWork { return .tasks }
            found += 1
        }
        return found > 0 ? .work : .tasks
    }
}

/// 下のタブの名前と絵（ContentView の TabView から。名前は UI テストがタブを探す文字でもある）
struct S30TTabLabel: View {
    let tab: AppTab

    var body: some View {
        let item = S30TTabs.item(tab)
        Label(item.title, systemImage: item.symbol)
    }
}
