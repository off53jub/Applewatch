# s19 休日のライフログ（アプリの分。2026-11-21）

番号は母艦に出した 休1〜休50 の番号。しきい値はどれも仮（データがたまったら測り直す）。
決まりは `Shared/Audio/HolidayRules.swift`（時計と iPhone）と `LifeLog/Holiday.swift`（iPhone）。テストは `LifeLogTests/HolidayTests.swift`。

## 母艦に渡すもの

### ドライブ「LifeLog/休日」の `lifelog-holiday-YYYY-MM-DD.json`（1 日 1 ファイル。終わった日だけ・書き直さない）

```json
{
  "source": "LifeLog", "version": 1, "day": "2026-11-22",
  "dayOff": {"off": true, "why": "土日"},            // why は 土日・祝日・アプリの休み。休みでなければ {"off": false}
  "drinks": {"count": 2, "at": ["2026-11-22T19:00:00+09:00", "..."]},   // 時計の「お酒 +1」。0 杯なら無い
  "notes": [{"kind": "best", "at": "...", "text": "...", "ref": "..."}],  // best・golf・payment・venue。ref は決済の id・会場の名前
  "places": [{"at": "...", "name": "...", "answer": "yes"}]              // 滞在の直後の「さっきの所は〇〇？」の答え
}
```

- 2026-11-01 から書く（休みの印はカレンダーからさかのぼって分かる）。iPhone だけ・Google にログインしているときだけ。
- 一言（notes の text）は本人の言葉。母艦は「いいこと帳」（best）・ゴルフ（golf）・休日の出費（payment）・映画の感想（venue）に使う。

### ヘルスケアの書き出し（`LifeLog/ヘルスケア/lifelog-health-*.json`）

- metrics に `heart_rate_variability`（units `ms`、data `[{"date","qty"(平均),"Min","Max"}]`）を足した（休45）。14 日の基準と比べる見立て（仮）は母艦（M1）。
- ワークアウトの名前に「ゴルフ」を足した（休32）。

### 家の PC への様子（PCDiag の watch detail。省略できる）

| 名前 | 形 | 中身 |
|---|---|---|
| watchInterruptions | 整数 | 今日の時計の中断（アラーム・電話・Siri）の回数（休10） |
| watchResumed | 整数 | 今日、中断のあとに録音を流し直せた回数（休10。PR #85 の効き目） |
| watchBatteryAt | `[[時刻(1970からの秒), 電池0〜1, 溜めていたら1]]` | 1 時間に 1 つ・直近 48 個（休8） |
| watchAwayHolding | 真偽 | いま外出モードで区切りを溜めているか（休8） |
| watchCrowd | 真偽 | いま「初めての人が多い」モードか（休17） |

### 家の PC への会話の記録（POST /records/<日>）と区切り（POST /jobs・時計の直接送り）

- 休13 車内の印: 車（CarPlay・車の Bluetooth）につないでいたあいだの会話に `"inCar": true`・`"vehicle": "car"` を足す
  （家の PC の records.py が読む名前。担当 P の PR #86 に合わせた。同期の形は変えず、PC に送る中身にだけ足す。印が無い会話には付けない）。
- 区切りの問い（POST /jobs と時計の直接送り）にも、同じ印を `inCar=1` で付ける（PC は無くても動く）。
  iPhone の区切りは CarAudioLog の時間で、時計の区切りは iPhone が送る「車につないだ時刻」（applicationContext の carSince）で決める。
- 電車などの乗り物（動きの vehicle）は今は印にしない（車のナビの声を外すためなので、車につないだときだけ）。

## 時計と iPhone のあいだ（applicationContext・transferUserInfo）

- iPhone → 時計: `holidayDay`（今日が休みならその日・違えば空）・`holidayLowBattery`・`holidayAwayMode`・`holidayAway`・`carSince`
- 時計 → iPhone: 様子に `interruptions`・`resumed`・`batteryAt`・`awayHolding`・`crowd`。「お酒 +1」は `{"drink": 時刻}`

## 知らせ（休日だけ・1 日 6 通まで（仮））

| 案 | いつ | 上限 | 初め |
|---|---|---|---|
| 休6・休7 | その日はじめて「自宅」を出たとき（5〜15 時。仮） | 1 | 点検はオン・録音の促しはオフ |
| 休9（時計） | 時計の電池が 20%（仮）を切った | 1 | オン |
| 休21 | 知らない所に 15〜30 分（仮）いて出た直後（30 分より長い所は 91 が聞いている） | 3 | オン |
| 休22 | かざして払った直後 | 3 | オン |
| 休32 | ゴルフのワークアウトがあった日の 13 時（仮）より後 | 1 | オン |
| 休34 | 映画館・劇場・ライブ会場（100 m・仮）を出たとき。中では録音を休む（最長 4 時間・仮） | 1 | オフ |
| 休42 | 21:00（仮） | 1 | オン |

一言の知らせは時計にも写り、時計で話して答えられる（iPhone の通知の文字入力）。

## 時計の外出モード（休8。初めはオフ）

iPhone が「自宅」を出たと分かったら、時計は区切りを iPhone にも家の PC にも送らずに溜め、家に戻るか充電を始めたら送る。
電池の効き目は仮説。`watchBatteryAt` の「溜めていた／いない」で 1 時間あたりの減りを比べる（`HolidayRules.drainPerHour`）。

## 休16 一緒にいた人の確かめ

アプリは「自分を知る」の問いの group `with_people`（answer `yesno`）を「一緒にいた人（仮）」として出す。
家の PC の `knowapp._extra_questions` は今は group を `general`・answer を `text` にしてしまうので、担当 P が通す必要がある。
