# s29 家の PC（LifeLog PC）の分（2026-11-27・担当 s29p）「声を分ける・当てる」

案の全文は母艦 `docs/system-proposal-2026-11-13.md` の「追記 19」。変えたのは `pc/` と このファイルだけ（アプリ・時計・`.github/` は触っていない）。
言語モデルの呼び出し・モデルのダウンロード・新しい部品の導入はしていない（0 円）。**記録の話し手は書き換えない・人をまとめない・名前を付けない。**

- 新しいファイル: `pc/s29pc.py`（つなぐ所）・`pc/s29panswers.py`（声22）・`pc/s29pgate.py`（声9・声25・声26）・`pc/s29pgroups.py`（声19）・
  `pc/s29pvoice.py`（声2・声3・声5・声6・声7・声12・声13・声17）・`pc/v29checks_s29p.py`（試し）
- 共通のファイルへの手入れ: `lifelog_pc.py`（import・features・start・GET の道の 4 か所）・`ops.py`（summary.md の「## s29 の数」）・
  `v27checks_s27p.py`（最後に v29checks を呼ぶ 3 行）
- 「仮説」はまだ確かめていない見立て。「仮」はしきい値（材料が少ない）。

## 先に: 測って分かったこと（実機の HOME・母艦は読むだけ）

- **答えた組が 0 の理由（声22）**: 家の PC が「答えた組」に数えるのは、母艦 `inbox/app_feedback.jsonl` の kind `same_person`
  （id が GET /same-person の組の id）と、確かめ待ちの `vp-…` の yes/no だけ。しかもその組の見本が `HOME/same-person/<日>.json`
  （7 日で消える）か `voices.json`（作り直すたびに置き換え）に残っている組だけを数えていた。
  - 母艦の `same_person` の答えは 25 個あったが、**どれも 11/17**。その組のファイルはもう消えていて、1 つも数えられなかった（確かめた）。
  - 11/24 から「同じ人か」の問い（s24 当1・`"same_person_ask": false`）を止めたので、新しい `same_person` の答えが来ない。
  - アプリの名前付けの入口 4 つ（声を聞いて直す・○× でまとめて・今日の人物 N を整理・直す）は POST /feedback を送らず、記録の話し手を
    直すだけ（`fixSpeaker`・`mergePerson`・`renamePerson`）。
  - 母艦の「いちばん多く話す人」の問い（id `spt-<番号>`）に名前を打った答えはあるが、記録は人物N のまま（数えていなかった）。
  - **見立て（仮説・S29N と同じ）**: PC が組に数える答えは same_person と vp- だけで、どちらも 11/24 に既定オフになった「同じ人かも」の
    問いの後ろにあった＝ほかの名前付けの答えは PC に届いていなかった。0 が始まった日（11/24）と合う。
    **確かめ方**: 新しいアプリが入ったあと、母艦 `inbox/app_feedback.jsonl` に `s29_kind` のある行が増えるか・`HOME/s29p/received.json` の
    `app_s29` が増えるか・`quality-daily.json` の `speaker_answers.pairs` と `s29_answers.total` が 0 でなくなるかを見る。
    もう 1 つの道（記録の直しから組）は、アプリを替えなくても、本人が名前のある人へ行を移した翌朝に `s29_answers.by_source.records` が増える。
- **名前の無い声のかたまり（声19）**: 7 日（11/21〜27）の人物N（区間 2 つ以上）は 95 人。近さのしきい値ごとのかたまり（読むだけで数えた）:
  0.50 → 16 かたまり・52 人／0.55 → 12・40 人／**0.60 → 9・31 人（既定・仮）**／0.65 → 8・24 人／0.70 → 6・19 人。
  答えた組がまだ無いので当たりは測れていない（`groups.json` の `table` に毎回残す）。
- **iPhone と時計が同じ時に録った音（声2・声25）**: 区切りの名前で数えると、iPhone の区切り 51 個のうち 35 個は 5 分以内に時計の区切りがある
  （11/20・21・24・26）。ただし**記録の行には同じ発話が両方から入っていない**（7 日で 0 組）＝ 声25 の「マイクが合った所」は今は材料なし。
  声2 は音声ファイルどうしで比べる（夜に、両方の音声が残っている組だけ）。

## 案ごと

| 案 | した／一部／できなかった | 既定 |
|---|---|---|
| 声22 答えの受け | した | オン（`"s29p_answers"`） |
| 声19 かたまり（作る側） | した | オン（`"s29p_groups"`） |
| 声9 s-norm の切り替えの条件 | した | `"s29p_snorm_score": "candidate"`（候補に出すだけ） |
| 声25 分け間違いの数 | した（マイクの所は今は材料なし） | オン |
| 声26 本番入りの条件 | した | すべて影のまま・自動で本番にしない |
| 声5 正本の候補 | 一部（候補と口まで。iPhone が当てる所はアプリ側） | 口はオフ（`"s29p_canonical": false`）・数えるのはオン（`"s29p_canonical_shadow"`） |
| 声7・声12・声13（PC 側） | した（影） | 声5 の中で数える |
| 声2 2 本のマイク | した（影） | オン（`"s29p_two_mic"`。数えるだけ） |
| 声3 雑音を消してから特徴 | した（影） | オフ（`"s29p_denoise_embed"`） |
| 声6 重なりを 2 本に | 一部（口は s26 の `s26pnight.separate`。部品があるかを数える） | オフ（`"s26p_separate"`）・**speechbrain を入れるかは本人の判断待ち** |
| 声17 モデル 4 種の比べ | した（道具） | 手で動かす |
| 声1 襟元マイク | docs だけ（下） | — |

### 声22 答えの受け（`s29panswers.py`）

PC 側で直した穴は 4 つ:
1. **答えの見本を写して残す**: 答えた組の見本を `HOME/s29p/answers.json` に写す（90 日・3,000 組まで）。組のファイルが消えても答えは消えない。
2. **記録の話し手の直しから組を作る**: 30 分ごとに直近 7 日の記録の話し手を `HOME/s29p/snap/<日>.json` と比べる。
   行の話し手が**名前のある人か自分に**変わった所だけを本人の答えとみなす（機械のまとめ＝名前の無い人どうしは入れない）。
   - 移した行 と 移した先の人のほかの行（同じ日。無ければ 7 日のほかの日）→ 同じ人（`orig_same: false`）
   - 移した行 と もとの人に残った行（同じ日）→ 違う人（`orig_same: true`）
   - 名前を付けただけ（番号はそのまま）は組を作らない。1 度に 300 行（仮）より多く変わったら番号の付け替えとみなして入れない。
3. **母艦の「いちばん多く話す人」の答え**（kind `review`・id `spt-<番号>`）: 打った名前が直近 7 日の記録の名前のある人と同じなら
   「人物<番号> と その人は同じ人」の組。新しい名前・はい/いいえ/分からないは組にしない。記録の名前は書き換えない。
4. **新しい形（アプリの S29N が送る）を受ける**: `appfeeds.parse_feedback` を包んで、kind `same_person` の `s29_*` を落とさずに母艦の
   inbox に残す（前の形はそのまま）。

**受ける形（POST /feedback。kind `same_person`。前の形 `{"kind","id","value","day"}` はそのまま。足した欄はどれも省ける）**:

```json
{"kind":"same_person","id":"s29g-0123456789ab","value":"merged","day":"2026-11-27",
 "s29_kind":"merged",
 "s29_pairs":[{"same":true,"ids":["12","7"],
               "people":[[{"audio":"20261126-090000.m4a","start":1.0,"end":4.0}],
                         [{"audio":"20261125-100000.m4a","start":2.0,"end":5.0}]]}],
 "s29_ids":["12","7"], "s29_group":"s29g-0123456789ab", "s29_at":"2026-11-27T09:00:00+09:00"}
```

- `value`: `merged` | `different`（前のまま。ほかは 400）。
- `s29_kind`: `move`・`keep`・`named`・`merged`・`unknown`・`split`（S29N）。`merge`・`quick_yes`・`quick_no`・`pair` も受ける。知らない文字は `pair`。
- `s29_pairs`: 20 組まで。`same` は真偽・`people` は 2 つの見本の並び（見本は `{"audio","start","end"}`・`start` の代わりに `offset` も可・
  0〜60 秒・音声の名前は英数字と `. _ -` だけ）。片方の見本が無い組は落とす。PC の組の id は `<id>#<番号>`。
- `s29_ids`（話し手の番号の並び・20 個まで）・`s29_group`（s29_groups の id）・`s29_at`（ISO 8601）。
- PC 担当が先に決めていた欄も受ける: `s29_a`・`s29_b`（見本かその並び・8 個まで）・`s29_from`・`s29_to`（話し手の番号。`s29_b` が無いとき、
  夜にその日の記録の `s29_to`（同じ人）・`s29_from`（違う人）の行から見本を探す）・`s29_screen`・`s29_scope`。
- **id が s29_groups の id（`s29g-…`）で `s29_pairs` が無いとき**: `merged`・`named` は「1 人目と k 人目は同じ人」の組を全部作る
  （かたまりの見本は `HOME/s29p/groups-seen.json` に 14 日残してある）。`split` は、だれとだれが違うかが分からないので組にしない。
  `unknown` も組にしない（相手が無い）。
- 形の違う欄は落として、答えそのものは受ける（落とした数は `HOME/s29p/received.json` の `dropped_fields`）。
- 答える前の iPhone の分け（`orig_same`。声25 に使う）: `keep` は答えと同じ・`move`/`named`/`merged`/`split` は答えと逆・
  前の形の `sp-`/`sx-`/`pm-` は「別の人に分けていた」。ほかは分からない（数えない）。
- 足した組は `s23voice.answers`・`s23voice.groups_with_samples` の包みから、s24 の当5（`quality-daily.json` の `speaker_answers.pairs`）・
  s23 の vp- の問いの「集まった数」にも入る。まとまり全体の答え（`s29g-…`）と `s29_pairs` のある答えは `<id>#<番号>` の組だけで数える
  （split を「違う 2 人」と数えないため）。

### 声19 かたまり（`s29pgroups.py`）

- 7 日の名前の無い人物N（区間 2 つ以上）の声の真ん中を、近さ 0.60（仮）以上で近い順にまとめる（`voices.cluster` と同じ。同じ区切りに出た
  2 人は同じかたまりにしない・12 人まで）。2 人以上のかたまりだけ・40 個まで。30 分ごとと夜に作り直す。
- **GET /same-person の省ける `s29_groups`**: `[{"id": str, "labels": ["人物12", …], "score": float, "seconds": float, "days": int}]`
  （S29N との約束どおり。labels は既存の `people[].name` と同じ「人物N」。話した秒の多い順。score はかたまりの中の近さの平均）。
  「同じ人か」の問いを止めていても出す（名前付けの 1 問にまとめるためで、問いを増やさない）。3 日より古いものは出さない。
- 当たりの測り: 既存の across の人がみな同じかたまりに入ったか・答えた組で「同じかたまり＝同じ人」が当たったかを、しきい値 0.50〜0.70 の表と
  一緒に `HOME/s29p/groups.json` へ。features `s29groups`。

### 声9 s-norm に切り替える条件（`s29pgate.py`）

- 「7 晩」をやめた。毎晩、答えた組のうち両側の声の特徴が置いてある組で、今の点と s-norm の AUC を出す（`voices/<日>.npz` の特徴を使う。
  モデルは動かさない）。
- 条件（仮）: 答えた組 **12 組以上**・同じ人と違う人が**それぞれ 4 組以上**・**s-norm の AUC ≥ 今 + 0.05**。足りないうちは今の点のまま。
- 判断は毎晩 `HOME/s29p/snorm-decisions.jsonl` に 1 行・`quality-daily.json` の昨日に省ける `s29_snorm`（pairs・same・auc_raw・auc_snorm・decision）。
- `"s29p_snorm_score"`: `"candidate"`（既定。summary.md に出すだけ）| `"on"`（いちばん新しい判断が s-norm の晩だけ、GET /same-person の
  組を s-norm の高い順に並べる。`score` の値は前のまま）| `"off"`。どの場合も GET /same-person に省ける `"s29_score": "raw" | "snorm"`。
- s24 当2（7 晩の決まり）の行は summary.md に残してある（消していない）。

### 声25 分け間違い（`s29pgate.split_wrong`）

- **`quality-daily.json` の `days[<日>].speaker_split_wrong = {"wrong": 数, "pairs": 数}`**（母艦の Build-Accuracy.py が読む名前）。
  数えるもの: 答えた組で、答える前の iPhone の分け（`orig_same`）が本人の答えと違った組 ＋ 同じ時に iPhone と時計の両方が書いた同じ発話
  （時刻 1.5 秒・文の近さ 0.6・仮）で話し手の印が違った所。数が 1 つも無い晩は書かない。
- 内訳は省ける `s29_split_detail`（answer_pairs・answer_wrong・mic_checks・mic_wrong・point_pairs・point_wrong（今の点 0.60 で）・
  plaud_compared・plaud_either）。PLAUD の話し手との食い違い（母艦 `digests/canonical/<日>.json`・s29m と同じ数え方）は内訳だけ
  （PLAUD の分けも正解ではないので、1 つの数には入れない）。
- 注意: 答えた組は「本人が直した所」に片寄る（直した組はいつも間違い）ので、数は高めに出る（仮説）。変わり方を見る数。

### 声26 本番入りの条件（`s29pgate.GATES`。ここ 1 か所）

| 名前 | 動かす設定（既定） | 物差し | 要る数 | 良くなった差 |
|---|---|---|---|---|
| snorm | `s29p_snorm_score`（candidate） | 答えた組の AUC（s-norm 対 今の点） | 12 組 | 0.05 |
| day_diar | `s26p_day_diar`（オフ） | 答えた組の当たり（1 日まるごと 対 iPhone の分け） | 12 組 | 0.05 |
| canonical | `s29p_canonical`（オフ） | 答えた組の当たり（正本の候補 対 iPhone の分け） | 12 組 | 0.05 |
| separate | `s26p_separate`（オフ） | 重なりの行の PLAUD と合った字（分けた 対 分けない） | 30 行 | 0.02 |
| boost | `s26p_boost`（影） | 持ち上げた行の PLAUD と合った字（上げた 対 前） | 30 行 | 0.02 |
| denoise_embed | `s29p_denoise_embed`（オフ） | 答えた組の AUC（消した 対 消さない） | 12 組 | 0.05 |
| two_mic | `s29p_two_mic`（影） | 自分の行を当てる AUC（2 本の差 対 1 本） | 30 行 | 0.05 |

- どれも仮。`config.json` の `"s29p_gates": {"<名前>": {"need": 数, "margin": 数}}` で上書きできる。
- 毎晩 `HOME/s29p/gates.json`（GET /s29/gates）に、今の状態・数・候補かどうか・理由。**条件を満たしても自動で本番にしない**
  （`"auto_promote": false`。summary.md の「気になる所」に候補を出すだけ。切り替えるのは本人が config で）。

### 声5・声7・声12・声13 正本の候補（`s29pvoice.canonical`）

- 夜に昨日の 1 日まるごとを、s26 聞4 と同じかたまり（近さ 0.6・仮）に分け、名前のある行が 6 割以上のかたまりに入った人物N を「付け直し案」に。
  - 声7: 予定・本人の答えの人数（`s22voice.headcounts`）が分かる会話は、自分以外のかたまりを 人数 − 1 まで（近いかたまりへ寄せる）。
  - 声12: 1 つの会話の中で、区切りごとに「自分と名前の無い 1 人」だけが交互に話していて、その 1 人が区切りごとに別の人物N のとき、
    あとの人物N を前の人物N に寄せる。
  - 声13: 予定の相手が 1 人だけの時間・母艦 M2 の場面の見込みで LINE が理由の候補の時間に、名前の無いかたまりの声がその人の真ん中と
    0.45（仮）以上なら案に。
- `HOME/s29p/canonical/<日>.json`。**GET /s29/canonical?day=YYYY-MM-DD**（features `s29canonical`）:
  `{"available": bool, "on": bool, "day", "items": [{"time": ISO, "audio", "start", "end", "from": {"id","name"}, "to": {"id","name"},
  "why": ["diar"|"headcount"|"chain"|"hint"]}], "counts", "generated_at", "gate"}`。既定オフのあいだは `{"available": false, "on": false, "reason"}`。
- 付け直すのは本人の端末だけ（PC は記録を変えない）。本番にする条件は 声26 の `canonical`。

### 声2 iPhone と時計の 2 本（`s29pvoice.two_mic`）

- 先に、3 日の区切りの名前から「始まりが 10 分以内の iPhone と時計の組」で、両方の音声が残っているものを探す。無ければ `"材料なし"`。
- あれば音の包絡（20 ミリ秒）で時間の差を合わせ（±3 秒）、iPhone の記録の行ごとに 2 本の大きさの差（時計 − iPhone の dB）で
  自分（差 ≥ 4 dB）／近い相手（大きいほうが −30 dBFS 以上）／遠い人に分ける（どれも仮）。自分の行（記録の印 me）を当てる AUC を
  2 本の差と 1 本（iPhone）の大きさで比べる。1 晩 20 組まで。`HOME/s29p/two-mic.json`。記録は変えない。

### 声3 雑音を消してから声の特徴（`s29pvoice.denoise_compare`）

- オン（`"s29p_denoise_embed": true`）のときだけ、夜に答えた組（新しい 60 組まで）を、既にある GTCRN で消した音と消さない音の両方で測り、
  AUC を比べる（`HOME/s29p/denoise-embed.json`）。雑音のモデル・話し手のモデルのファイルが手元に無ければ測らない（取ってこない）。

### 声6 重なりを 2 本に分ける

- 口は s26 の `s26pnight.separate`（`"s26p_separate": true` で動く。SpeechBrain の部品が要る）。s29 では、部品（speechbrain・torch）が
  入っているかを夜に数えるだけ（読み込まない・入れない）。**入れるかは本人の判断待ち。**

### 声17 声の特徴のモデル 4 種を比べる道具

- `python pc/s29pvoice.py models [--home HOME] [--mother 母艦]`: `s22models.SPEAKERS` の 4 種を、答えた組と機械の組（across・maybe＝同じ人かも、
  同じ区切りで iPhone が分けた 2 人＝違う人かも）で比べて `HOME/s29p/models.json` に。`HOME/speaker` に無いモデルは「無し」で飛ばす（取ってこない）。
  重いので、夜か手で（動いている LifeLog PC とは別に動かすときは、終わるまで PC が重くなる）。毎晩の測り直しは s24 当5 が続けている
  （答えた組が増えれば、そちらにも入る）。

### 声1 襟元のマイク（買ったときに見ること 3 行）

1. iPhone のショートカットか録音で外付けのマイクのとき `POST /jobs` に `mic=external` が付いて届くか（summary.md の s26 の行「外付けのマイク（聞2）」が 0 字でなくなる）。
2. 1 週間つけたあと、summary.md の s26「場面ごとのマイク（聞1）」で、店・電車の PLAUD と合った字の割合が時計・iPhone より上がったか。
3. 同じ週の s29「分け間違い（声25）」と「答えた組」の数が、つける前の週より下がったか（声26 の two_mic・canonical の行も見る）。

## 夜と 30 分ごと（`s29pc.py`）

- 30 分ごと（軽い）: 記録の直しの写し・母艦の答えの取り込み・spt の答え・かたまりの作り直し。
- 夜 00:00〜05:00 に 1 回（新しい区切りが待っていないとき・20 分まで・仮）: 上の軽い分 → s-norm の判断 → 分け間違い → 正本の候補（影）→
  2 本のマイク（影）→ 雑音を消した特徴（オフ）→ 持ち上げ・重なりの数 → gates.json。数は `HOME/s29p/night.json` と `quality-daily.json`
  の昨日（`speaker_split_wrong`・`s29_split_detail`・`s29_snorm`・`s29_answers`）。
- summary.md の「## s29 の数」に 6 行（答えた組・s-norm の判断・分け間違い・本番入りの条件・かたまり・2 本のマイク）。
- 記録（log.txt）には数だけ（名前・文・音声の名前は書かない）。

## ほかの担当との約束

- アプリ S29N: GET /same-person の `s29_groups`（上の形）を読む。POST /feedback の `s29_*`（上の形）を送る。
- 母艦: `quality-daily.json` の `speaker_split_wrong`（`{"wrong","pairs"}`）を Build-Accuracy.py が読む。`s29_snorm`・`s29_answers`・
  `s29_split_detail` は省ける欄。

## 本人の判断待ち

- speechbrain（声6）を入れるか。
- 条件を満たした影の機能（声26 の候補）を本番にするか（`config.json` で切り替える）。
- 声5 の正本の候補を iPhone に出すか（`"s29p_canonical": true`）。

## 試し

- `python pc/v29checks_s29p.py`（`v27checks_s27p.py` の最後でも動くので、CI の「s20 を確かめる」の手順で一緒に動く）: 62 項目 OK。
  作りものの記録・声の特徴（16 次元）・答え・音（雑音の並び）で、受けの新旧の形・S29N の形・記録の直しから組・spt・答えた組の s24 への入り方・
  s-norm の判断と並べ替え・分け間違いの数・条件の候補・かたまりの形と当たり・2 本のマイクの時間合わせと分け方・材料なし・雑音の比べ・
  モデルの「無し」・正本の候補（diar・人数・鎖・手がかり）と口・夜の通し・つなぎを確かめる。モデルは動かさない。
- 既存の試し: `v24checks_s20.py` からの通し（s20〜s29）530 項目 OK。`lifelog_pc.py --check-v10`・`--check-v11`・`--check-v7-records`・
  v12〜v23 の試しは OK。`--check-vote`・`--check-v7-ops`・`--check-v8`・`--check-v9` はこの PC の Python に av・cryptography などが無いため
  main（6398537）でも同じ所で落ちる（CI では入る）。
