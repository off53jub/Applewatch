# s19「休日のライフログ」家の PC の分（2026-11-21）

担当 P。中身は `pc/holidaymarks.py`（新しいモジュール）。既存への足しは呼び出しの数行だけ:
`knowme.py`（見回りの 1 つと GET /holiday-marks）・`voicetone.py`（1 行: 信用 low にする）・`records.py`（車内の印 inCar・vehicle を読む）。
確かめ: `python pc/v23checks_holiday.py`（作り物の記録・母艦・一時フォルダ）。

## 印の置き場所と形（母艦はこれを読む）
- HOME/holiday-marks/<日>.json、母艦 `inbox/holiday-marks/days/<日>.json`、確かめ待ちの束 `inbox/holiday-marks/needs_check.json`
- 記録（records）は書き換えない。会話の `conversation_start`（ISO）・`start_ms` に結ぶ。印は `marks[]`:
  `kind`（loud_venue / in_car_media / media_suspect / couple_topic）・`effect`（speaker_caution＝話し手の判定を控えめに /
  not_self＝本人の発話にしない / needs_check＝本人の話と決めず確かめ待ち）・`scope`（conversation / lines。lines のときは `line_times`＝行の時刻 ms）・
  `label`（見立て（仮））・`why`・`evidence`。couple_topic だけ `pending`・`question`・`words`。
- 声の調子（voice-tone/<日>.json）の会話には、印があれば `trust: "low"`・`tier_cap: "tentative"`・`holiday_marks: [kind…]` が付く。

## 仮のしきい値（config.json の "holiday_marks" で上書き）
| 名前 | 仮の値 | 意味 |
| --- | --- | --- |
| venue_noisy_share | 0.25 | 場の言葉がある会話で騒がしい行がこの割合以上 |
| venue_sound_share | 0.35 | または周りの音（音楽・拍手・笑い）の行がこの割合以上 |
| venue_min_lines | 6 | 行が少ない会話には付けない |
| car_sound_share | 0.1 | 車内の印が無いとき、車の音の行の割合 |
| car_navi_min_lines | 2 | 車内の印が無いとき、ナビらしい言い回しの行の数 |
| media_min_lines | 8 | メディアの音の疑いに要る行の数 |
| media_top_share | 0.8 | いちばん多い声の行の割合 |
| media_holiday_only | true | 休日だけ（休日でない日は変えない） |
| couple_min_speakers | 3 | 3 人以上の会話だけ |
| pending_days | 14 | 確かめ待ちの束に入れる日数 |

休日の判定は母艦 `state/holiday/days.json`（M1）があればそれ、無ければ土日だけ（祝日は分からない）。滞在は `state/stays_labeled.json`。
