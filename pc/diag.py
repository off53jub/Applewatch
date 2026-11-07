"""LifeLog PC 版 7: 実機の様子（POST /diag）を端末ごとに置き、気になる所を見つける。

iPhone（と iPad）が1時間に1回ほど・アプリを開いたとき・見えない通知で起きたときに送ってくる（2MB まで）。
決まりは docs/v7-plan.md の「1. 実機の様子」。置き場所は <home>/diag/:
- <deviceID>/latest.json        いちばん新しい様子（受け取った時刻 receivedAt を足したもの）
- <deviceID>/YYYY-MM-DD.jsonl   日ごとの履歴（受け取った日。60 日より前のものは消す）
- <deviceID>/metrickit/…json    MetricKit の診断（送られたまま。同じものは1つだけ置く。60 日で消す）
- summary.md                    人が読む、今の様子と気になる所（ops.py が書き直す。この PC で動く Claude が読む）
会話の中身・人の名前は iPhone が入れない決まり。PC も記録（log.txt）には数だけを書く。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import math
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Callable

DEVICE_ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z-]{7,63}")
BODY_LIMIT = 2_000_000       # POST /diag の大きさの上限
KEEP_DAYS = 60               # 日ごとの履歴・MetricKit の診断を残す日数
STALE = 3 * 3600             # これより長く様子が届かなければ、気になる所
CRASH_RECENT = 24 * 3600     # 落ちた・固まったを気になる所に数える長さ
HEARTBEAT_LATE = 30 * 60     # 時計が録音中なのに、時計からの便りがこれより前なら気になる所
CHUNK_LATE = 60 * 60         # 録音中なのに、録音の区切りがこれより前なら気になる所
RETIRED = 14 * 86400         # これより長く届かない端末は、気になる所に数えない（使わなくなった端末）
ROWS_MAX = 1000
CRASHES_MAX = 300
METRICKIT_MAX = 100
TEXT_MAX = 2000              # 1つの文字の項目の長さの上限（受け取るときに切る）
PRUNE_EVERY = 3600.0

CRASH = ("crash", "落ちた")
HANG = ("hang", "固まった")


def valid_device(value) -> bool:
    """端末の ID として使えるか（英数字と - の 8〜64 文字。フォルダの名前にするので、ほかの字は使わない）"""
    return isinstance(value, str) and DEVICE_ID.fullmatch(value) is not None


def parse_time(value) -> float | None:
    """ISO 8601 の日時（ミリ秒あり・なし、Z・+09:00 のような時差つき・時差なしは UTC とみなす）か、
    1970 年からの秒を、1970 年からの秒にする。読めなければ None。"""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return number if math.isfinite(number) and number > 0 else None
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text[-1] in "Zz":
        text = text[:-1] + "+00:00"
    try:
        moment = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.timestamp()


def iso(when: float) -> str:
    """"2026-11-07T06:58:25.123Z" の形（UTC・ミリ秒つき）"""
    moment = datetime.datetime.fromtimestamp(when, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def clock(when: float | None) -> str:
    """この PC の時刻で "11/07 15:58"（分からなければ "—"）"""
    if not when:
        return "—"
    return time.strftime("%m/%d %H:%M", time.localtime(when))


def ago(seconds: float | None) -> str:
    """"12 分"・"4.2 時間"・"3.0 日" のような長さ"""
    if seconds is None:
        return "—"
    seconds = max(0.0, float(seconds))
    if seconds < 3600:
        return f"{seconds / 60:.0f} 分"
    if seconds < 86400 * 2:
        return f"{seconds / 3600:.1f} 時間"
    return f"{seconds / 86400:.1f} 日"


def _text(value, limit: int = TEXT_MAX):
    """置く前に、長すぎる文字を切る（文字でなければそのまま）"""
    if isinstance(value, str) and len(value) > limit:
        return value[:limit] + "…"
    return value


def _clean_rows(rows) -> list[dict]:
    out = []
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict):
            out.append({k: _text(v, 500) for k, v in row.items() if isinstance(k, str)
                        and (v is None or isinstance(v, (str, int, float, bool)))})
        if len(out) >= ROWS_MAX:
            break
    return out


def _clean_crashes(crashes) -> list[dict]:
    out = []
    for crash in crashes if isinstance(crashes, list) else []:
        if isinstance(crash, dict):
            out.append({k: _text(v) for k, v in crash.items() if isinstance(k, str)
                        and (v is None or isinstance(v, (str, int, float, bool)))})
        if len(out) >= CRASHES_MAX:
            break
    return out


def _clean_flat(value, depth: int = 0):
    """state・tally・push のような、浅い入れ物だけを残す"""
    if isinstance(value, dict) and depth < 3:
        return {str(k)[:100]: _clean_flat(v, depth + 1) for k, v in list(value.items())[:200]}
    if isinstance(value, list) and depth < 3:
        return [_clean_flat(v, depth + 1) for v in value[:200]]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return _text(str(value), 500)


def clean(body: dict) -> dict:
    """受け取った様子のうち、置くもの（MetricKit の診断は別のファイルに置くので除く）"""
    out: dict = {}
    for key in ("deviceID", "device", "model", "os", "install", "sentAt"):
        if isinstance(body.get(key), (str, int, float)) and not isinstance(body.get(key), bool):
            out[key] = _text(str(body[key]), 200)
    build = body.get("build")
    if isinstance(build, (int, str)) and not isinstance(build, bool):
        out["build"] = build if isinstance(build, int) else _text(build, 50)
    out["rows"] = _clean_rows(body.get("rows"))
    out["crashes"] = _clean_crashes(body.get("crashes"))
    for key in ("tally", "state", "push"):
        if isinstance(body.get(key), dict):
            out[key] = _clean_flat(body[key])
    return out


def _write_json(path: Path, body) -> None:
    """途中で止まっても壊れたファイルが残らないよう、別の名前に書いてから置き換える"""
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def crash_kind(crash: dict) -> str:
    kind = str(crash.get("kind") or "")
    if kind in CRASH:
        return "落ちた"
    if kind in HANG:
        return "固まった"
    return kind or "そのほか"


def recent_crashes(record: dict, now: float, within: float = CRASH_RECENT) -> list[tuple[float, dict]]:
    """within 秒以内の、落ちた・固まった記録（時刻の順）"""
    found = []
    for crash in record.get("crashes") or []:
        if not isinstance(crash, dict) or crash_kind(crash) not in ("落ちた", "固まった"):
            continue
        at = parse_time(crash.get("at"))
        if at is not None and now - at <= within:
            found.append((at, crash))
    return sorted(found, key=lambda pair: pair[0])


def concerns(record: dict, now: float) -> list[str]:
    """気になる所（やさしい日本語の文の並び）。無ければ空。"""
    out: list[str] = []
    received = parse_time(record.get("receivedAt"))
    if received is None:
        return ["受け取った時刻が分かりません"]
    if now - received > RETIRED:
        return []
    if now - received > STALE:
        out.append(f"{ago(now - received)}、様子が届いていません（最後に届いたのは {clock(received)}）")
    crashes = recent_crashes(record, now)
    if crashes:
        counts: dict[str, int] = {}
        for _, crash in crashes:
            counts[crash_kind(crash)] = counts.get(crash_kind(crash), 0) + 1
        last_at, last = crashes[-1]
        detail = str(last.get("detail") or "").strip()
        out.append("24時間以内に " + "・".join(f"{k} {n} 回" for k, n in counts.items())
                   + f"（最後は {clock(last_at)}" + (f"・{_text(detail, 120)}" if detail else "") + "）")
    bad = [row for row in record.get("rows") or [] if isinstance(row, dict) and row.get("ok") is False]
    for row in bad[:10]:
        out.append(f"自己点検で ok でない行: {row.get('group') or '—'} / {row.get('name') or '—'}: "
                   f"{_text(str(row.get('value') if row.get('value') is not None else '—'), 120)}")
    if len(bad) > 10:
        out.append(f"…ほかにも ok でない行が {len(bad) - 10} 行あります")
    state = record.get("state") if isinstance(record.get("state"), dict) else {}
    snapshot = parse_time(record.get("sentAt")) or received
    if state.get("watchRecording") is True:
        heartbeat = parse_time(state.get("watchHeartbeatAt"))
        if heartbeat is not None and snapshot - heartbeat > HEARTBEAT_LATE:
            out.append(f"時計が録音中なのに、時計からの便りが {ago(snapshot - heartbeat)} 来ていません"
                       f"（最後は {clock(heartbeat)}）")
    if state.get("phoneRecording") is True or state.get("watchRecording") is True:
        chunk = parse_time(state.get("lastChunkAt"))
        if chunk is not None and snapshot - chunk > CHUNK_LATE:
            out.append(f"録音中なのに、録音の区切りが {ago(snapshot - chunk)} できていません（最後は {clock(chunk)}）")
    # 2026-11-07: 時計が区切りを作っていない・時計に区切りが残っている（新しい時計のアプリだけが知らせる）
    if state.get("watchRecording") is True and state.get("watchHeld") is not True and state.get("watchResting") is not True:
        cut = parse_time(state.get("watchLastCut"))
        if cut is not None and snapshot - cut > CHUNK_LATE:
            out.append(f"時計が録音中なのに、時計が区切りを {ago(snapshot - cut)} 作っていません（最後は {clock(cut)}）")
    pending = state.get("watchPending")
    if isinstance(pending, int) and not isinstance(pending, bool) and pending >= 4:
        out.append(f"時計の中に、まだ iPhone に送っていない区切りが {pending} 個あります")
    return out


def label(record: dict) -> str:
    """"iPhone（iPhone17,1・1A2B）" のような、端末の見分け方（名前は入れない）"""
    device = str(record.get("device") or "端末")
    model = str(record.get("model") or "").strip()
    short = str(record.get("deviceID") or "")[:4].upper()
    return f"{device}（" + "・".join(p for p in (model, short) if p) + "）"


def _yes(value) -> str:
    return {True: "はい", False: "いいえ"}.get(value, "—")


# 版 8: iPhone が state.latency で送る、区間ごとの時間（直近24時間の中央値。秒）
LATENCY_PARTS = (("toPhone", "録音の終わり→iPhone"), ("toPC", "iPhone→PC"), ("pcWait", "PC の待ち"),
                 ("pcWork", "PC の作業"), ("toRecord", "PC→記録"), ("total", "合計"),
                 # 2026-11-07: 時計→iPhone の内訳（時計で区切ってから送り始めるまで・送り始めてから iPhone のアプリが受け取るまで）
                 ("watchWait", "時計で待った"), ("handoff", "時計→iPhone の受け渡し"))


def _secs(value: float) -> str:
    value = float(value)
    return f"{value:.1f} 秒" if value < 120 else f"{value / 60:.1f} 分"


def phone_latency(state: dict) -> str | None:
    """state.latency を1行にする（"録音の終わり→iPhone 40.5 秒・…（12 件）"）。無ければ None"""
    latency = state.get("latency") if isinstance(state, dict) else None
    if not isinstance(latency, dict):
        return None
    parts = [f"{label} {_secs(latency[key])}" for key, label in LATENCY_PARTS
             if isinstance(latency.get(key), (int, float)) and not isinstance(latency.get(key), bool)
             and math.isfinite(float(latency[key])) and latency[key] >= 0]
    if not parts:
        return None
    count = latency.get("count")
    return "・".join(parts) + (f"（{count} 件）" if isinstance(count, int) and not isinstance(count, bool) else "")


def pc_latency(stats: dict | None) -> list[str]:
    """jobqueue.JobQueue.latency() の答えを、人が読む行にする"""
    if not stats or not stats.get("count"):
        return ["まだでき上がった仕事がありません"]
    labels = (("wait", "PC の待ち（受け終わり→文字にし始め）"), ("work", "PC の作業（文字にし始め→でき上がり）"),
              ("draft", "下書きまで（文字にし始め→下書き）"), ("to_pc", "iPhone→PC（送り始め→受け終わり）"))
    lines = []
    for key, label in labels:
        value = stats.get(key)
        if value:
            lines.append(f"{label}: 中央値 {_secs(value['median'])}・いちばん長い {_secs(value['max'])}（{value['count']} 件）")
    lines.append(f"待ち合わせで渡した: {stats.get('handed', 0)} / {stats['count']} 件")
    return lines


def state_lines(record: dict) -> list[str]:
    """state の中身を、人が読む行にする"""
    state = record.get("state") if isinstance(record.get("state"), dict) else {}
    if not state:
        return []
    when = lambda key: clock(parse_time(state.get(key)))  # noqa: E731
    lines = [f"録音: iPhone {_yes(state.get('phoneRecording'))}・時計 {_yes(state.get('watchRecording'))}"
             f"（時計の便り {when('watchHeartbeatAt')}・時計に残っている {state.get('watchUnsent', '—')}・"
             f"時計の build {state.get('watchBuild', '—')}）",
             # 2026-11-07: 時計に残っている区切りの内訳（新しい時計のアプリだけ）
             *([f"時計の中: まだ送っていない {state.get('watchPending')}・送っている途中 {state.get('watchOutstanding', '—')}・"
                f"返事待ち {state.get('watchKept', '—')}・最後に区切った {when('watchLastCut')}・"
                f"休む場所 {_yes(state.get('watchHeld'))}・録音しているつもり {_yes(state.get('watchWanted'))}"]
               if 'watchPending' in state else []),
             f"待ち: 取り込み {state.get('queue', '—')}・PC の仕事 {state.get('jobsPending', '—')}・"
             f"最後に文字にした {when('lastProcessedAt')}・最後の区切り {when('lastChunkAt')}・"
             f"夜の処理 {state.get('nightlyDoneFor') or '—'} の分まで"]
    latency = phone_latency(state)
    if latency:
        lines.append(f"文字になるまでの時間（iPhone で測った直近24時間の中央値）: {latency}")
    return lines


class DiagStore:
    """端末ごとの様子を置き、いちばん新しいものを覚えておく。"""

    def __init__(self, folder: Path, log: Callable[[str], None], clock_fn: Callable[[], float] = time.time) -> None:
        self.folder = Path(folder)
        self.log = log
        self.clock = clock_fn
        self.lock = threading.Lock()
        self.latest: dict[str, dict] = {}
        self.pruned = 0.0
        self.load()

    def load(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True)
        for path in self.folder.glob("*/latest.json"):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            device = record.get("deviceID") if isinstance(record, dict) else None
            if valid_device(device) and path.parent.name == device:
                self.latest[device] = record

    def receive(self, body, ip: str | None = None) -> dict:
        """POST /diag の中身を置く。置いたもの（MetricKit はファイルの名前）を返す。おかしければ ValueError。"""
        if not isinstance(body, dict):
            raise ValueError("中身が JSON のオブジェクトではありません")
        device = body.get("deviceID")
        if not valid_device(device):
            raise ValueError("deviceID がありません（英数字と - の 8〜64 文字）")
        now = self.clock()
        record = clean(body)
        record["receivedAt"] = iso(now)
        if ip:
            record["ip"] = ip
        folder = self.folder / device
        with self.lock:
            folder.mkdir(parents=True, exist_ok=True)
            record["metrickit"] = self._save_metrickit(folder, body.get("metrickit"), now)
            _write_json(folder / "latest.json", record)
            day = time.strftime("%Y-%m-%d", time.localtime(now))
            with (folder / f"{day}.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            self.latest[device] = record
            if now - self.pruned > PRUNE_EVERY:
                self.prune(now)
        return record

    def _save_metrickit(self, folder: Path, payloads, now: float) -> list[str]:
        """MetricKit の診断を1つずつファイルにする（同じ中身は1つだけ）。置いた（もうあった）ものの名前を返す。"""
        names: list[str] = []
        items = payloads if isinstance(payloads, list) else []
        if items:
            (folder / "metrickit").mkdir(exist_ok=True)
        for payload in items[:METRICKIT_MAX]:
            if not isinstance(payload, (dict, list)):
                continue
            text = json.dumps(payload, ensure_ascii=False, sort_keys=True)
            digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
            existing = sorted((folder / "metrickit").glob(f"*-{digest}.json"))
            if existing:
                names.append(f"metrickit/{existing[0].name}")
                continue
            name = time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + f"-{digest}.json"
            _write_json(folder / "metrickit" / name, payload)
            names.append(f"metrickit/{name}")
        return names

    def prune(self, now: float | None = None) -> int:
        """60 日より前の履歴・MetricKit の診断と、60 日より長く届いていない端末のフォルダを消す。消した数を返す。"""
        now = self.clock() if now is None else now
        limit = now - KEEP_DAYS * 86400
        cutoff = time.strftime("%Y-%m-%d", time.localtime(limit))
        removed = 0
        for folder in [p for p in self.folder.iterdir() if p.is_dir() and valid_device(p.name)]:
            record = self.latest.get(folder.name)
            received = parse_time((record or {}).get("receivedAt"))
            if received is not None and received < limit:
                shutil.rmtree(folder, ignore_errors=True)
                self.latest.pop(folder.name, None)
                removed += 1
                continue
            for path in folder.glob("*.jsonl"):
                if re.fullmatch(r"\d{4}-\d{2}-\d{2}", path.stem) and path.stem < cutoff:
                    path.unlink(missing_ok=True)
                    removed += 1
            for path in (folder / "metrickit").glob("*.json") if (folder / "metrickit").is_dir() else []:
                try:
                    if path.stat().st_mtime < limit:
                        path.unlink()
                        removed += 1
                except OSError:
                    pass
        self.pruned = now
        if removed:
            self.log(f"実機の様子: {KEEP_DAYS} 日より前のものを {removed} 個片づけました")
        return removed

    def devices(self) -> list[dict]:
        """端末ごとのいちばん新しい様子（新しく届いた順）"""
        with self.lock:
            records = list(self.latest.values())
        return sorted(records, key=lambda r: parse_time(r.get("receivedAt")) or 0, reverse=True)

    def last_received(self, device: str) -> float | None:
        record = self.latest.get(device)
        return parse_time((record or {}).get("receivedAt"))

    def device_for_ip(self, ip: str | None) -> str | None:
        """その宛先（Tailscale の番号）から最後に様子を送ってきた端末"""
        if not ip:
            return None
        best, when = None, 0.0
        for device, record in list(self.latest.items()):
            received = parse_time(record.get("receivedAt")) or 0.0
            if record.get("ip") == ip and received > when:
                best, when = device, received
        return best

    def summary_lines(self, now: float | None = None) -> tuple[list[str], list[str]]:
        """(気になる所の行, 端末ごとの行)。summary.md に書く（Markdown）。"""
        now = self.clock() if now is None else now
        worries: list[str] = []
        lines: list[str] = []
        old: list[str] = []
        for record in self.devices():
            name = label(record)
            received = parse_time(record.get("receivedAt"))
            if received is not None and now - received > RETIRED:
                old.append(f"- {name}: 最後に届いたのは {clock(received)}（{ago(now - received)}前）")
                continue
            found = concerns(record, now)
            worries.extend(f"- {name}: {text}" for text in found)
            lines.append(f"### {name}")
            lines.append(f"- iOS {record.get('os') or '—'}・build {record.get('build') or '—'}・"
                         f"入れ方 {record.get('install') or '—'}")
            lines.append(f"- 最後に届いた: {clock(received)}（{ago(now - received) if received else '—'}前）・"
                         f"送った時刻 {clock(parse_time(record.get('sentAt')))}")
            lines.extend(f"- {text}" for text in state_lines(record))
            push = record.get("push") if isinstance(record.get("push"), dict) else {}
            if push.get("token"):
                lines.append(f"- 通知の登録: あり（{push.get('environment') or '—'}・…{str(push['token'])[-8:]}）")
            else:
                lines.append("- 通知の登録: まだありません")
            rows = record.get("rows") or []
            bad = [r for r in rows if isinstance(r, dict) and r.get("ok") is False]
            lines.append(f"- 自己点検: {len(rows)} 行（ok でない {len(bad)} 行）")
            for row in bad[:20]:
                lines.append(f"  - {row.get('group') or '—'} / {row.get('name') or '—'}: {_text(str(row.get('value')), 200)}")
            week = recent_crashes(record, now, 7 * 86400)
            if week:
                lines.append(f"- 落ちた・固まった（直近 7 日）: {len(week)} 回")
                for at, crash in week[-5:]:
                    detail = _text(str(crash.get("detail") or ""), 200)
                    lines.append(f"  - {clock(at)} {crash_kind(crash)}" + (f"・{detail}" if detail else ""))
            tally = record.get("tally") if isinstance(record.get("tally"), dict) else {}
            for day in sorted(tally, reverse=True)[:2]:
                counts = tally[day] if isinstance(tally[day], dict) else {}
                text = "・".join(f"{k} {v}" for k, v in list(counts.items())[:30]) or "—"
                lines.append(f"- {day} の数: {text}")
            if record.get("metrickit"):
                lines.append(f"- MetricKit の診断（この回）: {len(record['metrickit'])} 件")
            lines.append(f"- 置き場所: {self.folder / str(record.get('deviceID'))}")
            lines.append("")
        if old:
            lines.append("### しばらく届いていない端末")
            lines.extend(old)
            lines.append("")
        return worries, lines
