"""LifeLog PC: s23（2026-11-23）の家の PC の分をまとめてつなぐ所。担当の案は 続1〜続4・続8・続10・試4・届7・止1/続5 の受け口。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s22pc.start のあと）と FEATURES・GETS・POSTS・http_get・http_post。
summary.md の「## s23 の数」の節は ops.write_summary が summary_lines(...) で足す。0 円・言語モデルの呼び出しは足さない。

つなぐ口（start で入れる。どれも無ければ今までどおり）:
- 確かめ待ち（GET /review-queue）に、続1「この 2 つの声は同じ人ですか」（vp-）と続3「騒がしい所の声の正しい文」（gn-）を足す
  （s20feeds.REVIEW_EXTRA を包む。s22 の分のあと・合わせて PC_LIMIT 個まで）。答え（POST /feedback の kind review）は
  appfeeds.REVIEW_HOOK を包んで受ける（gn- は正解集の材料に足す。vp- は母艦の答えの行をあとで読むだけ。ほかは s22 の受け口へ）
- 続5: POST /headcount（会話のあとに本人が答えた人数）を HOME/s23/headcount.jsonl に。s22 確6 の人数に足す（s22voice.EXTRA_HEADCOUNTS）
見回り（1 分ごと）:
- 30 分ごと（軽い）: 確かめ待ちを作り直す（昨日の分）・届7 の日ごとの録れた時間と版（3 日）
- 01:00〜05:00 に 1 回（新しい区切りが待っていないとき）: 続4 抜けの段（昨日〜3 日前）・続10 s-norm の答え合わせ・続1 の影（オンのときだけ）
- 00:00〜05:00: 続1 の影のモデルのファイルを取る（オンのときだけ。s22models の決まり）
- 試4: 家の PC の版（BUILD）が前に確かめた版と違えば、起きてから 10 分たって新しい区切りが待っていないときに 1 回、s22 で
  「本物の PC ではまだ動かしていない」7 つを呼んで HOME/s23/checks.json に（GET /s23/checks・summary.md）

config.json（どれも書かなければ下の既定）:
- "speaker_shadow": "wespeaker34"（続1 の影。既定は無し＝オフ。切り替えはしない。両方の点を並べるだけ）
- "voice_pairs": false（続1 の問いを出さない）・"noisy_gold": false（続3 の問いを出さない）・"s23_checks": false（試4 をしない）
"""

from __future__ import annotations

import datetime
import io
import json
import os
import threading
import time
from pathlib import Path

import jobfirst
import quality
import s22models
import s23gaps
import s23gold
import s23voice

FEATURES = ["headcount", "s23checks", "voicepairs", "noisygold"]
GETS = ("/s23/checks",)
POSTS = ("/headcount",)
TICK = 60.0
FIRST_WAIT = 200.0
LIGHT_EVERY = 1800.0
CHECK_AFTER = 600.0       # 試4: 起きてからこれだけ待つ
PC_LIMIT = 4              # 確かめ待ちに足す s23 の問いの数
SHADOW_BUDGET = 600.0     # 続1 の影: 1 晩の上限（秒）
HEADCOUNT_MAX = 30
BODY_LIMIT = 4096


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    started = 0.0
    next_light = 0.0
    night_day: str | None = None
    lock = threading.Lock()
    last: dict = {}


def _config() -> dict:
    try:
        return S.main.load_config() or {}
    except Exception:  # noqa: BLE001
        return {}


def _base() -> Path | None:
    try:
        base = S.main.mothership.home(_config())
        return base if base is not None and Path(base).is_dir() else None
    except Exception:  # noqa: BLE001
        return None


def _store():
    return getattr(getattr(S.main, "App", None), "records", None)


def _log(text: str) -> None:
    try:
        S.main.log(text)
    except Exception:  # noqa: BLE001
        pass


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _days(today: datetime.date, count: int) -> list[str]:
    return [(today - datetime.timedelta(days=i)).isoformat() for i in range(count)][::-1]


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    S.started = time.time()
    try:
        import appfeeds

        before = appfeeds.REVIEW_HOOK

        def hook(row: dict, before=before):
            got = review_hook(row)
            if got is not None:
                return got
            return before(row) if before is not None else None

        appfeeds.REVIEW_HOOK = hook
    except Exception:  # noqa: BLE001
        pass
    try:
        import s20feeds

        extra = s20feeds.REVIEW_EXTRA

        def merged(body, base, extra=extra):
            body = extra(body, base) if extra is not None else body
            return merge_review(body, base, S.home)

        s20feeds.REVIEW_EXTRA = merged
    except Exception:  # noqa: BLE001
        pass
    try:
        import s22voice

        s22voice.EXTRA_HEADCOUNTS = lambda day: headcount_rows(S.home, day)
    except Exception:  # noqa: BLE001
        pass
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s23", daemon=True)
        S.thread.start()


def _loop() -> None:
    time.sleep(FIRST_WAIT)
    failed_at = 0.0
    while True:
        try:
            tick()
        except Exception as error:  # noqa: BLE001 — 裏の仕事が止まっても、受け付けは続ける
            if time.time() - failed_at > 3600:
                failed_at = time.time()
                _log(f"s23 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def tick(moment: datetime.datetime | None = None) -> dict:
    """1 分ごとの見回り。したことの名前を返す（確かめ用）"""
    moment = moment or datetime.datetime.now()
    now = time.time()
    config = _config()
    home, store, base = S.home, _store(), _base()
    done: dict = {}
    if home is None:
        return done
    busy = jobfirst.busy()
    if now >= S.next_light:
        S.next_light = now + LIGHT_EVERY
        done["light"] = light(home, store, base, config, moment.date())
    shadow = shadow_model(config)
    if shadow and s22models.download_window(moment) and not busy:
        got = s22models.fetch_missing(home, {"speaker_model": shadow}, S.main.fetch, S.main.log, moment)
        if got:
            done["shadow_model"] = got
    day = moment.date().isoformat()
    if 1 <= moment.hour < 5 and S.night_day != day and not busy:
        S.night_day = day
        done["night"] = night(home, store, base, config, moment.date())
    if config.get("s23_checks") is not False and not busy and now - S.started >= CHECK_AFTER and checks_due(home, _build()):
        done["checks"] = run_checks(home, store, base, config)
    return done


def _build() -> str:
    try:
        return str(S.main.BUILD)
    except Exception:  # noqa: BLE001
        return "0"


def light(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    try:
        out["review"] = build_review(home, store, base, config, today)
    except Exception as error:  # noqa: BLE001
        out["review"] = type(error).__name__
    try:
        out["recorded"] = recorded_days(home, today)
    except Exception as error:  # noqa: BLE001
        out["recorded"] = type(error).__name__
    S.last["light"] = out
    return out


def night(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    yesterday = (today - datetime.timedelta(days=1)).isoformat()
    for back in (1, 2, 3):   # PLAUD は遅れて届くので 3 日前まで数え直す
        day = (today - datetime.timedelta(days=back)).isoformat()
        try:
            novoice = s23gaps.diag_day(Path(home) / "diag", day)["novoice"]
            got = s23gaps.miss_stages(home, base, day, novoice or 0)
            if got is not None:
                quality.update_day(home, day, {"plaud_miss_stages": got})
            out[f"miss {day}"] = None if got is None else got["blocks"]
        except Exception as error:  # noqa: BLE001
            out[f"miss {day}"] = type(error).__name__
    try:
        check = s23voice.snorm_check(home, base)
        quality.update_day(home, yesterday, check)
        out["snorm"] = check
    except Exception as error:  # noqa: BLE001
        out["snorm"] = type(error).__name__
    if shadow_model(config):
        try:
            out["shadow"] = run_shadow(home, store, base, config, yesterday)
        except Exception as error:  # noqa: BLE001
            out["shadow"] = type(error).__name__
    _log("s23 の夜の数: " + "・".join(f"{k} {v if not isinstance(v, dict) else len(v)}" for k, v in out.items()))
    S.last["night"] = out
    return out


# MARK: - 確かめ待ち（続1・続3）


def build_review(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    yesterday = (today - datetime.timedelta(days=1)).isoformat()
    parsed = store.day(yesterday) if store is not None else None
    items = s23voice.make_pair_items(home, parsed, yesterday, base, config, today)
    levels = (_read(Path(home) / "s22" / "levels" / f"{yesterday}.json", {}) or {}).get("chunks") or {}
    answered = _answered(base)
    find = getattr(quality, "find_audio", None)
    items += s23gold.update(home, parsed, yesterday, levels, config, answered, job_scenes(home, yesterday),
                            (lambda name: find(name) is not None) if find else (lambda name: True), today)
    items = [i for i in items if i.get("id") not in answered]
    _write(s23voice.folder(home) / "items.json", {"version": 1, "generated_at": datetime.datetime.now().astimezone()
                                                  .isoformat(timespec="seconds"), "items": items})
    counts: dict[str, int] = {}
    for item in items:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    return counts


def _answered(base: Path | None) -> set[str]:
    try:
        import s22feeds

        return s22feeds.answered_ids(base)
    except Exception:  # noqa: BLE001
        return set()


def job_scenes(home: Path, day: str) -> dict[str, str]:
    """POST /jobs の scene（s22 確22）を区切りの名前ごとに（その日の分だけ）"""
    out = {}
    stamp = day.replace("-", "")
    for path in (Path(home) / "jobs").glob("*.json"):
        meta = _read(path, {}) or {}
        name = str(meta.get("id") or "")
        scene = (meta.get("params") or {}).get("scene") if isinstance(meta.get("params"), dict) else None
        if name.startswith(stamp) and isinstance(scene, str):
            out[name] = scene
    return out


def merge_review(body: dict, base: Path | None, home: Path | None) -> dict:
    """GET /review-queue の答えに s23 の問いを足す（答えたものは出さない）"""
    extra = ((_read(s23voice.folder(home) / "items.json", {}) or {}).get("items") or []) if home is not None else []
    extra = [i for i in extra if isinstance(i, dict)]
    if not extra:
        return body
    if not isinstance(body, dict) or not body.get("available"):
        body = {"available": True, "version": 1, "items": []}
    items = list(body.get("items") or [])
    seen = {i.get("id") for i in items if isinstance(i, dict)} | _answered(base)
    added = 0
    for item in extra:
        if added >= PC_LIMIT or item.get("id") in seen:
            continue
        items.append(item)
        seen.add(item.get("id"))
        added += 1
    return {**body, "items": items}


def review_hook(row: dict) -> dict | None:
    """s23 の問いの答え（gn- は正解集に足す・vp- は母艦の答えの行を夜に読むので、ここでは {"changed": 0}）。ほかは None"""
    key = str(row.get("id") or "")
    if S.home is None:
        return None
    if key.startswith("vp-"):
        return {"changed": 0}
    if key.startswith("gn-"):
        main = S.main
        return s23gold.take_answer(S.home, row, quality.find_audio, main.load_audio, main.save_sample, main.PERSONAL_DATA, _log)
    return None


# MARK: - 続5 人数の答え


def parse_headcount(data: bytes, now: datetime.datetime | None = None) -> dict:
    """POST /headcount の中身 → 置く行。おかしければ ValueError（文は日本語）"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("JSON の形が違います")
    count = body.get("count")
    if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= HEADCOUNT_MAX:
        raise ValueError(f"count は 1〜{HEADCOUNT_MAX} の数です")
    start = body.get("start")
    if isinstance(start, (int, float)) and not isinstance(start, bool):
        moment = datetime.datetime.fromtimestamp(float(start) / 1000).astimezone()
    elif isinstance(start, str):
        try:
            moment = datetime.datetime.fromisoformat(start.replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError("start は会話の始まりの時刻（ISO かミリ秒）です") from error
        if moment.tzinfo is None:
            moment = moment.astimezone()
    else:
        raise ValueError("start（会話の始まりの時刻）がありません")
    day = moment.astimezone().date().isoformat()
    if body.get("day") not in (None, day):
        raise ValueError("day と start の日が合いません")
    row = {"day": day, "start": moment.isoformat(timespec="seconds"), "count": count,
           "at": (now or datetime.datetime.now()).astimezone().isoformat(timespec="seconds")}
    if body.get("orMore") is True:
        row["orMore"] = True
    conversation = body.get("conversation")
    if isinstance(conversation, str) and 0 < len(conversation) <= 40:
        row["conversation"] = conversation
    return row


def headcount_rows(home: Path | None, day: str) -> list[dict]:
    """s22 確6 に渡す行（その日・「N 人以上」は数が決まらないので渡さない）。同じ会話はあとの答えが勝つ"""
    if home is None:
        return []
    try:
        raw = (Path(home) / "s23" / "headcount.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    by_start: dict[str, dict] = {}
    for line in raw:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("day") == day and isinstance(row.get("count"), int):
            by_start[str(row.get("start"))] = row
    return [{"day": r["day"], "start": r["start"], "count": r["count"]} for r in by_start.values() if not r.get("orMore")]


def http_post(handler, path: str) -> None:
    """POST /headcount（認証は呼ぶ側が済ませてから）"""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > BODY_LIMIT:
        if hasattr(handler, "discard_body"):
            handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    try:
        row = parse_headcount(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    target = Path(S.home) / "s23" / "headcount.jsonl"
    with S.lock:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as out:
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
    _log(f"{handler.client_address[0]} から /headcount: {row['day']} の会話の人数 {row['count']}" + ("（以上）" if row.get("orMore") else ""))
    handler.send_json(200, {"ok": True, "day": row["day"], "count": row["count"]})


# MARK: - 届7


def recorded_days(home: Path, today: datetime.date, days: int = 3) -> dict:
    """直近 days 日（今日まで）の録れた時間と版を quality-daily.json に置く。家の PC の版は、その日にまだ無ければ今の版"""
    daily = quality.read_daily(home)["days"]
    out = {}
    for day in _days(today, days):
        got = s23gaps.diag_day(Path(home) / "diag", day)
        chunks = s23gaps.chunk_spans(Path(home) / "jobs", day)
        if not chunks and got["watch_recorded_s"] is None:
            continue
        minutes = s23gaps.recorded_minutes(chunks, got["watch_recorded_s"])
        old = (daily.get(day) or {}).get("builds") or {}
        pc = old.get("pc") if day < today.isoformat() and old.get("pc") else _build()
        builds = {"app": got["app"] or old.get("app"), "watch": got["watch"] or old.get("watch"), "pc": pc}
        quality.update_day(home, day, {"recorded_min": minutes, "builds": builds})
        out[day] = minutes
    return out


# MARK: - 続1 影で並べる


def shadow_model(config: dict) -> str | None:
    name = (config or {}).get("speaker_shadow")
    return name if isinstance(name, str) and name in s22models.SPEAKERS and s22models.SPEAKERS[name]["url"] else None


def _extractor(path: Path):
    import sherpa_onnx

    return sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(path), num_threads=1, provider="cpu"))


def run_shadow(home: Path, store, base: Path | None, config: dict, day: str) -> dict | None:
    """今のモデルと影のモデルの両方で、答えのある時計の声の組と、その日の組の点を出す（切り替えはしない）"""
    import numpy as np

    name = shadow_model(config)
    entry = s22models.SPEAKERS.get(name or "")
    shadow_path = Path(home) / "speaker" / str((entry or {}).get("file"))
    now_path = Path(home) / "speaker" / s22models.SPEAKERS["campplus"]["file"]
    if not name or not shadow_path.is_file() or not now_path.is_file():
        return None
    deadline = time.time() + SHADOW_BUDGET
    audio_cache: dict = {}

    def maker(extractor):
        cache: dict = {}

        def vec(sample):
            key = (sample["audio"], round(sample["start"], 2), round(sample["end"], 2))
            if key in cache:
                return cache[key]
            cache[key] = None
            if time.time() > deadline:
                return None
            if sample["audio"] not in audio_cache:
                found = quality.find_audio(sample["audio"])
                try:
                    audio_cache[sample["audio"]] = S.main.load_audio(found.read_bytes()) if found else None
                except Exception:  # noqa: BLE001
                    audio_cache[sample["audio"]] = None
                if len(audio_cache) > 120:
                    audio_cache.pop(next(iter(audio_cache)))
            audio = audio_cache.get(sample["audio"])
            if audio is None:
                return None
            rate = S.main.RATE
            piece = audio[int(sample["start"] * rate):int(sample["end"] * rate)]
            if len(piece) <= rate // 2:
                return None
            stream = extractor.create_stream()
            stream.accept_waveform(rate, piece)
            stream.input_finished()
            if not extractor.is_ready(stream):
                return None
            v = np.asarray(extractor.compute(stream), np.float64)
            n = float(np.linalg.norm(v))
            cache[key] = v / n if n > 0 else None
            return cache[key]
        return vec

    pairs = s23voice.watch_pairs(home, base)
    parsed = store.day(day) if store is not None else None
    cohort = s23voice.cohort_from([parsed] if parsed else [], 150)
    groups = [{"id": gid, "same": False, "people": [p for p in g["people"] if p]}
              for gid, g in s23voice.groups_with_samples(home).items() if g.get("day") == day]
    groups = [g for g in groups if len(g["people"]) >= 2][:40]
    out = {"model": name, "day": day}
    for label, path in (("now", now_path), ("shadow", shadow_path)):
        vec = maker(_extractor(path))
        answered = s23voice.pair_scores(vec, pairs, cohort)
        day_groups = s23voice.pair_scores(vec, groups, cohort)
        out[label] = {"pairs": answered["pairs"], "auc_raw": answered["auc_raw"], "auc_snorm": answered["auc_snorm"],
                      "groups": day_groups["pairs"], "scores": {s["id"]: s["raw"] for s in day_groups["scored"]}}
    body = {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "note": "s23 続1。影のモデルの点（切り替えていない）。scores は組の id → 日の平均を引いた真ん中の近さ", **out}
    _write(Path(home) / "s23" / "shadow" / f"{day}.json", body)
    summary = {"model": name, "pairs": out["shadow"]["pairs"], "groups": out["shadow"]["groups"],
               "auc_now": out["now"]["auc_raw"], "auc_shadow": out["shadow"]["auc_raw"],
               "auc_now_snorm": out["now"]["auc_snorm"], "auc_shadow_snorm": out["shadow"]["auc_snorm"]}
    quality.update_day(home, day, {"speaker_shadow": summary})
    return summary


# MARK: - 試4 新しい版の最初の空き時間に 7 つを 1 回ずつ


class _Fake:
    """受け口の代わり（中で呼んで、返したものを覚える）"""
    client_address = ("127.0.0.1", 0)

    def __init__(self) -> None:
        self.status = None
        self.body = None
        self.wfile = io.BytesIO()

    def send_json(self, status: int, body) -> None:
        self.status, self.body = status, body

    def send_response(self, status: int) -> None:
        self.status = status

    def send_header(self, *_args) -> None:
        pass

    def end_headers(self) -> None:
        pass


def checks_due(home: Path, build: str) -> bool:
    body = _read(Path(home) / "s23" / "checks.json", {}) or {}
    return build not in ("", "0") and str(body.get("build")) != build


def _record_lines(store, days: list[str]) -> list[dict]:
    rows = []
    for day in days:
        try:
            body = json.loads(store.path(day).read_text(encoding="utf-8"))
        except (OSError, ValueError, AttributeError):
            continue
        for conversation in body.get("conversations") or []:
            for line in (conversation.get("lines") or []) if isinstance(conversation, dict) else []:
                if isinstance(line, dict):
                    rows.append(line)
    return rows


def run_checks(home: Path, store, base: Path | None, config: dict, today: datetime.date | None = None) -> dict:
    """s22 で「本物の PC ではまだ動かしていない」7 つ。{"build","at","results": [{"name","ok","note"}]}。
    ok は True（動いた）・False（動かない）・None（材料待ち）。記録・答えは変えない（読むだけ・中で呼ぶだけ）"""
    import s22feeds

    today = today or datetime.date.today()
    results = []

    def add(name: str, ok, note: str) -> None:
        results.append({"name": name, "ok": ok, "note": note})

    for path, name in (("/reports", "報告の棚 /reports（楽5）"), ("/capture-gap-patterns", "/capture-gap-patterns（楽20）")):
        fake = _Fake()
        try:
            s22feeds.http_get(fake, path, "", base, home, lambda _m: None)
            body = fake.body if isinstance(fake.body, dict) else {}
            if path == "/reports":
                count = len(body.get("reports") or [])
                add(name, fake.status == 200, f"返事 {fake.status}・報告 {count} 件" + ("（母艦の allow が空）" if not count else ""))
            else:
                add(name, (True if body.get("available") is not False else None) if fake.status == 200 else False,
                    f"返事 {fake.status}" + ("・表あり" if body.get("available") is not False else "・母艦に表が無い"))
        except Exception as error:  # noqa: BLE001
            add(name, False, f"呼べませんでした: {type(error).__name__}")
    items = (_read(Path(home) / "same-person" / "snorm.json", {}) or {}).get("items") or {}
    scored = sum(1 for v in items.values() if isinstance(v, dict) and isinstance(v.get("snorm"), (int, float)))
    add("同じ人かの点 s-norm（確1）", scored > 0 if items else None, f"組 {len(items)}・点あり {scored}")
    lines = _record_lines(store, _days(today, 2)) if store is not None else []
    for key, name in (("conf", "行ごとの確かさ conf（確18）"), ("norm", "表記のゆれ norm（確20）")):
        has = sum(1 for line in lines if key in line)
        add(name, (has > 0) if lines else None, f"今日と昨日の行 {len(lines)} のうち {key} あり {has}")
    rec = _read(Path(home) / "s22" / "rec-exp.json", None)
    if rec is None:
        add("録り方の実験の数（確24）", None, "rec-exp.json がまだ無い（30 分ごとの見回りのあと）")
    else:
        add("録り方の実験の数（確24）", True if rec.get("days") else None,
            f"日 {len(rec.get('days') or {})}" + ("" if rec.get("days") else "（アプリの入れ替えがオフなので数えるものが無い）"))
    try:
        import appfeeds

        hooked = appfeeds.REVIEW_HOOK is not None
    except Exception:  # noqa: BLE001
        hooked = False
    spread_items = [i for i in (_read(Path(home) / "s22" / "review" / "items.json", {}) or {}).get("items") or []
                    if isinstance(i, dict) and i.get("kind") == "speaker_line"]
    try:
        expanded = len((Path(base) / "inbox" / "review_expanded.jsonl").read_text(encoding="utf-8").splitlines()) if base else 0
    except OSError:
        expanded = 0
    add("答えの広げ（確27）", False if not hooked else (True if expanded else None),
        f"受け口 {'つながっている' if hooked else 'つながっていない'}・問い {len(spread_items)}・広げた答え {expanded}"
        + ("" if expanded else "（答えを待っています）"))
    body = {"build": _build(), "at": datetime.datetime.now().isoformat(timespec="seconds"), "results": results}
    _write(Path(home) / "s23" / "checks.json", body)
    _log("s22 の 7 つの確かめ（試4）: " + "・".join(f"{r['name'].split('（')[0]} {'○' if r['ok'] else '×' if r['ok'] is False else '待ち'}"
                                                 for r in results))
    return body


def http_get(handler, path: str, query: str) -> None:
    """GET /s23/checks（認証は呼ぶ側が済ませてから）"""
    body = _read(Path(S.home) / "s23" / "checks.json", None) if S.home is not None else None
    handler.send_json(200, body if isinstance(body, dict) else {"available": False, "reason": "まだ確かめていません"})


# MARK: - summary.md


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    """(気になる所の行, 「## s23 の数」の節の行)。ops.write_summary が呼ぶ"""
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    lines: list[str] = []
    worries: list[str] = []
    daily = quality.read_daily(home)["days"]

    def checks_line():
        body = _read(Path(home) / "s23" / "checks.json", None)
        if not isinstance(body, dict):
            return "s22 の 7 つの確かめ（試4）: まだ（家の PC が新しい版になって、最初の空き時間に 1 回）"
        marks = "・".join(f"{r['name']} {'動いた' if r['ok'] else '動かない' if r['ok'] is False else '材料待ち'}（{r['note']}）"
                          for r in body.get("results") or [])
        return f"s22 の 7 つの確かめ（試4・版 {body.get('build')}・{str(body.get('at'))[5:16].replace('T', ' ')}）: {marks}"

    def recorded_line():
        parts = []
        for day in _days(today, 4):
            entry = daily.get(day) or {}
            minutes, builds = entry.get("recorded_min"), entry.get("builds") or {}
            if isinstance(minutes, dict):
                parts.append(f"{day[5:]} 時計 {minutes.get('watch', 0):.0f} 分・iPhone {minutes.get('phone', 0):.0f} 分"
                             f"（版 アプリ {builds.get('app') or '—'}・時計 {builds.get('watch') or '—'}・PC {builds.get('pc') or '—'}）")
        return "1 日に録れた時間と版（届7）: " + " / ".join(parts) if parts else None

    def stages_line():
        return s23gaps.stage_line({d: e.get("plaud_miss_stages") for d, e in daily.items()
                                   if isinstance(e, dict) and isinstance(e.get("plaud_miss_stages"), dict)})

    def snorm_line():
        days = [d for d in _days(today, 4) if isinstance((daily.get(d) or {}).get("snorm_pairs"), int)]
        if not days:
            return None
        e = daily[days[-1]]
        fmt = lambda v: "—（組が少ない）" if v is None else f"{v:.2f}"  # noqa: E731
        return (f"同じ人かの点の答え合わせ（続10・{days[-1][5:]}）: 答えのある組 {e.get('snorm_pairs')}（同じ人 {e.get('snorm_same')}）で "
                f"s-norm の AUC {fmt(e.get('snorm_auc'))}・今の点の AUC {fmt(e.get('raw_auc'))}（{e.get('raw_pairs')} 組）")

    def shadow_line():
        name = shadow_model(_config())
        rows = [(d, (daily.get(d) or {}).get("speaker_shadow")) for d in _days(today, 4)]
        rows = [(d, e) for d, e in rows if isinstance(e, dict)]
        if not name and not rows:
            return "話し手のモデルの影（続1）: オフ（config.json の \"speaker_shadow\": \"wespeaker34\" で今と並べて点を出します。切り替えはしません）"
        if not rows:
            return f"話し手のモデルの影（続1・{name}）: まだ点がありません（01:00〜05:00 に出します）"
        fmt = lambda v: "—" if v is None else f"{v:.2f}"  # noqa: E731
        return "話し手のモデルの影（続1。切り替えていない）: " + " / ".join(
            f"{d[5:]} {e.get('model')} 答えのある組 {e.get('pairs')}・AUC 今 {fmt(e.get('auc_now'))} 対 {fmt(e.get('auc_shadow'))}"
            f"（s-norm 今 {fmt(e.get('auc_now_snorm'))} 対 {fmt(e.get('auc_shadow_snorm'))}）・その日の組 {e.get('groups')}" for d, e in rows[-3:])

    def pairs_line():
        pairs = s23voice.watch_pairs(home, _base())
        gold = s23gold.progress(home)
        return (f"答えを集める問い: 時計の声だけの答えのある組 {len(pairs)} / {s23voice.WANTED}（続1）・"
                f"騒がしい場面の正解集の候補 {gold['items']} / {s23gold.WANTED}（答え {gold['answered']}・材料に足した {gold['added']}・"
                + "・".join(f"{s23gold.SCENE_LABEL.get(k, k)} {v}" for k, v in sorted(gold["by_scene"].items(), key=str)) + "。続3）")

    def headcount_line():
        try:
            raw = (Path(home) / "s23" / "headcount.jsonl").read_text(encoding="utf-8").splitlines()
        except OSError:
            return None
        recent = [r for r in raw if any(f'"day": "{d}"' in r for d in _days(today, 7))]
        return f"会話のあとに答えた人数（続5・7 日）: {len(recent)} 件（s22 確6 の人数に足しています）" if recent else None

    def resume_lines():
        out = []
        for record in (diag_store.devices() if diag_store is not None else []):
            device = record.get("deviceID")
            if not device:
                continue
            by_day = {d: s23gaps.diag_day(diag_store.folder / str(device), d)["resume"] for d in _days(today, 3)}
            text = s23gaps.resume_line(by_day)
            if text:
                out.append(text)
        return out

    for name, make in (("checks", checks_line), ("recorded", recorded_line), ("stages", stages_line), ("snorm", snorm_line),
                       ("shadow", shadow_line), ("pairs", pairs_line), ("headcount", headcount_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    try:
        lines.extend(f"- {text}" for text in resume_lines())
    except Exception as error:  # noqa: BLE001
        lines.append(f"- （中断から戻るまでの数を数えられませんでした: {type(error).__name__}）")
    try:
        worries.extend(f"- {text}" for text in s23gaps.drop_lines(s23gaps.build_drops(daily, today.isoformat())))
    except Exception as error:  # noqa: BLE001
        lines.append(f"- （版ごとの録れた時間を比べられませんでした: {type(error).__name__}）")
    return worries, lines
