# 家の PC 側: 地名・場所で探す・聞き取りの測り直し（強化案 85〜135。2026-11-16）

番号と根拠の数は母艦の `docs/system-proposal-2026-11-13.md` の「追記 7」。ここは PC（`pc/`）の分。
母艦は**読むだけ**、ダウンロード・外への送信はしていない。例・テストの名前は全部作り物。測った道具は `pc/asrmeasure.py`。

## 1. 入れたもの（PR 本文と同じ）

| 案 | ファイル | 中身 | 既定 |
|---|---|---|---|
| 85 | `placehints.py` | 母艦の `state/places-index.json`（無ければ `places_for_app.json`）・年表の位置・予定の場所・PC の記録の place を読む。地名の辞書は `%LOCALAPPDATA%\LifeLogPC\gazetteer\*.tsv`（名前 TAB よみ TAB 種類）があれば使う。**どれも無ければ今のまま動く** | 読むだけ |
| 99 | `hintpolicy.py` | 仕事のヒントの先頭に、その時間にいた所 → 最寄りの駅 → 今日の予定の場所 → よく行く所（6 語まで）を足す | `"place_hints"` は **オフ** |
| 131 | `hintpolicy.py` | Whisper に渡すヒントを `"whisper_hints": "current"｜"none"｜"top10"` で選ぶ。**kotoba にはいつもヒントを渡さない** | 下の「5」で決めた値 |
| 100 | `placefix.py`・`nightreview.py` | 読み（かな）が近い地名を、夜の読み直しの「聞き間違いかも」と同じ形の候補にする（Claude 不要・勝手に直さない） | オン（`"place_fix": false` で止める） |
| 128 | `mothersearch_extra.py` | 意味の索引に 年表（位置・予定・決済・写真だけ・座標は消す）・予定・写真の読み取り・場所のノート・場所の台帳 を足す。会話の行は足さない | オン |
| 129 | `motherquery.py`・`askmother.py`・`lifelog_mcp.py` | 「聞く」の探し方に lookups（その時どこにいたか・1日の年表・場所で引く・約束・人と場所のページ）。MCP に 6 つ（読むだけ） | オン |
| 130 | `audioclip.py` | 答えの出どころに音声の所を付け、`GET /audio-clip` で切り出す。音声が無ければ「もう残っていません」と返すだけ | オン |
| 132 | `selective.py` | `"whisper_scope": "doubt"` で、haas が迷った区間だけ Whisper に回す | `"all"`（今と同じ） |
| 133・134・135 | `asrmeasure.py` | 測るだけ（作り込みは数が出てから） | — |

職場の会話の扱いは今のまま: 年表の「会話」の行はどの道具からも返さない（`lifelog_mcp.INCLUDE_WORK` が False のときは人と場所のページ・約束も返さない）。
`GET /night-review` の形は変えていない（地名の候補は `misheard` の 1 件として混ざり、保存ファイルにだけ `place_fix` の数が付く）。

## 2. 地名の聞き間違い（100）を実データの 14 日で当てた

母艦の場所の担当が 2026-11-16 20:33 に作った `state/places-index.json` は 155 件のうち 88 件が「話に出ただけ（kind mentioned・tier none）」で、
会話の中の語からそのまま台帳に入ったためノイズが多い（読みで照らすと、ふつうの語を地名に直す候補が出る）。

| 版 | 11/3〜16 の候補の数 | 見えたこと |
|---|---|---|
| 最初（読みの近さ 0.8 以上・台帳の全部） | 712 | 「東京→東京都」「一番下→一番市」のように、短い名前・名前の一部・ノイズの名前に当たりすぎ |
| 絞った版（いま） | 14（1 日 0〜4） | 話に出ただけの地名と推測の店を使わない・名前が語の一部（東京と東京都）は出さない・短い名前（読み 5 字以下）は同じ読み（漢字違い）だけ |

絞った 14 件を、語の組だけ見て（行は見ていない）分けると、駅名・町名の書き違いらしいもの（漢字違い・助詞の混ざり）が半分ほど、
ふつうの語に当たったもの（「〜行」「〜線」）が残り半分ほど【仮説。当たりの数は本人が「直す」を押した数で測る】。
**実際に直すかどうかは本人**（アプリの「聞き間違いかも」に出るだけ）。台帳が育って推測の名前が減れば当たりは上がる見込み。

## 3. 迷った所だけ Whisper（132）を、同じ 5,212 行で比べた

物差しは PLAUD との 5 分ごとの文字の合い方（表記 F。5,212 行・200 窓・合わせた参照 13.3 万字）。今の Whisper の文は実際に出した票（ヒント 40 語・これが「今」）。

| 形 | 表記 F | Whisper にかけた区間 | 全部の形との差（95% の幅） |
|---|---|---|---|
| 今（haas＋whisper を全部の区間） | 0.498 | 100% | — |
| haas だけ | 0.496 | 0% | −0.002 |
| **迷った所だけ**（haas だけが速いモデル。まばら・繰り返し） | 0.496 | 522 行・音声の **25.6%** | −0.0024（−0.0044〜−0.0004） |
| 迷った所だけ（haas＋reazon が速いモデル。食い違いも迷い） | 0.497 | 3,673 行・音声の 72.7% | −0.0017（−0.0032〜−0.0002） |

読み（かな）の F は 0.535（全部）／0.533（haas だけ・迷った所だけ・差の幅が 0 をまたぐ）。

読み方: 点は全部の形に 0.002 ほど届かない（測れる範囲で、haas だけと同じ）。GPU の Whisper の時間は 74% 減る（haas だけが速いモデルのとき）。
haas が何も書かなかった区間は、Whisper だけが書いた行を vote が作り話として捨てるので、かけても無駄（迷いにしない）。
設定の `"whisper_scope": "doubt"` は用意したが**既定は全部のまま**（点を 0.002 譲って GPU を空けるかは本人の判断）。

## 4. 133・134（測っただけ。PLAUD と重なる 16 録音）

- **133（PLAUD の話し手で声の見本を育てる）**: PLAUD と重なる録音は 16 本、PLAUD の話し手は 1 本あたり 1〜8 人。この PC の 1.5〜20 秒の行のうち、PLAUD の話し手の区切りに入るものが **2,843 行（19,353 秒）**。
  うち 1 人の話し手に収まる行は 2,973 件対 複数にまたがる行 500 件（86% が 1 人）。話し手ごと・録音ごとに 12 行以上たまる組が **43**（4 行以上は 57）、組の全部は 61。
  いま PC にある声の特徴は 7,857 個（6 日・話し手の名前は付いていない行が多い）。つまり先生にできるのは**今ある量の 36% ほどを「同じ人」の組にできる**量で、録音をまたぐ同一人物の判定は声の特徴で別にやる必要がある（PLAUD の話し手の名前は録音ごと）。作り込みは、PLAUD の重なりがもっと貯まってから。
- **134（時計・iPhone・PLAUD の良い所取り）**: PLAUD と重なる時間のうち、時計の区間は 22,966 秒・iPhone は 5,945 秒。PLAUD との読みの合い方は、時計 0.301（152 窓）・iPhone 0.333（64 窓）で、同じ窓に 3 つとも録れているのは **5 窓だけ**。
  良い方を採る上限（最良の方を窓ごとに選ぶ）は、5 窓では測れない。作らない（重なりが 30 窓以上になってから）。

## 5. 131・99: whisper のヒントの測り直し（夜の GPU）

2026-11-17 00:00 以降に `pc/asrmeasure.py run` を条件ごとに回した（`none`・`hint10`・`now`・`place`。同じ 5,212 行）。結果は追記する。

## 6. 135: あなた向けモデルを入れる前の物差し

`asrmeasure.py run --cond now --model <PERSONAL_MODEL のフォルダ> --tag mine` を、今の large-v3 の `now` と同じ 5,212 行にかけて、`score --conds now,mine` で比べる。
入れる条件（案）: 表記・読みの F が上がり、95% の幅が 0 をまたがず、haas＋whisper との比べで下がらない。全部の行で 30 分ほどの GPU（00:00〜05:00 に回す）。

## 7. 本人の手が要ること

- 地名の辞書（国の公開データ・OpenStreetMap）の入手と利用条件の確認（ダウンロードは未実施）。置き場所は `%LOCALAPPDATA%\LifeLogPC\gazetteer\*.tsv`
- `"place_hints"`・`"whisper_hints"`・`"whisper_scope"` の既定をどうするか（§3・§5 の数で）
- 音声の保存期間（130 は、無ければ「もう無い」と返すだけ）

## 8. アプリとつなぐ口（`placelinks.py`。強化案 89・90・136・137）

アプリの `docs/s16-place-links.md` が求める口を、PC に作った。母艦は**読むか、inbox/ の下に 1 行足すだけ**（`state/`・`archive/`・`people-index.md` は書かない）。
認証は今の GET/POST と同じ（`authorized()`）。読んで確かめてから足し、決まりに合わなければ何も書かずに 400（種類が違えば 422・問が見つからなければ 409）。
features: `placenames`・`checkups`・`linkfind`。

| 口 | 母艦のどこを | 返す・足す |
|---|---|---|
| `POST /place-names` | `inbox/place_answers.jsonl` に足す | 下の「名前直しの変換」 |
| `GET /checkups` | `state/place_quiz_for_app.json`・`state/name_candidates.json` を読む | アプリの列（下）。もう答えた問（inbox に答えがある）は出さない |
| `GET /link-candidates` | `state/link_night_candidates.json`（直近 3 日）と `digests/events/<日>.jsonl`（題）を読む | 同じ列で `kind: "link"`・`source: "night"`。切られた組・もう答えた組は出さない |
| `POST /checkups/answer` | 場所 → `inbox/place_answers.jsonl`／人 → `inbox/name_answers.jsonl`／繋がり → `inbox/link_feedback.jsonl` | 同じ問の 2 回目は足さない（`duplicate: true`） |

**列の形**（`GET /checkups`・`GET /link-candidates`）: `{"available", "generated_at", "items": [{"id", "kind", "title", "detail", "weight", "day", "pl", "pe", "text", "options": [{"id", "label"}], "source"?}]}`。ファイルが無ければ `{"available": false, "items": []}`。
- 場所の問: `id` は母艦の `pq_YYYYMMDD_HHMM`。`kind` は現在の段が none なら `place_unnamed`、そうでなければ `place`。`options` は候補 `c0`〜`c2`（母艦の `candidates` の順）と `not_place`（場所ではない）。`text: true`。`weight` は分数の半分（最大 1000）。
- 人の問: `id` は `nc_…`。`options` は候補の人の番号 `pe_…`（3 人まで）と `none`（どれでもない）。選べる候補が無い問は出さない（アプリが答えられないので）。`weight` は件数。
- 繋がりの問: `id` は `lk:<ev_a>:<ev_b>`（順不同）。`options` は `yes`・`no`。題は出来事の表の題（先頭 40 字ほど）をそれぞれ 24 字まで。

**答えの変換**:
- 場所の答え → 母艦の答え合わせの答えの形 `{id, day, start("HH:MM"), name, choice(candidate|typed|not_place), at}`（`from: "checkup"` を足す。`value` が `c0` なら候補の 1 番目の名前で `candidate`・`text` なら文字で `typed`・`not_place` は名前を空にして `not_place`）。`skip`（あとで）は何も書かない。
- 人の答え → `inbox/name_answers.jsonl`: `{"id", "verdict": "yes"|"no", "pe", "at", "by": "app"}`（母艦の `state/name_answers.json` の items と同じ形。`none` は `no`・`pe` は null）。**母艦は読んで people-index に反映するかを自分で決める（PC は書かない）**。
- 繋がりの答え → `inbox/link_feedback.jsonl`: `{"a", "b", "verdict": "sure"|"cut", "at", "by": "app"}`（母艦の `state/link_feedback.json` の items と同じ形。`yes` が sure・`no` が cut）。**この jsonl を `state/link_feedback.json` に取り込むのは母艦側の仕事**（新しいファイルの名前: `inbox/name_answers.jsonl`・`inbox/link_feedback.jsonl`）。

**名前直しの変換**（`POST /place-names` の本文 → 答え合わせの答えの形）:
- アプリの本文 `{name, lat, lon, pl, from, day, at}` のうち、`name` だけが必須。`lat`・`lon` は両方か両方なし。
- 母艦の答え合わせの材料に、**同じ日で 150 m 以内**の問があれば、その問の `id`・`start` を使う（母艦が同じ滞在に戻せる）。なければ `id` は `pn_` ＋ 10 文字の hash、`start` は `at` の時刻（HH:MM）。
- 足す 1 行: `{id, day, start, name, choice: "typed", at(PC が受けた時刻), from(conversation|page|registered|watch|visit|checkup|app)}` に、あれば `lat`・`lon`（5 桁）・`pl` を足す。
- 場所のページの直し（`pl` だけ・`lat`/`lon` なし）は、母艦の `apply_answers` が日・時刻で滞在に戻せない。**`pl` の欄を見て台帳の名前を「確か」にするのは母艦側の仕事**（PC は欄を付けて足すだけ）。

## 9. 地名の辞書: 駅の GeoJSON も読む

`%LOCALAPPDATA%\LifeLogPC\gazetteer\` の `*.tsv`（名前 TAB よみ TAB 種類）に加えて、母艦の `scripts/gazetteer.py` と同じ国土数値情報 N02 の駅の GeoJSON（`stations\*.geojson` か直下の `*.geojson`）も読む。
駅名（N02_005。重なりをまとめて 8,504 駅）に「駅」を付けた名前にして、読み（かな）は PC が pykakasi で作る。
辞書の名前は数が多いので、聞き間違いの候補は**読みが同じで漢字が違う語**（名前と 1 字は同じ字がある）だけにした
（読みが近いだけだと、全国の駅では「正直→少路駅」のようにふつうの語に当たりすぎた。11/3〜16 の候補は辞書を入れても 14 件のまま）。
