# 時計から家の PC への外の道（2026-11-07）— iPhone と時計の側

時計 → iPhone の送り（WatchConnectivity の `transferFile`）は Apple に抑えられていて、日によっては届くまで6時間かかる。
家の Wi-Fi では時計から PC に直接送っていた（`docs/v8-latency.md` の「時計の区切りを早く届ける」）が、家の外では届かなかった。
PC が Tailscale の Funnel で「送るだけの入口」を外に出せるようになったので、時計はそこにも送る。PC の側は別に作る（下の約束だけを使う）。

## PC との約束

- `/hello` の `features` に `"watchroute"` があるときだけ使う（古い PC なら今までどおり家の中の住所だけ）。
- `GET /watch-route`（いつもの宛先・いつもの合言葉）→ `{"url": "https://desktop-xxxx.tailXXXX.ts.net" | null, "token": "…", "funnel": true|false, "port": 47617}`。
  Funnel がオフなら `url` は null。
- 外の入口（Funnel。正しい https の証明書なので ATS の例外は足さない）:
  - `GET <url>/w/ping`（`Authorization: Bearer <時計用の合言葉>`）→ 200 `{"ok":true}`（いまは使っていない）
  - `POST <url>/w/jobs?<今までの WatchDelivery.jobQuery と同じ>`（`Authorization: Bearer <時計用の合言葉>`、中身は m4a・8MB まで）。
    200 = しまった（もう知っていた）・401 = 合言葉が違う・429 = しばらく受け付けない・400 = 名前が違う。名前は iPhone で付く名前（`WatchDelivery.phoneName`）。

## iPhone（`LifeLog/WatchDirect.swift`）

- 家の PC を使っていて「時計から家の PC に直接送る」がオンのとき、`GET /watch-route` を聞く。
  起動して時計とつながったとき・前に出たとき（6時間に1回まで。聞けなければ10分は聞かない）と、PC の設定（オンオフ・宛先・合言葉・家の中の住所・時計から直接）が変わったとき（2秒待ってすぐ）。
- 宛先は `WatchDelivery.publicBaseURL` で確かめる: `https://` で、名前が `.ts.net` で終わり、道・問い・番号（443 以外）が付いていないものだけ。ほかは無いのと同じ。
- 時計用の合言葉は iPhone の Keychain（`com.off53jub.lifelog` / `pc-watch-token`。PC の合言葉とは別の名前）、宛先は UserDefaults（`pcWatchRouteURL`）に置く。ログには出さない。
- 時計へは `transferUserInfo` の `pcPublicURL`・`pcPublicKey` で送る（空なら時計は消す）。この起動で前に送ったものと違うときだけ。
  家の PC で文字起こしを切る・「時計から家の PC に直接送る」を切る・合言葉を消すと、空を送る。
- 時計に「直接送る」（`pcDirect`）を伝えるのは、家の中の住所か外の道のどちらかがあるとき（前は家の中の住所があるときだけ）。
- 設定の「時計から直接」の下に、いまの道を1行出す（「家の外でも送れます（Tailscale の Funnel）」など）。
- 自己点検の「時計」に「時計から PC への外の道」を出す（あり／なし・時計が受け取ったか・直近24時間に外の道で送れた数・合言葉が違うと言われたか・PC に聞いた時刻）。

## 時計（`LifeLogWatch/WatchPC.swift`）

- 時計用の合言葉は時計の Keychain（`pc-public-key`。家の PC の合言葉 `home-pc-key` とは別）、宛先は UserDefaults に置く。
- 送るたびに道を選ぶ（`WatchDelivery.directRoute`）: 外の道（宛先と合言葉がある）ならいつもそちら（家の中でも外でも届く）。
  無い・合言葉が違うと言われた・しばらく待つあいだは、家の中の住所（今までどおり `/jobs` と PC の合言葉）。
- 電池の決まり（低電力モード・20% より少ないとき（充電中を除く）は送らない）と、モバイル通信では送らないのは今までどおり。
  家の外では iPhone の Bluetooth を通るので、待つ時間を延ばした（途切れたら30秒・全部で5分）。
- 返事ごと（`WatchDelivery.directOutcome`）: 届かなかったら10分は試さない（今までどおり）。外の道で 401 なら新しい合言葉が届くまで外の道は使わない。
  429 なら15分は外の道を使わない。400 などはその区切りだけ送らない。
- 追いかけて送る（`WatchDelivery.catchUpPick`）: 区切ったとき・送れたときに、時計に残っていて（まだ iPhone に届いていない）まだ PC に送っていない、
  24時間より新しい区切りを、古い順に3つまで1つずつ送る（ほかの区切りを送っている途中なら、それが終わってから）。
- `transferFile` の `pc` の印は今までどおり「PC に送り始めた・送れた」とき。iPhone はこの印があれば、先に PC の答えを見る。
- iPhone への様子（applicationContext）に `pcPublic`（外の道があるか）・`pcPublicSent`（直近24時間に外の道で送れた数）・`pcPublicRefused`（合言葉が違うと言われた）を足した。

どれも実機ではまだ確かめていない。
