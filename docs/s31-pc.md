# s31 家の PC 担当（s31p）: 文字と声の結びを配る口

2026-11-27・ブランチ `feature/s31-p`。取り決め K31-2（名前と形は共通の決まりのまま）。

## 作ったもの

新しいファイル `pc/s31plinks.py`。`pc/lifelog_pc.py` には 3 か所だけ足した（import・features・GET の道。口は `self.authorized()` の後ろ）。

### GET /links（オーナーの Bearer）

- `?day=YYYY-MM-DD`: 母艦の `state/s31_links_for_app.json` から、その日の links と、その日に出てくる people（`days` に含む人）を返す。
- `?person=<名前か person_id>`: その人だけの people。links は、その人の `link_ids` にあるもの、または書き手・話し手（`text.who`・`voice.speakers`）にその名前があるもの。
- 両方あれば両方で絞る。知らない日・人は空（`available: true`）。
- 返事: `{"version", "generated_at", "links", "people", "available": true}`。
- 母艦が無い・止めてある・ファイルが無い・大きすぎ（12 MB 超。仮）・壊れ・形が違う → `{"available": false, "reason": …}`（200）。
- day の形が違う・person が空か 100 文字超・day も person も無い → 400。
- 読むたびには開かない。`s27pwork._load` の覚え（更新時刻と大きさが同じなら使い回す）を使う。絞りは毎回、覚えた中身に対して行う。
- 記録（log）には何も出さない（この口は log を持たない）。

### features

`"links"`: 母艦のフォルダがあり、`state/s31_links_for_app.json` があり、止めていないとき。

### 止める切り替え

母艦の `state/s27_work_config.json` の `"s31p": {"links": false}`（無ければオン。s27p・s30p の切り替えとは別）。

## 試し

`pc/v31checks_s31p.py`（作りものの母艦）: 日・人（名前・id・両方）の絞り、無い日・知らない人、形違いの 400、無い・大きすぎ・壊れ・配列・母艦なし、覚え（読み直さない・変われば読み直す）、止める切り替え、実際の HTTP（鍵なし・違うで 401・合えば返す・features）、つなぎ方と道の名前のぶつかり。
`pc/v30checks_s30p.py` の `run_all` の最後から呼ぶ（v29 → v30 → v31 の鎖。CI の手順は増やしていない）。既存の v20〜v30 の checks もすべて通った。

## 仮・気づき

- 大きさの上限 12 MB・person 100 文字は仮。
- people の `link_ids` が空で名前も links に出てこない人は、links が空で返る。
- 母艦 s31m が作るファイルの形（K31-1）は読むだけで、欄の中身は検めていない（links・people が並びであることだけ確かめる）。
