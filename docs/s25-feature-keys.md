# s25 機能の数の名前（K5・大2）

2026-11-24（s25 の A2）。母艦の `docs/features.md` の 31 の機能それぞれについて、アプリが「使った回数」を
tally の `feat.<slug>` に足す。slug は features.md の id のまま。

- 数え方: アプリの tally（`tally.json`）に右の列の名前が足されるたびに、同じ数を `feat.<slug>` にも足す（`Tally.add` の中。`S25UFeatures.slug(for:)`）。
  `app-watch` と `app-tv` だけは、その場所でアプリが直接足す。
- 届く道: 今までの様子（`POST /diag` の `tally`。直近 2 日の日ごと）にそのまま入る。家の PC の `%LOCALAPPDATA%\LifeLogPC\diag\<端末>\latest.json` と日ごとの jsonl で読める（M2 は読むだけ）。
- 数え始めは、この版が入った日から。前の日の分は今ある名前（`screen.*`・`notice.*`・`task.*`）で数える。
- 「使った」は、開いた・押した・答えた・機械が作った（見出し）を含む粗い数（仮）。効いたかどうかは features.md の指標と並べて本人が決める。
- 表を変えるときは `LifeLog/S25URules.swift` の `S25UFeatures.all` を直し、この表も直す（テスト `S25UTests` が 31 個・重なりなしを確かめる）。

| slug | 機能 | tally の名前 | 数える元 |
|---|---|---|---|
| app-record | 常時録音と文字起こし | `feat.app-record` | `work.lines` `other.lines` `screen.dayView` `screen.recordsDays` |
| app-watch | Apple Watch の録音を家の PC へ | `feat.app-watch` | 時計の区切りが iPhone に届くたび（Latency.noteChunk） |
| app-speaker | 話者の聞き分け | `feat.app-speaker` | `sameperson.merged` `sameperson.different` `sameperson.maybe.merged` `sameperson.maybe.different` `unnamed.named` `s21.quickReview.keep` `s21.quickReview.forget` `s21.selfVoice.yes` `s21.selfVoice.no` `spkdoubt.self` `spkdoubt.dismiss` `pc.speakerAccepted` `pc.speakerRejected` `screen.speakerDoubts` `screen.unnamedVoices` `screen.voiceReview` `screen.samePerson` |
| app-tv | テレビ・動画の見分け | `feat.app-tv` | 行を放送の行にしたとき（Pipeline.markMedia） |
| app-headline | 会話の見出しと1日のまとめ | `feat.app-headline` | `title.made` `title.filled` |
| app-tasks | 頼まれごと帳 | `feat.app-tasks` | `screen.taskBook` `screen.confirmBox` `task.bulk.rest` `promise.added` `s23.promise.notice.add` `s23.promise.today.*` |
| app-ask | 記録に質問する・探す | `feat.app-ask` | `screen.ask` `screen.unifiedSearch` `askmother.found` `askmother.none` `voiceAsk.answered` `voiceAsk.timeout` |
| app-stop-alert | 録音が止まったら知らせる | `feat.app-stop-alert` | `notice.opened.phone-stopped` `notice.opened.stopped` `notice.opened.watch-silent` `notice.opened.watch-not-recording` `notice.opened.not-recording` |
| app-weekly | 週のまとめ | `feat.app-weekly` | `weekly.shown` `screen.workWeek` |
| app-good | いいこと帳 | `feat.app-good` | `screen.goodThings` |
| app-learned | わかったこと帳 | `feat.app-learned` | `screen.facts` |
| app-location | 位置の書き出し | `feat.app-location` | `screen.places` `screen.placeMap` `screen.placePage` `screen.placePages` `screen.unnamedPlaces` `placeask.answered` `s23.placesNight.answered` |
| app-health | ヘルスケアの書き出し | `feat.app-health` | アプリでは数える口が無い（母艦の数で見る） |
| ms-line | LINE の自動保存 | `feat.ms-line` | アプリでは数える口が無い（母艦の数で見る） |
| ms-digest | 朝のまとめ（日次ダイジェスト） | `feat.ms-digest` | `morningSpeech.played` `screen.briefCompare` `notice.opened.brief` |
| ms-plaud-audio | PLAUD 音声の取り込み | `feat.ms-plaud-audio` | アプリでは数える口が無い（母艦の数で見る） |
| ms-plaud-text | PLAUD 公式の文字起こし | `feat.ms-plaud-text` | `plaudfill.viewed` |
| ms-drive | 母艦からドライブへの写し | `feat.ms-drive` | アプリでは数える口が無い（母艦の数で見る） |
| ms-today | 今日の三つ | `feat.ms-today` | `proposal.accept` `proposal.later` `proposal.never` |
| ms-todo | TODO の寿命・期限切れの整理 | `feat.ms-todo` | アプリでは数える口が無い（母艦の数で見る） |
| ms-decisions | 決定の寿命（未決に期限とデフォルト） | `feat.ms-decisions` | `decision.chosen` `screen.decisions` |
| ms-timeline | 1日の年表 | `feat.ms-timeline` | `timeline.fetched` `screen.moment` |
| ms-people | 人物ノート（いまの様子） | `feat.ms-people` | `screen.personPage` `screen.peoplePages` `screen.people` `prep.shown` |
| ms-spend | カードの利用速報・月次決算 | `feat.ms-spend` | `screen.money` `screen.unmatchedPayments` `screen.paypayShot` `paypayshot.sent` |
| ms-sleep | 睡眠プロキシ | `feat.ms-sleep` | アプリでは数える口が無い（母艦の数で見る） |
| ms-pledge | コスト誓約の突き合わせ | `feat.ms-pledge` | アプリでは数える口が無い（母艦の数で見る） |
| ms-browser | 閲覧履歴・PC の作業記録 | `feat.ms-browser` | アプリでは数える口が無い（母艦の数で見る） |
| ms-work | 仕事のまとめの写し | `feat.ms-work` | `screen.workDigest` `screen.workThreads` |
| ms-vocab | 言葉の登録の候補 | `feat.ms-vocab` | `screen.vocabulary` `bulk.vocab` |
| ms-board | 止まっていないか（この台帳の入力） | `feat.ms-board` | `screen.reflection` |
| ms-photos | 写真の索引 | `feat.ms-photos` | アプリでは数える口が無い（母艦の数で見る） |
