# 大型アップデート 2（2026-11-07）— iPhone と家の PC（版 7）の決まり

本人が選んだ5つ（2026-11-07）:

1. 実機の不具合が自動で見つかるしくみ（実機の様子を PC へ送る・TestFlight の報告を PC で読む）
2. 時計の文字盤とウィジェットに中身を出す（App Group）
3. 家の PC から iPhone を起こす（APNs の見えない通知）と、録音が止まった知らせを「即時」にする
4. あなた向けの Whisper を毎週自動で学び直す（GPU の時間割も）
5. PC の大きい画面で記録を読む・直す（直した分は iPhone に戻す）

このファイルは、iPhone 側と PC 側を別々に作るための「やり取りの決まり」。食い違ったら、このファイルに合わせる。

## 共通

- PC の版は 7（`VERSION = 7`。上げるのはつなぐ人がやる）。`/hello` の `features` に、使えるものだけ
  `diag`・`push`・`records`・`edits`・`autotrain` を足す。iPhone は版ではなく features を見て使う。
- 合言葉は今と同じ（`Authorization: Bearer <合言葉>`）。画面（`/dash` の下）は今の Basic 認証・クッキー。
- JSON の日時は ISO 8601・UTC・ミリ秒つき（例 `"2026-11-07T06:58:25.123Z"`）。
  iPhone は `ISO8601DateFormatter`（`.withInternetDateTime, .withFractionalSeconds`）で書く。
  PC は「ミリ秒なし」「+09:00 のような時差つき」も読めるようにする。
- 日の名前は、アプリが使っている `yyyy-MM-dd`（端末の暦・時刻の日）。
- PC は受け取ったものを PC の外に出さない（記録・音声・診断・TestFlight の報告）。
- PC の置き場所は今と同じ `%LOCALAPPDATA%\LifeLogPC`（下では HOME と書く）。

## 1. 実機の様子 — `POST /diag`

iPhone（と iPad）が1時間に1回ほど・アプリを開いたとき・見えない通知で起きたときに送る。2MB まで。

```json
{
  "deviceID": "端末ごとの UUID（UserDefaults の pcDiagDeviceID。名前は入れない）",
  "device": "iPhone",
  "model": "iPhone17,1",
  "os": "26.1",
  "build": 154,
  "install": "testflight",
  "sentAt": "2026-11-07T06:58:25.123Z",
  "rows": [{"group": "端末", "name": "空き容量", "value": "12 GB", "ok": true}],
  "crashes": [{"kind": "crash", "at": "…", "detail": "…"}],
  "metrickit": [{}],
  "tally": {"2026-11-07": {"jobs.sent": 3}},
  "state": {
    "phoneRecording": true, "watchRecording": false, "watchHeartbeatAt": "…", "watchUnsent": 0, "watchBuild": 154,
    "queue": 2, "lastProcessedAt": "…", "lastChunkAt": "…", "nightlyDoneFor": "2026-11-06", "jobsPending": 1
  },
  "push": {"token": "16進", "environment": "production", "topic": "com.off53jub.lifelog", "team": "ABCDE12345"}
}
```

- `install` は `testflight`（TestFlight・App Store で入れた）・`sideload`・`other`。
- `rows` は「自己点検」の行と同じもの。**会話の中身・人の名前・メールアドレスは入れない**（Diagnostics の決まりと同じ）。
  `ok` は分からなければ null。
- `crashes` は CrashWatch の記録。`metrickit` は、まだ送っていない MetricKit の診断（`MXDiagnosticPayload.jsonRepresentation()` を
  そのまま JSON にしたもの）。合わせて 1MB まで。送れたら、送った分は iPhone から消す。
- `tally` は今日と昨日の数（NightReport の Tally）。
- `state` の項目は、分からなければ null か省く。
- `push` は通知の登録ができたときだけ。`environment` は TestFlight・App Store なら `production`、それ以外は `development`。
  `team` は Info.plist の `AppIdentifierPrefix`（`$(AppIdentifierPrefix)`。末尾の `.` は取る）。
- 答え: `{"ok": true}`。

PC は端末ごとに HOME/diag/<deviceID>/ に、最新（latest.json）・日ごとの履歴（YYYY-MM-DD.jsonl、60日分）・
MetricKit の診断（metrickit/…json）を置く。HOME/diag/summary.md に、人が読める今の様子と気になる所を書き直す
（この PC で動く Claude が読む）。見守りの画面に「実機の様子」を出す。

気になる所の例: 3時間 diag が来ない／24時間以内に落ちた・固まった／ok が false の行／
時計が録音中なのに watchHeartbeatAt が30分より前／録音中なのに lastChunkAt が60分より前。

### TestFlight の報告（PC だけ）

HOME/asc/ に App Store Connect の API キー（`AuthKey_<KEYID>.p8` と `config.json` の `{"key_id","issuer_id"}`）が
あるときだけ、1日に数回、TestFlight のスクショつき報告と落ちた報告を読んで HOME/feedback/ に置き、画面に出す。
キーは見守りの画面から入れられるようにする。GitHub など外には出さない（リポジトリは公開なので）。

## 3. 見えない通知 — PC → iPhone

- iPhone は起動したら `registerForRemoteNotifications()`（見えない通知は、通知の許可が無くても届く）。
  トークンは `/diag` の `push` で PC に渡す。
- PC は APNs の HTTP/2（本番 `api.push.apple.com`、開発 `api.sandbox.push.apple.com`）に、トークン認証（ES256 の JWT。
  kid = 鍵の ID、iss = team）で送る。鍵は HOME/apns/AuthKey_<KEYID>.p8（見守りの画面から入れるか、手で置く）。
- 見えない通知: `apns-push-type: background`、`apns-priority: 5`、`apns-topic: com.off53jub.lifelog`、
  中身 `{"aps":{"content-available":1},"lifelog":{"kind":"wake"}}`。
  `kind` は `wake`（取り込み・送り出しを進めて）・`job`（文字起こしができた。`"job":"<名前>"` つき）・
  `nightly`（夜の処理がまだなら進めて）・`diag`（様子を送って）。
- 試しの通知（画面のボタン）: `apns-push-type: alert`、`apns-priority: 10`、
  `{"aps":{"alert":{"title":"LifeLog PC","body":"テストの通知です（家の PC から届きました）"},"sound":"default"},"lifelog":{"kind":"test"}}`。
- PC が送るとき:
  - 文字起こしができた → `job`（同じ端末へは10分に1回まで）
  - 10分ごとの見回り: 最新の diag で録音中（phoneRecording か watchRecording）なのに、その端末から30分なにも来ていない
    → `wake`（1時間に2回・1日12回まで）
  - 3時間 diag が来ない → `diag`（1日4回まで）
  - 毎日 3:30 → `nightly`（1日1回）
  - APNs が 410（Unregistered）を返したら、そのトークンは使わない。
- iPhone は見えない通知を受けたら、25秒以内に終える: wake・job → 取り込み（processQueue）・PC の仕事の受け取り・
  記録と直しのやり取り（5）を短く進める。nightly → 夜の処理がまだなら、BGProcessingTask を今すぐで頼む。
  diag → 様子を送る。どれでも最後に `/diag` を送る（起きたことが PC に分かる）。
- 録音が止まった・時計の録音が届いていない、の知らせは `interruptionLevel = .timeSensitive`。

## 5. 記録 — `POST /records/<day>`・`GET /edits`・`POST /edits/ack`

### iPhone → PC: 記録

- `POST /records/<day>`。中身は `ConversationLog.SyncDay` を上の日時の決まりで JSON にしたもの（同期と同じ中身・閉じた会話だけ）。
  任意で `"audioNames": {"<Line.audio>": "<PC の仕事の名前>"}`（同じなら不要）。8MB まで。
- 送る日: PC とつながったときに、多くても10分に1回、前に送ってから変わった日（日ごとの時刻を UserDefaults に残す）。
  初めては、さかのぼって60日分を、1回に5日ずつ。職場の会話も送る（家の PC の中だけなので外に出ない）。
- 答え: `{"ok": true, "conversations": N, "lines": M}`。

### PC: 置き場所と音声

- HOME/records/<day>.json（来るたびに置き換え、1つ前を <day>.prev.json に残す）。
- 音声: iPhone が `DELETE /jobs/<名前>` したとき、消さずに HOME/audio/<日>/<名前> に移す。30日（設定で変えられる）か
  合計 30GB を超えた古いものから消す。`/jobs` を通らなかった区切りの音声は PC に無い（画面では「PC に音声がありません」）。
  Line.audio（聞き直し用の音声ファイル名）は、仕事の名前（`url.lastPathComponent`）と同じ。違う場合は audioNames で渡す。

### PC の画面（/dash の下・同じ合言葉）

日の一覧 → 1日の会話（時刻・見出し・要点・相手・場面、行ごとに時刻・話し手・文・印・確からしさ・再生）、
文字で探す・意味で探す（今の semantic を使う）、行の文を直す・行の話し手を変える。
話し手は、記録に出てくる名前と「自分」から選ぶだけ（新しい名前は作らない。名前のある人を統合・改名しない）。
直した分は「iPhone に送る前」「iPhone で直しました」「iPhone で直せませんでした（理由）」と出す。

### PC → iPhone: 直し

`GET /edits?after=<id>` → まだ当てていない直し（id が after より大きいもの、古い順）:

```json
{"edits": [{
  "id": 12, "day": "2026-11-07", "time": "2026-11-07T06:58:25.123Z", "kind": "text",
  "base": {"text": "直す前の文", "speaker": "田中", "speakerID": "p3"},
  "text": "直したあとの文", "speaker": null, "speakerID": null,
  "created": "2026-11-07T07:10:00.000Z"
}]}
```

- `kind` は `text`（文を直す）か `speaker`（話し手を変える。`speaker` は名前か「自分」。`speakerID` は分かれば）。
- iPhone は day と time（差が 1ms 未満）で行を探し、今の文と話し手が base と同じときだけ当てる。違えば
  `skipped`（理由「iPhone の記録が先に変わっていました」）。
  - text → `editText([TextChange(…, manual: true, by: "PC で直した")])`
  - speaker → アプリの中で本人が1行の話し手を直すときと同じしかた。名前のある人を新しく作ったり、まとめたり、
    名前を変えたりしない（名前の無い「人物N」も PC からは作らない）。
- 当てたら `POST /edits/ack {"results":[{"id":12,"status":"applied","reason":null}]}`（status は
  `applied`・`skipped`・`failed`）。答えは `{"ok": true, "updated": n}`（知らない id は数えない）。
  当てた日は、早めに `/records/<day>` を送り直す。
- `GET /edits` は1回に 500 件まで（続きの印は無い）。返ってきた最後の id を after にして、0件になるまで呼ぶ。
- 「自分」の speakerID は、いつも `me`。
- PC は、iPhone で当てた直しを、その日の記録が届き直すまで次の直しの base に入れる（記録が届くまでに作った直しが
  食い違いで飛ばされないように）。同じ行の直しが重なったときは、iPhone が読みに来る前なら同じ種類の新しいほうだけ残す。
- 同じ日に同じ時刻の行が2つあると、PC はその行を直せない（iPhone も、同じ時刻の行が2つあれば当てずに skipped）。
- 記録の日時を数で送ると 400。8MB は 8MiB として受ける。

## 2. 文字盤とウィジェット — App Group `group.com.off53jub.lifelog`

- iPhone アプリ・iPhone のウィジェット・時計のアプリ・時計のウィジェットの4つに App Group を付ける（project.yml）。
- 中身は `Shared/Widget/WidgetState.swift` の `WidgetState`（Codable）を、App Group の UserDefaults に1つ置く。
  iPhone 側と時計側で、それぞれの App Group に書く（iPhone と時計は別の入れ物）。
- iPhone: 録音中か・時計が録音中か・今日までと期限切れの頼まれごとの数・次の予定・最後に文字にした時刻・PC とつながるか。
- 時計: 録音中か・iPhone に送っていない数・頼まれごとの数・次の予定（iPhone から届く WatchInfo から）。
- 書いたら WidgetCenter で読み直してもらう（1分に1回まで）。予定の名前は `.privacySensitive()`（ロック中・手首を下ろしたときは隠す）。

## 4. 学び直しと GPU の時間割（PC だけ）

- 材料（HOME/personal/data）が 300 以上で、前に学び直してから 50 以上増えていたら、週に1回（初めは日曜 2:00〜6:00）、
  仕事が無いときに `train_personal.py` を自動で動かす。学び直しの部品（Python と torch など 5GB ほど）は、
  初めて要るときに HOME の下に自分で用意する。良くなったときだけ入れ替わる（今の train_personal.py のとおり）。
- GPU の時間割: 昼は文字起こしのモデル。夜（1:00〜6:00）に30分仕事が無ければ、文字起こしの GPU のモデルを下ろして、
  言語モデル（Ollama）と学び直しに GPU を空ける。仕事が来たら戻す（戻るまでは CPU のモデルで受ける）。
- `/train-status` に自動の様子（次の予定・前回の結果）を足す。見守りの画面にも出す。
