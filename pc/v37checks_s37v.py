"""2026-11-28（s37。担当 v）: 家の PC の s37 精2 の分を確かめる。

    python pc/v37checks_s37v.py          （v36checks_s36p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

- 精2: 自分の声の見本を、母艦の「PLAUD の音で本人と確かめた区間だけ」の見本（state/s37v_self_center.json）に切り替える。
  use が true・同じ型・同じ次元・30 日以内（仮）のときだけ。だめなら前の見本（center.json）のまま。
  config.json の "self_lines": {"clean_center": false} で止められる。前の見本は今まで通り作って残す。

本物の HOME・母艦は使わない（一時フォルダに作りもの）。
"""

from __future__ import annotations

import datetime
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import selflines  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v37s-"))
TODAY = datetime.date(2026, 11, 29)


def _mother(data: dict | None) -> Path:
    m = Path(tempfile.mkdtemp(prefix="mother-", dir=TMP))
    if data is not None:
        (m / "state").mkdir(parents=True, exist_ok=True)
        (m / selflines.CLEAN_FILE).write_text(json.dumps(data), encoding="utf-8")
    return m


def check_clean_center() -> int:
    failed = 0
    cfg = selflines.settings({})
    dim = 8
    vec = list(np.linspace(0.1, 0.8, dim))
    good = {"use": True, "model": voices.MODEL, "made_at": "2026-11-28T12:00:00+09:00", "vec": vec, "lines": 120,
            "sha": "abc", "auc_now": 0.48, "auc_new": 0.68}
    got, why = selflines.clean_center(_mother(good), cfg, TODAY, dim)
    failed += say(got is not None and abs(float(np.linalg.norm(got)) - 1) < 1e-6 and why["source"] == "clean",
                  "精2: 母艦の確かめた見本（use true・同じ型・同じ次元・新しい）を使う")
    cases = [({**good, "use": False}, "not used", "母艦の見張りが use を false に戻したら使わない（前の見本へ）"),
             ({**good, "model": "another.onnx"}, "other model", "型が違えば使わない"),
             ({**good, "vec": vec[:4]}, "bad vector", "次元が違えば使わない"),
             ({**good, "made_at": "2026-10-01T00:00:00+09:00"}, "old", "30 日（仮）より古ければ使わない"),
             (None, "none", "母艦に見本が無ければ前の見本のまま")]
    for data, reason, text in cases:
        got, why = selflines.clean_center(_mother(data), cfg, TODAY, dim)
        failed += say(got is None and why.get("clean") == reason, f"精2: {text}")
    got, why = selflines.clean_center(_mother(good), selflines.settings({"self_lines": {"clean_center": False}}), TODAY, dim)
    failed += say(got is None and why.get("clean") == "stopped", "精2: config の clean_center false で止めて前の見本に戻せる")
    got, why = selflines.clean_center(None, cfg, TODAY, dim)
    failed += say(got is None, "精2: 母艦が無ければ前の見本のまま")
    return failed


def check_run_switch() -> int:
    """run() が確かめた見本で測り、前の見本（center_of の作るもの）は残すか"""
    failed = 0
    dim = 8
    own = voices._unit(np.ones(dim))
    clean = voices._unit(np.arange(1, dim + 1, dtype=np.float64))
    seen = []
    keep_center_of, keep_build = selflines.center_of, selflines.build_day
    try:
        selflines.center_of = lambda home, store, cfg, today, heavy: (own, {"lines": 50, "made_on": today.isoformat(), "cached": True})

        def fake_build(home, store, day, center, meta, cfg):
            seen.append((center.copy(), dict(meta)))
            return {"day": day, "summary": {"self_lines": 3, "far": 1}}
        selflines.build_day = fake_build
        home = TMP / "home"
        m = _mother({"use": True, "model": voices.MODEL, "made_at": "2026-11-28T12:00:00+09:00", "vec": list(clean), "sha": "x1"})
        out = selflines.run(home, None, m, {}, lambda s: None, [TODAY.isoformat()], heavy=False, mother_copy=False, today=TODAY)
        c, meta = seen[-1]
        failed += say(out.get("source") == "clean" and np.allclose(c, clean) and meta.get("own_lines") == 50 and meta.get("clean_sha") == "x1",
                      "精2: run は確かめた見本で測り、各日の center に source clean と前の見本の行数を書く")
        out = selflines.run(home, None, m, {"self_lines": {"clean_center": False}}, lambda s: None, [TODAY.isoformat()], heavy=False,
                            mother_copy=False, today=TODAY)
        c, meta = seen[-1]
        failed += say(out.get("source") == "own" and np.allclose(c, own) and meta.get("clean") == "stopped",
                      "精2: スイッチを切ると前の見本で測る（source own）")
        (m / selflines.CLEAN_FILE).write_text(json.dumps({"use": False, "model": voices.MODEL, "made_at": "2026-11-28", "vec": list(clean)}),
                                             encoding="utf-8")
        out = selflines.run(home, None, m, {}, lambda s: None, [TODAY.isoformat()], heavy=False, mother_copy=False, today=TODAY)
        failed += say(out.get("source") == "own" and np.allclose(seen[-1][0], own), "精2: 母艦が戻したら（use false）次の回から前の見本")
    finally:
        selflines.center_of, selflines.build_day = keep_center_of, keep_build
    return failed


CHECKS = [check_clean_center, check_run_switch]


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
