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


def _pc_latency(stats) -> list[str]:
    """版 8: 直近の仕事の待ち・作業の時間（diag.pc_latency と同じ行）"""
    import diag

    return diag.pc_latency(stats)

STYLE = """
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2228;--sub:#5d6670;--line:#dfe3e8;--ok:#1f7a3a;--ng:#b3261e;--warn:#9a6700;--btn:#2556c7}
@media (prefers-color-scheme:dark){:root{--bg:#111418;--card:#1b2026;--ink:#e8ebef;--sub:#9aa4ae;--line:#2c333b;--ok:#5cc97b;--ng:#ff8a80;--warn:#e3b341;--btn:#6d95ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,"Hiragino Sans",system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:12px 16px 40px}h1{font-size:20px;margin:8px 0 12px}
h2{font-size:15px;margin:0 0 8px;color:var(--sub)}section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:0 0 12px}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:4px 6px;border-top:1px solid var(--line);vertical-align:top}
th{color:var(--sub);font-weight:600}.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.ok{color:var(--ok)}.ng{color:var(--ng)}.warn{color:var(--warn)}.sub{color:var(--sub);font-size:13px}
.kv{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:2px 12px}.kv div{min-width:0;overflow-wrap:anywhere}
.kv div:nth-child(odd){color:var(--sub)}td{overflow-wrap:anywhere}
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
    # 版 7（records）: 記録の画面への入口
    parts.append("<p><a href='/dash/records' style='color:var(--btn)'>記録を読む・探す・直す →</a></p>")
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
        # 版 8: 待ち（受け終わり→文字にし始め）・下書きまで・渡したか
        started, queued = job.get("started_at"), job.get("queued_at")
        waited = _seconds(float(started) - float(queued)) if started and queued else "—"
        draft = job.get("draft_at")
        drafted = _seconds(float(draft) - float(started)) if draft and started else "—"
        handed = "<br><span class='sub'>待ち合わせで渡した</span>" if job.get("handed") else ""
        rows.append(f"<tr><td>{_e(job.get('id'))}<br><span class='sub'>{_clock(job.get('queued_at'))}</span></td>"
                    f"<td class='{css}'>{_e(state)}{error}{handed}</td><td class='num'>{_seconds(job.get('audio_seconds'))}</td>"
                    f"<td class='num'>{waited}</td><td class='num'>{drafted}</td>"
                    f"<td class='num'>{_seconds(took)}</td><td class='num'>{speed}</td></tr>")
    table = "".join(rows) or "<tr><td colspan=7>まだありません</td></tr>"
    summary = "・".join(f"{STATUS[k]} {counts.get(k, 0)}" for k in ("queued", "working", "done", "failed"))
    latency = "".join(f"<li>{_e(text)}</li>" for text in _pc_latency(info.get("job_latency")))
    parts.append(f"<section><h2>後で受け取る文字起こし（{_e(summary)}）</h2>"
                 f"<p class='sub'>直近 50 件のでき上がりの時間（PC で測った分）</p><ul>{latency}</ul><div class='scroll'><table>"
                 "<tr><th>区切り</th><th>状態</th><th class='num'>音声</th><th class='num'>待ち</th><th class='num'>下書き</th>"
                 f"<th class='num'>処理</th><th class='num'>速さ</th></tr>{table}</table></div>"
                 "<p class='sub'>待ち = 受け取ってから文字にし始めるまで。下書き = 文字にし始めてから、速いモデルの下書きができるまで。"
                 "速さ = 処理にかかった秒 ÷ 声のある秒（1 より小さければ録音に追いつけます）。"
                 "iPhone で測った区間ごとの時間は「実機の様子」に出ます。</p></section>")
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
    # 版 7（ops）: 実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割
    parts.extend(ops_sections(info.get("ops") or {}))
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


# MARK: - 版 7（ops）: 実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割
# 中身は ops.dash_info() が作る。ボタンは /dash/ops/… に、画面の中だけが付ける印（X-LifeLog-Dash）を付けて送る。
# この画面は 60 秒ごとに新しくなるので、鍵を入れる欄は別の画面（/dash/ops/keys）にしてある。

# TestFlight の報告の詳しい画面だけは、スクショ（この PC の中の /dash/ops/feedback-file）を出すので img-src を許す
FEEDBACK_CSP = ("default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; script-src 'unsafe-inline'; "
                "connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'")

OPS_SCRIPT = """
async function opsPost(path, body, ask, out){
  if(ask && !confirm(ask)) return;
  const msg=document.getElementById(out||'opsMsg'); msg.textContent='送っています…';
  try{
    const r=await fetch(path,{method:'POST',credentials:'same-origin',
      headers:{'X-LifeLog-Dash':'1','Content-Type':'application/json'},body:JSON.stringify(body||{})});
    const j=await r.json().catch(()=>({}));
    msg.textContent=j.message||j.error||('答え '+r.status);
  }catch(e){msg.textContent='送れませんでした: '+e}
}
function opsKey(kind){
  const out=kind==='apns'?'opsMsgPush':'opsMsgAsc';
  const f=document.getElementById(kind+'File').files[0];
  if(!f){document.getElementById(out).textContent='.p8 のファイルを選んでください'; return}
  const typed=(document.getElementById(kind+'Key').value||'').trim();
  const id=typed||((f.name.match(/AuthKey_([A-Z0-9]{10})/)||[])[1]||'');
  const reader=new FileReader();
  reader.onload=()=>{
    const body={key_id:id, p8:String(reader.result||'')};
    if(kind==='apns') body.team=(document.getElementById('apnsTeam').value||'').trim();
    else body.issuer_id=(document.getElementById('ascIssuer').value||'').trim();
    opsPost('/dash/ops/'+kind+'-key', body, null, out);
  };
  reader.readAsText(f);
}
"""

OPS_STYLE = ".dev{border-top:1px solid var(--line);padding:8px 0}.dev:first-of-type{border-top:0}" \
            "section p,section li{overflow-wrap:anywhere}" \
            "details{margin:6px 0}summary{cursor:pointer;color:var(--sub)}ul{margin:4px 0;padding-left:20px}" \
            "input{font:inherit;padding:8px;border:1px solid var(--line);border-radius:8px;margin:0 8px 8px 0;" \
            "max-width:100%;background:var(--card);color:var(--ink)}a{color:var(--btn)}"


def _when(when) -> str:
    """時刻と、どれだけ前か（"11/07 15:58（12 分前）"）"""
    if not when:
        return "—"
    return f"{_clock(when)}（{_seconds(max(0.0, time.time() - float(when)))}前）"


def _iso_clock(text) -> str:
    """ISO 8601 の日時を、この PC の時刻の "11/07 15:58" にする"""
    import datetime

    if not text:
        return "—"
    try:
        moment = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return _e(text)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return _clock(moment.timestamp())


def _ops_devices(ops: dict) -> str:
    rows = []
    for device in ops.get("devices") or []:
        record = device.get("record") or {}
        concerns = device.get("concerns") or []
        worry = ("<ul class='ng'>" + "".join(f"<li>{_e(c)}</li>" for c in concerns) + "</ul>") if concerns \
            else ("<p class='sub'>しばらく届いていない端末です</p>" if device.get("old")
                  else "<p class='ok'>気になる所はありません</p>")
        state = "".join(f"<div>{_e(k)}</div><div>{_e(v)}</div>" for k, v in
                        [("最後に届いた", _when(device.get("received"))),
                         *[(text.split(":", 1)[0], text.split(":", 1)[1].strip()) for text in device.get("state") or []
                           if ":" in text]])
        checks = [r for r in record.get("rows") or [] if isinstance(r, dict)]
        bad = sum(1 for r in checks if r.get("ok") is False)
        table = "".join(f"<tr><td>{_e(r.get('group'))}</td><td>{_e(r.get('name'))}</td><td>{_e(r.get('value'))}</td>"
                        f"<td class='{'ng' if r.get('ok') is False else 'ok' if r.get('ok') else ''}'>"
                        f"{'×' if r.get('ok') is False else '○' if r.get('ok') else '—'}</td></tr>" for r in checks)
        crashes = [c for c in record.get("crashes") or [] if isinstance(c, dict)]
        crash_rows = "".join(f"<tr><td>{_iso_clock(c.get('at'))}</td><td>{_e(c.get('kind'))}</td>"
                             f"<td>{_e(c.get('detail'))}</td></tr>" for c in crashes[-30:][::-1])
        push = record.get("push") if isinstance(record.get("push"), dict) else {}
        rows.append(f"<div class='dev'><b>{_e(device.get('label'))}</b> <span class='sub'>iOS {_e(record.get('os') or '—')}・"
                    f"build {_e(record.get('build') or '—')}・{_e(record.get('install') or '—')}・"
                    f"通知の登録 {'あり' if push.get('token') else 'なし'}</span>"
                    f"<div class='kv'>{state}</div>{worry}"
                    f"<details><summary>自己点検（{len(checks)} 行・ok でない {bad} 行）</summary><div class='scroll'><table>"
                    f"<tr><th>まとまり</th><th>名前</th><th>値</th><th>ok</th></tr>{table}</table></div></details>"
                    + (f"<details><summary>落ちた・固まった記録（{len(crashes)} 件）</summary><div class='scroll'><table>"
                       f"<tr><th>時刻</th><th>種類</th><th>くわしく</th></tr>{crash_rows}</table></div></details>"
                       if crashes else "")
                    + "</div>")
    body = "".join(rows) or "<p class='sub'>まだ届いていません（iPhone の LifeLog が1時間に1回ほど送ってきます）</p>"
    return (f"<section><h2>実機の様子</h2>{body}<p class='sub'>まとめのファイル（この PC で動く Claude が読みます）: "
            f"{_e(ops.get('summary'))}</p></section>")


def _ops_push(ops: dict) -> str:
    push = ops.get("push") or {}
    key = f"AuthKey_{_e(push.get('key_id'))}.p8" if push.get("key_id") else \
        ("<span class='ng'>鍵のファイルが読めません</span>" if push.get("key_file") else "<span class='warn'>まだありません</span>")
    team = _e(push.get("team")) if push.get("team") else "<span class='warn'>まだ分かりません（iPhone が様子を送ると分かります）</span>"
    state = "<span class='ok'>送れます</span>" if push.get("ready") else "<span class='warn'>まだ送れません（鍵とチームの ID が要ります）</span>"
    devices = "".join(
        f"<tr><td>{_e(d.get('device'))}<br><span class='sub'>{_e(d.get('model'))}</span></td><td>{_e(d.get('environment'))}</td>"
        f"<td>…{_e(d.get('token_tail'))}" + ("<br><span class='ng'>使えなくなりました（"
                                             f"{_e((d.get('dead') or {}).get('status'))} {_e((d.get('dead') or {}).get('reason'))}）</span>"
                                             if d.get("dead") else "") + "</td>"
        f"<td>{_e('・'.join(f'{k} {v}' for k, v in (d.get('today') or {}).items() if v) or '—')}</td>"
        f"<td>{_e((d.get('last') or {}).get('kind') or '—')} → {_e((d.get('last') or {}).get('status') or '—')}"
        f"<br><span class='sub'>{_clock((d.get('last') or {}).get('at'))}</span></td></tr>"
        for d in push.get("devices") or []) or "<tr><td colspan=5>まだありません（iPhone の LifeLog を開くと登録されます）</td></tr>"
    history = "".join(f"<tr><td>{_clock(h.get('at'))}</td><td>{_e(h.get('kind'))}</td><td>{_e(h.get('status'))}</td>"
                      f"<td>{_e(h.get('reason') or '')}</td></tr>" for h in (push.get("history") or [])[::-1])
    error = f"<div>最後の失敗</div><div class='ng'>{_e(push.get('last_error'))}</div>" if push.get("last_error") else ""
    return ("<section><h2>見えない通知（家の PC から iPhone を起こす）</h2><div class='kv'>"
            f"<div>様子</div><div>{state}</div><div>鍵</div><div>{key}</div><div>チームの ID</div><div>{team}</div>"
            f"<div>HTTP/2 の部品</div><div>{'あります' if push.get('http2') else '<span class=ng>ありません</span>'}</div>{error}</div>"
            "<div class='scroll'><table><tr><th>端末</th><th>環境</th><th>トークン</th><th>この 24 時間</th><th>最後</th></tr>"
            f"{devices}</table></div>"
            + (f"<details><summary>最近送ったもの</summary><div class='scroll'><table><tr><th>時刻</th><th>種類</th>"
               f"<th>答え</th><th>理由</th></tr>{history}</table></div></details>" if history else "")
            + "<p class='sub'>送るとき: 文字にし終えた（job・待ち合わせで渡せなかったときだけ・同じ端末へ10分に1回）・録音中なのに30分なにも来ない（wake・1時間に2回、1日12回）・"
              "3時間様子が来ない（diag・1日4回）・毎日 3:30（nightly）</p>"
              "<button onclick=\"opsPost('/dash/ops/apns-test',{},'iPhone にテストの通知を送ります。よろしいですか？','opsMsgPush')\">"
              "テスト通知を送る</button><a href='/dash/ops/keys'>鍵を入れる画面を開く</a>"
              "<div id='opsMsgPush' class='sub'></div></section>")


def _ops_feedback(ops: dict) -> str:
    feedback = ops.get("feedback") or {}
    kinds = {"screenshot": "スクショつき", "crash": "落ちた"}
    rows = "".join(
        f"<tr><td>{_iso_clock(item.get('created'))}</td><td>{_e(kinds.get(item.get('kind'), item.get('kind')))}</td>"
        f"<td>{_e(item.get('build') or '—')}</td><td>{_e(item.get('device') or '—')}<br>"
        f"<span class='sub'>iOS {_e(item.get('os') or '—')}</span></td><td>{_e((item.get('comment') or '')[:120]) or '—'}</td>"
        f"<td><a href='/dash/ops/feedback?id={_e(item.get('id'))}'>詳しく</a></td></tr>"
        for item in feedback.get("recent") or []) or "<tr><td colspan=6>まだありません</td></tr>"
    key = f"AuthKey_{_e(feedback.get('key_id'))}.p8" if feedback.get("configured") else "<span class='warn'>まだありません</span>"
    error = f"<div>失敗</div><div class='ng'>{_e(feedback.get('error'))}</div>" if feedback.get("error") else ""
    return ("<section><h2>TestFlight の報告</h2><div class='kv'>"
            f"<div>App Store Connect のキー</div><div>{key}</div><div>最後に読んだ</div><div>{_when(feedback.get('checked'))}</div>"
            f"<div>様子</div><div>{_e(feedback.get('state'))}（全部で {_e(feedback.get('count', 0))} 件）</div>{error}</div>"
            "<div class='scroll'><table><tr><th>日時</th><th>種類</th><th>build</th><th>端末</th><th>コメント</th><th></th></tr>"
            f"{rows}</table></div><p class='sub'>1日に4回読みます。置き場所: {_e(feedback.get('folder'))}（PC の外には出しません）</p>"
            "<button onclick=\"opsPost('/dash/ops/asc-fetch',{},null,'opsMsgAsc')\">今すぐ読む</button>"
            "<a href='/dash/ops/keys'>キーを入れる画面を開く</a><div id='opsMsgAsc' class='sub'></div></section>")


def _ops_train(ops: dict) -> str:
    train = ops.get("train") or {}
    plan = ops.get("gpu") or {}
    last = train.get("last") or {}
    labels = {"improved": "良くなったので入れ替えました", "not_improved": "良くならなかったので前のまま",
              "refused": "学び直しませんでした", "failed": "うまくいきませんでした", "timeout": "時間がかかりすぎたので止めました"}
    if last:
        cers = ""
        if isinstance(last.get("cer_before"), (int, float)) and isinstance(last.get("cer_after"), (int, float)):
            cers = f"（誤りの割合 {last['cer_before']:.2%} → {last['cer_after']:.2%}）"
        result = (f"{_iso_clock(last.get('at'))} {_e(labels.get(last.get('result'), last.get('result')))}{cers}"
                  + (f"<br><span class='sub'>{_e(last.get('message'))}</span>" if last.get("message") else ""))
    else:
        result = "まだありません"
    memory = plan.get("memory") or {}
    night = plan.get("night") or {}
    rows = [("自動の学び直し", _e(train.get("state"))),
            ("時間帯", f"{_e(train.get('window'))}（次は {_iso_clock(train.get('next'))}）"),
            ("材料", f"{_e(train.get('count'))} 個（前回から +{_e(train.get('since_last'))}。{_e(train.get('min_samples'))} 個以上で、"
                     f"{_e(train.get('min_new'))} 個増えたら学び直します）"),
            ("学び直しの部品", _e(train.get("runtime")) + (f"<br><span class='ng'>{_e(train.get('runtime_error'))}</span>"
                                                     if train.get("runtime_error") else "")),
            ("前回", result),
            ("GPU の割り当て", _e(plan.get("text"))),
            ("下ろしているもの", _e("・".join(plan.get("down") or [])) or "—"),
            ("夜の割り当て", f"{_e(night.get('start'))}〜{_e(night.get('end'))} に {_e(night.get('idle_minutes'))} 分仕事が無いとき"
             if night else "使わない設定です"),
            ("GPU のメモリー", f"{memory['used']} / {memory['total']} MB" if memory.get("total") else "—")]
    failed = plan.get("failed") or {}
    if failed:
        rows.append(("戻せなかったもの", "<span class='ng'>" + _e("・".join(f"{k}: {v}" for k, v in failed.items())) + "</span>"))
    body = "".join(f"<div>{_e(k)}</div><div>{v}</div>" for k, v in rows)
    return f"<section><h2>学び直しと GPU の時間割</h2><div class='kv'>{body}</div></section>"


def ops_sections(ops: dict) -> list[str]:
    """見守りの画面の版 7 の節（ops.dash_info() が空なら、何も出さない）"""
    if not ops:
        return []
    return [f"<style>{OPS_STYLE}</style>", _ops_devices(ops), _ops_push(ops), _ops_feedback(ops), _ops_train(ops),
            f"<script>{OPS_SCRIPT}</script>"]


def _page(title: str, body: str, refresh: bool = False) -> str:
    return ("<!doctype html><html lang='ja'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'><meta name='color-scheme' content='light dark'>"
            + ("<meta http-equiv='refresh' content='60'>" if refresh else "")
            + f"<title>{_e(title)}</title><style>{STYLE}{OPS_STYLE}</style></head><body><main>{body}</main>"
            f"<script>{OPS_SCRIPT}</script></body></html>")


def keys_page(push: dict, feedback: dict) -> str:
    """鍵を入れる画面（/dash/ops/keys）。ファイルは、この PC の LifeLog PC の置き場所の下（apns・asc）にだけ置く。"""
    body = ("<h1>鍵を入れる</h1><p><a href='/dash'>見守りの画面に戻る</a></p>"
            "<section><h2>見えない通知の鍵（APNs）</h2>"
            f"<p class='sub'>今の鍵: {('AuthKey_' + _e(push.get('key_id')) + '.p8') if push.get('key_id') else 'まだありません'}・"
            f"チームの ID: {_e(push.get('team') or '—')}</p>"
            "<p class='sub'>Apple Developer の「Certificates, Identifiers &amp; Profiles」→「Keys」で、Apple Push Notifications service（APNs）に"
            "チェックを入れて作った鍵のファイル（AuthKey_XXXXXXXXXX.p8）を選びます。鍵の ID はファイルの名前から入ります。"
            "チームの ID は空でかまいません（iPhone の LifeLog が様子を送ると分かります）。</p>"
            "<input type='file' id='apnsFile' accept='.p8'><br><input id='apnsKey' placeholder='鍵の ID（10 文字）'>"
            "<input id='apnsTeam' placeholder='チームの ID（10 文字・空でもよい）'><br>"
            "<button onclick=\"opsKey('apns')\">通知の鍵を入れる</button><div id='opsMsgPush' class='sub'></div></section>"
            "<section><h2>App Store Connect のキー（TestFlight の報告を読む）</h2>"
            f"<p class='sub'>今のキー: {('AuthKey_' + _e(feedback.get('key_id')) + '.p8') if feedback.get('key_id') else 'まだありません'}</p>"
            "<p class='sub'>App Store Connect の「ユーザとアクセス」→「統合」→「App Store Connect API」で作ったキー"
            "（役割は Developer 以上）のファイル（AuthKey_XXXXXXXXXX.p8）を選び、同じ画面の上にある issuer ID を入れます"
            "（個人のキーなら issuer ID は空にします）。</p>"
            "<input type='file' id='ascFile' accept='.p8'><br><input id='ascKey' placeholder='キーの ID（10 文字）'>"
            "<input id='ascIssuer' placeholder='issuer ID（36 文字）'><br>"
            "<button onclick=\"opsKey('asc')\">App Store Connect のキーを入れる</button><div id='opsMsgAsc' class='sub'></div>"
            "</section><p class='sub'>鍵は、この PC の中だけに置きます（GitHub などには置きません）。</p>")
    return _page("LifeLog PC 鍵を入れる", body)


def feedback_page(info: dict, crash: str | None) -> str:
    """TestFlight の報告の詳しい画面（/dash/ops/feedback?id=…）"""
    from urllib.parse import quote

    kinds = {"screenshot": "スクショつきの報告", "crash": "落ちた報告"}
    battery = info.get("batteryPercentage")
    free, total = info.get("diskBytesAvailable"), info.get("diskBytesTotal")
    uptime = info.get("appUptimeInMilliseconds")
    rows = [("種類", kinds.get(info.get("kind"), info.get("kind"))), ("日時", _iso_clock(info.get("createdDate"))),
            ("build", info.get("build") or "—"), ("端末", info.get("deviceModel") or "—"),
            ("iOS", info.get("osVersion") or "—"), ("時計", info.get("pairedAppleWatch") or "—"),
            ("電池", f"{battery}%" if battery is not None else "—"),
            ("空き容量", f"{free / 1e9:.1f} / {total / 1e9:.1f} GB" if isinstance(free, (int, float)) and isinstance(total, (int, float)) else "—"),
            ("つながり", info.get("connectionType") or "—"),
            ("アプリが動いていた時間", _seconds(uptime / 1000) if isinstance(uptime, (int, float)) else "—")]
    table = "".join(f"<div>{_e(k)}</div><div>{v if k == '日時' else _e(v)}</div>" for k, v in rows)
    sid = quote(str(info.get("id") or ""), safe="")
    images = "".join(f"<p><img src='/dash/ops/feedback-file?id={sid}&amp;name={quote(str(name), safe='')}' alt='スクショ {n}' "
                     "style='max-width:100%;border:1px solid var(--line);border-radius:8px'></p>"
                     for n, name in enumerate(info.get("files") or [], 1))
    comment = _e(info.get("comment")) or "（コメントはありません）"
    body = (f"<h1>{_e(kinds.get(info.get('kind'), 'TestFlight の報告'))}</h1><p><a href='/dash'>見守りの画面に戻る</a></p>"
            f"<section><h2>コメント</h2><p style='white-space:pre-wrap'>{comment}</p></section>"
            f"<section><h2>様子</h2><div class='kv'>{table}</div></section>"
            + (f"<section><h2>スクショ</h2>{images}</section>" if images else "")
            + (f"<section><h2>落ちた記録</h2><pre class='log'>{_e(crash)}</pre></section>" if crash else ""))
    return _page("TestFlight の報告", body)


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
