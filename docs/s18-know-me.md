# s18「自分を知ってもらう」— アプリと家の PC の口（2026-11-19・担当 A）

母艦（D:\Lifelog）の作り手（M1 見立て・M3 自信の段）が `state/` に置く写しを、家の PC（`pc/knowme.py`）が確かめて返し、
アプリ（`LifeLog/KnowMe.swift`・`KnowMeViews.swift`）が見せる。答えは家の PC が母艦の `inbox/` に 1 行ずつ足す（`at` は PC が付ける）。
features の名前は `knowme`。写しが無いときは `{"available": false, "reason"}` で、アプリは空の表示のまま動く。

## 読む（GET）

| 道 | 元 | 中身 |
|---|---|---|
| `/know/hypotheses` | `state/know/hypotheses_for_app.json`（無ければ M1 の `state/know/h_*.json`。`h_names` と `private` は読まない） | 根拠のある見立てだけ。印「見立て（仮）」・`evidence[]`（M1 の `{text,when,source,ref}` と M3 の `{quote,day,conversation_start,line_time,…}` のどちらも）・`tier`/`confidence`（無ければ `state/tiers_for_app.json` の `h_<種類>:<id>` から） |
| `/know/questions` | 上の見立て（段が `ask`）・`state/profile_recheck_for_app.json`（M3 の 41）・`state/know/questions_for_app.json`（母艦の問い・省ける）・束（`knowme.BUNDLE`）・`state/know/drafts_for_app.json`（46 の下書き・省ける） | 4 つの列から順に 1 つずつ。答えた id は出さない（65）。飛ばしたものは列のうしろ |
| `/know/spot-checks` | `state/spot_checks_for_app.json`（M3 の 81。いちばん新しい週） | 週 5 件。答えは `POST /feedback` の kind `spot` |
| `/know/tiers` | `state/tiers_for_app.json`（M3 の 66） | `"<出力名>:<鍵>"` → `{tier, confidence, final, kind}` |

問いの形: `{"id","group","answer":"text"|"record"|"yesno"|"recheck","text","draft"?,"evidence"?,"current"?,"checked_on"?,"tier"?}`。
`group` は general（2）・notdo（8）・dislike（10）・respect（12）・adult（13 の 5 場面）・ask_friend（4）・family（30）・recheck（41）・hypothesis（61）。

母艦が下書き（46）を足すときの形（`state/know/drafts_for_app.json`）: `{"items":[{"question_id","draft"(≤400),"evidence"?,"confidence"?}]}`。
母艦が問いを足すときの形（`state/know/questions_for_app.json`）: `{"items":[{"id","group","answer","text","draft"?,"evidence"?}]}`。

## 送る（POST → 母艦の inbox）

| 道 | inbox | 1 行の形（`at` は PC が足す） | 案 |
|---|---|---|---|
| `/know/answer` | `know_answers.jsonl` | `{"id","kind":"question"|"draft","value":"answered"|"skip"|"ok"|"fixed","text"?,"group"?,"question"?,"day","by"}` | 2・46・65 |
| `/know/recheck` | `profile_recheck_answers.jsonl` | `{"id","value":"still"|"changed"|"outdated","note"}`（M3 の形） | 41 |
| `/feedback`（前から） | `app_feedback.jsonl` | kind `hypothesis`・`spot`（value `right`/`wrong`/`unsure`） | 1・61・62・81 |
| `/know/note` | `conversation_notes.jsonl` | `{"day","conversation_start","line_time"?,"text"}` | 7 |
| `/know/person-goal` | `person_goals.jsonl` | `{"day","person","pe"?,"text"}`（名前は本人のページのもの。まとめ・付け替えはしない） | 9 |
| `/know/why-wrong` | `why_wrong.jsonl` | `{"day","target":"ask"|"mother"|"hypothesis"|…,"reason":"fact"|"person"|"old"|"offtopic"|"tone"|"other","why"?,"head"?,"question"?}` | 42 |
| `/know/mark` | `recording_marks.jsonl` | `{"day","kind":"ask_friend"|"weekly_talk"|"family_childhood"|"other","start","end"?,"question_id"?}` | 4・11・30 |
| `/know/voice-fix` | `voice_fixes.jsonl` | 下の節 | 63 |
| `/mood/tap` | `mood_taps.jsonl` | `{"day","at","slot":"morning"|"night","mood":1〜5}`（`at` は押した時刻のまま） | 6 |

夜の気分は前からの「夜の10秒」（`POST /mood` → `mood.jsonl`）のまま。朝の 1 タップだけを `mood_taps.jsonl` に分けた（`mood.jsonl` を読む母艦の
スクリプトが energy・grip を前提にしているため）。

## 時計の「違う、〇〇さん」（63）— 家の PC の担当 P が読む形

時計の録音の画面の入力欄に話す → 時計が `transferUserInfo(["voiceFix": 言葉, "at": 秒])` → iPhone が、言った時刻より前 10 分（仮）の
いちばん新しい会話の行を添えて `POST /know/voice-fix`:

```json
{"text": "違う、〇〇さん", "said_at": "2026-11-19T10:02:00+09:00", "by": "watch",
 "near": {"conversation_start": "2026-11-19T09:50:00+09:00", "line_time": "2026-11-19T09:58:00+09:00",
          "speaker": "いまの話し手の名前", "text_head": "その行の頭 60 字", "audio": "区切りの音声の名前"}}
```

`inbox/voice_fixes.jsonl` の 1 行はこれに `at`（PC が受けた時刻）を足したもの。言葉の解釈（だれに直すか）と、直すかどうかは P の担当。
名前の自動の付け替えはしない（候補まで）。

## アプリの決まり（しきい値はすべて仮）

- 1 日 1 回: その日はじめて読んだときに上から 3 問を決め、その日は入れ替えない（`KnowMeRules.perDay`）。
- 今週の見立て: 週の頭に、○× を付けていないものから 3 つ（ask の段のものは今日の問いで聞くので、あとに回す）。
- 61: 自信の段が `auto` のものは聞かない。`tentative` を聞くかは `KnowMeRules.askTentative`（仮。初めは聞く）。自分の声の候補・話し手の疑いにも同じ決まりを当てる
  （`self_candidates:<id>`・`speaker_doubts:<日>|<会話の始まり>|<行の時刻>`）。
- 62: 1 日 1 通（20:30・仮）、通知の上に「はい・いいえ・わからない」。時計にもそのまま出て、時計で押せる。設定で切れる。
- 6: 朝の 1 タップは 5〜11 時（仮）、「今日」に出す。
- 11: 日曜 20:00（仮）に「5 分しゃべる振り返り」を促す（設定で切れる）。
- 57: 登録した場所の「職場」と「自宅」を CLMonitor で見張る（半径の下限 150 m・同じ場所は 6 時間に 1 回・どちらも仮）。
  職場: 「職場に着いたら録音を始めてみる」（初めはオフ）がオンなら録音を始めてみる。iOS は裏からの録音の開始を AudioRecordingIntent
  （ショートカット・Siri・コントロール）からしか許さないので、始められなかったら「録音を始める」ボタンの付いた知らせを出す。
  始められた・始められなかった回数は tally の `know.geo.bgrec.ok`・`know.geo.bgrec.fail`。確実に始めたいときは、ショートカットの
  オートメーション「職場に到着したとき」→ LifeLog の「録音を始める」。
  自宅: 「家に着いたら取り込みを急ぐ」（初めはオン）で、たまった区切りを文字にし、ためた答えを家の PC に送り、次の裏の処理を 1 分後から頼む。
- 48: ヘルスケアの 1 日分（ドライブの「LifeLog/ヘルスケア」→ 母艦の Process-HealthInbox.ps1）に、動いたエネルギー（active_energy）・
  エクササイズ（apple_exercise_time）・立った時間（apple_stand_time）・ワークアウトを足した。前に許可した人には、足した種類だけを 1 回聞く。
