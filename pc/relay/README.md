# 家の PC の控えの見張り（relay）

強化案 62（2026-11-15）。**まだどこにも置いていません**。どこに置くかは本人が決めます（母艦の `state/DECISIONS.md`「家の PC の控えをどこに置くか」）。

## なにをするか

家の PC（LifeLog PC）が止まると、見張りも知らせも家の PC から出ているので何も届きません。
`relay_watch.py` は**別の機械**から 15 分ごとに次を見て、6 時間黙ったら 1 通だけ知らせます（12 時間に 1 回まで・戻ったら 1 通）。

- 家の PC の `GET /hello`（Tailscale の中から）。HTTP の答えが返れば（401 でも）生きているとみなします。
- （省ける）ドライブの同期フォルダのいちばん新しいファイルの時刻。

一度もつながったことが無いうちは鳴らしません。知らせの文に会話の中身・名前・URL は入りません。
標準のライブラリだけで動きます（Python 3.9 以上・`pip install` は要りません）。

## 置き方（どれか 1 つ）

| 置き場所 | はじめの費用 | 毎月 | よい所 | 気をつける所 |
|---|---|---|---|---|
| 小さな常時稼働の PC（中古のミニ PC など） | 1.5〜2.5 万円 | 電気代 150〜250 円（6〜10W） | 家の中で完結・ドライブの同期も見られる | 家ごと停電・回線断のときは一緒に止まる |
| Raspberry Pi | 1〜1.5 万円（電源・SD 込み） | 電気代 100 円ほど（3〜5W） | 小さく静か | SD カードが壊れやすい（年 1 回の作り直しを見込む） |
| 使っていないスマートフォン（Android と Termux） | 0 円 | ほぼ 0 円 | 買わなくてよい | 電池の劣化・OS が裏で止めることがある |
| クラウドの小さな VM | 0 円 | 0〜1,000 円（無料枠・最小の VPS） | 家の停電・回線断でも知らせが届く | ドライブを見るには rclone の設定が要る。無料枠は条件が変わることがある |

費用はどれも 2026-11 時点の目安です（仮）。どれでも Tailscale（個人は無料）をその機械に入れ、家の PC と同じ tailnet に入れます。

## 動かし方

1. その機械に Python 3.9 以上と Tailscale を入れ、`relay_watch.py` だけを写す。
2. 環境変数を入れる（**このリポジトリやファイルに書かない**。systemd の `Environment=`・タスクスケジューラの「ユーザー環境変数」・`~/.profile` など）:
   - `RELAY_HELLO_URL` … 家の PC の `/hello`（Tailscale の名前とポート）
   - `RELAY_CHANNEL` … `line`（Messaging API の broadcast・`RELAY_LINE_TOKEN`）、`ntfy`（`RELAY_NTFY_URL`）、`webhook`（`RELAY_WEBHOOK_URL`）、`print`
   - 省ける: `RELAY_HELLO_KEY`・`RELAY_DRIVE_DIR`・`RELAY_QUIET_HOURS`（既定 6）・`RELAY_REPEAT_HOURS`（既定 12）・`RELAY_STATE`
3. 15 分ごとに `python relay_watch.py --once`（cron の `*/15 * * * *`・systemd の timer・タスクスケジューラ）。または `--loop` で回しっぱなし。
4. はじめに `python relay_watch.py --selftest` で確かめる。

`line` の broadcast は **Bot の友だち全員に届きます**（宛先を選べません）。家の PC の知らせと同じ Bot を使うなら同じことです。
LINE Notify（`line_notify`）は 2025-03-31 に終わったサービスで、残してあるだけです。

## やらないこと

- 受け口（録音の受け取り・文字起こし）は写しません。見張りだけです。
- 家の PC を遠くから起こす・直すことはしません。知らせるだけです。
