"""2026-11-29（s39）: iPhone と iPad の 2 台の記録のつなぎ合わせ（s39overlap.py・records.RecordStore.receive）を確かめる。

    python pc/v39checks_s39two.py          （v37checks_s37v.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME は使わない（一時フォルダに作りもの。文は「見本の文」だけ）。
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import forget  # noqa: E402
import records  # noqa: E402
import s39overlap  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v39s-"))


def _t(sec: int) -> str:
    """2026-11-29 10:00:00Z から sec 秒あと"""
    return records.iso_ms(records.parse_time("2026-11-29T10:00:00Z", "t") + sec * 1000)


def _line(sec: int, text: str, conf: float | None = None) -> dict:
    out = {"time": _t(sec), "text": text, "speaker": "自分"}
    if conf is not None:
        out["confidence"] = conf
    return out


def _conv(start: int, end: int, lines: list[dict]) -> dict:
    return {"start": _t(start), "end": _t(end), "closed": True, "lines": lines}


def _body(convs: list[dict], device: str | None = None, kind: str | None = None, **extra) -> bytes:
    body = {"conversations": convs, "removed": [], "summaryWritten": False, **extra}
    if device is not None:
        body["device"] = device
    if kind is not None:
        body["deviceKind"] = kind
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


def _store(name: str, config: dict | None = None) -> records.RecordStore:
    home = TMP / name
    return records.RecordStore(home, lambda _m: None, lambda: config or {})


def _lines(store: records.RecordStore, day: str) -> list[dict]:
    raw = json.loads(store.path(day).read_text(encoding="utf-8"))
    return [line for c in raw["conversations"] for line in c["lines"]]


DAY = "2026-11-29"


def check_similarity() -> int:
    failed = 0
    failed += say(s39overlap.norm("見本の文、です！ ＡＢ") == "見本の文ですab", "正規化: 句読点・空白を除き、全角を半角・小文字に")
    failed += say(s39overlap.similarity("見本の文を読みます", "見本の文を読みます。") == 1.0, "似ている度合い: 句読点だけの違いは 1")
    failed += say(s39overlap.similarity("見本の文を読みます", "見本の文") == 1.0, "似ている度合い: 4 文字以上が入っていれば 1")
    failed += say(s39overlap.similarity("見本", "見本の文を読みます") < 0.6, "似ている度合い: 短すぎる一致（3 文字以下）は 1 にしない")
    failed += say(s39overlap.similarity("見本の文を読みます", "見本の文を呼びます") >= 0.6, "似ている度合い: 1 文字の聞き違いは同じ発言とみなす")
    failed += say(s39overlap.similarity("今日は晴れ", "明日の予定") < 0.6, "似ている度合い: 違う文は低い")
    cfg = s39overlap.settings({"two_devices": {"window_s": 10, "similarity": 0.9, "on": False, "contain_min": "x"}})
    failed += say(cfg["window_s"] == 10.0 and cfg["similarity"] == 0.9 and cfg["on"] is False and cfg["contain_min"] == 4,
                  "config の two_devices でしきい値を変えられる（読めない値は既定のまま）")
    return failed


def check_legacy_unchanged() -> int:
    """印の無い古い送りだけの日は、今までと同じ（届いたまま <日>.json）"""
    failed = 0
    store = _store("legacy")
    data = _body([_conv(0, 60, [_line(0, "見本の文その一")])])
    result = store.receive(DAY, data)
    failed += say(store.path(DAY).read_bytes() == data and not store.device_paths(DAY) and result["devices"] is None,
                  "古い形: 端末の印が無ければ、今までどおりの置き場に届いたまま置く")
    one = _store("one")
    data = _body([_conv(0, 60, [_line(0, "見本の文その一")])], device="aaaa1111", kind="phone")
    one.receive(DAY, data)
    failed += say(one.path(DAY).read_bytes() == data and len(one.device_paths(DAY)) == 1,
                  "1 台だけ: 端末ごとに控え、<日>.json は届いたまま（今までと同じ中身）")
    return failed


def check_overlap() -> int:
    """2 台・重なりあり: 同じ発言は 1 行に。iPhone の行を残す。重ならない行は足す"""
    failed = 0
    store = _store("overlap")
    phone = _body([_conv(0, 120, [_line(0, "見本の文を読みます", 0.7), _line(40, "見本の二つ目の文です", 0.6)])],
                  device="aaaa1111", kind="phone", work=[_t(0)])
    pad = _body([_conv(2, 200, [_line(3, "見本の文を読みます。", 0.8), _line(41, "見本の二つめの文です", 0.95),
                                 _line(150, "iPad だけが聞いた見本の文", 0.5)])],
                device="bbbb2222", kind="pad")
    store.receive(DAY, phone)
    result = store.receive(DAY, pad)
    lines = _lines(store, DAY)
    texts = [line["text"] for line in lines]
    failed += say(len(lines) == 3, f"重なりあり: 3 行になる（同じ発言 2 組を 1 行ずつに。今は {len(lines)} 行）")
    failed += say(texts[0] == "見本の文を読みます" and lines[0]["device"] == "aaaa1111" and lines[0]["overlap"] is True
                  and lines[0]["devices"] == ["aaaa1111", "bbbb2222"],
                  "重なりあり: 確からしさの差が小さいときは iPhone の行を残し、元の端末と「まとめた」印を付ける")
    failed += say(texts[1] == "見本の二つめの文です" and lines[1]["device"] == "bbbb2222",
                  "重なりあり: iPad の行の確からしさが仮の差（0.2）より高ければ iPad の行を残す")
    failed += say(lines[2]["device"] == "bbbb2222" and "overlap" not in lines[2], "重なりあり: iPad だけの行は足す（印は端末だけ）")
    raw = json.loads(store.path(DAY).read_text(encoding="utf-8"))
    failed += say(len(raw["conversations"]) == 1 and raw["mergedFrom"] == ["aaaa1111", "bbbb2222"]
                  and raw["conversations"][0]["end"] == _t(200),
                  "重なりあり: 時刻の重なる会話は 1 つにまとめ、終わりを延ばす")
    failed += say(result["devices"]["merged"] == 2 and result["devices"]["replaced"] == 1, "重なりあり: 数を返す")
    parsed = store.day(DAY)
    failed += say(parsed is not None and parsed["conversations"][0]["work"] is True,
                  "重なりあり: 合わせた日も今までどおり読める（職場の印も残る）")
    # 控え: 端末ごとのファイルはそのまま
    failed += say(store.device_path("bbbb2222", DAY).read_bytes() == pad and store.device_path("aaaa1111", DAY).read_bytes() == phone,
                  "控え: 端末ごとのファイルは届いたまま残す")
    # 同期で iPhone の会話を持っている iPad が送っても、2 回入らない
    pad2 = _body([_conv(0, 120, [_line(0, "見本の文を読みます", 0.7), _line(40, "見本の二つ目の文です", 0.6)])],
                 device="bbbb2222", kind="pad")
    store.receive(DAY, pad2)
    failed += say(len(_lines(store, DAY)) == 2, "同期で受け取った同じ会話を iPad が送っても、2 回入らない")
    return failed


def check_no_overlap() -> int:
    """2 台・重なりなし: 別の時間の会話はそのまま足す"""
    failed = 0
    store = _store("apart")
    store.receive(DAY, _body([_conv(0, 60, [_line(0, "見本の朝の文")])], device="aaaa1111", kind="phone"))
    store.receive(DAY, _body([_conv(3600, 3700, [_line(3600, "見本の朝の文")])], device="bbbb2222", kind="pad"))
    raw = json.loads(store.path(DAY).read_text(encoding="utf-8"))
    failed += say(len(raw["conversations"]) == 2 and raw["conversations"][1]["device"] == "bbbb2222",
                  "重なりなし: 時刻が離れていれば同じ文でもまとめず、別の会話として足す")
    store2 = _store("near", {"two_devices": {"window_s": 1}})
    store2.receive(DAY, _body([_conv(0, 60, [_line(0, "見本の文を読みます")])], device="aaaa1111", kind="phone"))
    store2.receive(DAY, _body([_conv(0, 60, [_line(5, "見本の文を読みます")])], device="bbbb2222", kind="pad"))
    failed += say(len(_lines(store2, DAY)) == 2, "しきい値: config で時刻の差を 1 秒にすると、5 秒ずれた行はまとめない")
    return failed


def check_legacy_then_device() -> int:
    """古い iPhone の送り（印なし）がある日に iPad が送っても、iPhone の分を上書きしない"""
    failed = 0
    store = _store("mix")
    old = _body([_conv(0, 60, [_line(0, "見本の古い iPhone の文")])])
    store.receive(DAY, old)
    store.receive(DAY, _body([_conv(600, 660, [_line(600, "見本の iPad の文")])], device="bbbb2222", kind="pad"))
    texts = [line["text"] for line in _lines(store, DAY)]
    failed += say(texts == ["見本の古い iPhone の文", "見本の iPad の文"], "古い形と新しい形: iPhone の古い送りを控えて合わせる")
    # 古い iPhone がもう一度（印なしで）送っても、iPad の分は消えない
    store.receive(DAY, _body([_conv(0, 60, [_line(0, "見本の古い iPhone の文"), _line(30, "見本の続き")])]))
    texts = [line["text"] for line in _lines(store, DAY)]
    failed += say(len(texts) == 3 and "見本の iPad の文" in texts, "古い形: 印の無い送りが来ても iPad の分を残して合わせ直す")
    # 新しい iPhone が送ったら、古い送りは合わせない（名前を変えて残す）
    store.receive(DAY, _body([_conv(0, 60, [_line(0, "見本の古い iPhone の文")])], device="aaaa1111", kind="phone"))
    legacy = store.device_path(s39overlap.LEGACY, DAY)
    failed += say(not legacy.exists() and legacy.with_name(f"{DAY}.replaced.json").exists()
                  and len(_lines(store, DAY)) == 2,
                  "新しい iPhone が送ったら、同じ iPhone の古い送りは名前を変えて残し、合わせない")
    try:
        store.receive(DAY, _body([], device="../x"))
        failed += say(False, "端末の印がおかしければ断る")
    except ValueError:
        failed += say(True, "端末の印がおかしければ断る")
    return failed


def check_forget() -> int:
    """消す（forget）は端末ごとのファイルからも消す。戻すと戻る"""
    failed = 0
    store = _store("forget")
    store.receive(DAY, _body([_conv(0, 60, [_line(0, "見本の消す文")])], device="aaaa1111", kind="phone"))
    store.receive(DAY, _body([_conv(1, 60, [_line(1, "見本の消す文"), _line(600, "見本の残す文")])],
                             device="bbbb2222", kind="pad"))
    start = records.parse_time(_t(0), "t")
    result = forget.forget(store, DAY, start, start + 10_000)
    pad = json.loads(store.device_path("bbbb2222", DAY).read_text(encoding="utf-8"))
    pad_texts = [line["text"] for c in pad["conversations"] for line in c["lines"]]
    failed += say("見本の消す文" not in pad_texts and "見本の残す文" in pad_texts,
                  "消す: 端末ごとのファイルからも同じ範囲を除く（次の合わせで戻らない）")
    store.receive(DAY, _body([_conv(1, 60, [_line(600, "見本の残す文")])], device="bbbb2222", kind="pad"))
    failed += say("見本の消す文" not in [line["text"] for line in _lines(store, DAY)], "消す: 合わせ直しても消した行は戻らない")
    if result.get("id"):
        try:
            forget.undo(store, DAY, result["id"])
        except RuntimeError:
            pass
    return failed


CHECKS = [check_similarity, check_legacy_unchanged, check_overlap, check_no_overlap, check_legacy_then_device, check_forget]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
