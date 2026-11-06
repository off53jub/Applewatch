"""LifeLog PC 版 6: 後で受け取る文字起こし（POST /jobs・GET /jobs・GET /jobs/<名前>・DELETE /jobs/<名前>）。

iPhone は録音の区切りを1つずつ裏で送っておき、PC が文字にし終えたころに答えを取りに来る。
- 区切りの名前（iPhone のファイルの名前）で見分ける。同じ名前が来たら、失敗したものだけを入れ直す。
- 1つずつ、来た順に文字にする（裏の仕事は1本だけ）。
- 受けた音声と状態は <home>/jobs/ に置くので、PC を起動し直しても続きから文字にする。
- 音声は、文字にし終えたら（失敗しても）すぐ消す。答えは、でき上がってから 7 日で消す。
ここには文字にする仕組みは無い。lifelog_pc.py が渡す runner(音声のファイル, 頼まれた設定, 名前) が文字にする。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable

NAME = re.compile(r"[0-9A-Za-z._-]{1,80}")
QUEUE_LIMIT = 500            # 待っている（queued・working）ものがこれだけあれば、断る（503）
LIST_LIMIT = 500             # GET /jobs で返す数の上限
BODY_LIMIT = 200_000_000     # 音声の大きさの上限（200MB）
KEEP_SECONDS = 7 * 86400     # でき上がった答えを残しておく長さ
CLEAN_EVERY = 3600.0         # 古い答えを消すのを確かめる間（秒）


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


class QueueFull(RuntimeError):
    """待っているものが多すぎる"""


class JobQueue:
    """区切りごとの仕事を、来た順に1つずつ文字にする。"""

    def __init__(self, folder: Path, runner: Callable[[Path, dict, str], tuple[dict, dict]],
                 log: Callable[[str], None], limit: int = QUEUE_LIMIT, keep: float = KEEP_SECONDS) -> None:
        self.folder = Path(folder)
        self.runner = runner
        self.log = log
        self.limit = limit
        self.keep = keep
        self.jobs: dict[str, dict] = {}
        self.receiving: set[str] = set()
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.paused = False
        self.working: str | None = None
        self.seq = 0
        self.cleaned = 0.0
        self.thread: threading.Thread | None = None
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
                meta["status"] = "queued"
                meta.pop("started_at", None)
                self.log(f"後で受け取る文字起こし {name}: 途中で止まっていたので、もう一度文字にします")
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
            if meta.get("status") in ("done", "failed"):
                _unlink(self.audio_path(name))

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

    def commit(self, name: str, params: dict, size: int) -> dict:
        """受け取った音声を待ちの最後に加える。失敗していた同じ名前のものは置き換える。"""
        with self.lock:
            self.receiving.discard(name)
            os.replace(self.part_path(name), self.audio_path(name))
            _unlink(self.result_path(name))
            self.seq += 1
            meta = {"id": name, "status": "queued", "queued_at": round(time.time(), 3), "done_at": None,
                    "seq": self.seq, "params": params, "size": int(size)}
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
        if short:
            return {"id": meta["id"], "status": meta["status"]}
        out = {"id": meta["id"], "status": meta["status"], "queued_at": meta.get("queued_at"),
               "done_at": meta.get("done_at")}
        if meta.get("status") == "failed":
            out["error"] = meta.get("error") or "文字にできませんでした"
        return out

    def get(self, name: str) -> dict | None:
        """GET /jobs/<名前> の答え。知らない名前なら None。"""
        with self.lock:
            meta = self.jobs.get(name)
            if meta is None:
                return None
            out = self.public(meta)
            if meta.get("status") != "done":
                return out
            path = self.result_path(name)
        try:
            out["result"] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            out.update(status="failed", error="答えのファイルを読めませんでした")
        return out

    def listing(self, limit: int = LIST_LIMIT) -> list[dict]:
        """新しい順に、最大 limit 個"""
        with self.lock:
            metas = sorted(self.jobs.values(), key=lambda m: int(m.get("seq") or 0), reverse=True)[:limit]
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
        """その仕事のもの（音声・答え・状態）を全部消す。文字にしている途中なら、でき上がった答えは捨てる。"""
        with self.lock:
            if self.jobs.pop(name, None) is None:
                return False
            self._remove_files(name)
            return True

    def _remove_files(self, name: str) -> None:
        for path in (self.meta_path(name), self.audio_path(name), self.result_path(name)):
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
        """次の仕事を始めない（入れ替え・起動し直しの前）"""
        with self.lock:
            self.paused = True

    def resume(self) -> None:
        with self.lock:
            self.paused = False
            self.changed.notify_all()

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
        """待っているもののうち、いちばん早く来たもの（self.lock を持って呼ぶ）"""
        waiting = [m for m in self.jobs.values() if m.get("status") == "queued"]
        if self.paused or not waiting:
            return None
        meta = min(waiting, key=lambda m: int(m.get("seq") or 0))
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
            audio = self.audio_path(name)
        reply, info, error = None, {}, None
        started = time.time()
        try:
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
            _unlink(audio)
            _write_json(self.meta_path(name), current)
            self.changed.notify_all()
        return True


# MARK: - 受け付け（lifelog_pc.py の Handler から呼ぶ。合言葉は確かめてある）


def parse_params(query: dict) -> dict:
    """POST /jobs の hints・noisy・enhance・weights（/transcribe と同じ形）"""
    def flag(name: str) -> bool | None:
        values = query.get(name)
        return None if not values else values[0] in ("1", "true", "yes")

    hints = [w.strip() for w in (query.get("hints") or [""])[0].split("\n") if w.strip()][:80]
    weights = (query.get("weights") or [None])[0]
    return {"hints": hints, "noisy": bool(flag("noisy")), "enhance": flag("enhance"),
            "weights": weights[:2000] if weights else None}


def http_post(handler, queue: JobQueue | None, query_text: str, length: int) -> None:
    from urllib.parse import parse_qs

    if queue is None:
        handler.discard_body()
        handler.send_json(503, {"error": "後で受け取る文字起こしは今は使えません"})
        return
    query = parse_qs(query_text)
    name = (query.get("name") or [""])[0]
    if not valid_name(name):
        handler.discard_body()
        handler.send_json(400, {"error": "name は英数字と . _ - だけで 80 文字までです"})
        return
    if length <= 0 or length > BODY_LIMIT:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413,
                          {"error": "音声がありません" if length <= 0 else "音声が大きすぎます（200MB まで）"})
        return
    state, current = queue.begin(name)
    if state == "exists":
        # 同じ名前はもう預かっている（失敗したものだけ預かり直す）。送られた音声は読み捨てる
        handler.discard_body()
        handler.send_json(200, current)
        return
    if state == "full":
        handler.discard_body()
        handler.send_json(503, {"error": f"待っているものが多すぎます（{queue.limit} 個まで）。少し待ってから送ってください"})
        return
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
            return
        reply = queue.commit(name, parse_params(query), length)
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        queue.abort(name)
        queue.log(f"後で受け取る文字起こし {name}: 預かれませんでした: {error!r}")
        handler.close_connection = True
        handler.send_json(500, {"error": f"預かれませんでした: {error}"})
        return
    handler.send_json(200, reply)


def _name_from(path: str) -> str:
    from urllib.parse import unquote

    return unquote(path[len("/jobs/"):])


def http_get(handler, queue: JobQueue | None, path: str) -> None:
    if queue is None:
        handler.send_json(503, {"error": "後で受け取る文字起こしは今は使えません"})
        return
    if path == "/jobs":
        handler.send_json(200, {"jobs": queue.listing()})
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
