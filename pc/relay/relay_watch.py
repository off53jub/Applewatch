"""家の PC の控えの見張り（2026-11-15。強化案 62。家の PC とは別の機械で動かす小さな見張り）。

家の PC（LifeLog PC）が落ちると、見張りも知らせも家の PC から出ているので何も届かない（AGENTS.md の罠の索引）。
iPhone の側の見張り（アプリの PCSilence.swift・強化案 38）に加え、別の機械からも見る:

- 家の PC の GET /hello に Tailscale の中から聞く。答え（200 でも 401 でも、HTTP の答えが返れば）を「生きている」とみなす。
- （省ける）ドライブの同期フォルダのいちばん新しいファイルの更新時刻（その機械に Google ドライブか rclone で写っているとき）。
- どちらかが QUIET_HOURS（既定 6 時間）より長く黙ったら、選んだ道で 1 通（REPEAT_HOURS に 1 回まで）。戻ったら 1 通。
- 一度もつながったことが無いうちは鳴らさない（未セットアップの見張りは鳴らさない）。

設定はすべて環境変数（このリポジトリには鍵も宛先も書かない）:
  RELAY_HELLO_URL     家の PC の /hello（例: http://<tailnet の名前>:<port>/hello）。必須
  RELAY_HELLO_KEY     家の PC の合言葉（省ける。無くても 401 が返れば生きているとみなす）
  RELAY_DRIVE_DIR     ドライブの同期フォルダ（省ける）
  RELAY_QUIET_HOURS   黙ったとみなす時間（既定 6）
  RELAY_REPEAT_HOURS  同じ知らせを繰り返す間（既定 12）
  RELAY_CHANNEL       line・line_notify・ntfy・webhook・print（既定 print＝標準出力だけ）
  RELAY_LINE_TOKEN    line（Messaging API の broadcast。Bot の友だち全員に届く）のチャネルのアクセストークン
  RELAY_LINE_NOTIFY_TOKEN  line_notify のトークン（LINE Notify は 2025-03-31 に終わった。残してあるだけ）
  RELAY_NTFY_URL      ntfy の話題の URL（例: https://ntfy.sh/<長いランダムな名前>）
  RELAY_WEBHOOK_URL   webhook（JSON {"text"} を POST）
  RELAY_STATE         控えのファイル（既定 ~/.lifelog-relay.json）

使い方:
  python relay_watch.py --once      # 1 回見る（cron・タスクスケジューラ・systemd の timer で 15 分ごと）
  python relay_watch.py --loop      # 15 分ごとに見続ける
  python relay_watch.py --selftest  # 作り物の家の PC で確かめる
標準のライブラリだけで動く（Python 3.9 以上）。知らせの文に会話の中身・名前・URL は入れない。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

EVERY = 15 * 60
SCAN_LIMIT = 20000


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def hours(name: str, default: float) -> float:
    try:
        value = float(env(name, str(default)))
    except ValueError:
        return default
    return value if value > 0 else default


def probe(url: str, key: str = "", timeout: float = 10.0) -> bool:
    """HTTP の答えが返れば True（401・404 も、家の PC が受け付けている印）。つながらない・時間切れは False"""
    if not url:
        return False
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"} if key else {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return 100 <= response.status < 600
    except urllib.error.HTTPError as error:
        return 100 <= error.code < 600
    except (urllib.error.URLError, OSError, ValueError):
        return False


def newest_mtime(folder: str, limit: int = SCAN_LIMIT) -> float | None:
    """フォルダの中でいちばん新しいファイルの更新時刻（見るのは limit 個まで）。無い・読めなければ None"""
    root = Path(folder)
    if not folder or not root.is_dir():
        return None
    best, seen = None, 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            seen += 1
            try:
                m = os.path.getmtime(os.path.join(dirpath, name))
            except OSError:
                continue
            best = m if best is None or m > best else best
            if seen >= limit:
                return best
    return best


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def _post(url: str, body: bytes, headers: dict) -> bool:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def send(text: str, channel: str) -> bool:
    """選んだ道で 1 通。送れたら True（鍵は環境変数から読み、どこにも書かない）"""
    if channel == "line":
        token = env("RELAY_LINE_TOKEN")
        body = json.dumps({"messages": [{"type": "text", "text": text}]}).encode("utf-8")
        return bool(token) and _post("https://api.line.me/v2/bot/message/broadcast", body,
                                     {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    if channel == "line_notify":
        token = env("RELAY_LINE_NOTIFY_TOKEN")
        body = urllib.parse.urlencode({"message": text}).encode("utf-8")
        return bool(token) and _post("https://notify-api.line.me/api/notify", body,
                                     {"Authorization": f"Bearer {token}",
                                      "Content-Type": "application/x-www-form-urlencoded"})
    if channel == "ntfy":
        url = env("RELAY_NTFY_URL")
        return bool(url) and _post(url, text.encode("utf-8"), {"Title": "LifeLog relay"})
    if channel == "webhook":
        url = env("RELAY_WEBHOOK_URL")
        return bool(url) and _post(url, json.dumps({"text": text}).encode("utf-8"), {"Content-Type": "application/json"})
    print(text)
    return True


def decide(state: dict, name: str, ok_at: float | None, now: float, quiet_h: float, repeat_h: float) -> str | None:
    """1 つの見張り（hello・drive）の知らせの文を決め、state を進める。知らせが無ければ None。
    ok_at はいちばん新しい「生きている」時刻（今つながったなら now）。一度も生きていなかったら鳴らさない"""
    s = state.setdefault(name, {})
    if ok_at is not None and ok_at > float(s.get("last_ok") or 0):
        s["last_ok"] = ok_at
    last_ok = float(s.get("last_ok") or 0)
    if not last_ok:
        return None
    silent = now - last_ok
    label = "家の PC" if name == "hello" else "ドライブの同期"
    if silent < quiet_h * 3600:
        if s.get("alerting"):
            s["alerting"] = False
            return f"{label}が戻りました（LifeLog の控えの見張り）。"
        return None
    if s.get("alerting") and now - float(s.get("alerted_at") or 0) < repeat_h * 3600:
        return None
    s["alerting"] = True
    s["alerted_at"] = now
    return (f"{label}から {int(silent // 3600)} 時間、便りがありません（LifeLog の控えの見張り）。"
            f"家の PC の電源・ネット・Tailscale を確かめてください。")


def once(now: float | None = None) -> int:
    now = time.time() if now is None else now
    url = env("RELAY_HELLO_URL")
    if not url:
        print("RELAY_HELLO_URL がありません（家の PC の /hello を入れてください）")
        return 2
    path = Path(env("RELAY_STATE") or Path.home() / ".lifelog-relay.json")
    state = load(path)
    quiet_h, repeat_h = hours("RELAY_QUIET_HOURS", 6), hours("RELAY_REPEAT_HOURS", 12)
    channel = env("RELAY_CHANNEL", "print") or "print"
    messages = []
    alive = probe(url, env("RELAY_HELLO_KEY"))
    text = decide(state, "hello", now if alive else None, now, quiet_h, repeat_h)
    if text:
        messages.append(("hello", text))
    folder = env("RELAY_DRIVE_DIR")
    if folder:
        text = decide(state, "drive", newest_mtime(folder), now, quiet_h, repeat_h)
        if text:
            messages.append(("drive", text))
    for name, text in messages:
        if not send(text, channel):
            state[name]["alerting"] = False  # 送れなかった。次の回にもう一度
    state["checked_at"] = now
    save(path, state)
    print(f"hello={'ok' if alive else 'no'} 知らせ {len(messages)} 通")
    return 0


def selftest() -> int:
    import http.server
    import tempfile
    import threading

    class Hello(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            self.send_response(401)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Hello)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/hello"
    assert probe(url) is True                      # 401 でも生きている
    assert probe("http://127.0.0.1:9/hello", timeout=2) is False
    server.shutdown()
    st: dict = {}
    t0 = 1_000_000.0
    assert decide(st, "hello", None, t0, 6, 12) is None            # 一度もつながっていないうちは鳴らさない
    assert decide(st, "hello", t0, t0, 6, 12) is None
    assert decide(st, "hello", None, t0 + 5 * 3600, 6, 12) is None
    msg = decide(st, "hello", None, t0 + 7 * 3600, 6, 12)
    assert msg and "7 時間" in msg
    assert decide(st, "hello", None, t0 + 8 * 3600, 6, 12) is None  # 12 時間は繰り返さない
    assert decide(st, "hello", None, t0 + 20 * 3600, 6, 12)
    assert "戻りました" in decide(st, "hello", t0 + 21 * 3600, t0 + 21 * 3600, 6, 12)
    with tempfile.TemporaryDirectory() as t:
        Path(t, "a.txt").write_text("x", encoding="utf-8")
        assert newest_mtime(t) is not None and newest_mtime(os.path.join(t, "none")) is None
        os.environ["RELAY_HELLO_URL"] = "http://127.0.0.1:9/hello"
        os.environ["RELAY_STATE"] = os.path.join(t, "state.json")
        os.environ["RELAY_CHANNEL"] = "print"
        assert once(now=t0) == 0 and load(Path(t, "state.json")).get("checked_at") == t0
    print("selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.loop:
        while True:
            once()
            time.sleep(EVERY)
    return once()


if __name__ == "__main__":
    sys.exit(main())
