"""LifeLog PC: s26 聞11（2026-11-25。担当 P）。自分専用の文字起こしモデル（mine）を毎週育てる・良くなった週だけ入れ替える・悪くなったら戻す。

- 毎週の学び直し（trainer.AutoTrainer。日曜 02:00〜05:00・材料 300 個から。今までの決まり）に、**候補として置くだけ**の
  --candidate を付ける（personal/model.candidate に置き、trained.json に正解集＝本人が直した材料での前後の CER）。
  config.json の "s26p_weekly_swap": true のときだけ、今までどおり学び直しの中で入れ替える（初めはオフ＝入れ替えない）。
- 入れ替え（"s26p_promote": true のときだけ。初めはオフ）: 候補の CER が今のモデルより PROMOTE_GAIN（仮）以上よいときだけ、
  夜 00:00〜05:00 に personal/model → model.old（前のものは 1 つだけ残す）・model.candidate → model にし、mine を読み直す。
- 戻す: 入れ替えた（どちらの道でも）あと ROLLBACK_DAYS 日の mine の当たり率（PLAUD と合った字の割合。plaudmatch.engine_rates）が
  入れ替える前の ROLLBACK_DAYS 日より ROLLBACK_DROP 以上下がったら「戻す候補」。"s26p_auto_rollback": true のときだけ
  model → model.bad・model.old → model にして読み直す（初めはオフ＝候補を summary.md に出すだけ）。
  当たり率の行が ROLLBACK_LINES に足りなければ決めない。
置き場所: HOME/s26p/train-week.json（数だけ）。
"""

from __future__ import annotations

import datetime
import json
import os
import shutil
import time
from pathlib import Path

PROMOTE_GAIN = 0.005      # 仮: CER がこれ以上下がったら
ROLLBACK_DAYS = 3
ROLLBACK_DROP = 0.02      # 仮
ROLLBACK_LINES = 100
STATE = Path("s26p") / "train-week.json"


def _read(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def dirs(home: Path) -> dict[str, Path]:
    personal = Path(home) / "personal"
    return {"model": personal / "model", "old": personal / "model.old", "candidate": personal / "model.candidate",
            "bad": personal / "model.bad"}


def trained(path: Path) -> dict:
    return _read(Path(path) / "trained.json")


# MARK: - 毎週の学び直しを「候補」に


def hook_weekly(trainer, config_of) -> bool:
    """trainer.command に --candidate を足す（"s26p_weekly_swap": true なら足さない）。包んだら True"""
    if trainer is None or getattr(trainer.command, "s26p_wrapped", False):
        return False
    original = trainer.command

    def command() -> list[str]:
        cmd = list(original())
        try:
            swap = (config_of() or {}).get("s26p_weekly_swap") is True
        except Exception:  # noqa: BLE001
            swap = False
        if not swap and "--candidate" not in cmd:
            cmd.append("--candidate")
        return cmd

    command.s26p_wrapped = True  # type: ignore[attr-defined]
    trainer.command = command
    return True


# MARK: - 入れ替え・戻す


def candidate_gain(home: Path) -> float | None:
    """候補の正解集での CER の下がり幅（候補が無い・数が無ければ None）"""
    info = trained(dirs(home)["candidate"])
    before, after = info.get("cer_before"), info.get("cer_after")
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)):
        return None
    return round(float(before) - float(after), 4)


def promote(home: Path) -> bool:
    d = dirs(home)
    if not (d["candidate"] / "model.bin").exists():
        return False
    if d["model"].exists():
        if d["old"].exists():
            shutil.rmtree(d["old"])
        d["model"].rename(d["old"])
    d["candidate"].rename(d["model"])
    return True


def rollback(home: Path) -> bool:
    d = dirs(home)
    if not (d["old"] / "model.bin").exists():
        return False
    if d["model"].exists():
        if d["bad"].exists():
            shutil.rmtree(d["bad"])
        d["model"].rename(d["bad"])
    d["old"].rename(d["model"])
    return True


def mine_rate(home: Path, base: Path | None, today: datetime.date, days: int = ROLLBACK_DAYS) -> dict | None:
    if base is None:
        return None
    import plaudmatch

    got = plaudmatch.engine_rates(Path(home), Path(base), today, days=days).get("mine")
    return got if got and got.get("rate") is not None else None


def nightly(home: Path, base: Path | None, config: dict, today: datetime.date, reload=None,
            moment: datetime.datetime | None = None, rate_of=None) -> dict:
    """夜に 1 回。{"swapped","promoted","rollback_candidate","rolled_back","gain"}"""
    moment = moment or datetime.datetime.now()
    rate_of = rate_of or (lambda days: mine_rate(home, base, today, days))
    path = Path(home) / STATE
    state = _read(path)
    out: dict = {"gain": candidate_gain(home)}
    now_trained = trained(dirs(home)["model"]).get("trained")
    # 入れ替わったか（学び直しの中で・本人が・この見回りで）
    if now_trained and now_trained != state.get("model_trained"):
        if state.get("model_trained") is not None:
            state["swap"] = {"at": today.isoformat(), "trained": now_trained, "before": state.get("last_rate")}
            out["swapped"] = True
        state["model_trained"] = now_trained
    # 入れ替える（初めはオフ）
    gain = out["gain"]
    if config.get("s26p_promote") is True and gain is not None and gain >= PROMOTE_GAIN and 0 <= moment.hour < 5:
        before = rate_of(7)
        if promote(home):
            state["swap"] = {"at": today.isoformat(), "trained": trained(dirs(home)["model"]).get("trained"),
                             "before": before, "gain": gain, "by": "s26p"}
            state["model_trained"] = state["swap"]["trained"]
            out["promoted"] = True
            if reload is not None:
                reload()
    # 戻す
    swap = state.get("swap") if isinstance(state.get("swap"), dict) else None
    if swap and not swap.get("judged"):
        since = (today - datetime.date.fromisoformat(swap["at"])).days
        before = swap.get("before")
        if since >= ROLLBACK_DAYS and isinstance(before, dict) and before.get("rate") is not None:
            after = rate_of(ROLLBACK_DAYS)
            if after is not None and int(after.get("lines") or 0) >= ROLLBACK_LINES:
                worse = after["rate"] < before["rate"] - ROLLBACK_DROP
                swap.update(judged=today.isoformat(), after=after, worse=worse)
                if worse:
                    out["rollback_candidate"] = True
                    if config.get("s26p_auto_rollback") is True and rollback(home):
                        swap["rolled_back"] = True
                        out["rolled_back"] = True
                        state["model_trained"] = trained(dirs(home)["model"]).get("trained")
                        if reload is not None:
                            reload()
    elif swap is None or swap.get("judged"):
        latest = rate_of(ROLLBACK_DAYS)
        if latest is not None:
            state["last_rate"] = latest
    state["checked"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    _write(path, state)
    return out


def summary(home: Path, config: dict) -> str:
    state = _read(Path(home) / STATE)
    gain = candidate_gain(home)
    weekly = "入れ替える" if config.get("s26p_weekly_swap") is True else "候補として置くだけ（\"s26p_weekly_swap\": true で入れ替え）"
    text = f"自分専用モデルを毎週（聞11）: 毎週の学び直しは{weekly}"
    text += "・候補の正解集での CER の下がり " + ("—" if gain is None else f"{gain:+.3f}")
    text += "・入れ替え " + ("オン" if config.get("s26p_promote") is True else "オフ（\"s26p_promote\": true）")
    swap = state.get("swap") if isinstance(state.get("swap"), dict) else None
    if swap:
        if swap.get("judged"):
            text += f"・{swap['at'][5:]} の入れ替えは" + ("悪くなった（戻す候補）" if swap.get("worse") else "悪くなっていない")
            if swap.get("rolled_back"):
                text += "→戻しました"
        else:
            text += f"・{swap['at'][5:]} に入れ替え（{ROLLBACK_DAYS} 日で測ります）"
    text += "・自動で戻す " + ("オン" if config.get("s26p_auto_rollback") is True else "オフ（\"s26p_auto_rollback\": true）")
    return text
