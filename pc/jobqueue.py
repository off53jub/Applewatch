"""LifeLog PC 版 6: 後で受け取る文字起こし（POST /jobs・GET /jobs・GET /jobs/<名前>・DELETE /jobs/<名前>）。

iPhone は録音の区切りを1つずつ裏で送っておき、PC が文字にし終えたころに答えを取りに来る。
- 区切りの名前（iPhone のファイルの名前）で見分ける。同じ名前が来たら、失敗したものだけを入れ直す。
- 1つずつ文字にする（裏の仕事は1本だけ）。版 8 から、待っているものが2つ以上あれば新しく受けたものから。
- 受けた音声と状態は <home>/jobs/ に置くので、PC を起動し直しても続きから文字にする。
- 音声は、文字にし終えたら（失敗しても）すぐ消す。答えは、でき上がってから 7 日で消す。
  版 7: 音声を残す先 keep_audio（records.RecordStore.keep_audio）を渡したときは、文字にし終えても消さずに残し、
  iPhone が消したとき（DELETE /jobs/<名前>）と 7 日たって片付けるときに、keep_audio(名前, 音声のファイル, 状態) に移してもらう。
ここには文字にする仕組みは無い。lifelog_pc.py が渡す runner(音声のファイル, 頼まれた設定, 名前) が文字にする。

版 8（決まりは docs/v8-latency.md）:
- 時間: POST /jobs の chunk_start・chunk_end・arrived・sent（iPhone の時刻）と、PC の received・started・draft_at・finished を
  残し、GET /jobs/<名前> と待ち合わせの答えに "timing" として返す（日時は ISO 8601・UTC・ミリ秒つき）。
- 待ち合わせ（POST /jobs?wait=1）: でき上がりまで答えを待たせ、WAIT_PING 秒ごとに空白を1文字書く。
  でき上がったら GET と同じ形で答える。WAIT_LIMIT 秒（25 分）たつか、起動し直す・閉じるときは pending を返す。
  答えを書き終え、iPhone が読み終えて閉じた仕事は「渡した」（"handed": true）と覚え、on_done（「できた」の見えない通知）を
  呼ばない。途中で切れた・閉じるのが WAIT_CONFIRM 秒のうちに来なかったときは、渡せなかったとして通知する。
- 下書き: runner が4つ目の引数 draft を受けるなら、draft(答えと同じ形) で下書きを残せる。GET はまだのとき下書きを返す。
- 新しい区切りから: 待っているものが2つ以上あれば、いちばん新しく受けたものから文字にする。

版 10（決まりは docs/v10-watch-route.md）:
- 時計の外の道（watchroute.py の POST /w/jobs）から預かった仕事には "origin": "watch" を付ける。
  http_post(..., origin="watch") は、待ち合わせ（wait）をしない・8MB まで・名前は「年月日-時分秒…-w.m4a」だけ。
- GET /jobs?origin=watch は、時計から預かった仕事だけを返す。GET /jobs・GET /jobs/<名前> は "origin" が付くだけで、ほかは同じ。
"""

from __future__ import annotations

import hashlib
import inspect
import json
import os
import re
import select
import socket
import threading
import time
from pathlib import Path
from typing import Callable

import diag  # 版 8: 日時の読み書き（ISO 8601。ミリ秒なし・時差つきも読める）

NAME = re.compile(r"[0-9A-Za-z._-]{1,80}")
QUEUE_LIMIT = 500            # 待っている（queued・working）ものがこれだけあれば、断る（503）
LIST_LIMIT = 500             # GET /jobs で返す数の上限
BODY_LIMIT = 200_000_000     # 音声の大きさの上限（200MB）
KEEP_SECONDS = 7 * 86400     # でき上がった答えを残しておく長さ
CLEAN_EVERY = 3600.0         # 古い答えを消すのを確かめる間（秒）
# 版 8: 新しい順にしても、これより長く待った区切りは先に文字にする（秒）
STARVE_AFTER = 15 * 60
# 2026-11-07 の落ち方への守り: 同じ仕事を文字にしている最中に、これだけ止まったら GPU のモデルを使わない・飛ばす
CRASH_CPU_ONLY = 2
CRASH_SKIP = 3


def _env_seconds(name: str, default: float) -> float:
    """試すときだけ、環境変数で秒を短くできる（ふだんは決まりの値）"""
    try:
        value = float(os.environ.get(name) or default)
    except ValueError:
        return default
    return value if value > 0 else default


# 版 8: 待ち合わせ（wait=1）。空白を書く間と、待つ長さの上限（試すときは環境変数で短くできる）
WAIT_PING = _env_seconds("LIFELOG_JOBWAIT_PING", 15.0)
WAIT_LIMIT = _env_seconds("LIFELOG_JOBWAIT_LIMIT", 25 * 60.0)
# 答えを書いたあと、iPhone が読み終えて閉じるのを待つ長さ。閉じなければ渡せたか分からないので、見えない通知も送る
WAIT_CONFIRM = _env_seconds("LIFELOG_JOBWAIT_CONFIRM", 10.0)
# 版 8: iPhone が query に付ける時刻（timing にそのまま返す）
CLIENT_TIMES = ("chunk_start", "chunk_end", "arrived", "sent")
# 版 10: 時計の外の道から預かるもの。5 分の区切り（約 1.2MB）には十分な大きさの上限と、時計の区切りの名前の形
WATCH_BODY_LIMIT = 8 * 1024 * 1024
WATCH_NAME = re.compile(r"\d{8}-\d{6}[A-Za-z0-9._-]*-w\.m4a")


def valid_name(name) -> bool:
    """区切りの名前として使えるか（英数字と . _ - だけ、80 文字まで。点だけの名前は使わない）"""
    return isinstance(name, str) and NAME.fullmatch(name) is not None and name.strip(".") != ""


def _write_json(path: Path, body: dict) -> None:
    """途中で止まっても壊れたファイルが残らないよう、別の名前に書いてから置き換える"""
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    os.replace(part, path)


def _unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _takes_four(runner) -> bool:
    """runner(音声, 設定, 名前, 下書きの口) と呼べるか（版 7 までの runner は3つしか受けない）"""
    try:
        inspect.signature(runner).bind(None, None, None, None)
        return True
    except (TypeError, ValueError):
        return False


def iso(when) -> str | None:
    return diag.iso(float(when)) if when else None


def parse_times(query: dict) -> dict[str, float]:
    """POST /jobs の chunk_start・chunk_end・arrived・sent（ISO 8601）を 1970 年からの秒にする。読めないものは省く。"""
    out: dict[str, float] = {}
    for key in CLIENT_TIMES:
        value = (query.get(key) or [None])[0]
        when = diag.parse_time(value) if isinstance(value, str) and len(value) <= 64 else None
        if when is not None:
            out[key] = round(when, 3)
    return out


def timing(meta: dict) -> dict:
    """"timing" の中身: iPhone の時刻と、PC の received（受け終わり）・started（文字にし始め）・
    draft_at（下書きができた）・finished（でき上がり）。分からないものは省く。"""
    out = {k: iso(v) for k, v in (meta.get("times") or {}).items() if k in CLIENT_TIMES and v}
    for key, field in (("received", "queued_at"), ("started", "started_at"), ("draft_at", "draft_at"),
                       ("finished", "done_at")):
        if meta.get(field):
            out[key] = iso(meta[field])
    return out


def peer_gone(connection) -> bool:
    """相手が接続を閉じたか（音声は読み終えているので、読めるのに中身が無ければ閉じている）"""
    try:
        readable, _, _ = select.select([connection], [], [], 0)
        if not readable:
            return False
        return connection.recv(1, socket.MSG_PEEK) == b""
    except (OSError, ValueError):
        return True


def delivered(connection, timeout: float | None = None) -> bool:
    """答えを書き終えたあと、こちらから送るのを閉じて、相手が読み終えて閉じるのを少し待つ。
    閉じたら True（渡せた）。届いたか分からない（つながりが途中で消えた）ときは False（見えない通知で知らせる）。"""
    timeout = WAIT_CONFIRM if timeout is None else timeout
    try:
        connection.shutdown(socket.SHUT_WR)
    except OSError:
        return False
    deadline = time.time() + timeout
    try:
        while True:
            left = deadline - time.time()
            if left <= 0:
                return False
            readable, _, _ = select.select([connection], [], [], min(left, 0.5))
            if readable:
                return connection.recv(4096) == b"" or delivered_more(connection, deadline)
    except (ConnectionResetError, ConnectionAbortedError):
        return True   # 読み終えた相手が、すぐ切った
    except (OSError, ValueError):
        return False


def delivered_more(connection, deadline: float) -> bool:
    """閉じる前に何か送ってきた（ふつうは無い）。閉じるまで読み捨てて待つ"""
    while time.time() < deadline:
        readable, _, _ = select.select([connection], [], [], max(0.0, min(deadline - time.time(), 0.5)))
        if readable and connection.recv(4096) == b"":
            return True
    return False


class QueueFull(RuntimeError):
    """待っているものが多すぎる"""


class JobQueue:
    """区切りごとの仕事を、1つずつ文字にする（版 8 から新しく受けたものから）。"""

    def __init__(self, folder: Path, runner: Callable[[Path, dict, str], tuple[dict, dict]],
                 log: Callable[[str], None], limit: int = QUEUE_LIMIT, keep: float = KEEP_SECONDS,
                 keep_audio: Callable[[str, Path, dict], None] | None = None) -> None:
        self.folder = Path(folder)
        self.runner = runner
        self.log = log
        self.limit = limit
        self.keep = keep
        # 版 7（records）: 音声を残す先。あれば、音声は消すときまで残して、ここに移してもらう
        self.keep_audio = keep_audio
        self.jobs: dict[str, dict] = {}
        self.receiving: set[str] = set()
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.paused = False
        self.working: str | None = None
        self.seq = 0
        self.cleaned = 0.0
        self.thread: threading.Thread | None = None
        # 版 7（ops）: 仕事が1つ終わったとき（でき上がり・失敗）に呼ぶ口。on_done(名前, 状態) で、状態は done か failed
        # 版 8: 待ち合わせで答えを渡した仕事には呼ばない（待っている人がいるあいだは、渡せたかが分かるまで待つ）
        self.on_done: Callable[[str, dict], None] | None = None
        # 版 8: 待ち合わせ（wait=1）で待っている数と、待っている人がいるあいだに終わった仕事（渡せたかが分かるまで預かる）
        self.waiters: dict[str, int] = {}
        self.held: dict[str, dict] = {}
        # 版 8: runner が下書きの口（4つ目の引数）を受けるか
        self.runner_drafts = _takes_four(runner)
        self.load()

    # MARK: 置き場所（ファイルの名前は区切りの名前のハッシュ。Windows の決まった名前や大文字小文字の違いでぶつからないように）

    def base(self, name: str) -> Path:
        return self.folder / hashlib.sha256(name.encode("utf-8")).hexdigest()[:32]

    def meta_path(self, name: str) -> Path:
        return self.base(name).with_suffix(".json")

    def audio_path(self, name: str) -> Path:
        return self.base(name).with_suffix(".audio")

    def result_path(self, name: str) -> Path:
        return self.base(name).with_suffix(".result")

    def draft_path(self, name: str) -> Path:
        """版 8: 下書き（速いモデルだけで文字にしたもの）。でき上がったら消す"""
        return self.base(name).with_suffix(".draft")

    def load(self) -> None:
        """起動したときに、前に受けた仕事を読み込む。途中だったものは待ちに戻す。"""
        self.folder.mkdir(parents=True, exist_ok=True)
        known: set[str] = set()
        for path in self.folder.glob("*.json"):
            try:
                meta = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            name = meta.get("id") if isinstance(meta, dict) else None
            if not valid_name(name) or self.meta_path(name) != path:
                continue
            known.add(path.stem)
            if meta.get("status") == "working":
                # 文字にしている最中に止まった（落ちた・電源が切れた）回数。入れ替えのときは、仕事が終わるのを待ってから止まる
                stops = int(meta.get("interrupted") or 0) + 1
                meta["interrupted"] = stops
                meta.pop("started_at", None)
                meta.pop("draft_at", None)  # 版 8: 下書きも作り直す
                _unlink(self.draft_path(name))
                if stops >= CRASH_SKIP:
                    meta.update(status="failed", done_at=time.time(),
                                error=f"文字にしている最中に LifeLog PC が {stops} 回止まったので、この区切りは飛ばしました")
                    self.log(f"後で受け取る文字起こし {name}: 文字にしている最中に {stops} 回止まったので、飛ばします"
                             "（GPU を使わずに試しても止まりました）")
                else:
                    meta["status"] = "queued"
                    self.log(f"後で受け取る文字起こし {name}: 途中で止まっていたので、もう一度文字にします"
                             + ("（2 回目なので、GPU のモデルを使わず CPU のモデルだけで）" if stops >= CRASH_CPU_ONLY else ""))
            if meta.get("status") == "queued" and not self.audio_path(name).exists():
                meta.update(status="failed", error="音声がありません（受け取り途中で止まりました）", done_at=time.time())
            if meta.get("status") not in ("queued", "done", "failed"):
                continue
            self.jobs[name] = meta
            self.seq = max(self.seq, int(meta.get("seq") or 0))
            _write_json(path, meta)
        # 名前の分からない残り物（受け取り途中のものなど）は消す
        for path in self.folder.iterdir():
            stem = path.name.split(".", 1)[0]
            if path.is_file() and (stem not in known or path.name.endswith(".part")):
                _unlink(path)
        for name, meta in self.jobs.items():
            if meta.get("status") in ("done", "failed") and self.keep_audio is None:
                _unlink(self.audio_path(name))
            if meta.get("status") in ("done", "failed"):
                _unlink(self.draft_path(name))

    # MARK: 受け付け

    def begin(self, name: str) -> tuple[str, dict | None]:
        """受け取りを始める。("exists", 今の状態) か ("full", None) か ("ok", None)。
        "ok" のときは、audio_path(name) + ".part" に音声を書いてから commit か abort を呼ぶ。"""
        with self.lock:
            meta = self.jobs.get(name)
            if meta is not None and meta.get("status") != "failed":
                return "exists", self.public(meta, short=True)
            if name in self.receiving:
                return "exists", {"id": name, "status": "queued"}
            active = sum(1 for m in self.jobs.values() if m.get("status") in ("queued", "working"))
            if active + len(self.receiving) >= self.limit:
                return "full", None
            self.receiving.add(name)
            return "ok", None

    def part_path(self, name: str) -> Path:
        return self.audio_path(name).with_name(self.audio_path(name).name + ".part")

    def commit(self, name: str, params: dict, size: int, times: dict | None = None,
               origin: str | None = None) -> dict:
        """受け取った音声を待ちの最後に加える。失敗していた同じ名前のものは置き換える。
        版 8: times は iPhone の時刻（parse_times の答え）。queued_at が received（受け終わり）になる。
        版 10: origin は、どこから預かったか（時計の外の道なら "watch"。iPhone からなら付けない）。"""
        with self.lock:
            self.receiving.discard(name)
            os.replace(self.part_path(name), self.audio_path(name))
            _unlink(self.result_path(name))
            _unlink(self.draft_path(name))
            self.seq += 1
            meta = {"id": name, "status": "queued", "queued_at": round(time.time(), 3), "done_at": None,
                    "seq": self.seq, "params": params, "size": int(size)}
            if times:
                meta["times"] = dict(times)
            if origin:
                meta["origin"] = origin
            self.jobs[name] = meta
            _write_json(self.meta_path(name), meta)
            self.changed.notify_all()
            return self.public(meta, short=True)

    def abort(self, name: str) -> None:
        with self.lock:
            self.receiving.discard(name)
            _unlink(self.part_path(name))

    # MARK: 見る・消す

    @staticmethod
    def public(meta: dict, short: bool = False) -> dict:
        # POST /jobs の短い答えは今までどおり（時計から預かった仕事に iPhone が送っても、同じ形で答える）
        if short:
            return {"id": meta["id"], "status": meta["status"]}
        out = {"id": meta["id"], "status": meta["status"], "queued_at": meta.get("queued_at"),
               "done_at": meta.get("done_at")}
        if meta.get("status") == "failed":
            out["error"] = meta.get("error") or "文字にできませんでした"
        if meta.get("origin"):  # 版 10: 時計の外の道から預かった仕事
            out["origin"] = meta["origin"]
        return out

    def get(self, name: str) -> dict | None:
        """GET /jobs/<名前> の答え。知らない名前なら None。
        版 8: "timing" を付ける。まだ（working）で下書きがあれば "draft"（result と同じ形）も付ける。"""
        with self.lock:
            meta = self.jobs.get(name)
            if meta is None:
                return None
            out = self.public(meta)
            out["timing"] = timing(meta)
            status = meta.get("status")
            if status == "working" and meta.get("draft_at"):
                path = self.draft_path(name)
            elif status == "done":
                path = self.result_path(name)
            else:
                return out
        try:
            body = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            if status == "done":
                out.update(status="failed", error="答えのファイルを読めませんでした")
            return out  # 下書きが読めない（でき上がって消えたところ）なら、下書き無しで返す
        out["result" if status == "done" else "draft"] = body
        return out

    def save_draft(self, name: str, seq, reply: dict) -> bool:
        """版 8: 下書きを残す（その仕事を文字にしている最中のときだけ）。残せたら True。"""
        with self.lock:
            meta = self.jobs.get(name)
            if meta is None or meta.get("seq") != seq or meta.get("status") != "working":
                return False
            _write_json(self.draft_path(name), reply)
            meta["draft_at"] = round(time.time(), 3)
            _write_json(self.meta_path(name), meta)
            self.changed.notify_all()
            return True

    def latency(self, limit: int = 50) -> dict:
        """版 8: 見守りの画面と summary.md に出す、直近 limit 個のでき上がった仕事の時間（秒）。
        wait = received→started（PC の待ち）、work = started→finished（PC の作業）、draft = started→draft_at、
        to_pc = sent→received（iPhone から PC へ送るのにかかった時間。iPhone が sent を付けたときだけ）。
        それぞれ {"median", "max", "count"}。handed は待ち合わせで渡した数。"""
        import statistics

        with self.lock:
            metas = sorted((m for m in self.jobs.values() if m.get("status") == "done"),
                           key=lambda m: float(m.get("done_at") or 0), reverse=True)[:limit]
            metas = [dict(m) for m in metas]
        spans: dict[str, list[float]] = {"wait": [], "work": [], "draft": [], "to_pc": []}
        for meta in metas:
            received, started, draft, done = (meta.get(k) for k in ("queued_at", "started_at", "draft_at", "done_at"))
            sent = (meta.get("times") or {}).get("sent")
            for key, a, b in (("wait", received, started), ("work", started, done), ("draft", started, draft),
                              ("to_pc", sent, received)):
                if a and b and float(b) >= float(a) - 5:
                    spans[key].append(max(0.0, float(b) - float(a)))
        out: dict = {"count": len(metas), "handed": sum(1 for m in metas if m.get("handed"))}
        for key, values in spans.items():
            out[key] = {"median": round(statistics.median(values), 2), "max": round(max(values), 2),
                        "count": len(values)} if values else None
        return out

    def listing(self, limit: int = LIST_LIMIT, origin: str | None = None) -> list[dict]:
        """新しい順に、最大 limit 個。版 10: origin を渡したら、その origin の仕事だけ"""
        with self.lock:
            metas = [m for m in self.jobs.values() if origin is None or m.get("origin") == origin]
            metas = sorted(metas, key=lambda m: int(m.get("seq") or 0), reverse=True)[:limit]
            return [self.public(m) for m in metas]

    def recent(self, limit: int = 20) -> list[dict]:
        """見守りの画面に出す、新しい順の仕事（かかった時間なども入れる。文の中身は入れない）"""
        with self.lock:
            metas = sorted(self.jobs.values(), key=lambda m: int(m.get("seq") or 0), reverse=True)[:limit]
            return [dict(m) for m in metas]

    def counts(self) -> dict[str, int]:
        with self.lock:
            counts = {"queued": 0, "working": 0, "done": 0, "failed": 0}
            for meta in self.jobs.values():
                counts[meta.get("status", "failed")] = counts.get(meta.get("status", "failed"), 0) + 1
            return counts

    def delete(self, name: str) -> bool:
        """その仕事のもの（音声・答え・状態）を全部消す。文字にしている途中なら、でき上がった答えは捨てる。
        版 7: 音声を残す先があれば、音声は消さずに移す。"""
        with self.lock:
            meta = self.jobs.pop(name, None)
            if meta is None:
                return False
            self._keep_audio(name, meta)
            self._remove_files(name)
            return True

    def _keep_audio(self, name: str, meta: dict) -> None:
        """版 7（records）: 音声を残す先に移す（無い・移せなければ、このあと消す）"""
        audio = self.audio_path(name)
        if self.keep_audio is None or not audio.exists():
            return
        try:
            self.keep_audio(name, audio, dict(meta))
        except Exception as error:  # noqa: BLE001 — 移せなくても、消す処理は続ける
            self.log(f"後で受け取る文字起こし {name}: 音声を残せませんでした（消します）: {error!r}")

    def _remove_files(self, name: str) -> None:
        for path in (self.meta_path(name), self.audio_path(name), self.result_path(name), self.draft_path(name)):
            _unlink(path)

    def clean(self, now: float | None = None) -> int:
        """でき上がって（失敗して）から keep 秒より経ったものを消す。消した数を返す。"""
        now = time.time() if now is None else now
        removed = 0
        with self.lock:
            for name, meta in list(self.jobs.items()):
                done_at = meta.get("done_at")
                if meta.get("status") in ("done", "failed") and done_at and now - float(done_at) > self.keep:
                    self.jobs.pop(name, None)
                    self._keep_audio(name, meta)
                    self._remove_files(name)
                    removed += 1
            self.cleaned = now
        if removed:
            self.log(f"後で受け取る文字起こし: 古い答えを {removed} 個消しました（{self.keep / 86400:.0f} 日より前）")
        return removed

    # MARK: 裏の仕事

    def busy(self) -> bool:
        """今、文字にしている最中か"""
        return self.working is not None

    def pause(self) -> None:
        """次の仕事を始めない（入れ替え・起動し直しの前）。版 8: 待ち合わせで待っている人には、すぐ pending を返す"""
        with self.lock:
            self.paused = True
            self.changed.notify_all()

    def resume(self) -> None:
        with self.lock:
            self.paused = False
            self.changed.notify_all()

    # MARK: 版 8: 待ち合わせ（wait=1）

    def enter_wait(self, name: str) -> None:
        with self.lock:
            self.waiters[name] = self.waiters.get(name, 0) + 1

    def wait_change(self, name: str, timeout: float) -> str:
        """その仕事が終わるか、閉じるところになるか、timeout 秒たつまで待つ。
        "done"（でき上がり・失敗）・"gone"（消された）・"closing"（起動し直す・閉じる）・"waiting" のどれか。"""
        deadline = time.time() + max(0.0, timeout)
        with self.lock:
            while True:
                meta = self.jobs.get(name)
                if meta is None:
                    return "gone"
                if meta.get("status") in ("done", "failed"):
                    return "done"
                if self.paused:
                    return "closing"
                left = deadline - time.time()
                if left <= 0:
                    return "waiting"
                self.changed.wait(min(left, 1.0))

    def leave_wait(self, name: str, handed: bool) -> None:
        """待ち合わせが終わった。handed なら答えを書き終えた（渡した）。
        待っている人がいなくなったとき、そのあいだに終わった仕事がだれにも渡せていなければ、ここで on_done を呼ぶ。"""
        notify = None
        with self.lock:
            left = self.waiters.get(name, 1) - 1
            if left > 0:
                self.waiters[name] = left
            else:
                self.waiters.pop(name, None)
            meta = self.jobs.get(name)
            if handed and meta is not None and not meta.get("handed"):
                meta["handed"] = True
                meta["handed_at"] = round(time.time(), 3)
                _write_json(self.meta_path(name), meta)
                if name in self.held:
                    self.held[name]["handed"] = True
            if left <= 0 and name in self.held:
                finished = self.held.pop(name)
                # 消された（iPhone が受け取って消した）仕事にも知らせない
                if meta is not None and not finished.get("handed") and not meta.get("handed"):
                    notify = finished
            self.changed.notify_all()
        if notify is not None:
            self._call_done(name, notify)

    def wait_waiters(self, timeout: float) -> bool:
        """待ち合わせで待っている人が、みな答え終わるまで待つ（閉じる前）。終われば True。"""
        deadline = time.time() + timeout
        with self.lock:
            while self.waiters:
                left = deadline - time.time()
                if left <= 0:
                    return False
                self.changed.wait(min(left, 0.2))
            return True

    def _call_done(self, name: str, finished: dict) -> None:
        callback = self.on_done
        if callback is None:
            return
        try:
            callback(name, finished)
        except Exception as failure:  # noqa: BLE001
            self.log(f"後で受け取る文字起こし {name}: 終わったことを知らせられませんでした: {failure!r}")

    def wait_idle(self, timeout: float) -> bool:
        """文字にしている最中のものが終わるまで待つ。終われば True。"""
        deadline = time.time() + timeout
        with self.lock:
            while self.working is not None:
                left = deadline - time.time()
                if left <= 0:
                    return False
                self.changed.wait(min(left, 1.0))
            return True

    def start(self) -> None:
        if self.thread is None:
            self.thread = threading.Thread(target=self.loop, name="jobs", daemon=True)
            self.thread.start()

    def next_job(self) -> tuple[str, dict] | None:
        """待っているもののうち、次に文字にするもの（self.lock を持って呼ぶ）。
        版 8: 2つ以上待っていれば、いちばん新しく受けたもの（遅れているときは新しい区切りから。古いものはあとで）"""
        waiting = [m for m in self.jobs.values() if m.get("status") == "queued"]
        if self.paused or not waiting:
            return None
        # 新しい区切りが次々来ても、古いものがずっと後回しにならないよう、15分より長く待ったものは先にする
        oldest = min(waiting, key=lambda m: int(m.get("seq") or 0))
        if time.time() - float(oldest.get("queued_at") or time.time()) > STARVE_AFTER:
            return oldest["id"], oldest
        meta = max(waiting, key=lambda m: int(m.get("seq") or 0))
        return meta["id"], meta

    def loop(self) -> None:
        while True:
            try:
                self.step(wait=60.0)
            except Exception as error:  # noqa: BLE001 — 裏の仕事は止めない
                self.log(f"後で受け取る文字起こしの裏の仕事でつまずきました: {error!r}")
                time.sleep(5)

    def step(self, wait: float = 0.0) -> bool:
        """1つ文字にする。待っているものが無ければ wait 秒まで待つ。文字にしたら True。"""
        if time.time() - self.cleaned > CLEAN_EVERY:
            self.clean()
        with self.lock:
            picked = self.next_job()
            if picked is None and wait > 0:
                self.changed.wait(wait)
                picked = self.next_job()
            if picked is None:
                return False
            name, meta = picked
            seq = meta.get("seq")
            meta["status"] = "working"
            meta["started_at"] = round(time.time(), 3)
            self.working = name
            _write_json(self.meta_path(name), meta)
            params = dict(meta.get("params") or {})
            if int(meta.get("interrupted") or 0) >= CRASH_CPU_ONLY:
                params["cpu_only"] = True  # この仕事で2回止まった。GPU のモデルを使わない（runner が見る。保存はしない）
            audio = self.audio_path(name)
        reply, info, error = None, {}, None
        started = time.time()

        def draft(body: dict) -> bool:
            """版 8: 下書きを残す口（runner が呼ぶ）。残せなくても、文字にするのは続ける"""
            try:
                return self.save_draft(name, seq, body)
            except Exception as failure:  # noqa: BLE001
                self.log(f"後で受け取る文字起こし {name}: 下書きを残せませんでした（このまま多数決をします）: {failure!r}")
                return False

        try:
            if self.runner_drafts:
                reply, info = self.runner(audio, params, name, draft)
            else:
                reply, info = self.runner(audio, params, name)
        except Exception as failure:  # noqa: BLE001 — 1つが失敗しても、次へ進む
            error = str(failure) or repr(failure)
            self.log(f"後で受け取る文字起こし {name}: 文字にできませんでした: {failure!r}")
        with self.lock:
            self.working = None
            current = self.jobs.get(name)
            if current is None or current.get("seq") != seq:
                # 途中で消された（DELETE /jobs/<名前>）。でき上がったものは捨てる
                self.changed.notify_all()
                return True
            current["done_at"] = round(time.time(), 3)
            current["processing_seconds"] = round(time.time() - started, 2)
            for key in ("audio_seconds", "voiced_seconds", "lines"):
                if key in info:
                    current[key] = info[key]
            if error is None and reply is not None:
                try:
                    _write_json(self.result_path(name), reply)
                    current["status"] = "done"
                    current.pop("error", None)
                except OSError as failure:
                    current.update(status="failed", error=f"答えを保存できませんでした: {failure}")
            else:
                current.update(status="failed", error=(error or "文字にできませんでした")[:500])
            if self.keep_audio is None:  # 版 7: 残す先があれば、iPhone が消すまで残す
                _unlink(audio)
            _unlink(self.draft_path(name))  # 版 8: でき上がったら下書きは要らない
            _write_json(self.meta_path(name), current)
            finished = dict(current)
            # 版 8: 待ち合わせで待っている人がいれば、渡せたかが分かるまで知らせるのを預かる（leave_wait が決める）
            waiting = self.waiters.get(name, 0) > 0
            if waiting:
                self.held[name] = finished
            self.changed.notify_all()
        # 版 7（ops）: 終わったことを知らせる（見えない通知など）。失敗しても裏の仕事は止めない
        if not waiting:
            self._call_done(name, finished)
        return True


# MARK: - 受け付け（lifelog_pc.py の Handler から呼ぶ。合言葉は確かめてある）


def wants_wait(query: dict) -> bool:
    return (query.get("wait") or [""])[0] in ("1", "true", "yes")


def wait_and_answer(handler, queue: JobQueue, name: str, entered: bool = False) -> None:
    """版 8: 待ち合わせ（POST /jobs?wait=1）。音声は受け取ってある。
    すぐ 200 と見出しを送り、でき上がるまで WAIT_PING 秒ごとに空白を1文字書く（JSON の前の空白は読み飛ばされる）。
    でき上がったら GET /jobs/<名前> と同じ形を書いて閉じる。WAIT_LIMIT 秒たつか、起動し直す・閉じるときは
    {"id", "status": "pending", "job_status", "timing"} を書いて閉じる（仕事は続ける）。"""
    handler.close_connection = True
    if not entered:
        queue.enter_wait(name)
    handed = False
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.flush()
        deadline = time.time() + WAIT_LIMIT
        state = "waiting"
        while True:
            state = queue.wait_change(name, min(WAIT_PING, max(0.0, deadline - time.time())))
            if state != "waiting" or time.time() >= deadline:
                break
            if peer_gone(handler.connection):
                return  # iPhone が待つのをやめた（あとで見えない通知で知らせる）
            handler.wfile.write(b" ")
            handler.wfile.flush()
        got = queue.get(name) if state == "done" else None
        if got is None:
            current = queue.get(name) or {"id": name, "status": "gone", "timing": {}}
            got = {"id": name, "status": "pending", "job_status": current.get("status"),
                   "timing": current.get("timing") or {}}
        if peer_gone(handler.connection):
            return
        handler.wfile.write(json.dumps(got, ensure_ascii=False).encode("utf-8"))
        handler.wfile.flush()
        if got.get("status") in ("done", "failed"):
            handed = delivered(handler.connection)
    except OSError:
        pass  # 途中で切れた。渡せなかったので、でき上がりの見えない通知で知らせる
    finally:
        queue.leave_wait(name, handed)


def parse_params(query: dict) -> dict:
    """POST /jobs の hints・noisy・enhance・weights（/transcribe と同じ形）"""
    def flag(name: str) -> bool | None:
        values = query.get(name)
        return None if not values else values[0] in ("1", "true", "yes")

    hints = [w.strip() for w in (query.get("hints") or [""])[0].split("\n") if w.strip()][:80]
    weights = (query.get("weights") or [None])[0]
    return {"hints": hints, "noisy": bool(flag("noisy")), "enhance": flag("enhance"),
            "weights": weights[:2000] if weights else None}


def http_post(handler, queue: JobQueue | None, query_text: str, length: int, origin: str | None = None) -> str | None:
    """POST /jobs（と、版 10 の時計の外の道の POST /w/jobs）。答えは送ってから、どうなったかを返す:
    "stored"（預かった）・"exists"（同じ名前をもう預かっている）・None（断った・失敗した）。
    origin="watch" のとき: 待ち合わせ（wait）はしない・WATCH_BODY_LIMIT まで・名前は WATCH_NAME の形だけ。"""
    from urllib.parse import parse_qs

    watch = origin == "watch"
    limit = WATCH_BODY_LIMIT if watch else BODY_LIMIT
    if queue is None:
        handler.discard_body()
        handler.send_json(503, {"error": "後で受け取る文字起こしは今は使えません"})
        return None
    query = parse_qs(query_text)
    name = (query.get("name") or [""])[0]
    if not valid_name(name):
        handler.discard_body()
        handler.send_json(400, {"error": "name は英数字と . _ - だけで 80 文字までです"})
        return None
    if watch and WATCH_NAME.fullmatch(name) is None:
        handler.discard_body()
        handler.send_json(400, {"error": "name は 年月日-時分秒…-w.m4a の形だけです"})
        return None
    if length <= 0 or length > limit:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413,
                          {"error": "音声がありません" if length <= 0
                           else f"音声が大きすぎます（{'8MB' if watch else '200MB'} まで）"})
        return None
    # 版 10: 時計の外の道では待ち合わせをしない（時計は答えを待たない。文字は iPhone が取りに来る）
    wait = wants_wait(query) and not watch
    state, current = queue.begin(name)
    if state == "exists":
        # 同じ名前はもう預かっている（失敗したものだけ預かり直す）。送られた音声は読み捨てる
        handler.discard_body()
        # 版 8: 待ち合わせなら、預かっている仕事のでき上がりを待って答える（受け取り途中のものは今までどおり）
        if wait and (queue.jobs.get(name) or {}).get("status") in ("queued", "working", "done"):
            wait_and_answer(handler, queue, name)
            return "exists"
        handler.send_json(200, current)
        return "exists"
    if state == "full":
        handler.discard_body()
        handler.send_json(503, {"error": f"待っているものが多すぎます（{queue.limit} 個まで）。少し待ってから送ってください"})
        return None
    entered = False
    try:
        left = length
        with queue.part_path(name).open("wb") as f:
            while left > 0:
                chunk = handler.rfile.read(min(left, 1 << 20))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        if left > 0:
            queue.abort(name)
            handler.close_connection = True
            handler.send_json(400, {"error": "音声が途中で切れました"})
            return None
        if wait:
            # 預けてすぐ終わっても「待っている人がいる」と分かるよう、預ける前から待ち合わせに入る
            queue.enter_wait(name)
            entered = True
        reply = queue.commit(name, parse_params(query), length, parse_times(query), origin=origin)
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        if entered:
            queue.leave_wait(name, False)
        queue.abort(name)
        queue.log(f"後で受け取る文字起こし {name}: 預かれませんでした: {error!r}")
        handler.close_connection = True
        handler.send_json(500, {"error": f"預かれませんでした: {error}"})
        return None
    if wait:
        wait_and_answer(handler, queue, name, entered=True)
        return "stored"
    handler.send_json(200, reply)
    return "stored"


def _name_from(path: str) -> str:
    from urllib.parse import unquote

    return unquote(path[len("/jobs/"):])


def http_get(handler, queue: JobQueue | None, path: str, query_text: str = "") -> None:
    from urllib.parse import parse_qs

    if queue is None:
        handler.send_json(503, {"error": "後で受け取る文字起こしは今は使えません"})
        return
    if path == "/jobs":
        # 版 10: GET /jobs?origin=watch は、時計の外の道から預かった仕事だけ（新しい順）
        origin = (parse_qs(query_text).get("origin") or [None])[0]
        handler.send_json(200, {"jobs": queue.listing(origin=origin or None)})
        return
    name = _name_from(path)
    got = queue.get(name) if valid_name(name) else None
    if got is None:
        handler.send_json(404, {"error": "その名前のものは預かっていません", "id": name})
        return
    handler.send_json(200, got)


def http_delete(handler, queue: JobQueue | None, path: str) -> None:
    if queue is None:
        handler.send_json(503, {"error": "後で受け取る文字起こしは今は使えません"})
        return
    name = _name_from(path)
    if not valid_name(name) or not queue.delete(name):
        handler.send_json(404, {"error": "その名前のものは預かっていません", "id": name})
        return
    handler.send_json(200, {"id": name, "deleted": True})
