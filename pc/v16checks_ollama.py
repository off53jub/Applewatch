"""2026-11-15: 意味で探すのモデル（bge-m3）だけは空きがあれば GPU に置く（gpu.embed_options）と、Ollama の優先度を
「通常以下」にする（priority.py）を確かめる。

    python pc/v16checks_ollama.py

本物の GPU・nvidia-smi・Ollama は使わない（GPU の空きは作り物の値を渡す。優先度は作り物の一覧と作り物の下げ方で。
Windows では、本物のプロセスの一覧が読めることだけ確かめ、優先度は変えない）。確かめること:
- 文字起こしのモデルが GPU に無いとき・"ollama_gpu" が always／never のときは、今までと同じ（ollama_options と同じ）
- 文字起こしのモデルが GPU にあっても、空き − 残しておく分が EMBED_NEED_MB 以上なら GPU（{}）、足りなければ CPU
- いったん GPU に決めたら、空きが残しておく分を割るまで GPU のまま（行ったり来たりしない）・1 分は見直さない
- 読み込み中・make_room のあとは CPU に戻して決め直す・nvidia-smi で見られなければ CPU・"embed_gpu": false なら前と同じ
- 決めが変わったときだけ EMBED_CHANGED を呼ぶ・gpu-state.json に embed_gpu を書く・MCP は LifeLog PC の決めに合わせる
- 言語モデル（ollama_options）は、bge-m3 を GPU に置いても CPU のまま
- 優先度: 既定は「通常以下」・"idle"・"normal" なら何もしない・通常のものだけ下げる・下げたときだけ記録に 1 行
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gpu  # noqa: E402
import priority  # noqa: E402
from v6checks import say  # noqa: E402

CPU = {"num_gpu": 0}


def fresh() -> None:
    gpu._embed.update(at=0.0, gpu=False)


def mem(free: int) -> dict:
    return {"used": 8192 - free, "total": 8192, "free": free, "name": "作り物"}


def check_embed() -> int:
    failed = 0
    calls: list[bool] = []
    gpu.EMBED_CHANGED = calls.append
    spare = gpu.free_min_mb({})
    need = gpu.EMBED_NEED_MB + spare

    # 1. 今までと同じ場合
    fresh()
    same = [gpu.embed_options({}, on_gpu=False, memory=mem(100), now=1.0),
            gpu.embed_options({"ollama_gpu": "always"}, on_gpu=True, memory=mem(100), now=2.0),
            gpu.embed_options({"ollama_gpu": "never"}, on_gpu=False, memory=mem(8000), now=3.0),
            gpu.embed_options({"embed_gpu": False}, on_gpu=True, memory=mem(8000), now=4.0)]
    failed += say(same == [{}, {}, CPU, CPU] and calls == [],
                  f"文字起こしが GPU に無い・always・never・embed_gpu false は前と同じ（{same}）")

    # 2. 空きが足りれば GPU、足りなければ CPU
    fresh()
    low = gpu.embed_options({}, on_gpu=True, memory=mem(need - 1), now=100.0, loading=False)
    fresh()
    calls.clear()
    high = gpu.embed_options({}, on_gpu=True, memory=mem(need), now=100.0, loading=False)
    failed += say(low == CPU and high == {} and calls == [True] and gpu.embed_on_gpu(),
                  f"空き {need - 1}MB なら CPU・{need}MB なら GPU（{low}・{high}・知らせ {calls}）")

    # 3. 行ったり来たりしない・1 分は見直さない
    calls.clear()
    within = gpu.embed_options({}, on_gpu=True, memory=mem(0), now=130.0, loading=False)
    keep = gpu.embed_options({}, on_gpu=True, memory=mem(spare), now=200.0, loading=False)
    back = gpu.embed_options({}, on_gpu=True, memory=mem(spare - 1), now=300.0, loading=False)
    failed += say(within == {} and keep == {} and back == CPU and calls == [False],
                  f"GPU に決めたら空きが残す分を割るまで GPU・1 分以内は見直さない（{within}・{keep}・{back}・{calls}）")

    # 4. 読み込み中・make_room・見られないとき
    fresh()
    gpu.embed_options({}, on_gpu=True, memory=mem(8000), now=400.0, loading=False)
    busy = gpu.embed_options({}, on_gpu=True, memory=mem(8000), now=410.0, loading=True)
    reset_ok = not gpu.embed_on_gpu()
    gpu.embed_options({}, on_gpu=True, memory=mem(8000), now=500.0, loading=False)
    hooked = []
    old = gpu.BEFORE_LOAD
    gpu.BEFORE_LOAD = lambda: hooked.append(1)
    gpu.make_room()
    gpu.BEFORE_LOAD = old
    after_room = not gpu.embed_on_gpu() and hooked == [1]
    fresh()
    blind = gpu.embed_options({}, on_gpu=True, memory={}, now=600.0, loading=False)
    failed += say(busy == CPU and reset_ok and after_room and blind == CPU,
                  f"読み込み中は CPU・make_room で決め直す・空きが見られなければ CPU（{busy}・{blind}）")

    # 5. 言語モデルは CPU のまま
    fresh()
    gpu.embed_options({}, on_gpu=True, memory=mem(8000), now=700.0, loading=False)
    llm = gpu.ollama_options({}, on_gpu=True)
    failed += say(llm == CPU and gpu.embed_on_gpu(), f"bge-m3 を GPU に置いても、言語モデルは CPU のまま（{llm}）")

    # 6. gpu-state.json と MCP
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        old_path = gpu.STATE_PATH
        gpu.STATE_PATH = home / gpu.STATE_FILE
        gpu._written = None
        try:
            gpu.note_change()
            written = json.loads((home / gpu.STATE_FILE).read_text(encoding="utf-8"))
            (home / gpu.STATE_FILE).write_text(json.dumps({"asr_gpu": True, "embed_gpu": True, "loading": []}),
                                               encoding="utf-8")
            mcp_gpu = gpu.state_embed_options(home, {})
            (home / gpu.STATE_FILE).write_text(json.dumps({"asr_gpu": True, "embed_gpu": False}), encoding="utf-8")
            mcp_cpu = gpu.state_embed_options(home, {})
            (home / gpu.STATE_FILE).write_text(json.dumps({"asr_gpu": True, "embed_gpu": True, "loading": ["whisper"]}),
                                               encoding="utf-8")
            mcp_loading = gpu.state_embed_options(home, {})
            mcp_off = gpu.state_embed_options(home / "無い", {})
            mcp_never = gpu.state_embed_options(home, {"ollama_gpu": "never"})
        finally:
            gpu.STATE_PATH = old_path
            gpu._written = None
    failed += say(written.get("embed_gpu") is True and mcp_gpu == {} and mcp_cpu == CPU and mcp_loading == CPU
                  and mcp_off == {} and mcp_never == CPU,
                  f"gpu-state.json に embed_gpu を書き、MCP はそれに合わせる（{mcp_gpu}・{mcp_cpu}・{mcp_loading}・"
                  f"{mcp_off}・{mcp_never}）")

    # 7. 見守りの文
    text = gpu.ollama_text({})
    failed += say(isinstance(text, str) and text, f"見守りの文が作れる（{text}）")
    gpu.EMBED_CHANGED = None
    fresh()
    return failed


def check_priority() -> int:
    failed = 0
    levels = [priority.level({}), priority.level({"ollama_priority": "idle"}),
              priority.level({"ollama_priority": "normal"}), priority.level({"ollama_priority": False}),
              priority.level({"ollama_priority": "変な値"}), priority.level({"ollama_priority": "Below Normal"})]
    failed += say(levels == [priority.BELOW_NORMAL, priority.IDLE, None, None, priority.BELOW_NORMAL,
                             priority.BELOW_NORMAL], f"ollama_priority の読み方（{levels}）")

    current = {11: priority.NORMAL, 12: priority.BELOW_NORMAL, 13: priority.NORMAL}
    asked: list[tuple[int, int]] = []

    def setter(pid: int, to: int) -> bool:
        asked.append((pid, to))
        if current.get(pid) != priority.NORMAL:
            return False
        current[pid] = to
        return True

    def finder() -> list[tuple[int, str]]:
        return [(11, "ollama.exe"), (12, "llama-server.exe"), (13, "llama-server.exe")]

    logged: list[str] = []
    done = priority.sweep({}, logged.append, finder=finder, setter=setter)
    again = priority.sweep({}, logged.append, finder=finder, setter=setter)
    off = priority.sweep({"ollama_priority": "normal"}, logged.append, finder=finder, setter=setter)
    failed += say(len(done) == 2 and again == [] and off == [] and len(logged) == 1
                  and current == {11: priority.BELOW_NORMAL, 12: priority.BELOW_NORMAL, 13: priority.BELOW_NORMAL},
                  f"通常のものだけ下げ、下げたときだけ記録に 1 行・normal なら何もしない（{done}・{len(logged)} 行）")

    def broken(pid: int, to: int) -> bool:
        raise OSError("作り物")

    failed += say(priority.sweep({}, None, finder=finder, setter=broken) == [], "下げられなくても止まらない")
    if os.name == "nt":
        found = priority.find(("python.exe", "pythonw.exe"))
        failed += say(isinstance(found, list) and any(pid == os.getpid() for pid, _ in found),
                      f"Windows で本物のプロセスの一覧が読める（python {len(found)} 個。優先度は変えない）")
    else:
        failed += say(priority.find() == [] and priority.lower(1, priority.BELOW_NORMAL) is False,
                      "Windows のほかでは何もしない")
    return failed


def main() -> int:
    failed = check_embed() + check_priority()
    print("ぜんぶ OK" if not failed else f"NG が {failed} 個")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
