"""LifeLog PC: 話し手の声の特徴の型（CAM++）を、sherpa-onnx の中の onnxruntime でも正しく計算させる直し（s39。2026-11-29）。

わけ（母艦の reports/s39-voice-fix.md で数を出した。確か）:
- CAM++ の中には、時間の方向に 100 こまずつの平均（AveragePool・kernel 100・stride 100・ceil_mode 1・count_include_pad 1・
  pads 0）が 52 か所ある。最後の 100 こまに満たない切れ端は、PyTorch（学んだときの道具）では「本当にあるこまの数」で割る。
- sherpa-onnx 2.0.1 に入っている onnxruntime 1.28.2（と 1.28 までの onnxruntime）は、切れ端も 100 で割っていた
  （28 こまなら 28/100 に縮む）。onnxruntime 1.29 からは PyTorch と同じ。同じ特徴を入れても、出てくる声の特徴の近さは 0.02 だった。
- その結果、家の PC の声の特徴は区間の長さと録音の癖に引っぱられ、人を見分けにくくなっていた
  （同じ区間で、区間 1 つでほかの日の本人と当てる AUC: 家の PC 0.565・正しい計算 0.802。s38 精12）。

直し方: 平均のあとに「同じ形の 1 だけの並びを同じ平均にかけたもの」で割る。正しい onnxruntime ではそれは 1 なので何も変わらず、
1.28 までの onnxruntime では切れ端の分だけ割り戻される。どちらの onnxruntime でも PyTorch と同じ答えになる。
型のファイル（取ってきたもの）は変えず、隣に <名前>.poolfix1.onnx を作る。作れなければ（onnx の部品が無いなど）元の型のまま動く。

ここで変えるのは型の計算だけ。名前・記録・人のまとめは変えない。
"""

from __future__ import annotations

from pathlib import Path

TAG = "poolfix1"


def fixed_path(path: Path) -> Path:
    path = Path(path)
    return path.with_name(f"{path.stem}.{TAG}.onnx")


def patch_model(model):
    """onnx の ModelProto をその場で直す。直した平均の数を返す"""
    from onnx import TensorProto, helper

    graph = model.graph
    nodes = list(graph.node)
    out_nodes = []
    count = 0
    for node in nodes:
        attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        if node.op_type != "AveragePool" or int(attrs.get("ceil_mode", 0)) != 1:
            out_nodes.append(node)
            continue
        count += 1
        name = node.name or f"avgpool{count}"
        original = node.output[0]
        raw = f"{original}__{TAG}_raw"
        node.output[0] = raw
        out_nodes.append(node)
        shape, ones, cnt = f"{original}__{TAG}_shape", f"{original}__{TAG}_ones", f"{original}__{TAG}_cnt"
        out_nodes.append(helper.make_node("Shape", [node.input[0]], [shape], name=f"{name}/{TAG}/Shape"))
        out_nodes.append(helper.make_node("ConstantOfShape", [shape], [ones], name=f"{name}/{TAG}/Ones",
                                          value=helper.make_tensor("one", TensorProto.FLOAT, [1], [1.0])))
        pool = helper.make_node("AveragePool", [ones], [cnt], name=f"{name}/{TAG}/Count")
        pool.attribute.extend(node.attribute)
        out_nodes.append(pool)
        out_nodes.append(helper.make_node("Div", [raw, cnt], [original], name=f"{name}/{TAG}/Div"))
    del graph.node[:]
    graph.node.extend(out_nodes)
    return count


def ensure(path: Path, log=None) -> Path | None:
    """直した型のファイル（無ければ作る）。作れなければ None（呼ぶ側は元の型のまま使う）"""
    path = Path(path)
    target = fixed_path(path)
    try:
        if target.is_file() and target.stat().st_size > 1_000_000 and target.stat().st_mtime >= path.stat().st_mtime:
            return target
        import onnx

        model = onnx.load(str(path))
        count = patch_model(model)
        if count == 0:
            return None
        part = target.with_name(target.name + ".part")
        onnx.save(model, str(part))
        part.replace(target)
        if log:
            log(f"話し手のモデルの平均の計算を直した型を作りました（{count} か所・{target.name}）")
        return target
    except Exception as error:  # noqa: BLE001 — 直せなければ元の型のまま（前と同じ動き）
        if log:
            log(f"話し手のモデルの直しを作れませんでした（元の型のまま）: {type(error).__name__}")
        return None
