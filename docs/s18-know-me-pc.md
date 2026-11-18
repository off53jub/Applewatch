# s18「自分を知ってもらう」家の PC の分（2026-11-19）

担当 P。案の番号は s18 の 84 案。中身は `pc/knowme.py`（口）と、案ごとのモジュール。`pc/lifelog_pc.py` には呼び出しの数行だけ。
確かめ: `python pc/v21checks_knowme.py`（一時フォルダ・作り物の Claude。49 項目）。`--check-v9`・`--check-v7-records` も通る。

## 動き方

- 30 分ごとに見回る（`knowme.tick`）。軽い所（文字と時刻だけ）はいつでも、今日と昨日。
- 重い所（音声を読んで声の高さと snr を測る・自分の声の置き場所の音声）は `voices.heavy_ok` の時間（00:00〜05:00・08:30〜18:00）だけ、
  直近 7 日のまだの日を、1 回 120 秒（仮）まで。実データで 1 日およそ 25 秒（音声を読むのがほとんど）。
- 初めの 1 回だけ、記録のある日を全部（軽い所だけ・30 日で 3 秒）作る（気分の見立てで比べる前の日のため）。
- `config.json` の `"knowme": false` で全部止める。`"knowme_mother_copy": false` で母艦への写しだけ止める。

## 案ごと

| 案 | モジュール | 置き場所（家の PC の `%LOCALAPPDATA%\LifeLogPC\` の下） | 母艦への写し | 受け口 |
|---|---|---|---|---|
| 45・78 声の調子・信用の低い録音 | `voicetone.py` | `voice-tone\<日>.json`・`voice-tone-daily.json`・`voice-tone-partners.json` | `inbox\voice-tone\` | GET /voice-tone?day= |
| 47 本音メモ | `honne.py` | `knowme\honne\<日>.json` | `inbox\honne\<日>.json` | GET /honne?days= |
| 63 声で直す（解釈） | `voicefix.py` | `knowme\voice-fix.jsonl`（控え）・edits.db（直し） | — | POST /voice-fix |
| 69 安い AI → 高い AI | `llmroute.py` | 帳簿は共有の `claude-usage.jsonl` | — | （47 が使う） |
| 70 声の見本の候補 | `voicesamples.py` | `knowme\voice-samples.json`・`knowme\conversation-ok.jsonl` | — | GET /voice-samples・POST /conversation-ok |
| 71 自分の声の取り直し | `selfvoice.py` | `knowme\self-voice.json`・置き場所 `knowme\self-voice\quiet|noisy|phone\` | — | GET /self-voice |
| 72 聞き取りの後の辞書 | `asrlearn.py` | `knowme\asr-learned.json`・`knowme\asr-applied.json` | `inbox\asr-learned\asr_learned_pairs.json` | 「聞いて直す」の理由 dict |
| 73 PLAUD と食い違う所だけ疑う | `plauddoubt.py` | （作らない。母艦の比べを読む） | — | GET /plaud-doubts・「聞いて直す」の理由 plaud |

### 45・78 声の調子

会話ごと: `self_rate_cps`（自分の 1 秒の文字数）・`pause_median_s`（行の間）・`reply_median_s`（相手のあと自分が話すまで）・
`laugh`/`laugh_per_min`（周りの音の「拍手・笑い」と文の「笑」「ハハ」）・`noisy_share`（iPhone の騒がしい印の割合）・`sounds`・
`talk_share`・`pitch_hz`/`pitch_spread_st`（自分の静かな行の声の高さ。自己相関）・`snr_db`（大きい所と静かな所の差）・
`trust`（`low` は騒がしい行が 0.5 以上・snr 10dB 未満・テレビなど）と `tier_cap: "tentative"`（low の会話から立てた見立ては確定にしない）。
文は入れない。名前は `partners`（名前のある相手）だけ。

気分の見立て（`mood`）: その日の自分の数（信用が低い会話は入れない）と、母艦の `archive\health\YYYY\MM\DD.md` の睡眠の長さ・
安静の心拍を、前の 28 日（5 日以上要る）と比べた z の平均。0.5 以上「元気」・−0.5 以下「しんどい」（仮）。
`layer: "hypothesis"`・`label: "見立て（仮）"`・`kind: "mood"`・tier は最高でも `tentative`・`evidence` に根拠の会話。

### 47 本音メモ

独り言＝自分の行が 1 つ以上・ほかの人の行が 0・話し手なしの行が 3 割以下・時計の音声の行が半分以上・12 文字以上・テレビでない（どれも仮）。
`llmroute.judge`（用途 `honne`）で honne・memo・task・other に分ける。頼む文に見本の文は入れない。新しい文は書かせない。
見立ての印（`tier_kind: "hypothesis.honne"`）。同じ会話・同じ文は二度頼まない。

### 63 声で直す

A の PR がまだ無いので、形は仮の `{text, at, target_id?}`。`target_id` は `"YYYY-MM-DD|<行の時刻のミリ秒>"` か行の時刻の ISO 8601。
無ければ言った時刻の前 300 秒（仮）でいちばん新しい行（話し手を直すときは自分以外の行）。
「違う、〇〇さん」→ 話し手を 〇〇 に、「違う、俺」→ 自分に、「〇〇じゃなくて△△」→ 文を直す。名前は記録にもう出てくる名前だけ
（`RecordStore.make_edit` と同じ。新しい名前を作らない・人をまとめない）。決まらなければ `{"status": "ask", "candidates"}`。
直しは今までの edits（pending）になり、iPhone が GET /edits で取りに来て当てる。

### 69 安い AI → 高い AI

`claude.call` だけを通る（鍵・今月の上限・用途ごとの止め・帳簿は家の PC と母艦で共有の仕組み）。答えに `confidence` を必ず入れてもらい、
0.7（仮）より低ければ Sonnet で頼み直す（用途 `<用途>.review`）。新しい用途の 1 日の上限は既定 `honne` $0.10・`honne.review` $0.10（仮）。
`claude-config.json` の `daily_caps` に鍵があればそれが先、次に `config.json` の `"llm_route_caps"`。

### 70 声の見本の候補

○ ＝ 「聞いて直す」の「合っている」・iPhone が当てた話し手の直し（当てる前の名前は使わない）・POST /conversation-ok の ok。
よく会う人（直近 14 日に 3 回以上の会話・仮）の、2〜10 秒（仮）の静かで重ならない行。声の特徴が置いてあれば真ん中から 0.5 未満（仮）を外す。
1 人 3 つまで。**名前は変えない・まとめない。足すのはアプリ（A）**。

### 71 自分の声の取り直し

録るのは本人。アプリの「直す」→「自分の声」→「もう一度録って足す（20秒）」を、静かな部屋・周りの音がある所・電話をスピーカーにして
話しているときの 3 回。読む文は GET /self-voice の `scripts`。PC は、静か・騒がしいの場面ごとに、自分の行の声が静かな所の自分の声の
真ん中にどれだけ近いか（中央値・0.5 未満の割合）を毎日 `history` に残し、録り直しの前と後で比べられるようにする。電話は記録に印が無いので、
本人が `knowme\self-voice\phone\` に録音を置いたときだけ測る。

### 72 聞き取りの後の辞書

聞き取り中のヒントは測ってやめた（`hintpolicy.py` の既定 none）ので触らない。本人の直し（records の history の「手で直した」「PC で直した」と
edits.db の文の直し）だけから、入れ替わった所を組にする（1 文字の入れ替えはとなりの同じ文字を足して 2 文字に）。
`precision = 直した回数 ÷（直した回数 ＋ まだ残っている行）`。auto ＝ 3 回以上かつ 0.9 以上 → 新しい行に edits を作って当てる（仮）。
tentative ＝ 0.5 以上 → 当てずに「聞いて直す」に「本人が前に直した言葉」で出す。ask ＝ それ以外（何もしない）。
自分で当てた直しは `asr-applied.json` に控えて学ばない・同じ行に二度当てない。`"asr_learned_apply": false` で当てるのを止める。

### 73 PLAUD と食い違う所だけ疑う

比べ直さない（母艦の `Build-PlaudGap.py`・`Build-CaptureLoss.py` がもうやっている）。`state\misheard_pairs.json` の行を「聞いて直す」に
「PLAUD と食い違う」で出す。母艦が省ける `state\plaud_line_match_for_pc.json`（PLAUD と合った行の時刻）を出せば、自信が低いだけの行は聞かない。

## 実データで 1 回動かした数（2026-11-19。本物の HOME には書かず、記録・edits.db・voices を一時フォルダに写して）

- 記録 30 日（10/14〜11/19）・会話 1,635。軽い所 30 日で約 3 秒、重い所 30 日で約 12 分（1 日約 25 秒）。
- 信用が低い会話 618（テレビなど 426・騒がしい行が 5 割以上 238・snr 10dB 未満 5）。騒がしい行の割合は中央 0・上から 1 割 0.80。
  テレビでない会話の snr（300 件）は下 1 割 12.4・中央 18.0・上 1 割 28.0dB、10dB 未満は 9 件。
- 自分の話す速さ（131 会話）: 下 1 割 2.1・中央 3.8・上 1 割 5.6 文字/秒。行の間（385）: 中央 2.3 秒。返事の間（111）: 中央 2.4 秒。
  笑い: 9 割の会話で 0。声の高さ（118 会話）: 中央 115Hz・幅 5.9 半音。
- 気分の見立て 30 日: 付けられない 10（前の日が足りない）・ふつう 14・元気 4・しんどい 2。合わせた信号は 1〜4 個。
- 相手ごとの表: 16 人（2 回以上の会話・218 会話）。
- 独り言の候補 22（30 日）。うち 10 件を実際に分けた（$0.0129）: honne 4・other 4・memo 1・切れた 1（max_tokens 200 → 400 に直した）。
  10 件中 6 件が自信 0.7 未満で Sonnet の見直しに回った（見直しのあとも 0.55〜0.62 が多い）。
- 本人の直し 8 件（30 日）→ 組 8（どれも 1 回）。tentative 4・ask 4・auto 0（今は黙って当てるものは無い）。
- ○ の行 15・○ の会話 0 → 見本の候補の人 0（よく会う名前のある人の ○ がまだ無い）。
- 自分の声: 静か 2,448 行・中央 0.768・0.5 未満 28.5%／騒がしい 270 行・中央 0.795・25.6%（騒がしい方が遠いわけではなかった）。電話は測れない。
- PLAUD と食い違う行: 11/18 に 58 行。「聞いて直す」の並びは 17,901 → 17,909（音声が残っている行だけが並ぶため 8 行増えた）。
- 声で直す: 名前のある話し手 32 のうち、「さん」を外して言っても 31/31 が 1 つに決まった。

## 仮のしきい値

| どこ | 値 |
|---|---|
| voicetone.NOISY_LOW | 0.5 |
| voicetone.SNR_LOW | 10 dB |
| voicetone.MOOD_UP / MOOD_DOWN | 0.5 / −0.5 |
| voicetone.BASE_DAYS / BASE_MIN | 28 / 5 日 |
| llmroute.REVIEW_BELOW | 0.7 |
| llmroute.DAILY_CAPS | honne $0.10・honne.review $0.10 |
| honne.UNKNOWN_MAX / WATCH_MIN / MIN_CHARS | 0.3 / 0.5 / 12 |
| voicefix.WINDOW_S | 300 秒 |
| voicesamples.FREQ_MIN / SAMPLE_MIN〜MAX / SIMILAR_MIN | 3 回 / 2〜10 秒 / 0.5 |
| selfvoice.FAR | 0.5 |
| asrlearn.AUTO_MIN / AUTO_PRECISION / TENTATIVE_PRECISION | 3 / 0.9 / 0.5 |
| knowme.HEAVY_BUDGET_S | 120 秒 |

## まだ・気づいたこと

- 声の高さは自己相関の簡単な測り方。180Hz あたりにも山があり、倍の高さを拾っている会話があるかもしれない（仮説）。
- 気分の見立ては、本人の夜の 10 秒（inbox\mood.jsonl）との答え合わせを母艦 M3 がする（tierlib の mood）。当たらなければ止める。
- 63 の形は A の PR が出たら合わせる。70 の見本を足す画面と、71 の GET /self-voice を出す画面はアプリ（A）。
- 47 は見直しに回る割合が高い（10 件中 6）。REVIEW_BELOW を下げるか、本人の ○× で測ってから決める。
