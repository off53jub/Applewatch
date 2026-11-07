"""LifeLog PC 版 10: 時計の外の道（決まりは docs/v10-watch-route.md）。

時計は家の Wi-Fi の外でも、5 分の区切りを PC に直接送れるようにする。Tailscale Funnel
（https://<この PC の Tailscale の名前> → http://127.0.0.1:47617）から入ってくるので、ここは「預けるだけ」の別の受け口:
- この PC の中（127.0.0.1）の番号 WATCH_PORT（--watch-port。0 で使わない）だけで待つ。外からは Funnel を通ってだけ届く。
- 受けるのは GET /w/ping と POST /w/jobs?<POST /jobs と同じ query> だけ。ほかは全部 404（見守りの画面・記録は見えない）。
- 合言葉は、ふだんの合言葉とは別の「時計の合言葉」（HOME/watch-token.txt。secrets.token_urlsafe(32)）。記録にも画面にも出さない。
- 10 分に 10 回、合言葉が違えば、10 分のあいだ、だれにも 429 を返す（始めたときに1回だけ記録に書く）。
- 預けた仕事には "origin": "watch" を付ける（jobqueue.http_post）。待ち合わせはしない。8MB まで。名前は「年月日-時分秒…-w.m4a」だけ。
- ふだんの受け口の GET /watch-route（ふだんの合言葉）で、iPhone に宛先と時計の合言葉を渡す（iPhone が時計に渡す）。
  Funnel の設定は、このプログラムは変えない（持ち主が `tailscale funnel` を1回だけ手で打つ）。様子を読むだけ。
"""

from __future__ import annotations

import collections
import json
import os
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

import jobqueue

WATCH_PORT = 47617
TOKEN_FILE = "watch-token.txt"
LOCK_FAILS = 10              # 合言葉の違う接続がこれだけ……
LOCK_WINDOW = 600.0          # ……この秒のうちにあれば、
LOCK_SECONDS = 600.0         # この秒のあいだ、だれにも 429 を返す
REQUEST_TIMEOUT = 60.0       # 1つの受け付けで、相手を待つ長さ（秒）
DRAIN_LIMIT = 2 * jobqueue.WATCH_BODY_LIMIT  # 断るときに読み捨てる中身の上限（これより大きければ読まずに閉じる）
FUNNEL_CACHE = 60.0          # Tailscale の Funnel の様子を覚えておく長さ（秒）
TAILSCALE = r"C:\Program Files\Tailscale\tailscale.exe"
PATHS = {("GET", "/w/ping"), ("POST", "/w/jobs")}


class W:
    """時計の外の道の様子（1つの LifeLog PC に1つ）"""
    main = None                       # lifelog_pc（App.jobs・log・Server を使う）
    server = None
    thread: threading.Thread | None = None
    port: int | None = None
    token: str | None = None
    lock = threading.Lock()
    fails: collections.deque = collections.deque()
    locked_until = 0.0
    lockouts = 0
    clock = time.time
    # Funnel の様子: (確かめた時刻, Funnel の名前か None)。status は serve の設定（JSON）を読む口（確かめで作り物にする）
    funnel_cache: tuple[float, str | None] | None = None
    status = None


def _log(message: str) -> None:
    main = W.main
    if main is not None:
        main.log(message)


# MARK: - 時計の合言葉


def token(home: Path) -> str:
    """HOME/watch-token.txt の時計の合言葉。無ければ作る（ふだんの合言葉とは別。記録には書かない）"""
    path = Path(home) / TOKEN_FILE
    try:
        value = path.read_text(encoding="utf-8").strip()
        if len(value) >= 32:
            return value
    except OSError:
        pass
    value = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(value + "\n", encoding="utf-8")
    os.replace(part, path)
    return value


# MARK: - 合言葉が違うのが続いたとき


def locked(now: float | None = None) -> bool:
    now = W.clock() if now is None else now
    with W.lock:
        return now < W.locked_until


def note_failure(now: float | None = None) -> None:
    """合言葉が違った。10 分に 10 回になったら、10 分のあいだ断る（始めたときに1回だけ記録に書く）"""
    now = W.clock() if now is None else now
    started = False
    with W.lock:
        W.fails.append(now)
        while W.fails and now - W.fails[0] > LOCK_WINDOW:
            W.fails.popleft()
        if len(W.fails) >= LOCK_FAILS and now >= W.locked_until:
            W.locked_until = now + LOCK_SECONDS
            W.lockouts += 1
            W.fails.clear()
            started = True
    if started:
        _log(f"時計の外の道: 合言葉の違う接続が {LOCK_WINDOW / 60:.0f} 分に {LOCK_FAILS} 回あったので、"
             f"{LOCK_SECONDS / 60:.0f} 分のあいだ、だれからも受け付けません")


def recent_failures(now: float | None = None) -> int:
    now = W.clock() if now is None else now
    with W.lock:
        return sum(1 for t in W.fails if now - t <= LOCK_WINDOW)


# MARK: - 受け口


class WatchHandler(BaseHTTPRequestHandler):
    """時計の外の道の受け口（GET /w/ping・POST /w/jobs だけ）。ふだんの Handler とは別"""
    server_version = "LifeLogPC"
    sys_version = ""
    timeout = REQUEST_TIMEOUT   # 1つの受け付けで相手を待つ長さ（ソケットの timeout）

    def log_message(self, format: str, *args) -> None:  # 標準の出力は使わない
        pass

    def send_json(self, status: int, body: dict, extra: dict | None = None) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        if status >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_error(self, code: int, message: str | None = None, explain: str | None = None) -> None:
        """読めない受け付け（壊れた見出しなど）にも、小さな JSON で答える"""
        try:
            self.close_connection = True
            self.send_json(code if code >= 400 else 400, {"error": "bad request"})
        except OSError:
            pass

    def discard_body(self) -> None:
        """送られてきた中身を読み捨てる（DRAIN_LIMIT まで）。答えたあと接続を閉じる"""
        self.close_connection = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return
        if length <= 0 or length > DRAIN_LIMIT:
            return
        try:
            while length > 0:
                chunk = self.rfile.read(min(length, 1 << 20))
                if not chunk:
                    break
                length -= len(chunk)
        except OSError:
            pass

    def token_ok(self) -> bool:
        given = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        expected = W.token or ""
        # 文字の種類が何であっても比べられるよう、バイトにして比べる（かかる時間は中身によらない）
        return bool(expected) and secrets.compare_digest(given.encode("utf-8", "replace"), expected.encode("utf-8"))

    def route(self, method: str) -> None:
        try:
            url = urlparse(self.path)
        except ValueError:
            self.discard_body()
            self.send_json(404, {"error": "not found"})
            return
        if locked():
            self.discard_body()
            self.send_json(429, {"error": "しばらく受け付けません"}, {"Retry-After": str(int(LOCK_SECONDS))})
            return
        if (method, url.path) not in PATHS:
            self.discard_body()
            self.send_json(404, {"error": "not found"})
            return
        if not self.token_ok():
            note_failure()
            self.discard_body()
            self.send_json(401, {"error": "合言葉が違います"})
            return
        if url.path == "/w/ping":
            self.discard_body()
            self.send_json(200, {"ok": True})
            return
        self.jobs(url.query)

    def jobs(self, query_text: str) -> None:
        """POST /w/jobs: 時計の区切りを預かる（待ち合わせはしない）"""
        from urllib.parse import parse_qs

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        main = W.main
        queue = getattr(getattr(main, "App", None), "jobs", None)
        name = (parse_qs(query_text).get("name") or [""])[0]
        state = jobqueue.http_post(self, queue, query_text, length, origin="watch")
        shown = name if jobqueue.valid_name(name) else "（名前の形が違う）"
        if state == "stored":
            _log(f"時計から（外の道） {shown}: {length / 1e6:.1f} MB を預かりました")
            try:
                import ops

                ops.note_watch()  # 夜に GPU のモデルを下ろしていれば戻す（iPhone から仕事が来たときと同じ）
            except Exception:  # noqa: BLE001 — 見守りのためなので、失敗しても受け付けは続ける
                pass
        elif state == "exists":
            _log(f"時計から（外の道） {shown}: もう預かっています（送られた音声は読み捨てました）")
        else:
            _log(f"時計から（外の道） {shown}: 預かりませんでした")

    def do_GET(self) -> None:
        self.route("GET")

    def do_POST(self) -> None:
        self.route("POST")

    def do_PUT(self) -> None:
        self.route("PUT")

    def do_DELETE(self) -> None:
        self.route("DELETE")

    def do_PATCH(self) -> None:
        self.route("PATCH")

    def do_HEAD(self) -> None:
        self.route("HEAD")

    def do_OPTIONS(self) -> None:
        self.route("OPTIONS")


def start(main, port: int) -> bool:
    """時計の外の道を 127.0.0.1:port で始める（裏のスレッド）。番号が使われていれば記録に書いて、無しで続ける。
    serve() は port が 1 以上のときだけ呼ぶ（確かめでは 0 を渡して、空いている番号を使う）。始められたら True。"""
    W.main = main
    try:
        W.token = token(main.HOME)
    except OSError as error:
        _log(f"時計の外の道: 時計の合言葉を用意できなかったので、始めません（{error}）")
        return False
    try:
        server = main.Server(("127.0.0.1", port), WatchHandler)
    except OSError as error:
        _log(f"時計の外の道: 番号 {port} はほかのソフトが使っているので、時計の外の道は無しで続けます（{error}）")
        return False
    server.daemon_threads = True
    W.server = server
    W.port = server.server_address[1]
    W.thread = threading.Thread(target=server.serve_forever, name="watch-route", daemon=True)
    W.thread.start()
    _log(f"時計の外の道: この PC の中の 127.0.0.1:{W.port} で待っています（Tailscale Funnel から届きます）")
    return True


def stop() -> None:
    """確かめのあとに止める"""
    server, W.server = W.server, None
    if server is not None:
        server.shutdown()
        server.server_close()
    W.port = None
    W.thread = None


def running() -> bool:
    return W.server is not None


# MARK: - Tailscale Funnel の様子（読むだけ。設定は変えない）


def _tailscale() -> str | None:
    import shutil

    for exe in (shutil.which("tailscale"), TAILSCALE):
        if exe and Path(exe).exists():
            return exe
    return None


def read_status() -> dict | None:
    """`tailscale funnel status --json`（だめなら `tailscale serve status --json`）の答え（ipn.ServeConfig の JSON）。
    読めなければ None。設定を変えるコマンドは使わない。"""
    exe = _tailscale()
    if exe is None:
        return None
    for args in (["funnel", "status", "--json"], ["serve", "status", "--json"]):
        try:
            out = subprocess.run([exe, *args], capture_output=True, timeout=10,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if out.returncode != 0:
                continue
            body = json.loads(out.stdout or b"{}")
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        if isinstance(body, dict):
            return body
    return None


def proxies_to(proxy, port: int) -> bool:
    """Funnel の取り次ぎ先（"http://127.0.0.1:47617"・"localhost:47617"・"47617" など）が、この PC の中の port か"""
    text = str(proxy or "").strip()
    if not text:
        return False
    if text.isdigit():
        return int(text) == port
    if "://" not in text:
        text = "http://" + text
    try:
        url = urlparse(text)
        return url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost", "::1") and url.port == port \
            and url.path in ("", "/")
    except ValueError:
        return False


def funnel_host(config, port: int) -> str | None:
    """serve の設定で、443 の Funnel がオン（AllowFunnel["<名前>:443"] が true）で、Web["<名前>:443"] の取り次ぎ
    （Handlers の Proxy）がこの PC の中の port に向いていれば、その名前（末尾の点は取る）。違えば None。
    前で動かしている `tailscale funnel`（--bg なし）の設定は Foreground の中にあるので、そこも見る。"""
    if not isinstance(config, dict):
        return None
    configs = [config]
    foreground = config.get("Foreground")
    if isinstance(foreground, dict):
        configs += [c for c in foreground.values() if isinstance(c, dict)]
    for current in configs:
        allow = current.get("AllowFunnel") or {}
        web = current.get("Web") or {}
        if not isinstance(allow, dict) or not isinstance(web, dict):
            continue
        for hostport, on in allow.items():
            host, _, number = str(hostport).rpartition(":")
            if on is not True or number != "443" or not host:
                continue
            handlers = (web.get(hostport) or {}).get("Handlers") if isinstance(web.get(hostport), dict) else None
            if not isinstance(handlers, dict):
                continue
            if any(isinstance(h, dict) and proxies_to(h.get("Proxy"), port) for h in handlers.values()):
                return host.rstrip(".")
    return None


def funnel(force: bool = False) -> str | None:
    """Funnel がこの受け口に向いていれば、その名前（FUNNEL_CACHE 秒覚えておく）"""
    now = time.time()
    cached = W.funnel_cache
    if not force and cached is not None and now - cached[0] < FUNNEL_CACHE:
        return cached[1]
    host = None
    if W.port:
        try:
            host = funnel_host((W.status or read_status)(), W.port)
        except Exception:  # noqa: BLE001 — 読めなければ「オフ」
            host = None
    W.funnel_cache = (now, host)
    return host


# MARK: - ふだんの受け口の GET /watch-route と、見守りの画面


def route_info() -> dict | None:
    """GET /watch-route の答え。時計の外の道が動いていなければ None"""
    if not running():
        return None
    host = funnel()
    return {"url": f"https://{host}" if host else None, "token": W.token, "funnel": bool(host), "port": W.port}


def http_route(handler) -> None:
    """GET /watch-route（ふだんの合言葉は確かめてある）。時計の合言葉が入るので、覚えさせない（no-store）"""
    body = route_info()
    if body is None:
        handler.send_json(503, {"error": "時計の外の道は今は動いていません"})
        return
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(data)


def today_count(queue, now: float | None = None) -> int:
    """今日（この PC の時計で 0 時から）時計の外の道から預かった仕事の数"""
    if queue is None:
        return 0
    moment = time.localtime(W.clock() if now is None else now)
    midnight = time.mktime((moment.tm_year, moment.tm_mon, moment.tm_mday, 0, 0, 0, 0, 0, -1))
    return sum(1 for job in queue.listing(origin="watch") if float(job.get("queued_at") or 0) >= midnight)


def dash_info() -> dict:
    """見守りの画面の「時計の外の道」に出すもの（時計の合言葉は入れない）"""
    queue = getattr(getattr(W.main, "App", None), "jobs", None)
    on = running()
    host = funnel() if on else None
    now = W.clock()
    return {"listening": on, "port": W.port, "funnel": bool(host), "url": f"https://{host}" if host else None,
            "today": today_count(queue) if on else 0, "locked": locked(now),
            "locked_until": W.locked_until if locked(now) else None, "failures": recent_failures(now),
            "lockouts": W.lockouts}
