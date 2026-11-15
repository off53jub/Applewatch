# 家の PC の言語モデルまわり（2026-11-16。強化案 75）

先に測ってから、いちばん小さい直しだけ入れた。測ったのは 2026-11-16 1:30 ごろ、家の PC の記録（log.txt）・Claude の帳簿・
iPhone が送ってくる実機の様子（diag）・Ollama の記録（server.log）・nvidia-smi。数だけを数え、会話の文は読んでいない。

## 1. 「Claude が 1 日 40 回ほど失敗」

iPhone の数（diag の tally）と、家の PC が iPhone の用途（correct・misheard・headline など）で Claude から答えを受け取った数:

| 日 | iPhone の claude.ok | iPhone の claude.failed | iPhone の claude.purposeOff | PC が答えを受け取った | PC が断った（iPhone へ 502 など） |
|---|---|---|---|---|---|
| 11/13 | 339 | 15 | — | 349 | 2（Anthropic の 503） |
| 11/14 | 801 | 44 | — | 841 | 3（max_tokens で切れた） |
| 11/15 | 214 | 40 | 16 | 249 | 2（max_tokens 1・JSON でない 1）＋ 409 が 16 |

- 用途ごとの上限（daily_caps）・止めた用途（stopped）で断った分（409）は、11/15 の 16 回（用途 "day"）だけ。これは iPhone が
  もう `claude.purposeOff` として別に数えていて、`claude.failed` には入っていない。asr-judge を止めたのは PC の中の審判で、
  iPhone の数には出てこない。**つまり「失敗」は設計どおりの断りではない。**
- PC が断った（502）のは 3 日で 7 回だけ。
- 残りの 92 回のうち **85 回（10・40・35）は、PC では Claude から答えを受け取れていた**（帳簿に値段も付いている。
  1 回およそ $0.0014〜0.0024、3 日で約 $0.15）。iPhone がその答えを使えなかった。
- 残りの 7 回ほどは PC まで届いていない（つながらなかった）。
- PC で答えるのにかかった秒（iPhone の用途）: 中央 5〜8 秒・上から 1 割 15〜19 秒・いちばん長くて 38 秒。iPhone が待つ秒
  （`ClaudeRoute.timeout`）は 40 秒より短くならないので、iPhone の待ち切れではない。PC の受け付けは 1 つずつではない
  （ThreadingHTTPServer）ので、PC で待たされたのでもない。

**見立て（仮。まだ確かめていない）:** iPhone が自分で取りやめている。見えない通知で起きたときの取り込みは 10 秒で
`queue.cancel()` する（Push.swift の `handlePush`）。通知は 1 日 106〜124 回（push.job）。裏の時間切れ（`BackgroundTime`・
BGTask の `expirationHandler`）でも取りやめる。取りやめると `URLSession` の頼みもその場で切れ、PC は答えを作り終えても
誰も受け取らない。同じ形（cancelled）の失敗が、ドライブへの書き込みで「最近のエラー」に毎晩出ている。

**直したこと（iPhone。数え方だけ）:** `Summarizer.viaClaude` で、取りやめ（`Task.isCancelled`）のときは `claude.cancelled` と
数え、`claude.failed` に入れず、Claude を 2 分止めること（`ClaudeRoute.note`）もしない。夜の報告に「こちらで取りやめた N」を出す
（作れた割合には入れない）。次の版の数で、`claude.failed` が 1 日数回まで減り、`claude.cancelled` が 40 前後になれば見立てどおり。
取りやめそのもの（10 秒で切る・切られる前に Claude を始めない）を直すのは iPhone の動きを変えるので、今回はしていない。

## 2. 「llama-server が約 11 分おきに起動し直す」

Ollama の記録の「starting llama-server」（11/14 0:00〜11/16 1:30）:

| モデル | 起動の回数 | 間（中央） | 15 分以内の間 |
|---|---|---|---|
| bge-m3（意味で探す。CPU、19:42 からは GPU） | 29（CPU）＋ 5（GPU） | 11.9 分 | 28 のうち 19 |
| qwen3:8b（/llm。いつも CPU。num_gpu 0） | 27 | 51.7 分 | 26 のうち 3 |

- **約 11 分おきは本当。ただし bge-m3 のほう。** 11/15 6:15〜8:28 は 10〜12 分おきに 13 回。1 回の読み込みは 2〜5 秒。
  わけ: LifeLog PC も MCP も keep_alive を付けておらず、Ollama の既定の 5 分で下ろされ、約 11 分おきの取り込みで読み直していた。
- bge-m3 と qwen3:8b の入れ替え（片方を下ろしてもう片方を載せる）ではない。CPU の RAM は 31.9GB あり、両方載る。
- qwen3:8b（約 5.2GB）の読み込み直しは 11/15 に 23 回。使うのがまれ（/llm は 1 日数十回）で、5 分で下ろされるため。

**直したこと（PC）:** bge-m3 に頼むときに keep_alive "30m" を付ける（LifeLog PC と MCP の両方。`semantic.embed_keep_alive`）。
config.json の `"embed_keep_alive"`: `"30m"`（既定）・`"1h"`・秒の数・`false`（前と同じ）。ずっと載せたまま（-1）にはしない。
GPU に置いているときは約 0.7GB を 30 分持つが、空きの決め方（`gpu.embed_options`）と、文字起こしのモデルを載せる前に下ろす口
（`gpu.make_room`）は今までどおり。qwen3:8b は変えていない（約 5GB を RAM に置いたままにしないため）。

## 2b. 測っていて見つけた: /llm の時間切れ

- 11/15 の /llm: 答えた 18 回・600 秒で時間切れ 46 回・時間切れの直後に「Ollama が動いていない」で即断り 11 回。
- 答えた 18 回のうち 16 回は 180 秒より長い（247〜528 秒）。iPhone は 180 秒で待つのをやめる（`HomePC.llm`）ので、受け取られて
  いない。iPhone の `llm.pcFallback`（PC の言語モデルで作れた数）は 11/15 に 1 回だけ。
- CPU だけの qwen3:8b は 1 秒に約 2.2 トークン。Ollama は 1 度に 1 つしか答えない（-np 1）ので、誰も待っていない答えを作るあいだ
  次の頼みも待たされ、時間切れが続いた（11/15 1:00〜9:00）。
- 同じ夜、8,741 トークンの頼みが 45 回、2,050 トークンに切り詰められていた（Ollama の「truncating input prompt」。文脈 4096）。
  iPhone が同じ長い頼みを何度も送り直している。

**直したこと（PC）:** /llm で待つのを 175 秒までにした（`llm_timeout`。config.json の `"llm_timeout_seconds"`、30〜600）。
時間切れは「Ollama が動いていない」にしない（つながらないときは今までどおり）。11/15 の Ollama の記録では、こちらが接続を
閉じたところでその頼みは 500 で終わっている。長い頼みの切り詰めと、iPhone の送り直しは直していない（下の「まだ」）。

## 3. 夜に qwen3:8b を GPU で動かせるか

実測（RTX 2070 SUPER・8192MB）:

- Windows とほかのソフトだけの空き（whisper を載せる前）: 6069〜6727MB（11/13〜15 の 7 回）
- whisper（large-v3・int8_float16）: 約 1920〜2458MB。載せたあとの空き: 3906〜4702MB。いま（1:40）の使用 4314MB・空き 3676MB
- qwen3:8b を全部 GPU に載せたとき（11/07 の Ollama の記録、文脈 4096）: 重み 4644MB・KV 576MB・計算 108MB ＝ 約 5328MB
  （ほかに CUDA の初めの分）。bge-m3 は 577MB＋80MB。
- 夜の割り当て（1:00〜6:00 に 30 分仕事が無ければ whisper を下ろす）は、11/13〜16 で 11/13 5:58 の 1 回だけ。
  時計・PLAUD の仕事が夜も来るので、30 分あくことがほとんどない。

判断: **入れない。** whisper を下ろしても、空き 6069〜6727MB から残しておく分（gpu_free_min_mb 1024MB）を引くと 5045〜5703MB で、
約 5.3GB＋CUDA の分には足りない夜がある。whisper と並べるのは空き 3.9〜4.7GB なので無理。長い頼み（8,741 トークン）を
切り詰めずに載せるなら KV がさらに約 1.2GB 要る。もともと夜の割り当て自体がほとんど起きない。
既にある仕組み（`gpu.ollama_options`：GPU に文字起こしのモデルが無いあいだは num_gpu を付けない）で、夜に whisper が
下りたときは今までも qwen3:8b は GPU を使ってよいことになっている。文字起こしは、そのあいだ CPU のモデル（haas・reazon）で受ける。

## 長すぎる頼み（2026-11-16。本人「B で」）

- PC: /llm は頼む文が 5,000 文字（`llm_prompt_max_chars`）より長ければ、Ollama に渡さずすぐ 413 `{"error", "max_chars"}` を返す。
  log.txt の実測で 4,558 文字までは答えていて、11,194 文字（8,741 トークン）は切り詰められていた（1 文字およそ 0.78 トークン・文脈 4096）。
- iPhone: 413 の `max_chars` を覚え、それより長い頼みは PC に送らない（`llm.tooLong` と数える）。見出しと要点は Claude・Groq が今までどおり作る。
- 確かめ: `pc/v19checks_llm.py` の check_too_long。

## まだ（確かめていない・決めること）

- 取りやめが `claude.failed` のわけ、という見立ては仮。新しい版の iPhone の数（claude.cancelled）で確かめる。
- iPhone の取りやめそのもの（通知で起きた 10 秒の中で Claude を始める・取りやめても PC は払う）は直していない。
- /llm の長い頼み（約 11,000 文字・8,741 トークン）は CPU の qwen3:8b ではどのみち間に合わない。iPhone から送らない・
  PC で短く断る・小さいモデルにする、のどれにするかは本人が決める。
- keep_alive "30m" で bge-m3 の起動し直しが減ったかは、入れたあとの Ollama の記録で数え直す。
- 確かめ: `python pc/v19checks_llm.py`（作り物の Ollama と一時フォルダ）。
