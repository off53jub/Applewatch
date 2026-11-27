# s33 家の PC（担当 p）

取り決め K33-1・K33-2。中身は `pc/s33pwork.py`、確かめは `pc/v33checks_s33p.py`（v32 の最後から続けて呼ばれる）。

## 口
| 口 | 中身 |
|---|---|
| `GET /s33`（Bearer） | 母艦の `state/s33_for_app.json` をそのまま返す。覚え・大きすぎ（12MB 超）・壊れ・無い・止めてある・母艦なし → `{"available":false,"reason":…}`。features `"s33"`（ファイルがあって止めていないとき） |
| `POST /feedback` `ramen_mark` | `at`（ISO・必須）`place`（80 字まで・null 可）`lat`/`lon`（数・範囲内・null 可）。`at` は食べた時刻なので上書きせず、届いた時刻は `received_at` |
| `POST /feedback` `feature_seen` | `day`・`counts`（名前→0 以上の整数・200 個まで。名前は英数字と `_.:- ` で 64 字まで） |
| `POST /feedback` `device_ok` | `build`（英数字と `.` で 20 字まで）・`screens`（名前 100 個まで）・`crash`（bool 必須） |
| `GET /s33/ports`（Bearer） | 強30 の PC 側。点検だけ（閉じない） |

POST は母艦の `inbox/app_feedback.jsonl` に 1 行（今の道）。おかしな形は 400。ログには kind だけで、場所・数・画面名は書かない。

## 止める
母艦の `state/s27_work_config.json` に `"s33p": {"s33": false}`（無ければオン）。`/s33` と features が止まる。POST は止めない（受けるだけ）。

## /s33/ports の返事（分かる範囲）
- `ports`: 受け口の番号と bind（main・watch）。
- `routes`: `lifelog_pc.py` の do_GET・do_POST を読んで拾った道（method・path・auth）。`self.authorized()` の後ろは `bearer`、それ以外は `other_auth`（今は /dash・/edits・/edits/ack・/notify/urgent。それぞれ別の守り方で、/edits は中で Bearer を確かめる）。
- `funnel`: `{"known","on"}` だけ。Funnel の名前は返さない。`reachable_from_outside` は Funnel がオンのときだけ中身が入り、`via_funnel_if_on` は「オンなら外から届く道」（/w/ping・/w/jobs は時計の合言葉、LINE の 2 つは署名）。
- 鍵・合言葉の値は返さない（試しで確認）。ソースを読んだ一覧なので、実際の待ち受けを調べたものではない。

## 手入れした所
`appfeeds.py`（parse_feedback に 3 種・`_http_inbox` で ramen_mark の `at` を残す・ログの詳細を kind だけに）、`lifelog_pc.py`（import・GET の口・features の 3 か所）。

## 試し
65 項目。作りものの母艦で、あり・無し・壊れ・大きすぎ・止める・覚え・401・3 種の受けと 400・上限ちょうど・ports に鍵が入らないこと・inbox の中身。既存の v25〜v30（連鎖で v31・v32 も）・v24 系を Python311 で通した。
