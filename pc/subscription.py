"""LifeLog PC: Claude の定額の枠（Claude Code の `claude -p`）で頼む道（2026-11-26）。

本人「安いモデルで削るより、アプリの Claude（定額の枠）を使って節約したい」。
母艦の scripts/claude_call.py と同じ決まり・同じ設定ファイル・同じ様子のファイルを使う。

- 設定: 母艦の state/claude_route.json（無くてよい）
  {"on": true, "tiers": ["standard","deep"], "purposes_cli": [], "purposes_api": [], "fallback_api": true,
   "daily_calls": 150, "timeout": 300, "exe": "<ホーム>\\.local\\bin\\claude.exe", "rest_min": 30}
  Sonnet・Opus の頼みは定額の枠へ。軽い頼み（Haiku・数が多い）は今までどおり API。
- 様子: 母艦の state/claude_route_status.json（今日の回数・最後に通った・最後の失敗・休み）
  ログイン切れ・枠切れのときは rest_min 分休んで API に戻る（fallback_api が false なら頼まない）
- iPhone のアプリからの頼み（POST /claude）は待たせないよう API のまま（呼ぶ側が route=False で渡す）
- 定額の枠の分は帳簿に usd 0・via "subscription"・usd_equiv（API なら掛かった額の目安）で書く
- API の鍵は子の環境から外す（外さないと claude -p が API の料金で動く）
"""
from __future__ import annotations

import datetime
import json
import os
import subprocess
import tempfile
import threading
from pathlib import Path

DEFAULT = {"on": True, "tiers": ["standard", "deep"], "purposes_cli": [], "purposes_api": [],
           "fallback_api": True, "daily_calls": 150, "timeout": 300,
           "exe": str(Path.home() / ".local" / "bin" / "claude.exe"),
           "models": {"light": "haiku", "standard": "sonnet", "deep": "opus"}, "rest_min": 30}
JST = datetime.timezone(datetime.timedelta(hours=9))
_lock = threading.Lock()


class CliFailed(RuntimeError):
    """定額の枠で頼めなかった"""


def mother_home() -> Path:
    try:
        import mothership
        cfg_path = Path(os.environ.get("LOCALAPPDATA", "")) / "LifeLogPC" / "config.json"
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig")) if cfg_path.exists() else {}
        return mothership.home(cfg if isinstance(cfg, dict) else {})
    except Exception:  # noqa: BLE001
        return Path(r"D:\Lifelog")


def _files() -> tuple[Path, Path]:
    h = mother_home() / "state"
    return h / "claude_route.json", h / "claude_route_status.json"


def config() -> dict:
    r = dict(DEFAULT)
    path, _ = _files()
    try:
        got = json.loads(path.read_text(encoding="utf-8-sig"))
        if isinstance(got, dict):
            r.update({k: v for k, v in got.items() if k in DEFAULT})
    except (OSError, ValueError):
        pass
    return r


def status() -> dict:
    _, path = _files()
    try:
        s = json.loads(path.read_text(encoding="utf-8"))
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(s: dict) -> None:
    _, path = _files()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(s, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def _hit(purpose: str, names) -> bool:
    return any(isinstance(n, str) and n and purpose.startswith(n) for n in (names or []))


def route_for(purpose: str, tier: str, now: datetime.datetime | None = None) -> dict | None:
    """定額の枠で頼むなら設定を、API なら None"""
    if os.environ.get("LIFELOG_SUBSCRIPTION") == "0":      # 確かめのとき（isolate_home が入れる）
        return None
    r = config()
    if not r.get("on") or _hit(purpose, r.get("purposes_api")):
        return None
    if not (_hit(purpose, r.get("purposes_cli")) or tier in (r.get("tiers") or [])):
        return None
    if not os.path.exists(str(r.get("exe") or "")):
        return None
    st = status()
    now = now or datetime.datetime.now(JST)
    rest = st.get("rest_until")
    if rest and rest > now.isoformat(timespec="seconds"):
        return None
    if (st.get("calls") or {}).get(now.date().isoformat(), 0) >= int(r.get("daily_calls") or 0):
        return None
    return r


def parse_output(raw: str) -> tuple[str, float, bool, str]:
    """claude -p --output-format json の出力から (答え, 相当の金額, 失敗か, 失敗の文)"""
    try:
        j = json.loads(raw)
    except ValueError:
        s, e = raw.find("{"), raw.rfind("}")
        try:
            j = json.loads(raw[s:e + 1]) if s >= 0 and e > s else {}
        except ValueError:
            j = {}
    if not isinstance(j, dict) or not j:
        return "", 0.0, True, "答えの形が読めません"
    usd = float(j.get("total_cost_usd") or 0)
    if j.get("is_error") or j.get("subtype") not in (None, "success"):
        return "", usd, True, str(j.get("result") or j.get("subtype") or "失敗")[:200]
    so = j.get("structured_output")
    text = json.dumps(so, ensure_ascii=False) if so is not None else str(j.get("result") or "").strip()
    if not text:
        return "", usd, True, "答えが空でした"
    return text, usd, False, ""


def ask(system: str | None, prompt: str, tier: str, schema: dict | None, r: dict, purpose: str) -> tuple[str, str, float]:
    """定額の枠で 1 回頼む。(答え, モデルの名前, 相当の金額)。だめなら CliFailed"""
    model = (r.get("models") or {}).get(tier) or DEFAULT["models"].get(tier, "sonnet")
    now = datetime.datetime.now(JST)
    why = ""
    with tempfile.TemporaryDirectory(prefix="lifelog-pc-cli-") as tmp:
        sp = Path(tmp) / "system.txt"
        sp.write_text((system or "") + ("\n\n" if system else "")
                      + "あなたは文を作るだけの係です。道具は使いません。答えだけを返してください。", encoding="utf-8")
        args = [str(r["exe"]), "-p", "--output-format", "json", "--model", model, "--tools", "",
                "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
                "--system-prompt-file", str(sp)]
        if schema:
            args += ["--json-schema", json.dumps(schema, ensure_ascii=False)]
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
        raw = ""
        try:
            p = subprocess.run(args, input=prompt.encode("utf-8"), capture_output=True, cwd=tmp, env=env,
                               timeout=float(r.get("timeout") or 300),
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            raw = p.stdout.decode("utf-8", "replace")
            err = p.stderr.decode("utf-8", "replace").strip()
        except (OSError, subprocess.TimeoutExpired) as e:
            err = type(e).__name__
        if raw:
            text, usd, failed, why = parse_output(raw)
        else:
            text, usd, failed, why = "", 0.0, True, "出力なし"
        if failed and err:
            why = (why + " / " + err)[:300]
    with _lock:
        st = status()
        calls = {k: v for k, v in (st.get("calls") or {}).items()
                 if k >= (now.date() - datetime.timedelta(days=7)).isoformat()}
        if failed:
            st["last_error"] = {"at": now.isoformat(timespec="seconds"), "purpose": purpose[:40], "why": why, "who": "pc"}
            if any(w in why.lower() for w in ("authenticate", "oauth", "login", "limit", "usage", "credit", "expired")):
                st["rest_until"] = (now + datetime.timedelta(minutes=int(r.get("rest_min") or 30))).isoformat(timespec="seconds")
            _save(st)
            raise CliFailed(why)
        day = now.date().isoformat()
        calls[day] = calls.get(day, 0) + 1
        st.update({"calls": calls, "last_ok": now.isoformat(timespec="seconds"), "rest_until": None})
        _save(st)
    return text, "claude-" + model, usd
