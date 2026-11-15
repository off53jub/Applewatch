# 重い所の見直し（2026-11-16・強化案 74）

v18（`docs/v18-crash-disk.md`）の落ちと書き込み過多と同じ形が、ほかに残っていないかを LifeLog/ の全部で探した。
v18 で直したもの（聞き間違いかもの 30 日読み・SpeakerLabeler・RecordingLedger・ConversationLog の外した行・Latency・AudioArchive）は触っていない。

形は 2 つ。

1. 画面を描く所（`var body: some View`・`-> some View` の関数）で、ディスクを読む・何日も見る。裏に回るときの描き直しが 10 秒を超えると、iOS に落とされる。
2. 小さく変わるたびに、ファイルを丸ごと書き直す（区切りごと・行ごと・送るたび）。

回数の見積もりは、区切りが 5 分ごと（1 時間に 12 個ほど）として。【見積もりで、測ってはいない】

## 1. 画面を描く所で読む

| どこ | 何をしていたか | 回数の見積もり | どうした |
|---|---|---|---|
| `ContentView.body` → `fixBadge` → `namelessVoiceCount` → `broadcastLike`・`crowdLike`（VoiceClues.swift） | 下のタブの「直す」の数字のために、直近 14 日を 2 回読む（1 分は覚えている） | いちばん外の画面なので、何かが変わって描き直すたび。1 分たっていれば毎回。裏に回るときの描き直しにも入る | 直した。描く所は覚えている答えだけを返す `skipVoicesForView`。古ければ裏で 1 日ごとに譲りながら 14 日を 1 回だけ読み、終わったら描き直させる（`VoiceSkipBook`） |
| `UnnamedVoicesView`（人物Nを整理）の `unnamed`・`dayCaption` | 描くたびに上と同じ 14 日 × 2 と、行ごとにその日を読み直す | 画面を開いているあいだ、再生の様子が変わるたび | 直した。テレビ・大勢の場の声は `skipVoicesForView`、その日は 1 回だけ読んで行に渡す |
| `MisheardView.lineRow` → `currentLine` | 行ごとに、その日の記録を読んで全部の行を並べ直す | 画面を開いているあいだ、描き直すたび（行の数 × ） | 直した。`.task` で 1 日 1 回だけ読む `currentLines` の答えを @State に置く |
| `ContentView`・`FixView` の `.task(id: 声のひとこま)` → `voiceReview` → `sampleInfo` | 描く所ではないが、すべての日を譲らずに読む（そのあいだ画面が止まる） | 声のひとこまが変わるたび（区切りを聞き分けるたびに変わりうる）。2 か所 | 直した。`voiceReviewCount` が 1 日ごとに譲り、途中で声が変われば止めて数え直す |
| `TodayView.body`・`FixView.body` の `conversations(on: 今日)` | 今日の 1 日だけ | 描くたび | 残した。アプリが書いたあとは中の写しを使い、ファイルは書いた時刻を見るだけ。印 `body-read-ok` を付けた |

描く所ではないが、開いたときにすべての日を譲らずに読む所も残っている（人の画面の `.onAppear` の `sampleInfo`・`voiceReview`、
外しすぎた行の `overRemoved`、人物Nを整理の `voiceClues`、まとめるときの `lineTimes`）。開いたときだけなので今回は残した。

## 2. 丸ごと書き直す

| どこ | 何を書いていたか | 回数の見積もり | どうした |
|---|---|---|---|
| `CloudLog.add`（書き込み時間の 2.5%） | 送るたびに 90 日分を読んで書き直す | 送るたび（区切りごとに数回） | 直した。中の写しに足し、2 分まとめて書く |
| `WatchDelayLog.received`・`processed`・`dropped`（4.1%） | 2400 件を書き直す | 時計の区切りごとに 2〜3 回 | 直した。2 分まとめて書く（記録には影響しない控え） |
| `NoiseLog.add` | 2000 件を書き直す | 区切りごとに 1 回 | 直した。2 分まとめて書く（記録には影響しない控え） |
| `Tally.add`（NightReport.swift） | 35 日分の数を書き直す | 区切り・行ごとに何回も | 直した。中の写しは前からあったので、ファイルには 2 分まとめて書く |
| `SearchIndex.replace`（`refreshSearchIndex`） | 区切りの処理のたびに、今日の行を索引から全部消して入れ直す（SQLite） | 区切りごとに 1 回 | 直した。区切りの処理からは 15 分に 1 回まで。探す画面は探す前にいつも入れ直す（AskViews.swift）ので、探した答えは古くならない |
| `MergeLog.add`（4.5%。`mergePerson`） | まとめるたびに 500 件（声の特徴つき）を書き直す | 会話が閉じて同じ人をまとめるたび・夜の整理で 30 組まで | 残した（下） |

アプリが裏に回ったときは、待っている分をすぐ書く（`Pipeline.appMovedToBackground`。鍵で守る CloudLog と Tally は裏の糸で）。

### MergeLog を残したわけ

まとめた記録は、まとめを戻すための元の人（名前・声の特徴）を持っている。夜の整理（`tidyUnnamedVoicesIfDue`）は、
この記録にある声には触らない決まり。落ちて記録が消えると、戻せなくなるだけでなく、守るはずの声を夜の整理がまとめたり忘れたりしうる。
「登録を壊さない」に当たるので、すぐ書くままにした。減らすなら、1 つの会話で続けてまとめるときに 1 回で書くなど、記録を失わない形で。

## CI の見張り（`.github/scripts/swift_precheck.py` の 3）

画面の body（`var x: some View {`・`-> some View {`）の中で、決めた名前（`BODY_DENY`: `conversations(on:`・`recordedDays(`・
`currentLine(`・`misheardOccurrences(`・`broadcastLike(`・`crowdLike(`・`voiceReview(`・`sampleInfo(for:`・`Data(contentsOf:` など）を呼んでいたら落とす。
`.task`・`.onAppear`・`.onChange`・`.refreshable`・`Button` の押したとき・`Task` などのクロージャの中は見ない。
わざとなら、その行かすぐ上の行に `// body-read-ok: わけ` と書く。

- v18 の前の Misheard.swift（`misheardOccurrences` と `currentLine`）と、今回直す前の `currentLine`・今日の 1 日読み 2 か所は、これで見つかる（確かめた）。
- 名前で見るだけなので、間に別の関数をはさむと見えない（今回の `fixBadge` → `namelessVoiceCount` → `broadcastLike` がそれ）。
  重い関数を足したら、`BODY_DENY` に名前を足す。

## まだ分からないこと

- Swift の組み立ては Windows ではできない。組み立てと試験は CI で。
- どれだけ減るかは、入れてから MetricKit の書き込みの記録と、落ちた・固まった回数で比べる。
- まとめて書くものは、裏に回ったあと 2 分以内に iOS にアプリを止められると、その数分の控えを失う（どれも記録・登録ではない）。
- 「直す」の数字は、アプリを開いてすぐの数秒、テレビ・大勢の場の声も数に入ることがある（裏の数え直しが終わるまで）。
