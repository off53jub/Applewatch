import XCTest
@testable import LifeLog

/// 知らせ・ウィジェットから開く画面（2026-11-12 のタブの組み替え。NoticeActions.swift の NoticeRoute）を確かめる。
final class NavRouteTests: XCTestCase {
    private func route(_ id: String) -> NoticeRoute? {
        NoticeRoute.route(identifier: id, title: "題", body: "本文")
    }

    func testTaskNoticesOpenTheTasksTab() {
        XCTAssertEqual(route("tasks-morning"), .tab(.tasks))
        XCTAssertEqual(route("tasks-due-abc"), .tab(.tasks))
        XCTAssertEqual(route(NoticePresenter.taskFoundID), .tab(.tasks))
    }

    func testTodayNotices() {
        XCTAssertEqual(route(MorningBrief.noticeID), .tab(.today))
        XCTAssertEqual(route(AppFeeds.noticePrefix + "line"), .tab(.today))
        XCTAssertEqual(route("signExpiry-24h"), .tab(.today))
        XCTAssertEqual(route("watch-silent"), .tab(.today))
        XCTAssertEqual(route("phone-stopped"), .tab(.today))
    }

    func testScreenNotices() {
        XCTAssertEqual(route("askQuestions"), .screen(.questions))
        XCTAssertEqual(route("good-tonight"), .screen(.goodThings))
        XCTAssertEqual(route("payments-monthly"), .screen(.money))
        XCTAssertEqual(route("cloud-monthly"), .screen(.cloudLog))
        XCTAssertEqual(route("review-nudge"), .screen(.reviewNudge))
        XCTAssertEqual(route("morning-check"), .screen(.diagnostics))
        XCTAssertEqual(route("home-pc"), .screen(.homePC))
        XCTAssertEqual(route("work-digest-reminder"), .digestImport(""))
    }

    func testProposalNoticeOpensTheProposalsScreen() {
        XCTAssertEqual(route(ProposalRules.noticePrefix + "2026-11-13"), .screen(.proposals))
        XCTAssertEqual(route("proposal-2026-11-14"), .screen(.proposals))
        XCTAssertEqual(NoticeRoute.kind(of: "proposal-2026-11-13"), ProposalRules.noticePrefix)
    }

    func testMeetingBriefKeepsTheText() {
        XCTAssertEqual(route("brief-1794034705-定例"), .note(title: "題", body: "本文"))
    }

    func testUnknownNoticeOpensNothing() {
        XCTAssertNil(route("something-else"))
    }

    func testWidgetLinks() {
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://tasks")!), .tab(.tasks))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://good")!), .screen(.goodThings))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://today")!), .tab(.today))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://fix")!), .tab(.fix))
        // Google のログインの戻り（別の住所）は渡さない
        XCTAssertNil(NoticeRoute.route(url: URL(string: "com.googleusercontent.apps.123:/oauth")!))
    }

    func testNoticeKindGroupsByPrefix() {
        XCTAssertEqual(NoticeRoute.kind(of: "brief-1-定例"), "brief-")
        XCTAssertEqual(NoticeRoute.kind(of: "askQuestions"), "askQuestions")
    }
}
