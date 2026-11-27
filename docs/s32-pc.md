# s32 家の PC（担当 p）: 仕事の聞き取りを仕事に合わせる

2026-11-27。型の頭は `s32p`（K32-4）。動いている LifeLog PC の設定は変えていない。どれも候補・先頭のヒントだけで、記録の文・話し手は書き換えない。

## 作ったもの
| 案 | 中身 | 場所 |
|---|---|---|
| 知9 | 母艦の `state/s32_meeting_people_for_pc.json`（M2。`{"items":[{day,start,end,name,people}]}`）を読み、その会議の時間に入る声の「名前のある人かも」の近さに、出席者だけ `MEETING_BONUS`（0.03・仮）を足す。窓の外・出席者でない人・ファイル無しは何もしない。今の予定・場所・LINE の近さ（prior_bonus 0.02）とは大きいほうを取る | `pc/s32pwork.py`（`meeting_score`・`combine`）→ `pc/s22pc.py` の `prior_bonus` の最後 |
| 知7 | 職場の時間（`work: true` の仕事、または会議の窓に区切りの始まりが入る）の文字起こしのヒントの先頭に、仕事の言葉を `WORK_HINTS_MAX`（8・仮）まで。元: `vocab_for_app.json` の `sure: true`、`work_for_app.json` の `glossary` のうち `for_asr: true`（または `asr: true`。M2 が聞き取りに回す印）。印つきが先、その中は日数の多い順 | `pc/s32pwork.py`（`add_hints`）→ `pc/lifelog_pc.py` の `place_hints_for` の最後 |
| 知8 | 読み上げた番号を `numbers`（行の optional の欄。`[{text,value,start,end,cue}]`）で返す。文は変えない。規則は純粋な関数 `pc/s32pnumbers.py`（`find`・`annotate`）なので母艦 M2 からも読める | `pc/s32pnumbers.py` → `lifelog_pc.run_job` の judge のあと |
| 切り替え | 母艦 `state/s27_work_config.json` の `"s32p": {"meeting": false, "hints": false, "numbers": false}`（無ければ全部オン） | `s32pwork.switch` |

## 番号の規則（仮）
- 「さんのにーよんご」→ `3-245`、「まるいちのごのご」→ `①-5-5`（まる＋1〜9 は丸数字）。区切りは「の・ハイフン・ダッシュ」。数字の字（3）・漢数字も読みとまざってよい。
- 数字の読みが 3 つ以上、または 2 つ以上＋手がかり（番号・チケット・ケース・案件・ナンバー・番）があるときだけ。
- 月日時分円人件…が続くもの、十・百・千・万 がつながるものは外す。「し」「く」「よ」の 1 字の読みは使わない。
- 1 つの文で 12 件まで。

## 知っておくこと（仮説を含む）
- 既定の `whisper_hints` は `none`（2026-11-18 の本人の決定）なので、足した仕事の言葉が実際に効くのは、今は haas の hotwords 側（仮説。測っていない）。whisper に渡すモードにしたときは `CURRENT_MAX` の 40 の中。
- 「聞き取りに回す印」の名前（`for_asr`/`asr`）は M2 と決めていない（こちらの仮定）。M2 が別の名前にしたらここを合わせる。印の無い glossary は、`firm: true` だけでも拾う。
- `numbers` の欄をアプリが読むかは S32A 側の決め。出しても害はない（optional）。
- 会議の窓は「日付＋HH:MM」でこの PC の時刻。出席者名は記録に書かない（数だけ）。

## 試し
`pc/v32checks_s32p.py`（v31 の最後から呼ばれる）。会議の窓（中・外・重なり・ファイル無し・止める・壊れた行）、ヒントの並び、番号 26 例（正しく直す・直さない）、行の注釈、止める切り替え。既存の checks も全部通した（Python311）。
