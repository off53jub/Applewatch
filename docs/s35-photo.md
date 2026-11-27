# s35 仕事のまとめの写真そのものも家の PC へ（K35・2026-11-28）

## なぜ

仕事のまとめの写真は、iPhone の中の Vision（`Pipeline.recognizeText`）で文字にして `POST /work/digest` で送っていた。
この読み方は画面の折り返しで項目がちぎれる（11/27 の分は 286 行のうち 160 行が続きの行だった）。
そこで、**写真そのものも家の PC に送り、母艦で Claude に書き起こさせる**。母艦の側（Claude で読む段）は別の担当が作る。
この回で作ったのは、iPhone から送る所と、家の PC が受けて母艦に置く所だけ。

## 取り決め K35（名前と形を変えない）

### POST /work/photo（家の PC・`pc/s35pwork.py`）

- オーナーの Bearer。1 枚ずつ。
- 体: `{"id": まとめの id（POST /work/digest と同じ）, "day": "YYYY-MM-DD", "index": 0 から, "count": 枚数, "jpeg_b64": "..."}`
- 検め（外れたら 400）: id は UUID・day は本当にある日・count は 1〜12・index は 0 以上 count 未満・
  jpeg_b64 は base64 で、デコードしたあと 3MB まで・中身は JPEG の頭（FF D8）で始まる。体が大きすぎれば 413。
- 置き場: `<母艦>/inbox/work_photo/<id>/<index>.jpg` と `<母艦>/inbox/work_photo/<id>/meta.json`
  （`{"id","day","count","received":[index…],"at"}`）。id は小文字（`POST /work/digest` の inbox のファイル名と同じ）。
  どちらも一時ファイルに書いてから入れ替える。
- count 枚がそろったら `POST /work/digest` と同じ起こし方（`s30pwork.kick` → `Run-WorkNow.py --kick`。二重起こしの抑えも同じ）。
- 返事: `{"ok":true,"have":そろった枚数,"count":n,"run":"started"|"already"|"off"|"waiting"}`（そろっていなければ waiting）。
- 同じ番号の送り直しは置き換え（二重に数えない）。同じ id で count か day が前と違えば、新しい組として数え直す
  （前の received を捨て、count 以上の番号の写真は消す）。
- 止めてある（`state/s27_work_config.json` の `"s30p": {"push": false}`）・母艦が無いときは、書かずに
  `{"ok":false,"have":0,"count":0,"run":"off"}`。
- features `"workphoto"` は、母艦の置き場があって止めていないときだけ（`workpush` と同じ決まり）。
- 記録（log）には id の頭 8 字と枚数だけ。写真・文字は書かない。

### アプリ（`LifeLog/S35PhotoRules.swift`・`LifeLog/S35PhotoBook.swift`）

- 送る所は 3 つ。どれも今の `POST /work/digest` の流れ（`S30WBook.saved` → `push`）に乗るだけ。
  1. 取り込む画面（`WorkDigestImportView.readImages` で読んだ写真 → `save` で `loosePhotos`）
  2. ショートカットの「仕事のまとめを取り込む」（`ImportDigestIntent.perform` → `DigestInbox.putPhotos` → 取り込む画面）
  3. s34 の写真から自動で拾う（`S34APhotoScan.scan` → 組ごとに `photos[まとめの id]`）
- 送る順: **Vision の文を先に** `POST /work/digest`。届いたあと、家の PC の features に `"workphoto"` があれば、
  同じ id で写真を `POST /work/photo` に 1 枚ずつ（まとめの順・番号の順）。PC が Claude で読めなくても、今の形は残る。
- 何日分かに分かれたまとめ（【日付】が 2 つ以上）は、写真を**最初の 1 件の id**にだけ付ける（仮）。
- 縮め方: 長い辺を 2000px 以下（大きくはしない）・JPEG の質 0.75。3MB を超えたときだけ質を 0.6・0.45 に下げる。
- 1 回のまとめで 12 枚まで（それより多ければ前から 12 枚）。
- 写真は端末に残さない。送るあいだだけ `tmp/S35Photo/<id>/<番号>.jpg` に置き、届いたら消す。
  送れなかったら、次に開いたとき（アプリが前に来た・仕事タブを開いた。その日のうちだけ）1 回だけ送り直し、
  送れても送れなくても消す。止めてある（`ok:false`・`off`）ときは送り直さない。
- 作り直しを待つ長さ `S30WRules.pollLimit` は 180 → 360 秒（6 分）。帯の文（「作り直しが 6 分で終わりませんでした」・
  「…6 分まで」）は数から作る。
- 写真がそろって作り直しが新しく始まった（写真の返事が `started`）ときは、写真を送り始めたあとに始まった回が終わるまで待つ。
  そうでなければ、今までどおり `POST /work/digest` の返事で待つ（`GET /work/run` の見方はそのまま）。
- 新しい知らせ・問い・設定のスイッチ・許可は足さない。画面の説明の文だけ、写真も送ることに合わせて直した。

## 試し

- 家の PC: `pc/v35checks_s35p.py`（52 項目）。`v34checks_s34p.py` の最後から続けて呼ぶ（CI の手順は増やさない）。
- アプリ: `LifeLogTests/S35PhotoTests.swift`（縮め方・枚数の上限・割り当て・体の形・送る順・features が無いときは送らない・
  止め方・返事の読み・待ち方・送り直しの決め方・6 分）。`S30WTests` の「止まった帯」の秒は pollLimit から作るように直した。

## 気づき（母艦の担当へ）

- 文（`POST /work/digest`）を先に送るので、その時点で `Run-WorkNow.py` が起きる。写真がそろって起こすときは、
  多くの場合まだ走っているか 20 秒以内なので `already` になり、**その回は写真なしで終わる**ことがある。
  写真は inbox に残るので、母艦の側で「走り終わる前に `inbox/work_photo` に新しい組が来ていたら続けてもう 1 回」
  などで拾ってもらうとよい（仮説。母艦の Run-WorkNow の作りを見ていない）。
