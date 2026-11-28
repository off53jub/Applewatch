"""2026-11-29（s39）: 話し手の声の特徴の型の直し（speakerfix.py）と、型が替わった日の夜の測り直し（voices.py）を確かめる。

    python pc/v39checks_voicefix.py          （v37checks_s37v.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

- 直し: CAM++ の 100 こまずつの平均（AveragePool・ceil_mode 1）のあとに、同じ形の 1 の平均で割る。
  小さな作りものの型で、切れ端が「本当にあるこまの数」で割られること（onnxruntime 1.29 からと同じ答え）・
  ceil_mode 0 の平均は触らないこと・作った型を使い回すこと・壊れた型では None（元の型のまま）を確かめる。
- 測り直し: 置き場所（voices/<日>.npz）の型の名前が今の型と違う日があれば、夜の流れは REDO_DAYS 日さかのぼる。

本物の HOME・本物の型は使わない（一時フォルダに作りもの）。本物の型での突き合わせは lifelog_pc.py --check-extras（check_poolfix）。
"""

from __future__ import annotations

import datetime
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import speakerfix  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v39-"))
TODAY = datetime.date(2026, 11, 29)


def _tiny_model(path: Path) -> None:
    """x (1, 2, T) → AveragePool(kernel 4, stride 4, ceil 1) と AveragePool(kernel 2, stride 2, ceil 0) を足した形にした作りもの"""
    from onnx import TensorProto, helper, save

    x = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 2, None])
    y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 2, None])
    z = helper.make_tensor_value_info("z", TensorProto.FLOAT, [1, 2, None])
    nodes = [
        helper.make_node("AveragePool", ["x"], ["y"], name="seg", ceil_mode=1, count_include_pad=1, kernel_shape=[4],
                         pads=[0, 0], strides=[4]),
        helper.make_node("AveragePool", ["x"], ["z"], name="plain", ceil_mode=0, kernel_shape=[2], strides=[2]),
    ]
    graph = helper.make_graph(nodes, "tiny", [x], [y, z])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    helper.set_model_props(model, {"feature_normalize_type": "global-mean"})
    save(model, str(path))


def check_patch() -> int:
    failed = 0
    try:
        import onnx
    except Exception:  # noqa: BLE001
        return say(False, "s39: onnx の部品が入っていない（requirements.txt の onnx）")
    src = TMP / "tiny.onnx"
    _tiny_model(src)
    model = onnx.load(str(src))
    count = speakerfix.patch_model(model)
    ops = [n.op_type for n in model.graph.node]
    failed += say(count == 1 and ops.count("AveragePool") == 3 and ops.count("Div") == 1,
                  f"s39: ceil_mode 1 の平均だけを直す（直した数 {count}・ceil_mode 0 はそのまま）")
    onnx.checker.check_model(model)
    props = {p.key: p.value for p in model.metadata_props}
    failed += say(props.get("feature_normalize_type") == "global-mean", "s39: 型の付記（sherpa-onnx が読む）を残す")
    fixed = speakerfix.ensure(src)
    failed += say(fixed is not None and fixed.name == "tiny.poolfix1.onnx" and fixed.is_file(),
                  "s39: 直した型を隣に作る（元の型は変えない）")
    again = speakerfix.ensure(src)
    failed += say(again == fixed, "s39: 2 回目も同じ置き場所の型を返す")
    bad = TMP / "broken.onnx"
    bad.write_bytes(b"not a model")
    failed += say(speakerfix.ensure(bad) is None, "s39: 壊れた型では None（呼ぶ側は元の型のまま）")
    try:
        import onnxruntime as ort
    except Exception:  # noqa: BLE001
        print("OK s39: onnxruntime が無いので、作りものの型の計算は飛ばす")
        return failed
    data = np.arange(1, 1 + 2 * 10, dtype=np.float32).reshape(1, 2, 10)
    # PyTorch の割り方: 最後の切れ端（2 こま）は 2 で割る
    want = np.stack([data[0, :, 0:4].mean(-1), data[0, :, 4:8].mean(-1), data[0, :, 8:10].mean(-1)], axis=-1)[None]
    got = ort.InferenceSession(str(fixed), providers=["CPUExecutionProvider"]).run(None, {"x": data})
    plain = ort.InferenceSession(str(src), providers=["CPUExecutionProvider"]).run(None, {"x": data})
    failed += say(np.allclose(got[0], want, atol=1e-5), f"s39: 直した型の切れ端は本当にあるこまの数で割る（onnxruntime {ort.__version__}）")
    failed += say(np.allclose(got[1], plain[1]), "s39: ceil_mode 0 の平均の答えは変わらない")
    return failed


def _npz(home: Path, day: str, model: str) -> None:
    store = voices.DayStore(home, day)
    store.vectors = {f"a.m4a|{i}.00|{i + 2}.00": np.ones(4, np.float32) for i in range(3)}
    saved = voices.MODEL
    voices.MODEL = model
    try:
        store.save()
    finally:
        voices.MODEL = saved


class _Store:
    def __init__(self, days: set[str]) -> None:
        self.days = days

    def day(self, day: str):
        return {"conversations": []} if day in self.days else None


def check_redo() -> int:
    failed = 0
    saved = voices.MODEL
    voices.MODEL = "camplus.onnx+poolfix1"
    try:
        home = Path(tempfile.mkdtemp(prefix="home-", dir=TMP))
        d0, d1, d2, d40 = (TODAY - datetime.timedelta(days=k) for k in (0, 1, 25, 40))
        days = {d.isoformat() for d in (d0, d1, d2, d40)}
        store = _Store(days)
        _npz(home, d0.isoformat(), "camplus.onnx+poolfix1")
        _npz(home, d1.isoformat(), "camplus.onnx")
        _npz(home, d2.isoformat(), "camplus.onnx")
        _npz(home, d40.isoformat(), "camplus.onnx")
        stale = voices.stale_days(home, store, TODAY)
        failed += say(stale == [d1.isoformat(), d2.isoformat()],
                      f"s39: 前の型で測った日（30 日以内・記録のある日）を新しい日から拾う（{stale}）")
        failed += say(voices.night_days(home, store, TODAY) == voices.REDO_DAYS == 30, "s39: 前の型の日があれば夜は 30 日さかのぼる")
        _npz(home, d1.isoformat(), "camplus.onnx+poolfix1")
        _npz(home, d2.isoformat(), "camplus.onnx+poolfix1")
        failed += say(voices.night_days(home, store, TODAY) == voices.WINDOW, "s39: 測り直しが済めば、夜はいつもの日数に戻る")
        failed += say(voices.DayStore(home, d0.isoformat()).load().vectors != {}, "s39: 今の型の日は読める")
        voices.MODEL = "camplus.onnx"
        failed += say(voices.DayStore(home, d0.isoformat()).load().vectors == {},
                      "s39: 型の名前が違う日は読まない（前の特徴と混ぜない・LIFELOG_SPEAKER_POOLFIX=0 で戻したときも）")
        failed += say(voices.KEEP_DAYS >= voices.REDO_DAYS, "s39: 置き場所は測り直す日数より長く残す")
    finally:
        voices.MODEL = saved
    return failed


CHECKS = [check_patch, check_redo]


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
