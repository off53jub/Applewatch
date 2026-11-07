# 時計の外の道（2026-11-07）— 時計・iPhone と家の PC（版 10）の決まり

本人の困りごと: 時計の 5 分の区切りが iPhone に届くまで、Apple の都合（WatchConnectivity の `transferFile` の間引き）で
長いと 6 時間かかった。時計は家の Wi-Fi では区切りを PC に直接送れる（docs/v8-latency.md の終わり）が、外ではできなかった。

そこで、PC に「預けるだけ」の別の受け口を作り、Tailscale Funnel でインターネットに出す:

    https://desktop-7ki97gp.tail997110.ts.net  →（Tailscale Funnel）→  http://127.0.0.1:47617（時計の外の道）

決まりの前提は docs/v7-plan.md・docs/v8-latency.md と同じ（日時は ISO 8601 の UTC ミリ秒つき・PC は受け取ったものを外に出さない）。
PC の版は 10。`/hello` の features に、時計の外の道が動いているときだけ `watchroute` を足す。iPhone は features を見て使う。
名前（道・項目・ファイル）は、時計・iPhone・PC で同じものを使う。変えるときは3つを一緒に直す。

## 1. 時計の合言葉

- ふだんの合言葉（config.json の key）とは別の合言葉。PC の `HOME/watch-token.txt` に置く（`secrets.token_urlsafe(32)`、43 文字）。
  初めて時計の外の道を始めたときに作る。ふつうのファイル（%LOCALAPPDATA% の中なので、その Windows の人だけが読める）。
- PC は画面にも記録にも出さない。起動したときの画面には「時計の外の道の合言葉: 用意しました」とだけ出す。
- 作り直すとき: LifeLog PC を止めて watch-token.txt を消し、起動し直す。iPhone は次に GET /watch-route を読んだときに新しいものを時計に渡す。

## 2. 時計の外の道（別の受け口）

- PC は `127.0.0.1` の番号 `47617`（`--watch-port`。`0` で使わない）だけで待つ（裏のスレッドの ThreadingHTTPServer）。
  この PC の中だけで待つので、家の中の番号や Tailscale の 100.x の番号からは届かない。外からは Funnel を通ってだけ届く。
  番号がほかのソフトに使われていれば、記録に書いて、時計の外の道は無しで続ける（ふだんの受け口はいつもどおり）。
- 受けるのは次の2つだけ。どちらも `Authorization: Bearer <時計の合言葉>`。
  - `GET /w/ping` → `200 {"ok": true}`（つながるかを確かめる）
  - `POST /w/jobs?<POST /jobs と同じ query>`（`name`・`chunk_start`・`chunk_end`・`sent`・`hints`・`weights` など）→
    iPhone の `POST /jobs` と同じに預かる（同じ置き場所・同じ答え `{"id", "status"}`）。ちがうのは:
    - `wait` は見ない（待ち合わせをしない。すぐ答える）
    - 音声は 8MB（8,388,608 バイト）まで。大きければ 413
    - `name` は `^\d{8}-\d{6}[A-Za-z0-9._-]*-w\.m4a$` の形だけ（時計の区切りの名前）。ほかは 400
    - 仕事に `"origin": "watch"` を付ける
- ほかの道・ほかのやり方は全部 `404 {"error": "not found"}`（送られた中身は読み捨てる）。`/dash`・`/records`・`/jobs`・`/hello`・
  `/watch-route` などは、この受け口からは何も見えない。
- 合言葉は、かかる時間が中身によらない比べ方で比べる。違えば 401。
- **10 分に 10 回**合言葉が違えば、それから **10 分のあいだ、この受け口はだれにも 429** を返す（正しい合言葉でも。`Retry-After: 600`）。
  始めたときに記録に1回だけ書く。
- 1つの受け付けで相手を待つのは 60 秒まで。
- 記録の書き方: `時計から（外の道） 20261107-135444-w.m4a: 1.2 MB を預かりました`。時計の合言葉・ヒントなどの query は書かない。

## 3. 同じ名前を1つにまとめる

- 時計が外の道で預けた区切りを、あとで iPhone が同じ名前で `POST /jobs` に送ってきても、2つ目の仕事は作らない
  （今までの「同じ名前はもう預かっている」と同じ。音声は読み捨てる）。
  - `wait` なし → 預かっている仕事の様子 `{"id", "status"}` をすぐ返す。
  - `wait=1` → 預かっている仕事のでき上がりを待って、`GET /jobs/<名前>` と同じ形で答える（docs/v8-latency.md の待ち合わせ）。
    渡せたら「渡した」（handed）と覚え、「できた」の見えない通知は送らない。
- 時計が同じ名前をもう一度外の道で送っても同じ（失敗した仕事だけ預かり直す）。
- 文字にするときの設定（ヒント・重み）と timing の時刻は、先に届いた送り（外の道なら時計）のもの。

## 4. ふだんの受け口で足したもの

- `GET /watch-route`（ふだんの合言葉）→
  `{"url": "https://<Tailscale の名前>" または null, "token": "<時計の合言葉>", "funnel": true|false, "port": 47617}`
  - `funnel` は、`tailscale funnel status --json`（だめなら `tailscale serve status --json`）の答えで、
    `AllowFunnel["<名前>:443"]` が true で、`Web["<名前>:443"].Handlers` のどれかの `Proxy` が
    この PC の中の時計の外の道（`http://127.0.0.1:47617`・`localhost:47617`・`47617` など）に向いているときだけ true。
    前で動かしている `tailscale funnel`（`--bg` なし）の設定は `Foreground` の中にあるので、そこも見る。名前の末尾の点は取る。
  - `funnel` が false なら `url` は null。様子は 60 秒覚えておく。
  - 時計の外の道が動いていなければ 503。答えは覚えさせない（`Cache-Control: no-store`）。
  - iPhone は url と token を時計に渡す。時計は、家の Wi-Fi の外にいるとき（家の中の住所に届かないとき）、この url の
    `/w/jobs` に区切りを預ける。
- `GET /jobs?origin=watch` → `{"jobs": [...]}`。時計から預かった仕事だけを新しい順に。
  `GET /jobs`・`GET /jobs/<名前>` の各仕事には、時計から預かったものだけ `"origin": "watch"` が付く（ほかの項目は今までどおり）。
  `POST /jobs` の短い答え `{"id", "status"}` は今までどおり（origin は付けない）。

## 5. iPhone を起こす

- 時計から預かった仕事ができ上がり、待ち合わせで iPhone に渡せていなければ、iPhone から預かった仕事と同じく
  「できた」の見えない通知（kind `job`、中身に仕事の名前）を送る。時計の外の道には iPhone の宛先が無いので、
  通知を登録した端末の全部に送る。回数の上限は今までどおり（端末ごとに 10 分に 1 回）。APNs の鍵が無ければ何もしない。
- 夜に GPU のモデルを下ろしていれば、外の道から預かったときにも戻す（iPhone から仕事が来たときと同じ）。

## 6. 見守りの画面

- 「時計の外の道」の節: 受け口が動いているか・Funnel がこの受け口に向いているか・今日（PC の時計で 0 時から）預かった区切りの数・
  合言葉の違いが続いて断っているか。時計の合言葉は出さない。

## 7. Funnel の設定（持ち主が手で1回だけ）

- LifeLog PC は Tailscale の設定を変えない（`funnel status`・`serve status` を読むだけ）。持ち主が1回だけ、手で打つ:

      tailscale funnel --bg 47617

  これで `https://<Tailscale の名前>/` が `http://127.0.0.1:47617` に取り次がれる。やめ方は Tailscale の説明
  （`tailscale funnel --help`）を見る。やめれば `/watch-route` の `funnel` は 60 秒のうちに false になる。

## PC 側で決めたこと

- 確かめの台本 `--check-v10` は、自分で一時のフォルダに切り替え、空いている番号を使い、本物の HOME と本物の Tailscale を使わない
  （Funnel の様子は作り物の JSON で確かめる）。CI（.github/workflows/pc.yml）でも、Python と exe の両方で動かす。
- 2026-11-07 にこの PC で Funnel をオンにしたときの `tailscale serve status --json` の答え（この形を前提にしている）:

      {"TCP":{"443":{"HTTPS":true}},
       "Web":{"desktop-7ki97gp.tail997110.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47617"}}}},
       "AllowFunnel":{"desktop-7ki97gp.tail997110.ts.net:443":true}}
