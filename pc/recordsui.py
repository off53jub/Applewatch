"""LifeLog PC 版 7: 記録の画面（/dash/records の下）と、保存した音声（/dash/audio/<名前>）。

- GET  /dash/records                  日の一覧・探す欄・直しの様子・PC にある音声
- GET  /dash/records/<日>             1日の会話（時刻・見出し・要点・相手・場面、行ごとに時刻・話し手・文・印・確からしさ・再生）
- GET  /dash/records/search?q=&mode=  文字で探す（mode=text、全部の日）・意味で探す（mode=meaning、semantic.py。職場の会話も含む）
- POST /dash/records/edit             行の文を直す・行の話し手を変える（画面の中のボタンだけが付ける印 X-LifeLog-Dash が要る）
- GET  /dash/audio/<名前>             保存した音声（Range に対応）
- GET  /dash/records/review           版 9: 聞いて直す（自信の低い行で、PC に音声がある行。新しい日から）
- POST /dash/records/review           版 9: 聞いて直すの答え（文を直す・話し手を変える・合っている。文と「合っている」は材料にする）
合言葉は見守りの画面（dashboard.py）と同じ（Basic 認証・クッキー・一度だけ ?key=）。ページはキャッシュさせない。
外の部品は使わない。画面の文・名前は、すべて HTML として扱わないように書く。
"""

from __future__ import annotations

import datetime
import html
import json
import re
import time
from urllib.parse import parse_qs, quote, unquote, urlencode

import dashboard
import records

PREFIX = "/dash/records"
AUDIO_PREFIX = "/dash/audio/"
EDIT_LIMIT = 64_000
WEEK = "月火水木金土日"
UNSURE = 0.45   # iPhone の「確かめたほうがよい行」の初めの線（ConversationLog.Line.uncertainBelow）
CSP = ("default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; "
       "media-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
AUDIO_TYPES = {".m4a": "audio/mp4", ".mp4": "audio/mp4", ".aac": "audio/aac", ".wav": "audio/wav", ".mp3": "audio/mpeg",
               ".caf": "audio/x-caf", ".flac": "audio/flac", ".aif": "audio/aiff", ".aiff": "audio/aiff"}


def handles(path: str) -> bool:
    return path == PREFIX or path.startswith(PREFIX + "/") or path.startswith(AUDIO_PREFIX)


# MARK: - 書き方


def _e(value) -> str:
    return html.escape("" if value is None else str(value))


def _date(day: str) -> datetime.date:
    return datetime.date.fromisoformat(day)


def day_label(day: str) -> str:
    d = _date(day)
    return f"{d.month}/{d.day}（{WEEK[d.weekday()]}）"


def day_title(day: str) -> str:
    d = _date(day)
    return f"{d.year}年{d.month}月{d.day}日（{WEEK[d.weekday()]}）"


def clock(ms: int, seconds: bool = True) -> str:
    """この PC の時刻で "09:05:12"（seconds でなければ "09:05"）"""
    return time.strftime("%H:%M:%S" if seconds else "%H:%M", time.localtime(ms / 1000))


def stamp(when) -> str:
    return time.strftime("%m/%d %H:%M", time.localtime(float(when))) if when else "—"


def size_text(count: int) -> str:
    if count >= 1e9:
        return f"{count / 1e9:.2f} GB"
    if count >= 1e6:
        return f"{count / 1e6:.1f} MB"
    return f"{max(0, count) / 1e3:.0f} KB"


def highlight(text: str, terms: list[str]) -> str:
    """text を HTML にし、terms のところを <mark> で囲む（大文字・小文字の違いは見ない）"""
    words = sorted({t for t in terms if t}, key=len, reverse=True)
    if not words:
        return _e(text)
    pattern = re.compile("|".join(re.escape(w) for w in words), re.IGNORECASE)
    out, last = [], 0
    for match in pattern.finditer(text):
        out.append(_e(text[last:match.start()]))
        out.append(f"<mark>{_e(match.group(0))}</mark>")
        last = match.end()
    out.append(_e(text[last:]))
    return "".join(out)


STYLE = """
:root{--hi:#fff4c2;--mark:#ffe58a}
@media (prefers-color-scheme:dark){:root{--hi:#3b3520;--mark:#6b5a00}}
[hidden]{display:none!important}
main{max-width:900px}a{color:var(--btn)}
.bar{display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;font-size:14px;margin:4px 0 6px}.bar a{text-decoration:none}
.grow{flex:1 1 auto}
.search{display:flex;flex-wrap:wrap;gap:8px;margin:0}
.search input{flex:1 1 220px;min-width:0;font:inherit;padding:10px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--ink)}
.search button{margin:0}
@media (max-width:560px){.search input{flex-basis:100%}.search button{flex:1 1 0}}
.acts{margin-left:auto;display:flex;gap:6px}.nw{white-space:nowrap}
button.ghost{background:transparent;color:var(--btn);border:1px solid var(--line)}
button.small{padding:5px 10px;font-size:13px;margin:0;border-radius:8px}button:disabled{opacity:.5}
.days{list-style:none;margin:0;padding:0}.days li{border-top:1px solid var(--line)}
.days a{display:flex;flex-wrap:wrap;gap:2px 12px;align-items:baseline;padding:9px 2px;text-decoration:none;color:var(--ink)}
.days .d{font-weight:600;min-width:7em}.month{margin:12px 0 2px;color:var(--sub);font-size:13px}
.conv h2{color:var(--ink);font-size:16px;margin:0 0 4px;overflow-wrap:anywhere}
.conv h2 .when{color:var(--sub);font-size:13px;font-weight:400;margin-right:8px;white-space:nowrap}
.chips{display:flex;flex-wrap:wrap;gap:4px 6px;margin:4px 0}
.chip{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:1px 8px;color:var(--sub);overflow-wrap:anywhere}
.points{margin:4px 0 6px;padding-left:1.3em}h3{font-size:14px;margin:8px 0 2px}
details>summary{cursor:pointer;color:var(--sub);font-size:13px;padding:4px 0}
.line{padding:8px 4px;border-top:1px solid var(--line);scroll-margin-top:8px}
.line:target{background:var(--hi);border-radius:8px}
.line .head{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;font-size:13px;color:var(--sub)}
.line .time{color:var(--sub);text-decoration:none;font-variant-numeric:tabular-nums}
.line .who{color:var(--ink);font-weight:600}.line .star{color:var(--warn)}
.line .text{margin:3px 0 0;overflow-wrap:anywhere;white-space:pre-wrap}
.line.media .text{color:var(--sub);font-style:italic}
.edits div{font-size:13px;margin-top:3px;overflow-wrap:anywhere}
.editor{margin-top:6px;display:grid;gap:6px}
.editor textarea{width:100%;font:inherit;padding:8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);resize:vertical}
.editor select{font:inherit;padding:6px 8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);max-width:100%;min-width:0}
.editor .row{display:flex;flex-wrap:wrap;gap:6px;align-items:center}.editor p{margin:0}
.player{position:sticky;bottom:0;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:8px 10px;display:flex;flex-wrap:wrap;gap:6px 10px;align-items:center;margin-top:8px}
.player audio{flex:1 1 240px;min-width:0;width:100%}
mark{background:var(--mark);color:inherit;border-radius:3px}
.hit{padding:8px 2px;border-top:1px solid var(--line)}.hit .text{overflow-wrap:anywhere}
.hit .ctx{color:var(--sub);font-size:13px;overflow-wrap:anywhere}.hit .head{font-size:13px;color:var(--sub)}
.rv{border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin:10px 0;background:var(--card)}
.rv.now{border-color:var(--btn);box-shadow:0 0 0 2px var(--btn) inset}.rv.done{opacity:.55}
.rv .ctx{color:var(--sub);font-size:13px;overflow-wrap:anywhere;margin:2px 0}
.rv .say{font-size:17px;margin:4px 0;overflow-wrap:anywhere}.rv .who{font-weight:600}
.rv textarea{width:100%;font:inherit;padding:8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);resize:vertical}
.rv select{font:inherit;padding:6px 8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);max-width:100%;min-width:0}
.rv .row{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:6px}.rv .votes{font-size:13px;color:var(--sub)}
"""

SCRIPT = """
const $=(s,el=document)=>el.querySelector(s);
const audio=$('#audio'),player=$('#player');let stopAt=null;
function play(btn){
  const base='/dash/audio/'+encodeURIComponent(btn.dataset.audio);
  const start=parseFloat(btn.dataset.start||'0')||0,stop=parseFloat(btn.dataset.stop||'0')||0;
  stopAt=stop>start?stop:null;player.hidden=false;$('#playing').textContent=btn.dataset.label||'';
  if(audio.dataset.base!==base){
    audio.dataset.base=base;audio.src=base+'#t='+start.toFixed(2);
    audio.addEventListener('loadedmetadata',()=>{if(Math.abs(audio.currentTime-start)>0.5)audio.currentTime=start;},{once:true});
  }else{audio.currentTime=start;}
  const p=audio.play();if(p&&p.catch)p.catch(()=>{});
}
if(audio)audio.addEventListener('timeupdate',()=>{if(stopAt!==null&&audio.currentTime>=stopAt){audio.pause();stopAt=null;}});
function editor(line){
  let ed=$('.editor',line);if(ed){ed.hidden=!ed.hidden;return;}
  ed=$('#editor-template').content.firstElementChild.cloneNode(true);
  $('textarea',ed).value=line.dataset.expect!==undefined?line.dataset.expect:$('.text',line).textContent;
  const current=line.dataset.expectSpeaker!==undefined?line.dataset.expectSpeaker:(line.dataset.speaker||'');
  const sel=$('select',ed);let picked=false;
  for(const o of $('#speakers').content.querySelectorAll('option')){const c=o.cloneNode(true);if(c.value===current){c.selected=true;picked=true;}sel.appendChild(c);}
  if(!picked){const o=document.createElement('option');o.value='';o.textContent='（選んでください）';o.selected=true;sel.prepend(o);}
  line.appendChild(ed);$('textarea',ed).focus();
}
async function send(btn,kind){
  const line=btn.closest('.line'),ed=btn.closest('.editor'),msg=$('.msg',ed);
  const body={day:document.body.dataset.day,time:Number(line.dataset.time),kind:kind};
  if(kind==='text')body.text=$('textarea',ed).value;else body.speaker=$('select',ed).value;
  if(kind==='speaker'&&!body.speaker){msg.textContent='話し手を選んでください';return;}
  msg.textContent='送っています…';btn.disabled=true;
  try{
    const r=await fetch('/dash/records/edit',{method:'POST',credentials:'same-origin',
      headers:{'X-LifeLog-Dash':'1','Content-Type':'application/json'},body:JSON.stringify(body)});
    const j=await r.json().catch(()=>({}));
    msg.textContent=j.message||j.error||('答え '+r.status);
    if(r.ok){if(typeof j.html==='string')$('.edits',line).innerHTML=j.html;
      if(j.expect){line.dataset.expect=j.expect.text;line.dataset.expectSpeaker=j.expect.speaker||'';}}
  }catch(e){msg.textContent='送れませんでした: '+e;}
  btn.disabled=false;
}
document.addEventListener('click',(ev)=>{
  const btn=ev.target.closest('[data-act]');if(!btn)return;const act=btn.dataset.act;
  if(act==='play')play(btn);else if(act==='edit')editor(btn.closest('.line'));
  else if(act==='cancel')btn.closest('.editor').hidden=true;
  else if(act==='text'||act==='speaker')send(btn,act);
  else if(act==='close'){audio.pause();player.hidden=true;}
});
"""


REVIEW_SCRIPT = """
function cards(){return Array.from(document.querySelectorAll('.rv'));}
function focusCard(card,autoplay){
  for(const c of cards())c.classList.toggle('now',c===card);
  if(!card){const end=document.getElementById('rv-end');if(end){end.hidden=false;end.scrollIntoView({block:'center'});}return;}
  card.scrollIntoView({block:'center',behavior:'smooth'});
  if(autoplay){const b=card.querySelector('[data-act=play]');if(b)play(b);}
}
function nextCard(card){
  const all=cards();const i=all.indexOf(card);
  for(const c of all.slice(i+1))if(!c.classList.contains('done'))return c;
  for(const c of all)if(!c.classList.contains('done'))return c;
  return null;
}
async function answer(btn,kind){
  const card=btn.closest('.rv'),msg=card.querySelector('.msg');
  const body={day:card.dataset.day,time:Number(card.dataset.time),kind:kind};
  if(kind==='text')body.text=card.querySelector('textarea').value;
  if(kind==='speaker'){body.speaker=card.querySelector('select').value;if(!body.speaker){msg.textContent='話し手を選んでください';return;}}
  msg.textContent='送っています…';for(const b of card.querySelectorAll('button'))b.disabled=true;
  let moved=false;
  try{
    const r=await fetch('/dash/records/review',{method:'POST',credentials:'same-origin',
      headers:{'X-LifeLog-Dash':'1','Content-Type':'application/json'},body:JSON.stringify(body)});
    const j=await r.json().catch(()=>({}));
    msg.textContent=(j.message||j.error||('答え '+r.status))+(j.sample_text?' '+j.sample_text:'');
    if(r.ok&&typeof j.count==='number'){const n=document.getElementById('rv-count');if(n)n.textContent=j.count;}
    if(r.ok&&j.done){card.classList.add('done');const left=document.getElementById('rv-left');
      if(left)left.textContent=Math.max(0,Number(left.textContent)-1);focusCard(nextCard(card),true);moved=true;}
    else if(r.ok&&j.expect){const sel=card.querySelector('select');if(sel)sel.value=j.expect.speaker||'';
      const who=card.querySelector('.say .who');if(who)who.textContent=j.expect.speaker||'（話し手なし）';}
  }catch(e){msg.textContent='送れませんでした: '+e;}
  if(!moved||!card.classList.contains('done'))for(const b of card.querySelectorAll('button'))b.disabled=false;
}
document.addEventListener('click',(ev)=>{
  const btn=ev.target.closest('[data-rv]');if(!btn)return;const act=btn.dataset.rv;
  if(act==='skip'){const card=btn.closest('.rv');focusCard(nextCard(card),true);}
  else answer(btn,act);
});
document.addEventListener('focusin',(ev)=>{const card=ev.target.closest&&ev.target.closest('.rv');
  if(card&&!card.classList.contains('now'))for(const c of cards())c.classList.toggle('now',c===card);});
window.addEventListener('load',()=>{const first=cards()[0];if(first)first.classList.add('now');});
"""


def page(title: str, body: str, day: str = "", script: str = "") -> str:
    return ("<!doctype html><html lang='ja'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<meta name='color-scheme' content='light dark'><meta name='referrer' content='no-referrer'>"
            f"<title>{_e(title)}</title><style>{dashboard.STYLE}{STYLE}</style></head>"
            f"<body data-day='{_e(day)}'><main>{body}</main><script>{SCRIPT}{script}</script></body></html>")


def search_form(query: str = "", mode: str = "text") -> str:
    first, second = ("", " class='ghost'") if mode != "meaning" else (" class='ghost'", "")
    return ("<form class='search' method='get' action='/dash/records/search' role='search'>"
            f"<input type='search' name='q' value='{_e(query)}' placeholder='探す言葉（空白で区切ると全部を含む行）' "
            "aria-label='探す言葉' required>"
            f"<button name='mode' value='text'{first}>文字で探す</button>"
            f"<button name='mode' value='meaning'{second}>意味で探す</button></form>")


# MARK: - 直しの様子


def edit_what(edit: dict) -> str:
    if edit["kind"] == "text":
        return f"文を「{_e(edit['text'])}」に"
    return f"話し手を「{_e(edit['speaker'])}」に"


def edit_state(edit: dict) -> tuple[str, str]:
    """(css, 様子の文)"""
    if edit["status"] == "pending":
        return "warn", "iPhone に送る前" + ("（iPhone が受け取り、直すのを待っています）" if edit.get("sent") else "")
    if edit["status"] == "applied":
        return "ok", "iPhone で直しました"
    if edit["status"] == "superseded":
        return "sub", "あとの直しに置き換えました"
    reason = f"（{_e(edit['reason'])}）" if edit.get("reason") else ""
    return "ng", "iPhone で直せませんでした" + reason


def edit_chips(edits: list[dict]) -> str:
    """行の下に出す直しの様子（文・話し手それぞれ、いちばん新しいもの）"""
    latest: dict[str, dict] = {}
    for edit in edits:
        if edit["status"] != "superseded":
            latest[edit["kind"]] = edit
    parts = []
    for kind in ("text", "speaker"):
        edit = latest.get(kind)
        if edit is not None:
            css, state = edit_state(edit)
            parts.append(f"<div class='{css}'>{edit_what(edit)}: {state}</div>")
    return "".join(parts)


# MARK: - 日の一覧


def render_index(store: records.RecordStore, index) -> str:
    days = store.days()
    pending = store.edits.pending_days()
    counts = store.edits.counts()
    parts = ["<nav class='bar'><a href='/dash'>← 見守りの画面</a><span class='grow'></span>"
             f"<a href='{PREFIX}/review'>聞いて直す →</a></nav><h1>記録</h1>",
             f"<section>{search_form()}<p class='sub'>意味で探す: 言葉が同じでなくても意味の近い行を探します"
             f"（この PC の Ollama の bge-m3。職場の会話も含みます。{_e(semantic_state(index))}）</p></section>"]
    # 直しの様子
    failed = counts.get("skipped", 0) + counts.get("failed", 0)
    rows = []
    for edit in store.edits.recent(20):
        css, state = edit_state(edit)
        rows.append(f"<tr><td><a href='{PREFIX}/{_e(edit['day'])}#t{edit['time']}'><span class='nw'>"
                    f"{_e(day_label(edit['day']))}</span> <span class='nw'>{_e(clock(edit['time']))}</span></a></td>"
                    f"<td>{edit_what(edit)}</td><td class='{css}'>{state}</td></tr>")
    table = ("<div class='scroll'><table><tr><th>行</th><th>直し</th><th>様子</th></tr>" + "".join(rows) + "</table></div>") \
        if rows else "<p class='sub'>まだ直していません。日を開いて、行の「直す」から直せます。</p>"
    parts.append(f"<section><h2>直しの様子（iPhone に送る前 {counts.get('pending', 0)}・iPhone で直しました "
                 f"{counts.get('applied', 0)}・iPhone で直せませんでした {failed}）</h2>{table}</section>")
    # 日の一覧
    if days:
        items, month = [], None
        for summary in days:
            day = summary["day"]
            if day[:7] != month:
                if month is not None:
                    items.append("</ul>")
                month = day[:7]
                items.append(f"<p class='month'>{int(day[:4])}年{int(day[5:7])}月</p><ul class='days'>")
            note = f"<span class='warn'>直し {pending[day]} 件（送る前）</span>" if pending.get(day) else ""
            work = summary.get("work")
            work_note = "<span class='sub'>職場の印が届いていません</span>" if work is None and "work" in summary \
                else (f"<span class='sub'>職場 {work}</span>" if work else "")
            items.append(f"<li><a href='{PREFIX}/{_e(day)}'><span class='d'>{_e(day_label(day))}</span>"
                         f"<span class='sub'>会話 {summary['conversations']}・行 {summary['lines']}</span>{note}{work_note}"
                         f"<span class='sub'>受け取り {_e(stamp(summary.get('received')))}</span></a></li>")
        items.append("</ul>")
        listing = "".join(items)
    else:
        listing = ("<p>まだ記録が届いていません。新しい iPhone のアプリが、PC とつながったときに送ってきます"
                   "（初めは 60 日分を、少しずつ）。</p>")
    parts.append(f"<section><h2>日の一覧（{len(days)} 日）</h2>{listing}</section>")
    audio = store.audio_stats()
    keep = "残しません（config.json の \"audio_keep_days\" が 0）" if audio["keep_days"] <= 0 else \
        f"{audio['keep_days']:g} 日・合計 {audio['keep_gb']:g} GB を超えた古いものから消します"
    parts.append(f"<section><h2>PC にある音声</h2><p>{audio['count']} 個・{size_text(audio['bytes'])}（{keep}）</p>"
                 "<p class='sub'>iPhone が「後で受け取る文字起こし」を受け取って消したときに、音声だけ残します。"
                 "それより前の録音や、PC を通らなかった録音の音声は PC にありません。</p></section>")
    return page("記録 — LifeLog PC", "".join(parts))


def semantic_state(index) -> str:
    if index is None or not getattr(index, "enabled", False):
        return "今は使わない設定です"
    if getattr(index, "pulling", False):
        return "モデルを取ってきてもらっている最中です"
    try:
        ready = index.available()
    except Exception:  # noqa: BLE001
        ready = False
    return "使えます" if ready else "今は使えません（Ollama が動いていないか、bge-m3 がありません）"


# MARK: - 1日の会話


def stop_time(lines: list[dict], i: int, start: float) -> float:
    """再生を止める位置（行の終わり。分からなければ、同じ音声の次の行の頭か、20 秒後）"""
    line = lines[i]
    if line.get("end") and line["end"] > start:
        return line["end"] + 0.3
    for other in lines[i + 1:]:
        if other.get("audio") == line.get("audio") and other.get("offset") is not None and other["offset"] > start:
            return min(other["offset"], start + 60)
    return start + 20


def render_day(store: records.RecordStore, day: str) -> str | None:
    parsed = store.day(day)
    if parsed is None:
        return None
    listing = store.days()
    days = [s["day"] for s in listing]
    i = days.index(day) if day in days else -1
    older = days[i + 1] if 0 <= i < len(days) - 1 else None
    newer = days[i - 1] if i > 0 else None
    nav = (f"<nav class='bar'><a href='{PREFIX}'>← 記録の一覧</a><span class='grow'></span>"
           + (f"<a href='{PREFIX}/{older}'>前の日 {_e(day_label(older))}</a>" if older else "")
           + (f"<a href='{PREFIX}/{newer}'>次の日 {_e(day_label(newer))}</a>" if newer else "") + "</nav>")
    edits = records.expected_lines(store.edits.for_day(day))
    available = store.audio_names()
    names = parsed["audio_names"]
    summary = listing[i] if i >= 0 else {}
    parts = [nav, f"<h1>{_e(day_title(day))}</h1>",
             f"<p class='sub'>会話 {len(parsed['conversations'])}・行 {parsed['lines']}・受け取り "
             f"{_e(stamp(summary.get('received')))}。行の右の数は聞き取りの確からしさ（0〜1）です。"
             f"{UNSURE} より低い行は「不確か」と出します。★ は時計やアプリで付けた印です。"
             + ("職場の会話の印は、この日はまだ届いていません（古い iPhone から来た日。職場かどうか分からない会話として扱います）。"
                if parsed.get("work") is None else "")
             + "</p>",
             f"<section>{search_form()}</section>"]
    day_summary = parsed.get("summary")
    if day_summary and any(day_summary.get(k) for k in ("flow", "decisions", "todos", "topics")):
        blocks = []
        for key, label in (("flow", "1日の流れ"), ("decisions", "決まったこと"), ("todos", "やること"), ("topics", "話題")):
            items = day_summary.get(key) or []
            if items:
                blocks.append(f"<h3>{label}</h3><ul class='points'>" + "".join(f"<li>{_e(x)}</li>" for x in items) + "</ul>")
        parts.append(f"<section><details open><summary>1日のまとめ</summary>{''.join(blocks)}</details></section>")
    if not parsed["conversations"]:
        parts.append("<section><p>この日の会話はありません。</p></section>")
    received = store.received_ms(day)
    for c in parsed["conversations"]:
        parts.append(render_conversation(c, edits, available, names, received))
    # 話し手に選べる名前（「自分」と、記録に出てくる名前だけ）と、直す欄のひな形
    options = "".join(f"<option value='{_e(s['name'])}'>{_e(s['name'])}</option>" for s in store.speakers())
    parts.append(f"<template id='speakers'>{options}</template>")
    parts.append("<template id='editor-template'><div class='editor'>"
                 f"<textarea rows='3' maxlength='{records.TEXT_MAX}' aria-label='直した文'></textarea>"
                 "<div class='row'><button class='small' data-act='text'>文を直す</button></div>"
                 "<div class='row'><select aria-label='話し手'></select>"
                 "<button class='small' data-act='speaker'>話し手を変える</button></div>"
                 "<div class='row'><button class='small ghost' data-act='cancel'>やめる</button>"
                 "<span class='msg sub' role='status'></span></div>"
                 "<p class='sub'>直した分は、iPhone が次に PC につながったときに渡します（iPhone の記録が先に変わっていたら、"
                 "iPhone は直さずに知らせてきます）。話し手は、記録に出てくる名前と「自分」から選びます。</p>"
                 "</div></template>")
    parts.append("<div id='player' class='player' hidden><span id='playing' class='sub'></span>"
                 "<audio id='audio' controls preload='none'></audio>"
                 "<button class='small ghost' data-act='close'>閉じる</button></div>")
    return page(f"{day_title(day)} — LifeLog PC", "".join(parts), day)


def render_conversation(c: dict, edits: dict[int, list[dict]], available: set[str], names: dict[str, str],
                        received: int | None = None) -> str:
    title = c.get("title") or ("（テレビ・動画など）" if c.get("media") else "（見出しなし）")
    chips = []
    # 版 9: 職場の会話の印（印の無い日は「分からない」）
    if c.get("work") is True:
        chips.append("職場")
    elif c.get("work") is None and not c.get("media"):
        chips.append("職場かどうか分からない")
    who = records.people(c)
    if who:
        chips.append("相手 " + "・".join(_e(n) for n in who))
    for key, label in (("place", "場所"), ("scene", "場面"), ("event", "予定"), ("movement", "移動")):
        if c.get(key):
            chips.append(f"{label} {_e(c[key])}")
    if c.get("media"):
        chips.append(_e(c["media"]) + (f"「{_e(c['program'])}」" if c.get("program") else ""))
    if c.get("heartRate"):
        chips.append(f"心拍 {c['heartRate']}" + (f"（最大 {c['heartRateMax']}）" if c.get("heartRateMax") else "")
                     + ("・いつもより高め" if c.get("tense") else ""))
    if c.get("minutes"):
        chips.append("議事録 " + _e(c["minutes"]))
    chip_html = "<div class='chips'>" + "".join(f"<span class='chip'>{x}</span>" for x in chips) + "</div>" if chips else ""
    points = "<ul class='points'>" + "".join(f"<li>{_e(p)}</li>" for p in c["points"]) + "</ul>" if c.get("points") else ""
    lines = c["lines"]
    jobs = [names.get(line["audio"], line["audio"]) if line.get("audio") else None for line in lines]
    playable = [bool(job) and job in available and records.safe_audio_name(job) for job in jobs]
    with_audio = any(jobs)
    none_here = with_audio and not any(playable)
    rows = []
    for i, line in enumerate(lines):
        rows.append(render_line(line, edits.get(line["time"], []), jobs[i] if playable[i] else None,
                                bool(jobs[i]) and not playable[i] and not none_here, lines, i, received))
    missing = "<p class='sub'>PC に音声がありません</p>" if none_here else ""
    return (f"<section class='conv' id='c{c['start']}'><h2><span class='when'>{_e(clock(c['start'], False))}〜"
            f"{_e(clock(c['end'], False))}</span>{_e(title)}</h2>{chip_html}{points}{missing}"
            f"<details open><summary>行 {len(lines)}</summary>{''.join(rows)}</details></section>")


def render_line(line: dict, edits: list[dict], job: str | None, missing: bool, lines: list[dict], i: int,
                received: int | None = None) -> str:
    ms = line["time"]
    speaker = line.get("speaker")
    head = [f"<a class='time' href='#t{ms}'>{_e(clock(ms))}</a>",
            f"<span class='who'>{_e(speaker) if speaker else '（話し手なし）'}</span>"]
    if line.get("marked"):
        head.append("<span class='star' title='印'>★</span>")
    if line.get("speakerDoubt") and line.get("speakerDoubt") != line.get("speakerID"):
        head.append("<span class='warn' title='2つの声のモデルで話し手が食い違いました'>？</span>")
    if line.get("media"):
        head.append(f"<span class='chip'>{_e(line['media'])}</span>")
    if line.get("checked"):
        head.append("<span class='chip'>手で直した行</span>")
    elif line.get("confidence") is not None:
        value = line["confidence"]
        head.append(f"<span class='warn'>不確か {value:.2f}</span>" if value < UNSURE else f"<span>{value:.2f}</span>")
    acts = []
    if job:
        start = max(0.0, float(line.get("offset") or 0.0))
        acts.append(f"<button class='small ghost' data-act='play' data-audio='{_e(job)}' data-start='{start:.2f}' "
                    f"data-stop='{stop_time(lines, i, start):.2f}' data-label='{_e(clock(ms))} {_e(speaker or '')}'>"
                    "▶ 再生</button>")
    elif missing:
        head.append("<span>PC に音声がありません</span>")
    acts.append("<button class='small ghost' data-act='edit'>直す</button>")
    head.append(f"<span class='acts'>{''.join(acts)}</span>")
    attrs = ""
    if edits:
        state = records.expected_state(line, edits, received)
        if state["text"] != line["text"] or state["speaker"] != speaker:
            attrs = f" data-expect='{_e(state['text'])}' data-expect-speaker='{_e(state['speaker'] or '')}'"
    css = "line media" if line.get("media") else "line"
    return (f"<div class='{css}' id='t{ms}' data-time='{ms}' data-speaker='{_e(speaker or '')}'{attrs}>"
            f"<div class='head'>{''.join(head)}</div><div class='text'>{_e(line['text'])}</div>"
            f"<div class='edits'>{edit_chips(edits)}</div></div>")


# MARK: - 版 9: 聞いて直す

REASONS = {"low": "確からしさが低い", "votes": "モデルの票が食い違う", "speaker": "話し手に「？」"}


def render_review(store: records.RecordStore, personal: dict | None = None) -> str:
    items, total = store.review_queue()
    personal = personal or {}
    count = int(personal.get("count") or 0)
    need = int(personal.get("need") or 300)
    parts = [f"<nav class='bar'><a href='{PREFIX}'>← 記録の一覧</a><span class='grow'></span><a href='/dash'>見守りの画面</a></nav>",
             "<h1>聞いて直す</h1>",
             "<section><p>自信の低い行（確からしさが低い・モデルの票が食い違う・話し手に「？」）で、PC に音声がある行を、"
             "新しい日から並べています。▶ で聞いて、違っていれば直し、そのままで正しければ「合っている」を押してください。"
             "答えると次の行へ進み、自動で流します。</p>"
             f"<p>残り <b id='rv-left'>{total}</b> 行・学び直しの材料 <b id='rv-count'>{count}</b> 個"
             f"（{need} 個で学び直せます）</p>"
             "<p class='sub'>文を直した行と「合っている」行は、PC にある音声からその所を切り出して、学び直しの材料に足します"
             "（PC の中だけ）。文と話し手の直しは、ほかの直しと同じく iPhone に渡します。「合っている」は iPhone には送りません。"
             "話し手は、記録に出てくる名前と「自分」から選びます。</p></section>"]
    if not items:
        parts.append("<section><p>今は聞いて直す行がありません。iPhone が「後で受け取る文字起こし」を受け取ると、"
                     "その音声が PC に残り、ここに並びます。</p></section>")
    options = "".join(f"<option value='{_e(s['name'])}'>{_e(s['name'])}</option>" for s in store.speakers())
    edits_by_day: dict[str, dict[int, list[dict]]] = {}
    for item in items:
        day, line, c = item["day"], item["line"], item["conversation"]
        if day not in edits_by_day:
            edits_by_day[day] = records.expected_lines(store.edits.for_day(day))
        state = records.expected_state(line, edits_by_day[day].get(line["time"], []), store.received_ms(day))
        start = max(0.0, float(line.get("offset") or 0.0))
        lines = c["lines"]
        stop = stop_time(lines, item["index"], start)
        chips = "".join(f"<span class='chip'>{_e(REASONS.get(r, r))}</span>" for r in item["reasons"])
        if line.get("confidence") is not None:
            chips += f"<span class='chip'>確からしさ {line['confidence']:.2f}</span>"
        votes = ""
        if "votes" in item["reasons"]:
            votes = "<div class='votes'>票: " + " ／ ".join(
                f"{_e(k)}「{_e(v)}」" for k, v in sorted((line.get("votes") or {}).items())) + "</div>"
        before = f"<div class='ctx'>前: {_e(item['before'].get('speaker') or '')} {_e(item['before']['text'])}</div>" \
            if item.get("before") else ""
        after = f"<div class='ctx'>後: {_e(item['after'].get('speaker') or '')} {_e(item['after']['text'])}</div>" \
            if item.get("after") else ""
        current = state.get("speaker") or ""
        select = (f"<select aria-label='話し手'><option value=''>（選んでください）</option>"
                  + options.replace(f"<option value='{_e(current)}'>", f"<option value='{_e(current)}' selected>", 1)
                  + "</select>") if current else \
            f"<select aria-label='話し手'><option value='' selected>（選んでください）</option>{options}</select>"
        title = c.get("title") or "（見出しなし）"
        parts.append(
            f"<div class='rv' data-day='{_e(day)}' data-time='{line['time']}' tabindex='-1'>"
            f"<div class='head sub'><a href='{PREFIX}/{_e(day)}#t{line['time']}'>{_e(day_label(day))} {_e(clock(line['time']))}</a>"
            f" ・{_e(title)}</div><div class='chips'>{chips}</div>{before}"
            f"<div class='say'><span class='who'>{_e(state.get('speaker') or '（話し手なし）')}</span> {_e(state['text'])}</div>"
            f"{after}{votes}"
            f"<div class='row'><button class='small' data-act='play' data-audio='{_e(item['job'])}' data-start='{start:.2f}' "
            f"data-stop='{stop:.2f}' data-label='{_e(clock(line['time']))}'>▶ 聞く</button></div>"
            f"<textarea rows='2' maxlength='{records.TEXT_MAX}' aria-label='正しい文'>{_e(state['text'])}</textarea>"
            "<div class='row'><button class='small' data-rv='text'>文を直す</button>"
            "<button class='small' data-rv='ok'>合っている</button>"
            "<button class='small ghost' data-rv='skip'>飛ばす</button></div>"
            f"<div class='row'>{select}<button class='small ghost' data-rv='speaker'>話し手を変える</button></div>"
            "<div class='msg sub' role='status'></div></div>")
    if total > len(items):
        parts.append(f"<p class='sub'>ほかに {total - len(items)} 行あります。ここまで答えたら、画面を開き直すと続きが出ます。</p>")
    parts.append("<section id='rv-end' hidden><p>ここに出した行は、全部答えました。画面を開き直すと続きが出ます。</p></section>")
    parts.append("<div id='player' class='player' hidden><span id='playing' class='sub'></span>"
                 "<audio id='audio' controls preload='none'></audio>"
                 "<button class='small ghost' data-act='close'>閉じる</button></div>")
    return page("聞いて直す — LifeLog PC", "".join(parts), script=REVIEW_SCRIPT)


def post_review(handler, store: records.RecordStore, log, personal=None) -> None:
    """POST /dash/records/review {"day", "time", "kind": "text"|"speaker"|"ok", "text"|"speaker"}"""
    if handler.headers.get(dashboard.HEADER) != "1":
        handler.discard_body()
        dashboard.send_json(handler, 403, {"error": "この画面のボタンから押してください"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > EDIT_LIMIT:
        handler.discard_body()
        dashboard.send_json(handler, 400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    try:
        body = json.loads(data.decode("utf-8"))
        if not isinstance(body, dict):
            raise ValueError("中身が JSON のまとまりではありません")
        kind = body.get("kind")
        day = body.get("day")
        moment = body.get("time")
        value = body.get("text") if kind == "text" else body.get("speaker") if kind == "speaker" else None
        result = store.review(day, moment, kind, value)
    except (UnicodeDecodeError, ValueError) as error:
        message = str(error) if not isinstance(error, json.JSONDecodeError) else "中身が JSON ではありません"
        dashboard.send_json(handler, 400, {"error": message})
        return
    sample = result.get("sample")
    if sample is None:
        sample_text = ""
    elif sample.get("added"):
        sample_text = f"材料に足しました（全部で {sample.get('count')} 個）。"
    else:
        sample_text = f"材料には足しませんでした（{sample.get('reason')}）。"
    # 文・名前は記録に書かない（日・種類・材料の数だけ）
    what = {"text": "文を直しました", "speaker": "話し手を変えました", "ok": "合っている"}[kind]
    log(f"聞いて直す: {day} の行（{what}）" + (f"・材料 {'足した' if sample.get('added') else '足さない'}" if sample else ""))
    # 文を直した・合っている → 次の行へ。話し手だけ変えたときは、文が合っているかをまだ答えていないので、その行にとどまる
    still = False
    if kind == "speaker":
        line, _, _ = store.find_line(day, moment)
        still = line is not None and any(r != "speaker" for r in records.doubt_reasons(line, records.REVIEW_UNSURE))
    state = result["state"]
    reply = {"ok": True, "message": result["message"], "sample": sample, "sample_text": sample_text, "done": not still,
             "expect": {"text": state["text"], "speaker": state["speaker"]}}
    if sample and isinstance(sample.get("count"), int):
        reply["count"] = sample["count"]
    if kind == "speaker" and still:
        reply["message"] += "。文も合っていれば「合っている」を、違えば直して「文を直す」を押してください"
    dashboard.send_json(handler, 200, reply)


# MARK: - 探す


def render_search(store: records.RecordStore, query: str, mode: str, index, log) -> str:
    query = (query or "").strip()[:200]
    mode = "meaning" if mode == "meaning" else "text"
    parts = [f"<nav class='bar'><a href='{PREFIX}'>← 記録の一覧</a></nav>",
             f"<h1>{'意味で' if mode == 'meaning' else '文字で'}探す</h1>", f"<section>{search_form(query, mode)}</section>"]
    if not query:
        parts.append("<section><p>探す言葉を入れてください。</p></section>")
    elif mode == "text":
        started = time.time()
        hits, more = store.search_text(query)
        terms = query.split()
        rows = []
        for hit in hits:
            rows.append(f"<div class='hit'><div class='head'><a href='{PREFIX}/{_e(hit['day'])}#t{hit['time']}'>"
                        f"{_e(day_label(hit['day']))} {_e(clock(hit['time']))}</a> "
                        f"<b>{_e(hit['speaker'] or '（話し手なし）')}</b>"
                        + (f" ・{_e(hit['title'])}" if hit.get("title") else "")
                        + f"</div><div class='text'>{highlight(hit['text'], terms)}</div></div>")
        note = "（多いので、新しい日から最初の 300 件だけ出しています）" if more else ""
        parts.append(f"<section><h2>{len(hits)} 件{note}</h2>{''.join(rows) or '<p>見つかりませんでした。</p>'}"
                     f"<p class='sub'>{time.time() - started:.2f} 秒</p></section>")
        # 探した言葉は記録に書かない
        log(f"記録の画面で文字で探しました: {len(hits)} 件")
    else:
        parts.append(render_meaning(store, query, index, log))
    return page("探す — LifeLog PC", "".join(parts))


def render_meaning(store: records.RecordStore, query: str, index, log) -> str:
    state = semantic_state(index)
    if state != "使えます":
        return f"<section><p>意味で探す機能は{_e(state)}。文字で探すを使ってください。</p></section>"
    import semantic

    started = time.time()
    try:
        request = semantic.parse_search(json.dumps({"query": query, "k": 30, "include_work": True},
                                                   ensure_ascii=False).encode("utf-8"))
        hits = index.search(request)
    except Exception as error:  # noqa: BLE001 — 探せなくても画面は出す
        log(f"記録の画面で意味で探せませんでした: {error!r}")
        return f"<section><p class='ng'>意味で探せませんでした: {_e(error)}</p></section>"
    rows = []
    for hit in hits:
        day = hit.get("day") or ""
        ms = int(round(float(hit.get("time") or 0) * 1000))
        line = None
        if records.valid_day(day):
            for delta in (0, -1, 1):
                line, _, _ = store.find_line(day, ms + delta)
                if line is not None:
                    ms += delta
                    break
        text = line["text"] if line is not None else hit.get("text") or ""
        speaker = (line.get("speaker") if line is not None else hit.get("speaker")) or "（話し手なし）"
        when = f"{_e(day_label(day))} {_e(clock(ms))}" if records.valid_day(day) else _e(day)
        link = f"<a href='{PREFIX}/{_e(day)}#t{ms}'>{when}</a>" if line is not None else \
            f"{when} <span class='sub'>（PC に記録がありません）</span>"
        before, after = [], []
        for item in hit.get("context") or []:
            if item.get("offset") in (-1, 1):
                (before if item["offset"] < 0 else after).append(
                    f"<div class='ctx'>{'前' if item['offset'] < 0 else '後'}: "
                    f"{_e(item.get('speaker') or '')} {_e(item.get('text'))}</div>")
        rows.append(f"<div class='hit'><div class='head'>{link} <b>{_e(speaker)}</b> ・近さ {float(hit.get('score') or 0):.2f}"
                    + (" ・職場" if hit.get("work") else "") + f"</div>{''.join(before)}<div class='text'>{_e(text)}</div>"
                    f"{''.join(after)}</div>")
    log(f"記録の画面で意味で探しました: {len(hits)} 件（{time.time() - started:.1f} 秒）")
    return (f"<section><h2>近い順に {len(hits)} 件</h2>{''.join(rows) or '<p>見つかりませんでした。</p>'}"
            f"<p class='sub'>{time.time() - started:.1f} 秒。索引は iPhone が送った行です（直した文が届くまでは前の文で探します）。</p>"
            "</section>")


# MARK: - 音声


def parse_range(header: str | None, size: int):
    """Range: bytes=… の1つの範囲。(始まり, 終わり) か、返せない範囲なら "bad"、無い・分からなければ None（全部を返す）"""
    if not header:
        return None
    match = re.fullmatch(r"\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*", header)
    if not match or (match.group(1) == "" and match.group(2) == ""):
        return None
    if size <= 0:
        return "bad"
    first, last = match.groups()
    if first == "":
        count = int(last)
        if count <= 0:
            return "bad"
        return max(0, size - count), size - 1
    start = int(first)
    end = min(int(last), size - 1) if last else size - 1
    if start >= size or start > end:
        return "bad"
    return start, end


def send_audio(handler, path) -> None:
    size = path.stat().st_size
    kind = AUDIO_TYPES.get(path.suffix.lower(), "application/octet-stream")
    span = parse_range(handler.headers.get("Range"), size)
    base = {"Accept-Ranges": "bytes", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer"}
    if span == "bad":
        handler.send_response(416)
        for name, value in {**base, "Content-Range": f"bytes */{size}", "Content-Length": "0"}.items():
            handler.send_header(name, value)
        handler.end_headers()
        return
    start, end = span if span else (0, size - 1)
    length = max(0, end - start + 1)
    handler.send_response(206 if span else 200)
    headers = {**base, "Content-Type": kind, "Content-Length": str(length)}
    if span:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    for name, value in headers.items():
        handler.send_header(name, value)
    handler.end_headers()
    try:
        with path.open("rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(left, 256 * 1024))
                if not chunk:
                    break
                handler.wfile.write(chunk)
                left -= len(chunk)
    except (ConnectionError, OSError):
        # ブラウザは再生の途中で読むのをやめることがよくある
        handler.close_connection = True


# MARK: - 受け付け（lifelog_pc.py の Handler から呼ぶ）


def _send_page(handler, status: int, body: str) -> None:
    dashboard.send(handler, status, body, extra={"Content-Security-Policy": CSP})


def _not_found(handler, text: str) -> None:
    _send_page(handler, 404, page("見つかりません — LifeLog PC",
                                  f"<nav class='bar'><a href='{PREFIX}'>← 記録の一覧</a></nav><section><p>{_e(text)}</p></section>"))


def http(handler, url, method: str, store: records.RecordStore | None, index, log, personal=None) -> None:
    """記録の画面・音声・直すボタン。合言葉は見守りの画面と同じ。
    版 9: personal は材料の数を返す関数（{"count", "need"}。聞いて直すの画面に出す）"""
    ok, set_cookie = dashboard.check(handler.headers, url.query, handler.key)
    if not ok:
        if handler.headers.get("Authorization") or "key=" in url.query:
            log(f"記録の画面で合言葉の違う接続を断りました: {handler.client_address[0]}")
        handler.discard_body()
        dashboard.send(handler, 401, dashboard.login_page(),
                       extra={"WWW-Authenticate": 'Basic realm="LifeLog PC", charset="UTF-8"', "Content-Security-Policy": CSP})
        return
    path = url.path
    if method == "GET" and set_cookie:
        # 合言葉の入った宛先を残さないよう、クッキーを渡して、key を除いた宛先に移る
        query = [(k, v) for k, values in parse_qs(url.query).items() if k != "key" for v in values]
        target = path + ("?" + urlencode(query) if query else "")
        dashboard.send(handler, 303, "", extra={"Location": target, "Set-Cookie": dashboard.cookie_header(handler.key)})
        return
    if store is None:
        handler.discard_body()
        _send_page(handler, 503, page("記録 — LifeLog PC", "<nav class='bar'><a href='/dash'>← 見守りの画面</a></nav>"
                                      "<section><p>記録の機能が動いていません（記録 log.txt に理由があります）。</p></section>"))
        return
    try:
        if method == "POST":
            if path == PREFIX + "/review":   # 版 9
                post_review(handler, store, log)
                return
            if path != PREFIX + "/edit":
                handler.discard_body()
                dashboard.send_json(handler, 404, {"error": "not found"})
                return
            post_edit(handler, store, log)
            return
        if path.startswith(AUDIO_PREFIX):
            name = unquote(path[len(AUDIO_PREFIX):])
            found = store.audio_file(name)
            if found is None:
                dashboard.send_json(handler, 404, {"error": "PC に音声がありません"})
                return
            send_audio(handler, found)
            return
        if path in (PREFIX, PREFIX + "/"):
            _send_page(handler, 200, render_index(store, index))
            return
        if path == PREFIX + "/review":   # 版 9
            _send_page(handler, 200, render_review(store, personal() if callable(personal) else personal))
            return
        if path == PREFIX + "/search":
            query = parse_qs(url.query)
            _send_page(handler, 200, render_search(store, (query.get("q") or [""])[0], (query.get("mode") or ["text"])[0],
                                                   index, log))
            return
        day = unquote(path[len(PREFIX) + 1:])
        body = render_day(store, day) if records.valid_day(day) else None
        if body is None:
            _not_found(handler, "その日の記録は PC にありません。")
            return
        _send_page(handler, 200, body)
    except Exception as error:  # noqa: BLE001 — 画面が作れなくても受け付けは続ける
        log(f"記録の画面を作れませんでした: {error!r}")
        dashboard.send_json(handler, 500, {"error": f"記録の画面を作れませんでした: {error}"})


def post_edit(handler, store: records.RecordStore, log) -> None:
    """POST /dash/records/edit {"day", "time": 行の時刻（1970 年からのミリ秒）, "kind": "text"|"speaker", "text"|"speaker"}"""
    if handler.headers.get(dashboard.HEADER) != "1":
        handler.discard_body()
        dashboard.send_json(handler, 403, {"error": "この画面のボタンから押してください"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > EDIT_LIMIT:
        handler.discard_body()
        dashboard.send_json(handler, 400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    try:
        body = json.loads(data.decode("utf-8"))
        if not isinstance(body, dict):
            raise ValueError("中身が JSON のまとまりではありません")
        kind = body.get("kind")
        day = body.get("day")
        moment = body.get("time")
        result = store.make_edit(day, moment, kind, body.get("text") if kind == "text" else body.get("speaker"))
    except (UnicodeDecodeError, ValueError) as error:
        message = str(error) if not isinstance(error, json.JSONDecodeError) else "中身が JSON ではありません"
        dashboard.send_json(handler, 400, {"error": message})
        return
    # 文・名前は記録に書かない（日と種類だけ）
    log(f"記録の画面で直しを作りました: {day} の行の{'文' if kind == 'text' else '話し手'}"
        + (f"（前の直し {len(result['replaced'])} 件を置き換え）" if result["replaced"] else ""))
    line_edits = [e for e in store.edits.for_day(day) if e["time"] == moment]
    state = result["state"]
    dashboard.send_json(handler, 200, {"ok": True, "message": result["message"], "html": edit_chips(line_edits),
                                       "expect": {"text": state["text"], "speaker": state["speaker"]},
                                       "id": result["edit"]["id"] if result["edit"] else None})
