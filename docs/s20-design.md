# s20 デザインの決まり（方向 A「夜の青」。2026-11-21）

本人の言葉「A でいいかな。全部作ろう。デザインは凝って、機能はトークン意識して」。
番号は母艦に出した 体1〜体38・次1〜次22・追1〜追4。しきい値はどれも仮（データがたまったら測り直す）。
新しい言語モデルの呼び出しは作っていない（0 円の作り直しだけ）。

## 1. 色（体1・体5。`Shared/Design/LLTheme.swift` の `LL`）

静かな道具の顔: 黒に近い紺の地・青みのグレー・差し色は水色 1 色だけ。暗い画面が先（初めは「暗い」）、明るい画面も同じ意味で作る。

| 名前 | 暗い画面 | 明るい画面 | 使う所 |
|---|---|---|---|
| `LL.bg` 地 | #0B1220 | #F3F6FB | 画面のいちばん奥 |
| `LL.surface` 面 | #121A2B | #FFFFFF | 一覧の行・カード |
| `LL.surface2` 面2 | #18233A | #E9EEF6 | カードの中の一段上・押せる札 |
| `LL.line` 線 | #22304A | #D5DDEA | 区切り・枠 |
| `LL.text` 文字 | #E6EDF7 | #0E1726 | 確かなこと |
| `LL.dim` 薄い文字 | #8A9BB8 | #55657F | 補足・見立て（仮） |
| `LL.accent` 差し色 | #5BC8F5 | #11719F（s22 で #147FB3 から濃く） | 押せる所・確かめ待ちの枠（これ 1 色だけ） |
| `LL.warn` 琥珀 | #F2B24C | #985C0C（s22 で #A8660E から濃く） | 止まっている・注意・外の AI に渡るもの |
| `LL.danger` くすんだ赤 | #E26D6D | #B8403F | 危ない・消す |
| `LL.good` くすんだ緑 | #5FC79A | #1E7952（s22 で #22875C から濃く） | よかった（使う所を絞る） |

明るい画面の色は、白の上で読める濃さ（だいたい 4.5:1 以上）に下げた。書き方はシステムの色と同じ: `.foregroundStyle(.llDim)`・`LL.accent`。
見た目は 設定 →「見た目」で 暗い（夜の青）・明るい・iPhone に合わせる を選ぶ（`@AppStorage("llAppearance")`。初めは暗い）。

## 2. 意味（体1・体2。`Certainty`。`LifeLog/S20Rules.swift`・`DesignKit.swift`）

| 確かさ | 見た目 | 母艦の値から |
|---|---|---|
| 確か `fact` | ふつうの文字 | tier `auto`/`final`・見立ての `confirmed` |
| 見立て（仮）`guess` | 薄い文字＋点線の枠 | tier `tentative`・見立ての `alive` |
| 確かめ待ち `waiting` | 差し色の細い枠 | tier `ask`・見立ての `unknown` |
| 止まっている `stopped` | 琥珀 | 見立ての `weakened`・施策の `retire_candidate`/`unused` |
| 危ない `danger` | くすんだ赤 | 施策の `broken` |
| よかった `good` | くすんだ緑 | 施策の `live` |

画面では `.certainty(.guess)`（枠つき）と `CertaintyBadge(certainty:)`（小さな印）を使う。

## 3. 文字・余白・角・影・動き・振動

- 文字: システムの文字（SF・ヒラギノ）。数字は `monospacedDigit()`。見出しは太さで差をつけ、色では差をつけない（`LLHeader`）。Dynamic Type に合わせて大きさは名前（`.callout` など）で書く。主な部品に `accessibilityLabel`（体6）。
- 余白 `LL.Space`: 4・8・12・16・24。角 `LL.Radius`: 札 6・小さなカード 10・カード 16・大きなカード 22。線 `LL.Stroke`: 0.5・1・1.5・点線 [4, 3]。
- 影: 明るい画面だけ、ごく薄く（`llShadow()`）。暗い画面は線で分ける。
- 動き `LL.Motion`: 状態が変わる所だけ（録音の丸がゆっくり息をする・○× のカード）。「視差効果を減らす」がオンなら動かさない。
- 振動 `LLHaptic`（体21）: 始まった（iPhone 中・時計 start）／止まった（強・stop）／確かめて（選択・notification）／完了（success）／うまくいかない（error・failure）。

## 4. 部品（`LifeLog/DesignKit.swift`）

| 部品 | 中身 |
|---|---|
| `LLList`・`LLForm` | List・Form の代わり。地を紺、行を面にする。アプリの List・Form は全部これに置き換えた（78 + 34 か所） |
| `LLCard` | 一覧の外のカード。確かさで枠が変わる |
| `CertaintyBadge`・`.certainty()` | 確かさの見た目（体2） |
| `TagChip`・`TagRow`・`TagIcons` | 札の小さな絵（体4。ラーメン fork.knife・ドライブ car.fill・ゴルフ figure.golf・ダンス figure.dance・映画 film・ゲーム gamecontroller.fill・競馬 figure.equestrian.sports・飲み会 wineglass.fill・カラオケ music.mic・写真多め photo.on.rectangle.angled・遠出 map.fill） |
| `MiniBars`・`Sparkline`・`StatTile` | 小さなグラフ（体3。Swift Charts。最後の棒だけ差し色） |
| `LLEmpty` | 空の状態（何がたまると出るか） |
| `WhyButton`・`WhySheet` | 「なぜこうなった？」（体33。理由・根拠・違っていたら） |
| `LLPillButtonStyle` | 押せる大きな札（44pt 以上） |
| `CaptureDotView` | 録音の丸（体8。時計・iPhone・PLAUD） |
| `LLWidgetBackground`・`LLWidgetTitle` | ウィジェットの地と見出し（追2） |

## 5. 言葉をそろえる（体34。アプリの「言葉の一覧」と同じ）

| 内輪の言葉 | 分かる言葉 | 説明 |
|---|---|---|
| 区切り | 録音のひとまとまり | 時計と iPhone が 45 秒〜5 分ごとに区切って送る音声 |
| 様子 | いまの状態 | 録音しているか・電池・つながり |
| 札 | 過ごし方の印 | 休日の「ラーメン」「ドライブ」など（母艦が付ける） |
| 母艦 | 家の PC の記録の本体 | まとめ・見立てを作る |
| 見立て（仮） | AI の推測 | まだ本人が確かめていないこと |
| 確かめ待ち | 答えると記録が正しくなる問い | 14 日で流れる |
| 便り | 朝夕にまとめた知らせ | 急ぎでない知らせを 1 日 2 回に |
| 帯 | 1 日の時間の線 | なぞって時間を選ぶ |
| 多数決 | いくつかの聞き取りを比べて選ぶこと | 家の PC |
| 写し | 家の PC から届いた最新の控え | つながらないときは前の写し |
| 休む場所 | 録音を書かない場所 | 家など。マイクは聞いたまま |
| 場面のセット | スイッチのまとめ | ふだん・休日・会議・旅行 |

## 6. 画面ごとの決まり

- 今日（体7〜10）: 上は大事な 3 つ（録音の丸 3 つ・今日の三つ・確かめ待ちの数）。ほかのカードは「ほかのカード」に畳む。朝（5〜11 時）は予定の前・朝のまとめ・1 年前の今日（体27）、夜（19〜4 時）は夜の 10 秒・今日の問いを上に。休日は地図の線・写真・食べた物・歩数・札の「今日の休日」（体9）。
- 丸を押すと理由と直し方、実機の確かめの ○×（次16 の `state/device_checks.json`）。
- 確かめる（体11〜15・次3）: 「直す」のいちばん上と「今日」の数から。右に払うと「はい」、左で「いいえ」。「分からない」「あとで」をいつも置く。根拠は 1 タップ。同じ group の問いはまとめて答える。あと何日で流れるかを出す。答えで直った行の数は返ってきたときだけ。
- 知らせ（体16・17・19・次2）: 設定「急ぎでない知らせを朝夕の便りに」（初めはオフ・場面のセットで入る）。急ぎ＝ボタンのある知らせ・録音が止まった・期限・約束・署名の期限。便りは朝 7:30・夕 19:00（仮）、3 行の型（何が起きたか＝題／なぜか／押すと）。履歴は 7 日・題と種類だけ。その場で「この種類はもう要らない」（急ぎは止めない）。
- 時計（体20〜22）: 録音の画面に出すボタンは、よく使う 3 つ（押した回数の順）。ほかは「ほか」。文字盤の長方形は 録音中か・あと何時間録れるか（電池÷1 時間の減り。分からなければ 9%/時・仮）・確かめ待ちの数。
- ふり返り（体3・23〜26）: 上に数の小さなグラフ（録った時間・会話の 7 日・今月のラーメン（見立て））。休日のページ（雑誌の 1 ページ）・今月/今年の物語（めくって進む）・面談の 1 枚（A4 で印刷・共有）・検品表の通信簿（A/B/C/×・続ける/止める）。
- 記録（体28〜30・次11・12）: 1 日の帯（会話・録れた・休む場所・抜け）を指でなぞって範囲を選ぶ（5 分きざみ）。消す（何が消えるか・30 秒は取り消せる・家の PC にも消す頼み）・書き出す（文字.md・まとめ.md・音声を zip で共有シート）・印。探す窓（人・場所・日・言葉・質問）。
- 設定と説明（体31〜37）: 場面のセット（ふだん・休日・会議・旅行）、見た目とアイコン、寝ているあいだ（次10）、一緒にいる人に見せる 1 枚（30 分・1 時間・3 時間休む）、新しく入ったもの、守りの 1 枚（どこにあり、どの AI に渡るか。外の AI に渡るものは琥珀）、言葉の一覧、初めての入口（許可は理由を付けて 1 つずつ）。

## 7. 受け渡し（母艦 M・家の PC P）

アプリは家の PC の features に名前があるときだけ読む・送る（無いときは前の写しか空のまま動く）。送るものは MothershipOutbox にためて、つながったときに送る。

| 道 | features | 元・行き先 | 形 |
|---|---|---|---|
| GET `/review-queue` | `reviewq` | 母艦 `state/review_queue_for_app.json` | s20-items の形。省ける足し: `clips:[{label,path}]`（体12・家の PC の音の道）、上の段に `done:[{id,changed,note?}]`（体14） |
| POST `/feedback` | `feedback` | `inbox/app_feedback.jsonl` | `{"kind":"review","id","answer","at"}`（answer は yes・no・unsure・選んだ文・書いた文） |
| GET `/feature-check` | `featcheck` | `state/audit/feature_check_for_app.json` | s20-items の形 |
| POST `/feature-answer` | `featcheck` | `inbox/feature_answers.jsonl` | `{"id","keep","at"}` |
| GET `/device-checks` | `devchecks` | `state/device_checks.json` | `{"generated_at","checks":[{"id","name","ok":true/false/null,"note"?,"day"?}]}` |
| GET `/interview-sheet` | `interview` | 次20 の印刷できる html | html のまま（アプリが A4 で印刷・共有） |
| GET `/holiday-tags` | `holidaytags` | `state/holiday/tags.json` | そのまま（`_meta` は読まない。`tag` だけ使う） |
| POST `/records/<日>/forget` | `forget` | 家の PC の records と音声のその時間 | `{"from","to"}`（ISO 8601・時差つき） |
| POST `/know/mark` | `knowme` | `inbox/recording_marks.jsonl` | 帯の「印」: kind `other`・start・end（前からの形） |
| POST `/diag` の state | — | 体験の数字（体38） | `uxAnswerSeconds`（今日の中央値・秒）・`uxNotifShown`・`uxNotifOpened`・`uxNotifMuted`（止めた種類の名前）。どれも省ける |
| POST `/records/<日>` | — | 次15 | 電車の中の会話に `"vehicle":"train"`（inCar は付けない。乗り物の動き＋場所・場面に駅・電車・線） |

## 8. アイコン（追1）

`.github/scripts/make_icons.py` で描いて PNG に書き出す（Pillow）。新しい「夜の青」が `AppIcon`（iPhone と時計）、前の青い波は `AppIconClassic` として残し、設定の「見た目」から選ぶ（`setAlternateIconName`）。時計は代わりのアイコンを選べない（watchOS の決まり）。

## 9. ウィジェット（追2・追3）

ホーム画面のウィジェット（様子・やること・いいこと帳）は紺の地（`LLWidgetBackground`）と意味の色に。ロック画面・文字盤は iOS が色を決める。
録音中と会議の Live Activity は地を紺、Dynamic Island の縁を意味の色に。充電中（StandBy）に「LifeLog の今日のまとめ」（会話の数・録った時間・今日の三つ・確かめ待ち。systemSmall）。
