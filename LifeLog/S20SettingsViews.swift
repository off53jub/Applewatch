import AppIntents
import AVFoundation
import Photos
import SwiftUI
import UIKit
import UserNotifications

// 設定と説明（s20 の 体5・体31〜37・次10・追1。2026-11-21）

/// 「設定」の「ふだん」のいちばん上: 場面のセット・見た目・寝ているあいだ・知らせ・説明
struct S20SettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(SceneSets.currentKey) private var current = ""
    @State private var changed: String?
    /// 場面のセットを出すか・よく使うと説明を出すか（引き算の版では分けて置く。2026-11-24。s25 の 大1。S25USimple）
    var showScene = true
    var showRest = true

    var body: some View {
        if showScene { sceneSection() }
        if showRest { restSections() }
    }

    @ViewBuilder
    private func sceneSection() -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(LifeScene.allCases) { scene in
                    let on = current == scene.rawValue
                    Button {
                        apply(scene)
                    } label: {
                        VStack(alignment: .leading, spacing: LL.Space.xs) {
                            Image(systemName: scene.symbol).font(.title3)
                                .foregroundStyle(on ? LL.bg : LL.accent)
                            Text(scene.label).font(.callout.weight(.semibold))
                                .foregroundStyle(on ? LL.bg : LL.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LL.Space.m)
                        .background(on ? LL.accent : LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scene.label + (on ? "（いま）" : "") + "。" + scene.note)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            if let scene = LifeScene(rawValue: current) {
                Text(scene.note).font(.caption).foregroundStyle(LL.dim)
            }
            if let changed {
                Label(changed, systemImage: "checkmark.circle").font(.caption).foregroundStyle(LL.good)
            }
            NavigationLink("場面ごとに変わるスイッチ") { SceneDetailView() }
        } header: {
            LLHeader(title: "場面のセット", symbol: "square.grid.2x2")
        } footer: {
            Text("押すと、その場面に合わせて下のスイッチをまとめて切り替えます。細かい設定は「くわしい設定」の奥にあります。")
        }
    }

    @ViewBuilder
    private func restSections() -> some View {
        Section {
            NavigationLink { AppearanceView() } label: { Label("見た目（暗い・明るい・アイコン）", systemImage: "paintpalette") }
            NavigationLink { SleepPauseView() } label: { Label("寝ているあいだは録音を休む", systemImage: "moon.zzz") }
            NoticeSettingsLink()
            NavigationLink { CompanionCardView() } label: { Label("一緒にいる人に見せる 1 枚", systemImage: "person.2.wave.2") }
        } header: {
            LLHeader(title: "よく使う", symbol: "star")
        }
        Section {
            NavigationLink { WhatsNewView(onClose: nil) } label: { Label("新しく入ったもの", systemImage: "sparkles") }
            NavigationLink { GuardMapView() } label: { Label("守りの 1 枚（どこにあり、どの AI に渡るか）", systemImage: "lock.shield") }
            NavigationLink { GlossaryView() } label: { Label("言葉の一覧", systemImage: "character.book.closed") }
            NavigationLink { OnboardingView(onClose: nil) } label: { Label("初めての入口（許可を 1 つずつ）", systemImage: "hand.wave") }
        } header: {
            LLHeader(title: "説明", symbol: "book")
        }
    }

    private func apply(_ scene: LifeScene) {
        let count = pipeline.applyScene(scene)
        current = scene.rawValue
        LLHaptic.done.play()
        changed = "\(scene.label)にしました（\(count) 個のスイッチ）"
    }
}

extension Pipeline {
    /// 場面のセットをまとめて切り替える（設定と「今日」から同じ道で。2026-11-25。s26 の 軽3）。変えたスイッチの数
    @discardableResult
    func applyScene(_ scene: LifeScene) -> Int {
        let values = SceneSets.values(for: scene)
        for (key, value) in values {
            switch key {
            case .stopAlerts: stopAlertsOn = value
            case .places: places.isOn = value
            case .batterySaver: chunkBatterySaver = value
            default: UserDefaults.standard.set(value, forKey: key.rawValue)
            }
        }
        UserDefaults.standard.set(scene.rawValue, forKey: SceneSets.currentKey)
        HolidayNudges.shared.sendWatchContext()
        Tally.add("s20.scene." + scene.rawValue)
        return values.count
    }
}

/// 場面ごとに変わるスイッチの表
private struct SceneDetailView: View {
    var body: some View {
        LLList {
            ForEach(LifeScene.allCases) { scene in
                Section {
                    let values = SceneSets.values(for: scene)
                    ForEach(SceneKey.allCases.filter { values[$0] != nil }, id: \.rawValue) { key in
                        LabeledContent(key.label, value: values[key] == true ? "オン" : "オフ")
                    }
                } header: {
                    LLHeader(title: scene.label, symbol: scene.symbol)
                } footer: {
                    Text(scene.note)
                }
            }
        }
        .navigationTitle("場面のセット")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 体5・追1 見た目

struct AppearanceView: View {
    @AppStorage(LLAppearance.key) private var appearance = LLAppearance.dark.rawValue
    /// 朝・昼・夜で地の色をわずかに変える（2026-11-22。s22 の 見20。初めはオン）
    @AppStorage(LLDayTint.key) private var dayTint = true
    @State private var icon: String?
    @State private var problem: String?

    var body: some View {
        LLList {
            Section {
                Picker("画面", selection: $appearance) {
                    ForEach(LLAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                LLHeader(title: "画面", symbol: "circle.lefthalf.filled")
            } footer: {
                Text("暗い画面が先（夜の青）。明るい画面も同じ色の意味で作っています。")
            }
            Section {
                Toggle("朝・昼・夜で地の色を少し変える", isOn: $dayTint)
            } header: {
                LLHeader(title: "地の色", symbol: "sun.horizon")
            } footer: {
                Text("朝（5〜10 時）は少し明るい紺、夕方は少し紫がかった紺、夜（20 時から）は深い紺にします。文字の読みやすさは変えません。変えたあとは、画面を開き直すと全部に効きます。")
            }
            Section {
                iconRow(nil, title: "夜の青（新しい）", file: "AppIcon")
                iconRow("AppIconClassic", title: "青い波（前の）", file: "AppIconClassic")
                if let problem { Text(problem).font(.caption).foregroundStyle(LL.warn) }
            } header: {
                LLHeader(title: "アイコン", symbol: "app")
            }
            Section {
                ForEach(Certainty.allCases, id: \.self) { c in
                    HStack {
                        Text("例の文").certainty(c)
                        Spacer()
                        CertaintyBadge(certainty: c)
                    }
                }
            } header: {
                LLHeader(title: "色の意味", symbol: "swatchpalette")
            }
        }
        .navigationTitle("見た目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { icon = UIApplication.shared.alternateIconName }
    }

    private func iconRow(_ name: String?, title: String, file: String) -> some View {
        Button {
            guard UIApplication.shared.supportsAlternateIcons else {
                problem = "この入れ方ではアイコンを切り替えられません"
                return
            }
            UIApplication.shared.setAlternateIconName(name) { error in
                Task { @MainActor in
                    if let error { problem = "切り替えられませんでした: " + error.localizedDescription } else { icon = name }
                }
            }
        } label: {
            HStack {
                RoundedRectangle(cornerRadius: 10).fill(name == nil ? LL.bg : Color(llHex: 0x1C5A9A))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: name == nil ? "waveform.badge.mic" : "waveform").foregroundStyle(name == nil ? LL.accent : Color.white))
                Text(title).foregroundStyle(LL.text)
                Spacer()
                if icon == name { Image(systemName: "checkmark").foregroundStyle(LL.accent) }
            }
        }
    }
}

// MARK: - 次10 寝ているあいだは録音を休む

struct SleepPauseView: View {
    @AppStorage(SleepPauseRules.enabledKey) private var on = false
    @AppStorage(SleepPauseRules.startKey) private var start = SleepPauseRules.defaultStart
    @AppStorage(SleepPauseRules.endKey) private var end = SleepPauseRules.defaultEnd
    @AppStorage(SleepPauseRules.focusSinceKey) private var focusSince = 0.0

    var body: some View {
        LLList {
            Section {
                Toggle("寝ているあいだは録音を休む", isOn: $on)
                    .onChange(of: on) { S20Hold.changed?() }
                if on {
                    DatePicker("休み始め", selection: minuteBinding($start), displayedComponents: .hourAndMinute)
                    DatePicker("休み終わり", selection: minuteBinding($end), displayedComponents: .hourAndMinute)
                    LabeledContent("集中モード（睡眠）", value: focusSince > 0 ? "オン（ショートカットから）" : "オフ")
                }
            } header: {
                LLHeader(title: "寝ているあいだ", symbol: "moon.zzz")
            } footer: {
                Text("初めはオフです。オンにすると、この時間のあいだ（と、集中モードの「睡眠」がオンのあいだ）は、iPhone と時計が書くのを休みます（マイクは聞いたまま・すぐ戻ります）。")
            }
            Section {
                Text("ショートカット App → オートメーション → 「集中モード」→「睡眠」→「オンになったとき」→ アクション「LifeLog の睡眠で休む」（オン）。同じように「オフになったとき」は（オフ）。")
                    .font(.callout)
                Text("ヘルスケアの睡眠の予定は、アプリから読む道が Apple から出ていないため、時刻か集中モードで決めます。")
                    .font(.caption).foregroundStyle(LL.dim)
            } header: {
                LLHeader(title: "集中モードとつなぐ（1 回だけ）", symbol: "moon")
            }
        }
        .navigationTitle("寝ているあいだ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func minuteBinding(_ value: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(value.wrappedValue) * 60)
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            S20Hold.changed?()
        })
    }
}

/// ショートカットの「LifeLog の睡眠で休む」（集中モードのオートメーションから呼ぶ。次10）
struct SleepFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "LifeLog の睡眠で休む"
    static let description: IntentDescription? = IntentDescription("集中モードの「睡眠」に合わせて、LifeLog の録音を休む・戻す。設定の「寝ているあいだは録音を休む」がオンのときだけ効きます。")
    static let openAppWhenRun = false

    @Parameter(title: "休む", default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(on ? Date.now.timeIntervalSince1970 : 0, forKey: SleepPauseRules.focusSinceKey)
        S20Hold.changed?()
        return .result()
    }
}

// MARK: - 体37 一緒にいる人に見せる 1 枚

struct CompanionCardView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var fullScreen = false

    var body: some View {
        LLList {
            Section {
                // 見せる 1 枚の見本（押すと全画面）
                Button {
                    fullScreen = true
                } label: {
                    VStack(spacing: LL.Space.s) {
                        Image(systemName: "waveform.badge.mic").font(.system(size: 30, weight: .light)).foregroundStyle(LL.accent)
                        Text("記録を取っています").font(.title3.weight(.heavy)).foregroundStyle(LL.text)
                        Text("止めてほしいときは、いつでも言ってください。").font(.caption).foregroundStyle(LL.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LL.Space.xl)
                    .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: LL.Radius.card).strokeBorder(LL.accent.opacity(0.5), lineWidth: LL.Stroke.thin))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                Button {
                    fullScreen = true
                } label: {
                    Label("見せる画面を開く", systemImage: "rectangle.inset.filled.and.person.filled")
                }
            } footer: {
                Text("一緒にいる人に「記録を取っています」と伝える 1 枚です。その場で、その人といるあいだ録音を休めます。")
            }
        }
        .navigationTitle("一緒にいる人に")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $fullScreen) {
            CompanionCard { fullScreen = false }
        }
    }
}

struct CompanionCard: View {
    @Environment(Pipeline.self) private var pipeline
    let onClose: () -> Void
    @State private var paused: String?

    var body: some View {
        VStack(spacing: LL.Space.xl) {
            Spacer()
            Image(systemName: "waveform.badge.mic").font(.system(size: 56, weight: .light)).foregroundStyle(LL.accent)
            Text("記録を取っています").font(.largeTitle.weight(.heavy)).foregroundStyle(LL.text)
            Text("会話を録音して、自分のふり返りのために文字にしています。\n止めてほしいときは、いつでも言ってください。")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(LL.dim)
            if let paused {
                Label(paused, systemImage: "pause.circle.fill").font(.headline).foregroundStyle(LL.good)
            }
            VStack(spacing: LL.Space.s) {
                Text("いまから休む").font(.caption.weight(.semibold)).foregroundStyle(LL.dim)
                HStack(spacing: LL.Space.s) {
                    ForEach(PersonPauseRules.choices, id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 時間") { pause(minutes) }
                            .buttonStyle(LLPillButtonStyle(filled: true))
                    }
                }
            }
            Spacer()
            Button("閉じる", action: onClose).buttonStyle(LLPillButtonStyle(tint: LL.dim))
        }
        .padding(LL.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LL.bg.ignoresSafeArea())
    }

    private func pause(_ minutes: Int) {
        let until = Date.now.addingTimeInterval(Double(minutes) * 60)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: PersonPauseRules.untilKey)
        S20Hold.changed?()
        LLHaptic.stopped.play()
        paused = until.formatted(date: .omitted, time: .shortened) + " まで休みます"
        Tally.add("s20.personPause")
    }
}

// MARK: - 体32 アップデートのあとの案内 1 枚

struct WhatsNewView: View {
    let onClose: (() -> Void)?

    var body: some View {
        LLList {
            Section {
                VStack(alignment: .leading, spacing: LL.Space.xs) {
                    Text("新しく入ったもの").font(.title2.weight(.bold))
                    Text("その場で入り切りできます。あとから「設定」でも変えられます。").font(.callout).foregroundStyle(LL.dim)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(WhatsNew.items) { item in
                Section {
                    WhatsNewRow(item: item)
                }
            }
        }
        .navigationTitle("新しく入ったもの")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
        .onAppear { UserDefaults.standard.set(WhatsNew.version, forKey: WhatsNew.seenKey) }
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNew.Item
    @State private var on = false

    var body: some View {
        HStack(alignment: .top, spacing: LL.Space.m) {
            Image(systemName: item.symbol).font(.title2).foregroundStyle(LL.accent).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(LL.dim)
            }
            Spacer()
            if let key = item.key {
                Toggle("", isOn: Binding(get: { on }, set: { value in
                    on = value
                    UserDefaults.standard.set(value, forKey: key)
                    S20Hold.changed?()
                    // 時計に伝える設定（寝ている時間の 5 分・強い守り）も送り直す（2026-11-22。s21）
                    S21Book.settingsChanged?()
                }))
                .labelsHidden()
            }
        }
        .onAppear {
            if let key = item.key { on = UserDefaults.standard.object(forKey: key) as? Bool ?? (item.defaultOn || item.id == "holiday") }
        }
    }
}

// MARK: - 体34 言葉をそろえる

enum Glossary {
    /// 内輪の言葉 → 分かる言葉（docs/s20-design.md と同じ）
    static let words: [(inner: String, plain: String, note: String)] = [
        ("区切り", "録音のひとまとまり", "時計と iPhone が 45 秒〜5 分ごとに区切って送る音声"),
        ("様子", "いまの状態", "録音しているか・電池・つながり"),
        ("札", "過ごし方の印", "休日の「ラーメン」「ドライブ」などの印（母艦が付ける）"),
        ("母艦", "家の PC の記録の本体", "D:\\Lifelog。まとめ・見立てを作る"),
        ("見立て（仮）", "AI の推測", "まだ本人が確かめていないこと。点線の枠で出す"),
        ("確かめ待ち", "答えると記録が正しくなる問い", "14 日で流れる"),
        ("便り", "朝夕にまとめた知らせ", "急ぎでない知らせを 1 日 2 回に"),
        ("帯", "1 日の時間の線", "なぞって時間を選ぶ"),
        ("多数決", "いくつかの聞き取りを比べて選ぶこと", "家の PC が複数のモデルの文を比べる"),
        ("写し", "家の PC から届いた最新の控え", "つながらないときは前の写しを出す"),
        ("休む場所", "録音を書かない場所", "家など。マイクは聞いたまま"),
        ("場面のセット", "スイッチのまとめ", "ふだん・休日・会議・旅行"),
    ]
}

struct GlossaryView: View {
    var body: some View {
        LLList {
            Section {
                ForEach(Glossary.words, id: \.inner) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(w.inner).font(.callout.weight(.semibold))
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(LL.dim)
                            Text(w.plain).font(.callout).foregroundStyle(LL.accent)
                        }
                        Text(w.note).font(.caption).foregroundStyle(LL.dim)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("画面の言葉は、右の分かる言葉に少しずつそろえています。")
            }
        }
        .navigationTitle("言葉の一覧")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 体35 初めて使う人の入口（許可は理由を付けて 1 つずつ）

struct OnboardingView: View {
    @Environment(Pipeline.self) private var pipeline
    let onClose: (() -> Void)?
    @State private var step = 0
    @State private var done: Set<Int> = []

    private struct Step {
        let symbol: String
        let title: String
        let why: String
    }

    private let steps: [Step] = [
        Step(symbol: "mic.fill", title: "マイク", why: "会話を録音して、文字にするために使います。録音は文字にしたあと iPhone から消えます。"),
        Step(symbol: "bell.badge", title: "知らせ", why: "録音が止まったとき・頼まれごとの期限の前に知らせます。急ぎでないものは朝夕にまとめられます。"),
        Step(symbol: "location.fill", title: "場所", why: "どこで話したかを見出しに添え、家では録音を休むために使います。"),
        Step(symbol: "figure.walk", title: "動き", why: "歩いている・電車に乗っている、を見出しに添えます。"),
        Step(symbol: "calendar", title: "カレンダー", why: "会議の題名と参加者を、聞き取りのヒントにします。"),
        Step(symbol: "heart.fill", title: "ヘルスケア", why: "睡眠と歩数を 1 日のまとめに添えます（書き込みはしません）。"),
        Step(symbol: "photo.on.rectangle", title: "写真", why: "会話の時間に撮った写真を、記録の横に並べます（送りません）。"),
    ]

    var body: some View {
        let s = steps[min(step, steps.count - 1)]
        VStack(spacing: LL.Space.l) {
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i <= step ? LL.accent : LL.line).frame(height: 4)
                }
            }
            .padding(.top, LL.Space.l)
            Spacer()
            Image(systemName: s.symbol).font(.system(size: 60, weight: .light)).foregroundStyle(LL.accent)
                .contentTransition(.symbolEffect(.replace))
            Text(s.title).font(.largeTitle.weight(.heavy)).foregroundStyle(LL.text)
            Text(s.why).font(.title3).multilineTextAlignment(.center).foregroundStyle(LL.dim)
            if done.contains(step) {
                Label("聞きました", systemImage: "checkmark.circle.fill").foregroundStyle(LL.good)
            }
            Spacer()
            Button {
                Task { await ask(step) }
            } label: {
                Text("許可をたずねる").frame(maxWidth: .infinity)
            }
            .buttonStyle(LLPillButtonStyle(filled: true))
            Button(step + 1 < steps.count ? "あとで（次へ）" : "おわる") { next() }
                .buttonStyle(LLPillButtonStyle(tint: LL.dim))
        }
        .padding(LL.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LL.bg.ignoresSafeArea())
        .navigationTitle("初めての入口")
        .navigationBarTitleDisplayMode(.inline)
        .animation(LL.Motion.state, value: step)
    }

    private func next() {
        if step + 1 < steps.count {
            step += 1
        } else {
            UserDefaults.standard.set(true, forKey: "s20.onboarded")
            onClose?()
        }
    }

    private func ask(_ i: Int) async {
        switch i {
        case 0: _ = await AVAudioApplication.requestRecordPermission()
        case 1: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case 2: pipeline.places.isOn = true
        case 3: await pipeline.motion.requestAccess()
        case 4: await pipeline.calendar.requestAccess()
        case 5: await pipeline.health.requestAccess()
        default: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        done.insert(i)
        LLHaptic.done.play()
        try? await Task.sleep(for: .milliseconds(500))
        next()
    }
}

// MARK: - 体36 守りの画面（何がどこにあり、どの AI に渡っているか）

struct GuardMapView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var claudeForWork = true

    var body: some View {
        let settings = pipeline.settings
        LLList {
            Section {
                row("iPhone の中", "録音（文字にしたら消す）・文字の記録・人と声の登録・言葉", "iphone", .fact)
                row("Google ドライブ", pipeline.email == nil ? "ログインしていない（送っていない）"
                    : "日ごとのドキュメント" + (pipeline.audioBackupOn ? "・音声の控え" : ""), "externaldrive.badge.icloud",
                    pipeline.email == nil ? .guess : .fact)
                row("家の PC", pipeline.homePC.isConfigured ? "録音の区切り・記録・答え（家の中か Tailscale で）" : "使っていない", "desktopcomputer",
                    pipeline.homePC.isConfigured ? .fact : .guess)
                row("Apple Watch", "録音の区切りを iPhone と家の PC へ", "applewatch", .fact)
            } header: {
                LLHeader(title: "どこにあるか", symbol: "externaldrive")
            }
            Section {
                row("文字起こし", settings.useCloud && settings.hasAPIKey ? settings.provider.name + "（クラウド）" : "iPhone の中・家の PC（外に送らない）",
                    "waveform", settings.useCloud ? .stopped : .fact)
                row("見出し・まとめ・質問", useClaude ? "Claude（家の PC 経由）" + (claudeForWork ? "・職場の会話も" : "・職場の会話は除く")
                    : "Groq か iPhone の中のモデル", "sparkles", useClaude ? .stopped : .fact)
                row("家の PC の中", "Whisper などの聞き取り・母艦のまとめ（家の PC の中）", "cpu", .fact)
            } header: {
                LLHeader(title: "どの AI に渡るか", symbol: "brain")
            } footer: {
                Text("琥珀の印は、外の AI に渡るものです。切り替えは「設定」の「ふだん」（Claude）と「くわしい設定」（文字起こし）にあります。")
            }
            Section {
                row("開くときに Face ID", UserDefaults.standard.bool(forKey: AppLock.key) ? "オン" : "オフ", "faceid", .fact)
                row("一緒にいる人のために休む", "「一緒にいる人に見せる 1 枚」から", "person.2.wave.2", .fact)
            } header: {
                LLHeader(title: "守り", symbol: "lock.shield")
            }
        }
        .navigationTitle("守りの 1 枚")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("guardMap")
    }

    private func row(_ title: String, _ value: String, _ symbol: String, _ c: Certainty) -> some View {
        HStack(alignment: .top, spacing: LL.Space.m) {
            Image(systemName: symbol).foregroundStyle(c == .stopped ? LL.warn : LL.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(value).font(.caption).foregroundStyle(c == .stopped ? LL.warn : LL.dim)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
