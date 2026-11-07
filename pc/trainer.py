"""LifeLog PC 版 7: あなた向けのモデル（mine）の学び直しを、週に1回、自動で行う。

決まりは docs/v7-plan.md の「4. 学び直しと GPU の時間割」。
- 材料（<home>/personal/data の samples.jsonl）が 300 以上で、前に学び直してから 50 以上増えていて、
  週の時間帯（初めは日曜 2:00〜6:00。config.json の "autotrain" で変えられる）に、仕事が無ければ、
  exe（Python のままなら lifelog_pc.py）の隣の train_personal.py を、別のプロセスで動かす（--home <home>）。
- 学び直しの部品（Python 3.12 と torch cu124 など、合わせて 5GB ほど）は、初めて要るときに <home>/train に用意する。
  Python は python-build-standalone の install_only（決めておいた sha256 と合うものだけ使う）、
  部品は train-requirements.txt（版と sha256 を決めたもの。pip の --require-hashes で、取ってきたものを確かめる）。
  用意するのは、材料がそろってから、夜（1:00〜6:00）か学び直しの時間帯だけ（昼の仕事の邪魔をしないため）。
- 学び直しのあいだは、GPU の文字起こしのモデルと Ollama のモデルを下ろす（gpu.py）。終わったら戻す。
  良くなって mine が入れ替わったら、戻すときに mine を新しいもので読み直す。
- 子のプロセスには SSLKEYLOGFILE を渡さない（Avast などが入れていると、Python の HTTPS が落ちるため）。
- 子のプロセスは、LifeLog PC が終わると一緒に終わる（Windows のジョブ）。途中で終わった学び直しは、次の時間帯にやり直す。
記録（log.txt）には、始めた・終わった・誤りの割合・理由だけを書く（子のプロセスの出力は <home>/personal/train-log.txt）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path
from typing import Callable

import diag

# Python 3.12（python-build-standalone、Windows の x86_64、install_only）。版と sha256 は SHA256SUMS で確かめたもの
PY_URL = ("https://github.com/astral-sh/python-build-standalone/releases/download/20261013/"
          "cpython-3.12.15%2B20261013-x86_64-pc-windows-msvc-install_only.tar.gz")
PY_SHA256 = "bbc902d4d187ac4914915bf538196a064b49109a33a104965b5164ced5b80a1e"
PY_MAX = 200_000_000
REQUIREMENTS = "train-requirements.txt"
SCRIPT = "train_personal.py"
PIP_INDEX = "https://pypi.org/simple"
NEED_DISK = 12_000_000_000       # 用意するときに要る空き（部品 約 5GB・取ってくる途中の分・元のモデル）
PREPARE_RETRY = 6 * 3600.0       # 用意に失敗したら、これだけおいてやり直す
PREPARE_TIMEOUT = 3 * 3600.0
DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
DAY_JA = dict(zip(DAYS, "月火水木金土日"))
DEFAULTS = {"enabled": True, "days": ["sun"], "start": "02:00", "end": "06:00", "min_samples": 300, "min_new": 50,
            "max_hours": 6.0, "args": None}
# GPU のメモリが足りないと言われたら、次は小さく学ぶ（train_personal.py の案内のとおり）
SMALLER = [[], ["--batch", "2", "--accumulate", "4"], ["--batch", "1", "--accumulate", "8"]]
ARG = re.compile(r"--(epochs|batch|accumulate|lr|rank|seed)")
NUMBER = re.compile(r"[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?")
STAMP = re.compile(r"^\d\d:\d\d:\d\d ")
CER = re.compile(r"CER: ([0-9.]+)%")
JAPANESE = re.compile(r"[ぁ-んァ-ヶ一-龥]")
# PyInstaller や Python の置き場所を指す環境変数は、子の Python に渡さない
DROP_ENV = {"SSLKEYLOGFILE", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONEXECUTABLE", "PYTHONUSERBASE",
            "VIRTUAL_ENV", "PYTHONSAFEPATH", "PYTHONNOUSERSITE", "CONDA_PREFIX"}


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def child_env(home: Path, drop_paths: list[Path] | None = None) -> dict:
    """子の Python に渡す環境変数（SSLKEYLOGFILE・exe の中の場所・GPU の部品の場所を除き、置き場所を HOME の下にする）"""
    inside = getattr(sys, "_MEIPASS", None)
    drop = [str(p).lower().rstrip("\\/") for p in (drop_paths or [])]
    if inside:
        drop.append(str(inside).lower().rstrip("\\/"))
    env = {}
    for name, value in os.environ.items():
        upper = name.upper()
        if upper in DROP_ENV or upper.startswith(("_PYI", "_MEI")):
            continue
        if inside and str(value).lower().startswith(str(inside).lower()):
            continue
        env[name] = value
    for name in list(env):
        if name.upper() == "PATH":
            parts = [p for p in env[name].split(os.pathsep) if p and p.lower().rstrip("\\/") not in drop]
            env[name] = os.pathsep.join(parts)
    env.update({"PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "PYTHONNOUSERSITE": "1",
                "HF_HOME": str(Path(home) / "train" / "hf"), "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1",
                "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_NO_INPUT": "1"})
    return env


def safe_untar(archive: Path, dest: Path) -> None:
    """tar.gz を dest に展開する。dest の外を指すもの・リンクがあれば、何もせずに ValueError。"""
    dest = Path(dest).resolve()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            target = (dest / member.name).resolve()
            if member.name.startswith(("/", "\\")) or ":" in member.name or member.issym() or member.islnk() \
                    or (target != dest and dest not in target.parents):
                raise ValueError(f"展開先の外を指すものがあります: {member.name}")
        try:
            tar.extractall(dest, members=members, filter="data")
        except TypeError:  # filter の無い古い Python
            tar.extractall(dest, members=members)


def kill_with_parent(process: subprocess.Popen):
    """子のプロセスを Windows のジョブに入れ、LifeLog PC が終わったら一緒に終わるようにする。ジョブ（閉じると終わる）を返す。"""
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel32.SetInformationJobObject.restype = wintypes.BOOL
        kernel32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

        class Basic(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class Counters(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in ("ReadOperationCount", "WriteOperationCount",
                                                         "OtherOperationCount", "ReadTransferCount",
                                                         "WriteTransferCount", "OtherTransferCount")]

        class Extended(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", Basic), ("IoInfo", Counters), ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        job = kernel32.CreateJobObjectW(None, None)
        if not job:
            return None
        info = Extended()
        info.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)) or \
                not kernel32.AssignProcessToJobObject(job, int(process._handle)):  # noqa: SLF001
            kernel32.CloseHandle(job)
            return None
        return (kernel32, job)
    except Exception:  # noqa: BLE001 — 入れられなくても学び直しはする
        return None


def close_job(job) -> None:
    if job:
        try:
            job[0].CloseHandle(job[1])
        except Exception:  # noqa: BLE001
            pass


def run_logged(command: list[str], log_path: Path, env: dict, timeout: float, cwd: Path) -> int:
    """command を動かし、出力を log_path に足す。終わりの番号を返す（時間切れなら止めて -1）。"""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
    with log_path.open("ab") as out:
        out.write(f"\n==== {time.strftime('%Y-%m-%d %H:%M:%S')} {' '.join(command[:4])} …\n".encode("utf-8"))
        out.flush()
        process = subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                                   cwd=str(cwd), creationflags=flags)
        job = kill_with_parent(process)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            return -1
        finally:
            close_job(job)


# MARK: - 学び直しの部品（<home>/train）


class Runtime:
    """学び直しに使う Python と部品を、<home>/train に用意する。"""

    def __init__(self, home: Path, install_dir: Path, log: Callable[[str], None],
                 download: Callable[[str, Path], None] | None = None,
                 run: Callable[[list[str], Path, dict, float, Path], int] | None = None,
                 url: str = PY_URL, sha256: str = PY_SHA256, drop_paths: list[Path] | None = None) -> None:
        self.home = Path(home)
        self.folder = self.home / "train"
        self.requirements = Path(install_dir) / REQUIREMENTS
        self.log = log
        self.download = download or self._download
        self.run = run or run_logged
        self.url = url
        self.sha256 = sha256
        self.drop_paths = drop_paths or []
        self.need_disk = NEED_DISK
        self.preparing = False
        self.state = ""
        self.error: str | None = None

    @property
    def python(self) -> Path:
        return self.folder / "python" / ("python.exe" if os.name == "nt" else "bin/python3")

    def lock_hash(self) -> str | None:
        try:
            return file_sha256(self.requirements)
        except OSError:
            return None

    def ready(self) -> bool:
        info = _read_json(self.folder / "ready.json")
        return self.python.exists() and info.get("lock") == self.lock_hash() and info.get("python") == self.sha256

    def status(self) -> str:
        if self.preparing:
            return "用意しています" + (f"（{self.state}）" if self.state else "")
        if self.ready():
            return "用意できています"
        return "まだありません（初めて要るときに、約 5GB を取ってきます）"

    @staticmethod
    def _download(url: str, target: Path) -> None:
        import urllib.request

        import updater

        request = urllib.request.Request(url, headers={"User-Agent": "LifeLogPC"})
        size = 0
        with urllib.request.urlopen(request, timeout=120, context=updater.https_context()) as response, \
                target.open("wb") as f:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                size += len(chunk)
                if size > PY_MAX:
                    raise RuntimeError("取ってきた Python が大きすぎます")
                f.write(chunk)

    def prepare(self) -> None:
        """Python を取ってきて確かめ、展開し、部品を入れて確かめる。失敗したら RuntimeError（途中のものは片づける）。"""
        if not self.requirements.exists():
            raise RuntimeError(f"{REQUIREMENTS} が exe の隣にありません")
        self.folder.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(self.folder).free < self.need_disk:
            raise RuntimeError(f"ディスクの空きが足りません（{self.need_disk / 1e9:.0f} GB 要ります）")
        self.preparing = True
        self.error = None
        log_path = self.folder / "prepare-log.txt"
        env = child_env(self.home, self.drop_paths)
        try:
            # 展開できた Python は python.json に覚えておく（途中で止まっても、次は取ってき直さずに続きから）
            if not self.python.exists() or _read_json(self.folder / "python.json").get("python") != self.sha256:
                self.state = "Python を取ってきています"
                self.log("学び直しの部品: Python 3.12 を取ってきます（約 46MB）")
                archive = self.folder / "download" / "python.tar.gz"
                archive.parent.mkdir(parents=True, exist_ok=True)
                part = archive.with_name(archive.name + ".part")
                self.download(self.url, part)
                got = file_sha256(part)
                if got != self.sha256:
                    part.unlink(missing_ok=True)
                    raise RuntimeError(f"取ってきた Python のハッシュが合いません（消しました）: {got[:12]}…")
                part.replace(archive)
                self.state = "Python を展開しています"
                temp = self.folder / "python.tmp"
                shutil.rmtree(temp, ignore_errors=True)
                temp.mkdir(parents=True)
                safe_untar(archive, temp)
                if not (temp / "python" / self.python.name).exists() and not (temp / "python" / "bin").exists():
                    raise RuntimeError("展開したものに python が見つかりません")
                shutil.rmtree(self.folder / "python", ignore_errors=True)
                (temp / "python").replace(self.folder / "python")
                shutil.rmtree(temp, ignore_errors=True)
                archive.unlink(missing_ok=True)
                (self.folder / "ready.json").unlink(missing_ok=True)
                _write_json(self.folder / "python.json", {"python": self.sha256, "at": diag.iso(time.time())})
            python = str(self.python)
            if self.run([python, "-m", "pip", "--version"], log_path, env, 300, self.folder) != 0:
                self.state = "pip を用意しています"
                if self.run([python, "-m", "ensurepip", "--upgrade"], log_path, env, 600, self.folder) != 0:
                    raise RuntimeError("pip を用意できませんでした")
            self.state = "部品を取ってきています（torch など、約 3GB）"
            self.log("学び直しの部品: torch などを取ってきます（約 3GB。sha256 を確かめながら入れます）")
            code = self.run([python, "-m", "pip", "install", "--require-hashes", "--no-deps", "--only-binary=:all:",
                             "--no-cache-dir", "--no-warn-script-location", "--progress-bar", "off",
                             "--index-url", PIP_INDEX, "-r", str(self.requirements)],
                            log_path, env, PREPARE_TIMEOUT, self.folder)
            if code != 0:
                raise RuntimeError(f"部品を入れられませんでした（終わりの番号 {code}。{log_path} を見てください）")
            self.state = "部品を確かめています"
            code = self.run([python, "-c", "import torch, transformers, peft, accelerate, ctranslate2, faster_whisper; "
                                           "print('torch', torch.__version__, 'cuda', torch.version.cuda)"],
                            log_path, env, 600, self.folder)
            if code != 0:
                raise RuntimeError(f"入れた部品を読み込めませんでした（{log_path} を見てください）")
            _write_json(self.folder / "ready.json", {"python": self.sha256, "lock": self.lock_hash(),
                                                     "at": diag.iso(time.time())})
            self.log("学び直しの部品を用意できました")
        except Exception as error:  # noqa: BLE001
            self.error = str(error) or repr(error)
            raise RuntimeError(self.error) from error
        finally:
            self.preparing = False
            self.state = ""


# MARK: - 時間帯


def parse_days(value) -> list[str]:
    days = []
    for item in value if isinstance(value, list) else [value]:
        text = str(item or "").strip().lower()[:3]
        found = text if text in DAYS else next((d for d, j in DAY_JA.items() if j == str(item).strip()[:1]), None)
        if found and found not in days:
            days.append(found)
    return days or ["sun"]


def train_config(config: dict) -> dict:
    """config.json の "autotrain"（false でやめる。{"days", "start", "end", "min_samples", "min_new", "max_hours", "args"}）"""
    import gpu

    value = config.get("autotrain", True)
    out = dict(DEFAULTS)
    if value is False:
        out["enabled"] = False
        return out
    value = value if isinstance(value, dict) else {}
    out["enabled"] = value.get("enabled", True) is not False
    out["days"] = parse_days(value.get("days", DEFAULTS["days"]))
    out["start"] = "%02d:%02d" % gpu.parse_clock(value.get("start"), DEFAULTS["start"])
    out["end"] = "%02d:%02d" % gpu.parse_clock(value.get("end"), DEFAULTS["end"])
    for key in ("min_samples", "min_new"):
        try:
            out[key] = max(1, int(value.get(key, DEFAULTS[key])))
        except (TypeError, ValueError):
            pass
    try:
        out["max_hours"] = min(24.0, max(0.01, float(value.get("max_hours", DEFAULTS["max_hours"]))))
    except (TypeError, ValueError):
        pass
    args = value.get("args")
    if isinstance(args, list) and len(args) % 2 == 0 and all(
            ARG.fullmatch(str(a)) if i % 2 == 0 else NUMBER.fullmatch(str(a)) for i, a in enumerate(args)):
        out["args"] = [str(a) for a in args]
    return out


def next_window(now: float, days: list[str], start: str, end: str) -> tuple[float, float] | None:
    """now より後に終わる、いちばん早い学び直しの時間帯 (始まり, 終わり)（この PC の時刻）"""
    import gpu

    sh, sm = gpu.parse_clock(start, "02:00")
    eh, em = gpu.parse_clock(end, "06:00")
    today = datetime.datetime.fromtimestamp(now).date()
    for offset in range(-1, 9):
        day = today + datetime.timedelta(days=offset)
        if DAYS[day.weekday()] not in days:
            continue
        begin = datetime.datetime.combine(day, datetime.time(min(sh, 23), sm))
        finish = datetime.datetime.combine(day, datetime.time(min(eh, 23), em))
        if finish <= begin:
            finish += datetime.timedelta(days=1)
        if finish.timestamp() > now:
            return begin.timestamp(), finish.timestamp()
    return None


def window_text(config: dict) -> str:
    days = "・".join(DAY_JA[d] for d in config["days"])
    return f"{days}曜 {config['start']}〜{config['end']}"


# MARK: - 自動の学び直し


class AutoTrainer:
    """材料と時間帯と仕事の様子を見て、train_personal.py を動かす。"""

    def __init__(self, home: Path, install_dir: Path, log: Callable[[str], None], *, gpu_plan, ollama,
                 count_samples: Callable[[], int], is_idle: Callable[[], bool], has_gpu: Callable[[], bool],
                 on_improved: Callable[[], None], runtime: Runtime | None = None,
                 clock: Callable[[], float] = time.time, python: Callable[[], str] | None = None) -> None:
        self.home = Path(home)
        self.script = Path(install_dir) / SCRIPT
        self.log = log
        self.gpu = gpu_plan
        self.ollama = ollama
        self.count_samples = count_samples
        self.is_idle = is_idle
        self.has_gpu = has_gpu
        self.on_improved = on_improved
        self.clock = clock
        self.runtime = runtime or Runtime(home, install_dir, log)
        self.python = python or (lambda: str(self.runtime.python))
        self.state_path = self.home / "personal" / "autotrain.json"
        self.state = _read_json(self.state_path)
        self.config = dict(DEFAULTS)
        self.running = False
        self.phase = ""
        self.started: float | None = None
        self.waiting = ""
        self.thread: threading.Thread | None = None
        self.lock = threading.Lock()

    def configure(self, config: dict) -> None:
        self.config = train_config(config)

    def available(self) -> bool:
        """この PC で自動の学び直しができるか（設定がオンで、NVIDIA の GPU と train_personal.py がある）"""
        return bool(self.config["enabled"]) and self.has_gpu() and self.script.exists() \
            and self.runtime.requirements.exists()

    def base_count(self) -> int:
        """前に学び直したときの材料の数（無ければ、手で作ったモデルの trained.json の数。それも無ければ 0）"""
        if isinstance(self.state.get("base_count"), int):
            return self.state["base_count"]
        trained = _read_json(self.home / "personal" / "model" / "trained.json")
        return int(trained.get("samples") or 0) if isinstance(trained.get("samples"), int) else 0

    def save(self) -> None:
        try:
            _write_json(self.state_path, self.state)
        except OSError as error:
            self.log(f"学び直し: 様子を保存できませんでした: {error!r}")

    # MARK: 見回り（ops.py が 1 分ごとに呼ぶ）

    def tick(self) -> None:
        now = self.clock()
        if self.running or not self.available():
            return
        count = self.count_samples()
        if count < self.config["min_samples"] or count - self.base_count() < self.config["min_new"]:
            self.waiting = "材料を待っています"
            return
        window = next_window(now, self.config["days"], self.config["start"], self.config["end"])
        inside = window is not None and window[0] <= now < window[1]
        if not self.runtime.ready():
            hour = time.localtime(now).tm_hour
            failed = float(self.state.get("prepare_failed_at") or 0)
            if not self.runtime.preparing and (inside or 1 <= hour < 6) and now - failed >= PREPARE_RETRY:
                self.waiting = "学び直しの部品を用意しています"
                threading.Thread(target=self._prepare, name="train-prepare", daemon=True).start()
            elif not self.runtime.preparing:
                self.waiting = "学び直しの部品を用意する時を待っています（夜 1:00〜6:00）"
            return
        if not inside:
            self.waiting = "学び直しの時間帯を待っています"
            return
        if self.state.get("attempted") == window[0]:
            self.waiting = "この時間帯の学び直しは終わりました"
            return
        if not self.is_idle():
            self.waiting = "仕事が終わるのを待っています"
            return
        self.state["attempted"] = window[0]
        self.save()
        self.start(count)

    def _prepare(self) -> None:
        try:
            self.runtime.prepare()
            self.state.pop("prepare_failed_at", None)
            self.state.pop("prepare_error", None)
        except Exception as error:  # noqa: BLE001
            self.state["prepare_failed_at"] = self.clock()
            self.state["prepare_error"] = str(error)
            self.log(f"学び直しの部品を用意できませんでした（{PREPARE_RETRY / 3600:.0f} 時間あとにやり直します）: {error}")
        self.save()

    def start(self, count: int) -> bool:
        with self.lock:
            if self.running:
                return False
            self.running = True
        self.thread = threading.Thread(target=self._run, args=(count,), name="autotrain", daemon=True)
        self.thread.start()
        return True

    def command(self) -> list[str]:
        args = self.config.get("args")
        if args is None:
            args = SMALLER[min(int(self.state.get("smaller") or 0), len(SMALLER) - 1)]
        return [self.python(), str(self.script), "--home", str(self.home), *args]

    def _trained(self) -> dict:
        return _read_json(self.home / "personal" / "model" / "trained.json")

    def _run(self, count: int) -> None:
        started = self.clock()
        self.started = started
        before = self._trained().get("trained")
        result: dict = {"at": diag.iso(started), "samples": count}
        saved: list = []
        try:
            self.phase = "GPU を空けています"
            self.gpu.hold("train")
            if self.ollama is not None:
                saved = self.ollama.unload_all()
            self.log(f"学び直し: 始めます（材料 {count} 個・前回から +{count - self.base_count()}）")
            code, timed_out, cers, message, improved_line = self._spawn(started)
            trained = self._trained()
            improved = code == 0 and (trained.get("trained") != before or improved_line) and bool(trained)
            if timed_out:
                result.update(result="timeout", message=f"{self.config['max_hours']:g} 時間を超えたので止めました"
                                                         "（次の時間帯にやり直します）")
            elif improved:
                result.update(result="improved", cer_before=trained.get("cer_before"), cer_after=trained.get("cer_after"))
                self.state["base_count"] = count
                self.state["smaller"] = 0
                self.on_improved()
            elif code == 0:
                result.update(result="not_improved", cer_before=cers[0] if cers else None,
                              cer_after=cers[1] if len(cers) > 1 else None)
                self.state["base_count"] = count
            elif code == 2:
                result.update(result="refused", message=message)
                if "メモリが足りません" in (message or ""):
                    self.state["smaller"] = int(self.state.get("smaller") or 0) + 1
            else:
                result.update(result="failed", message=message or f"終わりの番号 {code}")
        except Exception as error:  # noqa: BLE001 — 学び直せなくても、文字起こしは続ける
            result.update(result="failed", message=str(error) or repr(error))
        finally:
            result["seconds"] = round(self.clock() - started, 1)
            self.state["last"] = result
            self.save()
            self.phase = "GPU のモデルを戻しています"
            try:
                self.gpu.release("train", wait=True)
            except Exception as error:  # noqa: BLE001
                self.log(f"学び直し: GPU のモデルを戻せませんでした: {error!r}")
            if self.ollama is not None:
                try:
                    self.ollama.restore(saved)
                except Exception as error:  # noqa: BLE001
                    self.log(f"学び直し: Ollama のモデルを載せ直せませんでした: {error!r}")
            self.phase = ""
            self.started = None
            self.running = False
            self.log(self.result_line(result))

    def _spawn(self, started: float) -> tuple[int | None, bool, list[float], str | None, bool]:
        """子のプロセスで学び直す。(終わりの番号, 時間切れか, 出てきた CER（% ではなく割合）, 理由の文, 入れ替えたと言ったか)"""
        log_path = self.home / "personal" / "train-log.txt"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        env = child_env(self.home, self.runtime.drop_paths)
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
        command = self.command()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   env=env, cwd=str(self.home), creationflags=flags)
        job = kill_with_parent(process)
        cers: list[float] = []
        others: list[str] = []
        flags_seen = {"final": False, "improved": False}

        def read() -> None:
            with log_path.open("a", encoding="utf-8") as out:
                out.write(f"\n==== {time.strftime('%Y-%m-%d %H:%M:%S')} 自動の学び直し\n")
                for raw in process.stdout:  # type: ignore[union-attr]
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    out.write(line + "\n")
                    out.flush()
                    self._progress(line, cers, others, flags_seen)

        reader = threading.Thread(target=read, name="autotrain-read", daemon=True)
        reader.start()
        deadline = started + float(self.config["max_hours"]) * 3600
        timed_out = False
        try:
            while process.poll() is None:
                if self.clock() > deadline and not flags_seen["final"]:
                    timed_out = True
                    process.kill()
                    # ジョブを閉じると、子が動かしたもの（出力の管を持ったままのもの）も一緒に終わる
                    close_job(job)
                    job = None
                    break
                time.sleep(1.0)
            code = process.wait()
            reader.join(timeout=30)
        finally:
            close_job(job)
        message = next((o for o in others if JAPANESE.search(o) and "Warning" not in o), None) \
            or (others[-1] if others else None)
        return code, timed_out, cers, (message[:300] if message else None), flags_seen["improved"]

    def _progress(self, line: str, cers: list[float], others: list[str], seen: dict) -> None:
        """出力の1行から、今していることを読む（文字起こしの文は画面にも記録にも出さない）"""
        if not STAMP.match(line):
            if line.strip():
                others.append(line.strip())
                del others[:-40]
            return
        match = CER.search(line)
        if match:
            cers.append(float(match.group(1)) / 100.0)
        if "元のモデル" in line and "読み込んで" in line:
            self.phase = "元のモデルを読み込んでいます"
        elif "前の誤りの割合" in line:
            self.phase = "学び直す前の誤りの割合を測っています"
        elif "周目" in line:
            epoch = re.search(r"(\d+) 周目", line)
            self.phase = f"学び直しています（{epoch.group(1) if epoch else '?'} 周目まで終わりました）"
        elif "学び直しています" in line:
            self.phase = "学び直しています"
        elif "後の誤りの割合" in line:
            self.phase = "学び直した後の誤りの割合を測っています"
        elif "元のモデルに混ぜて" in line:
            self.phase = "新しいモデルを作って入れ替えています"
            seen["final"] = True
        elif "モデルを入れました" in line:
            seen["improved"] = True

    @staticmethod
    def result_line(result: dict) -> str:
        """記録（log.txt）に書く1行"""
        def pct(value) -> str:
            return f"{float(value):.2%}" if isinstance(value, (int, float)) else "—"

        took = diag.ago(result.get("seconds"))
        kind = result.get("result")
        if kind == "improved":
            return (f"学び直し: 終わりました（{took}）。誤りの割合 {pct(result.get('cer_before'))} → "
                    f"{pct(result.get('cer_after'))}。良くなったので、あなた向けのモデルを入れ替えました")
        if kind == "not_improved":
            return (f"学び直し: 終わりました（{took}）。良くならなかったので、前のモデルのままです"
                    f"（{pct(result.get('cer_before'))} → {pct(result.get('cer_after'))}）")
        if kind == "refused":
            return f"学び直し: 学び直しませんでした: {result.get('message') or '—'}"
        if kind == "timeout":
            return f"学び直し: {result.get('message')}"
        return f"学び直し: うまくいきませんでした: {result.get('message') or '—'}"

    # MARK: /train-status と見守りの画面

    def status(self) -> dict:
        now = self.clock()
        window = next_window(now, self.config["days"], self.config["start"], self.config["end"])
        inside = window is not None and window[0] <= now < window[1]
        if not self.config["enabled"]:
            state = "使わない設定です"
        elif not self.has_gpu():
            state = "NVIDIA の GPU が無いので、学び直しません"
        elif not self.script.exists():
            state = f"{SCRIPT} が見つかりません"
        elif self.running:
            state = "学び直しています" + (f"（{self.phase}）" if self.phase else "")
        elif self.runtime.preparing:
            state = self.runtime.status()
        else:
            state = self.waiting or "待っています"
        if window is None:
            upcoming = None
        elif inside and self.state.get("attempted") == window[0]:
            upcoming = next_window(window[1] + 1, self.config["days"], self.config["start"], self.config["end"])
        else:
            upcoming = window
        count = self.count_samples()
        last = self.state.get("last") if isinstance(self.state.get("last"), dict) else None
        return {"enabled": bool(self.config["enabled"]), "available": self.available(), "running": self.running,
                "state": state, "phase": self.phase or None, "window": window_text(self.config),
                "next": diag.iso(upcoming[0]) if upcoming else None, "in_window": inside,
                "started": diag.iso(self.started) if self.started else None,
                "count": count, "since_last": count - self.base_count(),
                "min_samples": self.config["min_samples"], "min_new": self.config["min_new"],
                "runtime": self.runtime.status(), "runtime_error": self.state.get("prepare_error"),
                "last": last}
