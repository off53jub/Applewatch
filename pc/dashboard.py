"""LifeLog PC 版 6: iPhone のブラウザで見る見守りの画面（GET /dash）と、直近の文字起こしの数（速さ・モデルの組の近さ）。

合言葉で守る。ブラウザの「ユーザー名とパスワード」の欄（Basic 認証。ユーザー名は何でもよく、パスワードが合言葉）か、
一度だけ /dash?key=合言葉 で開くと、その後はクッキー（HttpOnly）で開ける。
画面のボタン（再起動・更新を確かめる）は POST で、同じ合言葉と、画面の中からだけ付く印（X-LifeLog-Dash）が要る。
外の部品（フォントや部品の置き場）は使わない。文字起こしの文の中身は出さない。
"""

from __future__ import annotations

import base64
import hashlib
import html
import json
import re
import secrets
import statistics
import threading
import time
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs

COOKIE = "lifelog_dash"
HEADER = "X-LifeLog-Dash"
LOG_TAIL = 400_000           # 記録（log.txt）の終わりから読む大きさ
PROBLEM = re.compile(r"できません|できなかった|られません|失敗|エラー|[Ee]rror|Exception|Traceback|insufficient|"
                     r"NG |断りました|使いません|合いません|足りません|見つかりません|つまずき|止めました|戻します")
CUDA = re.compile(r"CUDA|cuda|cuBLAS|cudnn|cuDNN|GPU")


# MARK: - 直近の文字起こし（速さ・モデルの組の近さ）


class Recent:
    """直近の文字起こしの数だけを覚えておく（文の中身は持たない）。PC を起動し直すと空になる。"""

    def __init__(self, size: int = 100) -> None:
        self.rows: deque = deque(maxlen=size)
        self.lock = threading.Lock()

    def record(self, kind: str, took: float, voiced: float, duration: float, stats: dict | None) -> None:
        with self.lock:
            self.rows.append({"kind": kind, "at": time.time(), "took": float(took), "voiced": float(voiced),
                              "duration": float(duration), "pairs": dict((stats or {}).get("pairs") or {}),
                              "pair_lines": dict((stats or {}).get("pair_lines") or {}),
                              "silent": dict((stats or {}).get("silent") or {}),
                              "heard": int((stats or {}).get("heard_lines") or 0)})

    def speed(self, kind: str = "transcribe", count: int = 20) -> tuple[float | None, int]:
        """直近 count 回の (かかった秒 ÷ 声のある秒) の中央値と、数えた回数"""
        with self.lock:
            ratios = [r["took"] / r["voiced"] for r in self.rows if r["kind"] == kind and r["voiced"] > 0][-count:]
        return (statistics.median(ratios) if ratios else None), len(ratios)

    def pairs(self) -> dict:
        """覚えている全部（最大 100 回）の、モデルの組ごとの近さ（行の数で重みを付けた平均）と、何も書かなかった数"""
        sums: dict[str, list[float]] = {}
        silent: dict[str, int] = {}
        heard = 0
        with self.lock:
            rows = list(self.rows)
        for row in rows:
            heard += row["heard"]
            for pair, value in row["pairs"].items():
                n = int(row["pair_lines"].get(pair) or 1)
                entry = sums.setdefault(pair, [0.0, 0])
                entry[0] += float(value) * n
                entry[1] += n
            for name, n in row["silent"].items():
                silent[name] = silent.get(name, 0) + int(n)
        return {"requests": len(rows), "heard_lines": heard,
                "pairs": {k: round(v[0] / v[1], 3) for k, v in sums.items() if v[1]},
                "pair_lines": {k: int(v[1]) for k, v in sums.items()}, "silent": silent}


# MARK: - 記録（log.txt）から


def log_tail(path: Path, size: int = LOG_TAIL) -> list[str]:
    try:
        with Path(path).open("rb") as f:
            f.seek(0, 2)
            end = f.tell()
            f.seek(max(0, end - size))
            data = f.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    return lines[1:] if end > size else lines


def problems(lines: list[str], count: int = 15) -> list[str]:
    """失敗・注意の行（新しいものが後ろ）"""
    return [line for line in lines if PROBLEM.search(line)][-count:]


def last_cuda_error(lines: list[str]) -> str | None:
    for line in reversed(lines):
        if CUDA.search(line) and PROBLEM.search(line):
            return line
    return None


# MARK: - 合言葉


def token(key: str) -> str:
    """クッキーに入れる印（合言葉そのものは入れない）"""
    return hashlib.sha256(("lifelog-dash\0" + key).encode("utf-8")).hexdigest()


def cookies(header: str | None) -> dict[str, str]:
    out = {}
    for part in (header or "").split(";"):
        name, _, value = part.strip().partition("=")
        if name:
            out[name] = value
    return out


def check(headers, query: str, key: str) -> tuple[bool, bool]:
    """(合っているか, クッキーを渡すか)。Basic（パスワードが合言葉）・Bearer・クッキー・?key= のどれか。"""
    given = headers.get("Authorization", "") or ""
    if given.startswith("Basic "):
        try:
            _, _, password = base64.b64decode(given[6:].strip()).decode("utf-8").partition(":")
        except (ValueError, UnicodeDecodeError):
            password = ""
        if secrets.compare_digest(password.encode("utf-8"), key.encode("utf-8")):
            return True, False
    if given.startswith("Bearer ") and secrets.compare_digest(given[7:].strip().encode("utf-8"), key.encode("utf-8")):
        return True, False
    if secrets.compare_digest(cookies(headers.get("Cookie")).get(COOKIE, "").encode("utf-8"), token(key).encode("utf-8")):
        return True, False
    asked = (parse_qs(query).get("key") or [""])[0]
    if asked and secrets.compare_digest(asked.encode("utf-8"), key.encode("utf-8")):
        return True, True
    return False, False


def cookie_header(key: str) -> str:
    return f"{COOKIE}={token(key)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000"


# MARK: - 画面


def _e(value) -> str:
    return html.escape("" if value is None else str(value))


def _seconds(value) -> str:
    if value is None:
        return "—"
    value = float(value)
    if value < 60:
        return f"{value:.1f} 秒"
    if value < 3600:
        return f"{value / 60:.1f} 分"
    if value < 86400 * 2:
        return f"{value / 3600:.1f} 時間"
    return f"{value / 86400:.1f} 日"


def _clock(when) -> str:
    if not when:
        return "—"
    return time.strftime("%m/%d %H:%M", time.localtime(float(when)))


STATUS = {"queued": "待ち", "working": "文字にしています", "done": "でき上がり", "failed": "失敗"}

STYLE = """
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2228;--sub:#5d6670;--line:#dfe3e8;--ok:#1f7a3a;--ng:#b3261e;--warn:#9a6700;--btn:#2556c7}
@media (prefers-color-scheme:dark){:root{--bg:#111418;--card:#1b2026;--ink:#e8ebef;--sub:#9aa4ae;--line:#2c333b;--ok:#5cc97b;--ng:#ff8a80;--warn:#e3b341;--btn:#6d95ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,"Hiragino Sans",system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:12px 16px 40px}h1{font-size:20px;margin:8px 0 12px}
h2{font-size:15px;margin:0 0 8px;color:var(--sub)}section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:0 0 12px}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:4px 6px;border-top:1px solid var(--line);vertical-align:top}
th{color:var(--sub);font-weight:600}.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.ok{color:var(--ok)}.ng{color:var(--ng)}.warn{color:var(--warn)}.sub{color:var(--sub);font-size:13px}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:2px 12px}.kv div:nth-child(odd){color:var(--sub)}
.log{font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all;margin:0}
.scroll{overflow-x:auto}button{font:inherit;padding:10px 16px;border-radius:10px;border:0;background:var(--btn);color:#fff;margin:0 8px 8px 0}
#msg{min-height:1.5em}
"""

SCRIPT = """
async function act(path, ask){
  if(!confirm(ask)) return;
  const msg=document.getElementById('msg'); msg.textContent='送っています…';
  try{
    const r=await fetch(path,{method:'POST',credentials:'same-origin',headers:{'X-LifeLog-Dash':'1'}});
    const j=await r.json().catch(()=>({}));
    msg.textContent=j.message||j.error||('答え '+r.status);
    if(r.ok&&path.endsWith('restart')) setTimeout(()=>location.reload(),60000);
  }catch(e){msg.textContent='送れませんでした: '+e}
}
"""


def render(info: dict) -> str:
    """見守りの画面の HTML。info は lifelog_pc.dash_info() が作る。"""
    parts = [f"<h1>LifeLog PC 版 {_e(info.get('version'))}"
             f"<span class='sub'>（番号 {_e(info.get('build') or '—')}）</span></h1>"]
    # 動いているもの
    rows = [("動いている時間", _seconds(info.get("uptime"))),
            ("ディスクの空き", f"{info['disk_free'] / 1e9:.1f} GB（{_e(info.get('disk_path'))}）"
             if info.get("disk_free") is not None else "—"),
            ("動かし方", "exe" if info.get("frozen") else "Python")]
    parts.append("<section><h2>この PC</h2><div class='kv'>"
                 + "".join(f"<div>{_e(k)}</div><div>{v if k == 'ディスクの空き' else _e(v)}</div>" for k, v in rows)
                 + "</div></section>")
    # モデル
    engines = info.get("engines") or []
    gpu = info.get("gpu") or {}
    body = "".join(f"<tr><td>{_e(e.get('name'))}</td><td>{_e(e.get('label'))}</td>"
                   f"<td class='{'ok' if e.get('provider') == 'cuda' else ''}'>{_e(e.get('provider'))}</td></tr>"
                   for e in engines) or "<tr><td colspan=3>読み込めたモデルがありません</td></tr>"
    gpu_line = ("<span class='ok'>GPU で動いているモデルがあります</span>" if gpu.get("used")
                else ("<span class='warn'>NVIDIA の GPU はありますが、使えていません（CPU で動いています）</span>"
                      if gpu.get("nvidia") else "NVIDIA の GPU はありません（CPU で動いています）"))
    cuda = f"<p class='sub'>GPU の最後の失敗: <span class='log'>{_e(gpu.get('last_error'))}</span></p>" \
        if gpu.get("last_error") else ""
    parts.append(f"<section><h2>文字にするモデル</h2><div class='scroll'><table><tr><th>名前</th><th>モデル</th>"
                 f"<th>動く場所</th></tr>{body}</table></div><p>{gpu_line}</p>{cuda}</section>")
    # Ollama
    ollama = info.get("ollama") or {}
    models = "、".join(_e(m) for m in ollama.get("models") or []) or "—"
    parts.append("<section><h2>この PC の言語モデル（Ollama）</h2><div class='kv'>"
                 f"<div>Ollama</div><div class='{'ok' if ollama.get('running') else 'ng'}'>"
                 f"{'動いています' if ollama.get('running') else '答えません'}</div>"
                 f"<div>/llm</div><div>{_e(ollama.get('llm_model'))}："
                 f"{'使えます' if ollama.get('llm') else '使えません'}</div>"
                 f"<div>意味で探す</div><div>{_e(ollama.get('semantic_model'))}："
                 f"{_e(ollama.get('semantic_state'))}（{_e(ollama.get('semantic_count', 0))} 行）</div>"
                 f"<div>入っているモデル</div><div>{models}</div></div></section>")
    # 後で受け取る文字起こし
    counts = info.get("job_counts") or {}
    jobs = info.get("jobs") or []
    rows = []
    for job in jobs:
        voiced = job.get("voiced_seconds")
        took = job.get("processing_seconds")
        speed = f"{took / voiced:.2f}" if voiced and took else "—"
        state = STATUS.get(job.get("status"), job.get("status"))
        css = {"done": "ok", "failed": "ng", "working": "warn"}.get(job.get("status"), "")
        error = f"<br><span class='sub'>{_e(job.get('error'))}</span>" if job.get("error") else ""
        rows.append(f"<tr><td>{_e(job.get('id'))}<br><span class='sub'>{_clock(job.get('queued_at'))}</span></td>"
                    f"<td class='{css}'>{_e(state)}{error}</td><td class='num'>{_seconds(job.get('audio_seconds'))}</td>"
                    f"<td class='num'>{_seconds(took)}</td><td class='num'>{speed}</td></tr>")
    table = "".join(rows) or "<tr><td colspan=5>まだありません</td></tr>"
    summary = "・".join(f"{STATUS[k]} {counts.get(k, 0)}" for k in ("queued", "working", "done", "failed"))
    parts.append(f"<section><h2>後で受け取る文字起こし（{_e(summary)}）</h2><div class='scroll'><table>"
                 "<tr><th>区切り</th><th>状態</th><th class='num'>音声</th><th class='num'>処理</th>"
                 f"<th class='num'>速さ</th></tr>{table}</table></div>"
                 "<p class='sub'>速さ = 処理にかかった秒 ÷ 声のある秒（1 より小さければ録音に追いつけます）</p></section>")
    # 直近の文字起こし
    speed, count = info.get("speed") or (None, 0)
    pairs = info.get("pairs") or {}
    pair_rows = "".join(f"<tr><td>{_e(k)}</td><td class='num'>{v:.2f}</td>"
                        f"<td class='num'>{_e(pairs.get('pair_lines', {}).get(k, 0))}</td></tr>"
                        for k, v in (pairs.get("pairs") or {}).items()) or "<tr><td colspan=3>まだありません</td></tr>"
    silent = "・".join(f"{_e(k)} {_e(v)}" for k, v in (pairs.get("silent") or {}).items()) or "なし"
    parts.append("<section><h2>直近の文字起こし</h2><div class='kv'>"
                 f"<div>/transcribe の速さ</div><div>{f'{speed:.2f}' if speed is not None else '—'}"
                 f"<span class='sub'>（直近 {count} 回の中央値。処理の秒 ÷ 声のある秒）</span></div>"
                 f"<div>数えた回数</div><div>{_e(pairs.get('requests', 0))} 回（声のある区間 {_e(pairs.get('heard_lines', 0))}）"
                 "</div></div><div class='scroll'><table><tr><th>モデルの組</th><th class='num'>近さ</th><th class='num'>区間</th></tr>"
                 f"{pair_rows}</table></div><p class='sub'>何も書かなかった区間: {silent}</p></section>")
    # 更新
    update = info.get("update") or {}
    parts.append("<section><h2>更新</h2><div class='kv'>"
                 f"<div>自動の更新</div><div>{'オン' if update.get('auto') else 'オフ'}</div>"
                 f"<div>状態</div><div>{_e(update.get('state'))}</div>"
                 f"<div>最後に確かめた時</div><div>{_clock(update.get('checked'))}</div>"
                 + (f"<div>失敗</div><div class='ng'>{_e(update.get('error'))}</div>" if update.get("error") else "")
                 + "</div></section>")
    # 記録
    lines = info.get("problems") or []
    log = "\n".join(_e(line) for line in lines) or "（ありません）"
    parts.append(f"<section><h2>記録の中の失敗・注意（新しいものが下、最大 15 行）</h2><pre class='log'>{log}</pre></section>")
    parts.append("<section><h2>操作</h2>"
                 "<button onclick=\"act('/dash/restart','LifeLog PC を起動し直します。よろしいですか？')\">再起動</button>"
                 "<button onclick=\"act('/dash/update','新しい版があるか確かめます。あれば入れ替えて起動し直します。よろしいですか？')\">"
                 "更新を確かめる</button><div id='msg' class='sub'></div>"
                 f"<p class='sub'>この画面は 60 秒ごとに新しくなります。{_e(time.strftime('%H:%M:%S'))} 現在</p></section>")
    return ("<!doctype html><html lang='ja'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<meta name='color-scheme' content='light dark'><meta http-equiv='refresh' content='60'>"
            f"<title>LifeLog PC</title><style>{STYLE}</style></head><body><main>{''.join(parts)}</main>"
            f"<script>{SCRIPT}</script></body></html>")


def login_page() -> str:
    return ("<!doctype html><html lang='ja'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'><meta name='color-scheme' content='light dark'>"
            f"<title>LifeLog PC</title><style>{STYLE}</style></head><body><main><h1>LifeLog PC</h1><section>"
            "<p>合言葉が要ります。パスワードの欄に合言葉を入れてください（ユーザー名は何でもかまいません）。</p>"
            "<p class='sub'>または一度だけ <code>/dash?key=合言葉</code> で開くと、次からはそのまま開けます。</p>"
            "</section></main></body></html>")


SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                               "connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}


def send(handler, status: int, body: str, content_type: str = "text/html; charset=utf-8",
         extra: dict | None = None) -> None:
    data = body.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    for name, value in {**SECURITY_HEADERS, **(extra or {})}.items():
        handler.send_header(name, value)
    handler.end_headers()
    handler.wfile.write(data)


def send_json(handler, status: int, body: dict) -> None:
    send(handler, status, json.dumps(body, ensure_ascii=False), "application/json; charset=utf-8")
