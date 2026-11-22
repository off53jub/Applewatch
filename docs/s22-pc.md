# s22 家の PC（LifeLog PC）の分（2026-11-22・担当 P）

案の一覧は s22 の 75 案のうち [P] の付いたもの。本人の指示は「ぜんぶやって。ダウンロードもやって」。
どれも `pc/` の中だけを変えた（アプリ・時計・`.github/` は触っていない）。言語モデルの呼び出しは足していない（0 円）。
確かめは `python pc/v24checks_s22.py`（`pc/v24checks_s21.py` の最後でも動くので、CI の「s20 を確かめる」の手順で一緒に動く）。

「仮説」と書いたものは、まだ確かめていない見立て。「仮」と書いた数は、測ったが材料が少ないしきい値。
測るのは動いている LifeLog PC とは別のフォルダ（`D:\aw-s22-pc\_measure\`。コミットしない）で、本物の HOME と母艦は**読むだけ**にした。

## 先に: 測って分かったこと

- **同じ人かの点（確1）**: 答えのある 14 組（同じ人 5・違う人 9）で、今の家の PC の点の AUC は **0.31**（母艦の答え合わせと同じ）。
  同じ見本の声の特徴で、日の平均を引いた近さにすると 0.53、**s-norm（その日のほかの人たちの声との近さでならす）にすると 0.82**。
  s-norm が 1.5 より低い 6 組はどれも「違う人」だった（同じ人の 5 組は 1.71〜3.10）。14 組しかないので、しきい値 1.5 は仮。
- **自動の材料が増えない本当の理由（確16）**: s21 で自動の材料（そろった行）を既定で使うようにしたが、`samples.jsonl` は 11/22 18:55 でも
  **46 個のまま**。自動の材料は「3 つ以上のモデルがそろった行」（`AUTO_ENGINES = 3`）だけなのに、今の LifeLog PC は
  `--engines haas,whisper` で 2 つのモデルしか動いていないため、1 つも作られない（haas と雑音を除いた haas は同じモデルとして数える）。
  → PLAUD の文と 9 割以上合う行を材料にする道を足した（下の確16）。11/16〜11/20 の jobs で数えると 1 日 8〜142 行あり、1 日 60 個までで
  **5 日ほどで 300 個に届く見込み（仮説）**。
- **reazon を主にしても良くならない（確14）**: 7 日の当たり 81.5% は「書いた字のうち合った割合」で、reazon は書く量が少ない。
  3 つのモデルの票がある 811 行で比べると、合った字の数は 今の多数決 13,109 字（0.778）／reazon だけ 10,057 字（0.810）／
  reazon を主（割れたら多数決）11,824 字（0.775）。reazon だけにすると書き漏らしが 23% 増える。→ 既定は変えない。
- **Whisper の決まり文句（確12）**: whisper だけが書いた行は、もともと vote が作り話として捨てていた（jobs の 8,659 行で 0 行）。
  足りなかったのは「haas が別のことを書いた行で、whisper の票だけが『ご協力ありがとうございました』『以上です』『お待ちしております』
  『おやすみなさい』『以上で終わります』など」の場合で、90 行（haas との近さの中央値 0.10）・そのうち 9 行で選ばれていた。

## 案ごと

### 楽5（出す側）報告の棚（した）
- `s22feeds.py`: GET `/reports` → `{"generated_at","reports":[{"name","title","updated_at","bytes"}]}`、GET `/reports/<name>` → 母艦
  `reports/<name>` の本文（`text/markdown; charset=utf-8`）。features `reports`。
- 出すのは母艦 `state/reports_for_app.json` の `{"allow": [...]}` にある名前だけ。無ければ何も出さない（一覧は空・本文は 404）。
  名前は英数字と `. _ -` で `.md` で終わるものだけ（`..`・`/`・`\` は断る）。reports の直下だけ・2MB まで。title は最初の `# ` の行。
- 確かめ方: `v24checks_s22`「楽5」。まだ: 母艦の `reports_for_app.json` は担当 M が作る（今は無いので、一覧は空）。アプリ（A1）の画面。

### 楽20（出す側）いつも録れない場所・時間帯（した）
- GET `/capture-gap-patterns` → 母艦 `state/capture_gap_patterns.json` をそのまま（無い・読めないときは `{"available": false, "reason"}`）。
  features `gappatterns`。確かめ方: `v24checks_s22`「楽20」。

### 確1 「同じ人か」の点の作り直し（した。しきい値は仮）
- `s22voice.py`: 組の見本の声の特徴（`voices/<日>.npz` にあるもの。新しくは測らない）から s-norm を出し、組に省ける `"snorm"` を足す。
  見本が合わせて 4 秒より短い人がいる組は点を付けない（`"snorm": null`・`"short": true`）。
  GET `/same-person` で s-norm が 1.5 より低い組（日の組と日をまたぐ組）は出さない（隠した数は `"s22": {"hidden"}`）。今の `"score"` は残す。
  「名前のある人かも」は隠さず点だけ足す。母艦の答え合わせ用に `same-person/snorm.json`（`{id: {snorm, short}}`）を 30 分ごとに置く。
- 本物（読むだけ）で数えると、今出している 13 組（日の組 9・日をまたぐ組 4）のうち 6 組が隠れる。
- 設定: `"s22_voice": {"snorm_min": null}` で全部出す。確かめ方: `v24checks_s22`「確1」。
- まだ: 答えが増えたら（M の Build-AnswerCheck.py が snorm.json を読めば）しきい値を測り直す。担当 M へ: `snorm.json` を読んでほしい。

### 確2 声の見分けのモデルを比べる（測った・切り替えの口を作った・切り替えていない）
- 取ったもの（Hugging Face の sherpa-onnx の作者 csukuangfj の repo `csukuangfj/speaker-embedding-models`。元は WeSpeaker・3D-Speaker・NVIDIA NeMo）:
  `wespeaker_en_voxceleb_resnet34_LM.onnx`（26,530,550 バイト）・`3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx`（71,441,527 バイト）・
  `nemo_en_titanet_large.onnx`（101,405,493 バイト）。SHA-256 は `s22models.py`。
- 測った数: 下の「夜に測った数」。
- 切り替えの口: `"speaker_model": "wespeaker34" | "eres2netv2" | "titanet"`（`s22models.py`・`lifelog_pc.apply_s22_models`）。
  ファイルが無ければ 00:00〜05:00 に取り、取れるまでは今の CAM++ のまま。変えると /hello の speaker_model が変わり、iPhone は登録した声を
  測り直し、`voices/<日>.npz` も測り直しになる。**初めは今のまま**（本人が決める）。

### 確3 区切りをまたいで声をつなぐ（した。候補だけ）
- 同じ端末で続いた区切り（前の区切りの終わり（45 秒より短くは見ない）から次の頭まで 120 秒まで）の名前の無い人物N どうしで、
  日の平均を引いた真ん中の近さが 0.50 以上で互いにいちばん近い組を「同じ人かも」の候補（id `sc-…`・`"why": "chain"`）にする。
  同じ区切りに一緒に出た 2 人はつながない。GET `/same-person` のその日の groups に足す（自動ではまとめない）。
- 本物で数えた（読むだけ）: 45 秒の区切りの日 11/16 人物N 100 人→つなげば 95 人（組 3）・11/17 238 人→220 人（組 12）。
  11/18〜11/21 は 27〜33 人で、つなげる組は 0〜1。思ったほど減らない（仮説: アプリの聞き分けが区切りをまたいで同じ番号を付けている分が多い）。
- 確かめ方: `v24checks_s22`「確3」。

### 確4（PC 側）自分の声を音の大きさで（した。測る所まで・重みは決めていない）
- POST /jobs の省ける `levels`（`{"p10","p50","p90","voicedP50"}` の JSON か `p10,p50,p90,voicedP50` の並び）を区切りごとに `s22/chunks/<日>.jsonl` に。
  PC でも行の音の大きさ（dB）と区切りの要約を測る（重い仕事の時間・1 回 90 秒まで・`s22/levels/<日>.json`）。
- 毎晩、昨日の「行の dB − 区切りの声の真ん中」で、自分の行とほかの行が分かれるか（AUC）を quality-daily.json の `self_level_auc`・
  `self_level_gap_db` に。時計の levels があればそれを真ん中に使う。**重みはまだ決めていない**（数がたまってから）。仮説: 手首に近い自分の声は大きい。
- 確かめ方: `v24checks_s22`「確4」。まだ: アプリが levels を送るのは A1。本物の AUC は次の夜から。

### 確5 いそうな人を先に（した。重みは仮）
- 予定（archive/calendar）・同じ場所で前に話した人（記録）・直前 3 時間の LINE の相手（archive/line の送り手）に出てくる名前
  （記録にもう出てくる名前だけ）は、「名前のある人かも」の近さに 0.02 を足してから比べる（`voices.PRIOR_BONUS`・`suggest_named` の bonus）。
  名前はまとめない・候補の順と出るかどうかが少し変わるだけ。`"people_prior": false` で止める。
- 確かめ方: `v24checks_s22`「確5」。まだ: 本物で順がどれだけ変わるかは測っていない。

### 確6 人数が分かるとき（した。候補だけ）
- 予定に「N人」「N名」と書いてある時間（`HH:MM-HH:MM` か、無ければ 2 時間）と、本人が答えた人数（母艦 `inbox/headcount.jsonl` の
  `{"day","start","count"}`。**まだ誰も書いていない**）に重なる会話で、自分を除いた話し手が N−1 人より多ければ、声の近い人物N から順に
  N−1 人になるまでつないだ候補（id `sn-…`・`"why": "count"`）を GET /same-person に足す。同じ区切りの 2 人はつながない。
- まだ: 人数を本人に聞く画面は無い（A1 か M が作るなら上の形で）。

### 確7 通りすがり（した）・確8 重なり（した）・確9 遠い声（した。札だけ）・確10（PC 側）動画の声かも（した）
- `s22voice.tags_day`: 通りすがり（その日 1 つの区切りにだけ・2 行以下・8 秒以下の人物N）・重なり（ちがう話し手の前の行の終わりが
  次の行の始まりより 0.3 秒以上あと）・遠い声（自分でない行で、区切りの声の真ん中より 12dB 以上小さい。仮）・動画の声かも（PC の再生中の時間に重なる）。
  `s22/speaker-tags/<日>.json`・GET `/speaker-tags?day=`（features `speakertags`）・母艦 `inbox/speaker-tags/<日>.json`。消さない・札だけ。
- `s22media.py`: 1 分ごとに Windows の「いま再生中」（GSMTC。Windows PowerShell の WinRT で読む。新しい部品は足していない）から、
  再生中のアプリの名前だけを読む（曲名・動画の題は読まない）。PC を触っていた時刻も。`s22/media/<日>.json`（30 日）。
  記録の行が再生の時間（前後 30 秒）に入れば、行に省ける `"mediaNearby": true`（母艦の Build-MediaMarks.py が読む）。
- 本物で数えた札（読むだけ）: 11/17 通りすがり 91 人（人物N 238 人のうち）・重なり 94 行。11/21 通りすがり 10 人・重なり 6 行。
- まだ: 遠い声は行の dB を測ってから付く（次の重い仕事の時間から）。GSMTC は今この PC で再生中のものが無く、出力 0 件で動くことだけ確かめた。

### 確11 区切りの境目（一部）
- 今の作りを確かめた: 区切りは別々に文字にしていて、前の区切りとはつないでいない。続いた区切りの組 1,013 組のうち、前の終わりの 0.3 秒前まで
  声が続き、次の頭 0.3 秒から声が始まる組が 50 組（5%）。
- したこと: そういう区切りの最初の行に省ける `"joinPrev": true` を付ける（アプリ・母艦が前の行とつないで読める）。
- しなかったこと: 音声をつないで文字にし直すこと（2 つの区切りを同時に扱う作りの変更が大きいので、まず印だけ）。

### 確12 無音で出る決まり文句（した）
- 上の「先に」のとおり、足りなかった分を `s22text.EXTRA_JUNK` に足し、Whisper の仲間の票が決まり文句だけで、ほかのモデルの文と似ていない
  （近さ 0.5 未満）ときだけ、その票を数えない（行は消さない・票の文は残す）。`"junk_votes": false` で前と同じ。

### 確13 雑音を消してから文字に（測った・切り替えの口を作った・切り替えていない）
- 取ったもの: `Ceva-IP/DPDFNet`（作者 Ceva の Hugging Face）の `onnx/dpdfnet2.onnx`（10,178,747 バイト）・`onnx/baseline.onnx`（8,722,707 バイト）。
  sherpa-onnx 2.0.1 の `OfflineSpeechDenoiserDpdfNetModelConfig` でそのまま動くことを確かめた。今の GTCRN（`enhance/gtcrn_simple.onnx`）と比べる。
- 測った数: 下の「夜に測った数」。切り替えの口: `"enhance_model": "dpdfnet2"`。**初めは今のまま**。

### 確14 reazon を主に（測った・既定は変えない）
- 上の「先に」のとおり、良くならなかった。口だけ作った: `"vote_primary": "reazon"` でそのモデルの票を 1.5 倍（run_job）。
  そもそも今の LifeLog PC は `--engines haas,whisper` で reazon を動かしていない（7 日の 1,543 行だけ reazon の票がある）。

### 確15 新しい日本語のモデル（測った・切り替えの口を作った・切り替えていない）
- 取ったもの（Hugging Face の csukuangfj の sherpa-onnx 版）:
  `csukuangfj/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8`（NVIDIA parakeet-tdt_ctc-0.6b-ja。`model.int8.onnx` 655,542,604 バイト・`tokens.txt`）・
  `csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09`（`model.int8.onnx` 237,115,547 バイト・`tokens.txt`）。
  kotoba-whisper の新しい版（v2.1・v2.2）は faster-whisper の形が公式に無い（v2.0-faster が最新）ので取っていない。
- 測った数: 下の「夜に測った数」。切り替えの口: `"asr_extra": ["parakeet"]`（多数決に足す。CPU）。**初めは今のまま**。

### 確16 PLAUD と同じ時刻の時計の音を材料に（した）
- 今の材料の元を確かめた（上の「先に」）。毎晩 01:00〜05:00 に、昨日〜3 日前の後で受け取る文字起こしの行（2〜15 秒・6 字以上）のうち、
  PLAUD の文（前後 20 秒）と同じ並びで 9 割以上合う行を、1 日 60 個・全部で 1,500 個まで、自動の材料（`"origin": "pc-plaud"`・`"auto": true`）として足す。
  文は行の文（PLAUD が裏付けたもの）。正解集（goldset.py）と学び直しの試験（train_personal.py）には使わない。`"plaud_samples": false` で止める。

### 確18（PC 側）行ごとの確かさ（した）・確20（PC 側）数字と表記のゆれ（した）
- 記録（POST /records/<日>）を置く前に、行に省ける `"conf"`（iPhone の confidence と票のいちばん遠い 2 つの近さの小さいほう。0〜1）と
  `"norm"`（全角→半角・漢数字（数え方の言葉の前だけ。「一人」「十分」「千葉」などは替えない）→算用数字・「15時30分」→「15:30」・
  「午後3時」→「15時」・桁区切りを外す）を足す。元の `text` は消さない。変わらなければ norm は付けない。足せないときは届いたまま置く。

### 確19（作る側）数字・日付・金額が割れたら確かめ待ちに（した）
- 記録の行の票で、そろえたあとの数字の並びが違う行を kind `number`（`"answer": "pick"`・`choices` は票の文）の問いにする（1 日 5 件まで）。
  `s22/review/items.json` に置き、GET `/review-queue` の母艦の列の後ろに足す（答えたもの・同じ id は足さない・8 件まで）。母艦にも
  `inbox/pc-review/candidates.json` として写す。答えが今の文と違えば、その行の文を「PC から直す」と同じ直しにする。

### 確21 行の時刻を言葉の時刻から（確かめた・口を作った・既定はオフ）
- 今の作り: 行の始まり・終わりは声の区間のもの。言葉の時刻のある 8,417 行で、最初の言葉の始まりとの差は中央値 0.0 秒（90% で 0.8 秒）、
  終わりは中央値 0.44 秒あとまで区間が続いている。`"word_line_times": true` で、区間の中・1.5 秒までの幅で寄せる（元は `segStart`・`segEnd`）。
  差が小さいので既定は今のまま。

### 確22 場面ごとの雑音消し（口を作った・測れなかった）
- POST /jobs の省ける `scene=train|car|shop|outside|home` と `"enhance_scenes": {"train": true, …}` で、その場面だけ雑音を除いた票を足す。
- 測れなかった: 正解集（46 個）に場面の印が無い。場面ごとの数は、アプリが scene を送るようになってから。

### 確23 場所ごとの言葉の辞書（した。既定はオフ）
- `s22place.py`: 直近 30 日の記録で、場所ごとに多く出てほかの場所では少ない言葉（カタカナ 3 字・漢字 2 字以上。人の名前は除く）を 8 個ずつ。
  `"place_words": true` のときだけ、その時刻にいた所（母艦の年表）の言葉を 5 個までヒントの後ろに足す。測っていない（前に地名で下がったので、asrmeasure.py で測ってから）。

### 確24（PC 側）録り方の実験の組ごとの数（した）
- POST /jobs の省ける `recExp`（`32k45`・`48k45`・`32k300`・`48k300`）を区切りごとに残し、diag の `recExpHourly`（`state` か `detail` の
  `{時: 組}` か `[[時刻, 組]…]`）と時計の電池の見本（`watchBatteryAt`）から、日ごと・組ごとに 区切り・行・録れた分・声の分・人物N の種類・
  時間・電池の 1 時間あたりの減り を数える。置き場所: **`%LOCALAPPDATA%\LifeLogPC\s22\rec-exp.json`**（`{"days": {日: {組: {...}}}}`）と
  `quality-daily.json` の日ごとの `"rec_exp"`。summary.md にも。担当 M へ: この 2 つを読んで報告を作ってほしい。

### 確27（PC 側）答えを同じ声のかたまりに広げる（した）
- 家の PC の問い kind `speaker_line`（「この声は ○○ さんですか」。voices.json の「名前のある人かも」から 1 日 3 件）に「はい」と答えると、
  その日の同じ人物N の行のうち、見本と同じ区切りか声の近い（0.5 以上）行の話し手を ○○ にする（記録にある名前だけ・PC から直すと同じ直し）。
- POST /feedback（kind review）の答えに `"done": {"changed": 直した行の数}` を足して返し、母艦 `inbox/review_expanded.jsonl` に `{"id","lines","at"}`。
  家の PC の問いでない答えは今までどおり `{"ok": true}`。`"review_spread": false` で広げない。
- 担当 A1 へ: 答えの `done.changed` を「○行直りました」に使える。

### 確30（PC 側）職場かどうか「分からない」（した。数えるだけ）
- 毎晩、昨日の会話の「分からない」の数と割合、同じ場所で前に 2 回以上「職場」だった数（場所で見当）、平日 9〜19 時の数（時間で見当）を
  quality-daily.json の `work_unknown`・`work_unknown_share`・`work_guess_place`・`work_guess_time` に。印は変えない（しきい値は仮）。

## 夜に測った数（00:00〜05:00・CPU 2 スレッド・`_measure/m_night.py`）

（この節は 11/23 の夜に測ってから書き足す）

## 新しく置くファイル（どれも HOME＝%LOCALAPPDATA%\LifeLogPC の中）
- `s22\chain\<日>.json`・`s22\speaker-tags\<日>.json`・`s22\levels\<日>.json`・`s22\media\<日>.json`・`s22\chunks\<日>.jsonl`・
  `s22\rec-exp.json`・`s22\review\items.json`・`s22\place-words.json`・`same-person\snorm.json`・`s22\models\`（切り替えたときだけ）
- 母艦: `inbox\speaker-tags\<日>.json`・`inbox\pc-review\candidates.json`・`inbox\review_expanded.jsonl`

## 新しい設定（config.json。どれも書かなければ下の既定）
- `"media_watch": false`・`"s22_levels": false`・`"plaud_samples": false`・`"junk_votes": false`・`"review_spread": false`・`"people_prior": false`
- `"s22_voice": {...}`（snorm_min 1.5・short_seconds 4・chain_link 0.50・chain_gap 120・prior_bonus 0.02・passerby_lines 2・passerby_seconds 8・
  overlap_seconds 0.3・far_db 12。すべて仮）
- 切り替え（既定は今のまま）: `"speaker_model"`・`"enhance_model"`・`"enhance_scenes"`・`"asr_extra"`・`"vote_primary"`・`"word_line_times"`・`"place_words"`

## updater・部品について
- requirements.txt に新しい部品は足していない（GSMTC は Windows PowerShell で読む・モデルは sherpa-onnx 2.0.1 で動く）ので、updater の確かめは要らない。
- 切り替えたモデルのファイルは、PC が 00:00〜05:00 の枠でだけ Hugging Face から取る（大きさと SHA-256 が合わなければ消して今のまま）。
