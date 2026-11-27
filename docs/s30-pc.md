# s30 家の PC 担当（s30p）: 共有したらすぐ作り直す口

2026-11-27・ブランチ `feature/s30-p`。取り決め K30-2（名前と形は共通の決まりのまま）。

## 作ったもの

新しいファイル `pc/s30pwork.py`。`pc/lifelog_pc.py` には、`s27pwork` と同じ入れ方で 4 か所だけ足した（import・features・GET の道・POST の道。どちらの口も `self.authorized()` の後ろ）。

### POST /work/digest（オーナーの Bearer）

- 体: `{"entries": [{id, day, text, sections, source, addedAt}, ...]}`
- 返事: `{"accepted": n, "run": "started"|"already"|"off", "available": true}`
- 検め（どれも仮）: 1 回 50 件まで・id は UUID・day は本当にある YYYY-MM-DD・text は文字で 1 件 200 KB まで（バイト数）・体は 12 MB まで（超えたら読まずに 413）。**1 件でも違えば全部 400**（半端に書かない）。同じ id が 1 回の中に 2 つあれば 1 件。
- 書く先: 母艦の `inbox/work_digest_push/<id小文字>.json`。1 件 1 ファイル。`.<id>….tmp` に書いて fsync → `os.replace`（原子的）。同じ id を送り直しても 1 件（置き換え）。書くのは id・day・text と、あれば sections・source・addedAt だけ。
- そのあと母艦の `scripts/Run-WorkNow.py --kick` を起こす。Python は askmother.py と同じ決まり方（config の `mothership_python`・環境変数 `LIFELOG_MOTHERSHIP_PYTHON`・`%USERPROFILE%\AppData\Local\Programs\Python\Python311\python.exe`）。窓なし（CREATE_NO_WINDOW）・低い優先度（BELOW_NORMAL_PRIORITY_CLASS）・切り離し（DETACHED_PROCESS）・作業フォルダは母艦・入出力は DEVNULL。
- `run` の決まり
  - `state/s30_worknow_state.json` が `running` で `started_at` が 10 分以内 → `already`
  - 起こして 20 秒以内（状態のファイルがまだ書かれる前の二重送り）→ `already`（この PC のメモリ内の印。仮）
  - `Run-WorkNow.py` か Python が見つからない、または起こすのに失敗 → `off`（ファイルは書く）
  - それ以外 → `started`
- 止める切り替え: 母艦の `state/s27_work_config.json` の `"s30p": {"push": false}`（無ければオン。s27p の切り替えとは別）。止めているときは**書かず** `{"accepted": 0, "run": "off", "available": false, "reason": …}`。母艦のフォルダが見つからないときも同じ。

### GET /work/run（オーナーの Bearer）

- `state/s30_worknow_state.json` を読むだけ。`{"state": "idle"|"running", "started_at", "finished_at", "ok", "available": true}`。
- 無い・壊れている → idle と null。時刻が ISO でない・ok が真偽でないときはその欄だけ null。余計な欄は返さない。
- running のまま古い状態は、そのまま返す（読むだけ。10 分より古い running は次の POST で起こし直す）。母艦が見つからなければ `available: false`。

### features

`"workpush"`: 母艦のフォルダがあって、止めていないとき。`Run-WorkNow.py` が無くても出す（ファイルは書けるため）。

## 記録（log）

仕事のまとめの文は出さない。`POST /work/digest: N 件を受け取り・起こし <run>（id 先頭 8 文字…）` と、断ったときの短い理由だけ。

## 母艦（s30m）との約束

- `Run-WorkNow.py --kick` は、起こされたらすぐ戻る形にしてほしい（この PC は切り離して起こし、終わりを待たない）。作業フォルダは母艦（`D:\Lifelog`）。
- `state/s30_worknow_state.json` の形: `{"state": "running"|"idle", "started_at": ISO, "finished_at": ISO|null, "ok": bool|null}`。走り始めに running と started_at を書くこと（二重起こしの抑えはこれを見る）。
- `inbox/work_digest_push/*.json` は母艦が取り込んだら片付ける（この PC は消さない）。

## 試し

`pc/v30checks_s30p.py`（58 項目の OK）。`v29checks_s29p.run_all()` の最後から呼ばれる（v25 → v26 → v27 → v29 → v30 の鎖。CI の手順は増やさない）。作りものの母艦を一時フォルダに作り、起こす所は `s30pwork.SPAWN` を差し替えて実際には起こさない。

- 受け取り・1 件 1 ファイル・一時ファイルが残らない・同じ id・記録に文が出ない
- 検め: 空・51 件・UUID でない・`../`・変な day・text の型・大きすぎ（バイト数）・壊れた JSON・体が大きすぎ（413）・良い 1 件のあとに悪い 1 件（1 件も書かない）・ちょうど 200 KB と 50 件は受ける
- 二重起こし（running 3 分前 → already・11 分前 → 起こす・直後 → already）・Run-WorkNow.py が無ければ off（ファイルは書く）・Python が無ければ off・起こし方の旗
- 止める切り替え・features・GET /work/run（idle・running・壊れた・形違い）
- 本物の Handler に HTTP でつなぐ: 鍵が無い・違うと POST も GET も 401（書かず起こさない）・合えば受ける・`/hello` の features に workpush。lifelog_pc を読み込めない PC（部品が無い）では「SKIP」と言って飛ばす。

この PC では `Python311` で全部通る。既定の `python` は numpy が無く v6checks を読めない（main でも同じ）。v25 の鎖を通したとき 1 回だけ「声22: 組のファイルが消えても…」が NG になったが、再実行 2 回は全部 OK・変更前の HEAD でも通る（並行セッションとの競り合いの仮説。この変更とは無関係）。
