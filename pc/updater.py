"""LifeLog PC 版 6: 自分で新しい版に入れ替える（と、見守りの画面の「再起動」）。

GitHub の off53jub/Applewatch のリリースのうち、名前が pc-v で始まるもの（例 pc-v6-123。最後の数が作った回の番号）を見て、
自分の番号（BUILD.txt）より新しければ、LifeLogPC.zip と LifeLogPC.zip.sha256 を <home>/update/ に取ってくる。
ハッシュが合えば、入っているフォルダの隣に展開し、文字にしている最中のものが無いときに、
.cmd の手順（入っているフォルダの隣に書く）に入れ替えを任せて終わる。.cmd は
1. この PC の LifeLog PC が終わるのを待つ
2. 入っているフォルダを「<フォルダ> 前の版」に名前を変える（前の「前の版」は消す）
3. 新しい版のフォルダをもとの名前にする
4. タスク スケジューラの Lifelog-HomePC-Autostart で起動し直す（無ければ同じ引数で直接起動する）
5. 自分を消す
Python のまま動かしているとき（exe でないとき）は、新しい版があるかを確かめるだけで、入れ替えない。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path
from typing import Callable

API = "https://api.github.com/repos/off53jub/Applewatch/releases?per_page=30"
TASK = "Lifelog-HomePC-Autostart"
ZIP_NAME = "LifeLogPC.zip"
SHA_NAME = "LifeLogPC.zip.sha256"
EXE_NAME = "LifeLogPC.exe"
FIRST_CHECK = 600.0          # 起動してから 10 分後に1回目
CHECK_EVERY = 6 * 3600.0     # そのあとは 6 時間ごと
IDLE_RETRY = 30.0            # 文字にしている最中なら、この間をおいて待つ
DOWNLOAD_MAX = 3_000_000_000
TAG = re.compile(r"pc-v(\d+)-(\d+)")
SHA = re.compile(r"\b([0-9a-fA-F]{64})\b")


# MARK: - 決まり（テストできるよう、外に触れない関数にしてある）


def parse_tag(tag) -> tuple[int, int] | None:
    """"pc-v6-123" → (6, 123)。違う形なら None。"""
    match = TAG.fullmatch(str(tag or ""))
    return (int(match.group(1)), int(match.group(2))) if match else None


def asset_url(release: dict, name: str) -> tuple[str, int] | None:
    for asset in release.get("assets") or []:
        if isinstance(asset, dict) and asset.get("name") == name and asset.get("browser_download_url"):
            return str(asset["browser_download_url"]), int(asset.get("size") or 0)
    return None


def pick_release(releases, build: int) -> dict | None:
    """リリースの一覧から、build より新しい pc-v* のうちいちばん新しいもの（zip と sha256 があるもの）。
    下書きは除く。答えは {"tag", "version", "build", "zip", "zip_size", "sha"}。"""
    best = None
    for release in releases if isinstance(releases, list) else []:
        if not isinstance(release, dict) or release.get("draft"):
            continue
        parsed = parse_tag(release.get("tag_name"))
        if not parsed or parsed[1] <= build:
            continue
        zipped, sha = asset_url(release, ZIP_NAME), asset_url(release, SHA_NAME)
        if not zipped or not sha:
            continue
        if best is None or parsed[1] > best["build"]:
            best = {"tag": release["tag_name"], "version": parsed[0], "build": parsed[1],
                    "zip": zipped[0], "zip_size": zipped[1], "sha": sha[0]}
    return best


def parse_sha256(text: str) -> str | None:
    """sha256sum の形（"ハッシュ  LifeLogPC.zip"）からハッシュを取り出す（小文字）"""
    match = SHA.search(text or "")
    return match.group(1).lower() if match else None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sha256(path: Path, expected: str | None) -> bool:
    return bool(expected) and Path(path).is_file() and file_sha256(path) == expected.lower()


def read_build(folder: Path) -> int:
    """フォルダの BUILD.txt の番号（無ければ 0）"""
    try:
        return int((Path(folder) / "BUILD.txt").read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        return 0


def safe_extract(archive: Path, dest: Path) -> None:
    """zip を dest に展開する。dest の外を指すもの（../ や絶対の場所）があれば何もせず ValueError。"""
    dest = Path(dest).resolve()
    with zipfile.ZipFile(archive) as z:
        members = z.infolist()
        for member in members:
            target = (dest / member.filename).resolve()
            if member.filename.startswith(("/", "\\")) or ":" in member.filename or \
                    (target != dest and dest not in target.parents):
                raise ValueError(f"zip の中に、展開先の外を指すものがあります: {member.filename}")
        z.extractall(dest)


def find_root(folder: Path) -> Path | None:
    """LifeLogPC.exe のあるフォルダ（展開したフォルダそのものか、その中のただ1つのフォルダ）"""
    folder = Path(folder)
    if (folder / EXE_NAME).is_file():
        return folder
    subs = [p for p in folder.iterdir() if p.is_dir()]
    if len(subs) == 1 and (subs[0] / EXE_NAME).is_file():
        return subs[0]
    return None


def backup_dir(install: Path) -> Path:
    return Path(install).with_name(Path(install).name + " 前の版")


def staging_dir(install: Path) -> Path:
    return Path(install).with_name(Path(install).name + " 新しい版")


def _cmd_quote(text: str) -> str:
    """.cmd に書く引数（% は %% にする。" を含むものは使わない）"""
    text = str(text).replace("%", "%%")
    if '"' in text:
        raise ValueError(f"\" を含む引数は .cmd に書けません: {text}")
    return f'"{text}"'


def start_lines(task: str | None, argv: list[str], cwd: Path, log: Path) -> list[str]:
    """起動し直す行。task があればタスク スケジューラで起動し、20 秒たっても exe が見えなければ（タスクが無ければ）
    同じ引数で直接起動する。（ラベルの名前は、ほかのラベルの頭と重ならないものにしてある）"""
    direct = f'start "LifeLog PC" /D {_cmd_quote(cwd)} ' + " ".join(_cmd_quote(a) for a in argv)
    if not task:
        return [direct]
    image = Path(argv[0]).name
    return [f"schtasks /run /tn {_cmd_quote(task)} >nul 2>&1",
            "if errorlevel 1 goto directstart",
            "set /a k=0",
            ":checkup",
            "ping -n 3 127.0.0.1 >nul",
            f'tasklist /FI "IMAGENAME eq {image}" /NH 2>nul | findstr /I /C:"{image}" >nul',
            "if not errorlevel 1 goto launched",
            "set /a k+=1",
            "if %k% LSS 10 goto checkup",
            _say(log, "起動の手順: タスクで起動できなかったので、直接起動します"),
            ":directstart",
            direct,
            ":launched"]


def _wait_lines(pid: int, log: Path) -> list[str]:
    pid = int(pid)
    return [
        "set /a n=0",
        ":waitloop",
        # tasklist の表の PID は前後に空白がある。見つからなければ（終わっていれば）次へ
        f'tasklist /FI "PID eq {pid}" /NH 2>nul | findstr /C:" {pid} " >nul',
        "if errorlevel 1 goto exited",
        "set /a n+=1",
        f"if %n% GEQ 120 taskkill /PID {pid} /F >nul 2>&1",
        "if %n% GEQ 120 " + _say(log, "手順: 前の LifeLog PC が終わらないので止めました"),
        "if %n% GEQ 125 goto exited",
        "ping -n 2 127.0.0.1 >nul",
        "goto waitloop",
        ":exited",
    ]


def _say(log: Path, text: str) -> str:
    return f">>{_cmd_quote(log)} echo %date% %time% {text}"


def update_script(pid: int, install: Path, staging: Path, backup: Path, task: str | None, argv: list[str],
                  cwd: Path, log: Path) -> str:
    """入れ替えの .cmd の中身。1行目と2行目は英数字だけ（chcp 65001 のあとから UTF-8 の名前が読める）。"""
    q = _cmd_quote
    lines = ["@echo off", "chcp 65001 >nul", *_wait_lines(pid, log),
             _say(log, "更新の手順: 前の版を終えました。入れ替えます"),
             f"if exist {q(backup)} rmdir /s /q {q(backup)}",
             f"if exist {q(backup)} goto keepold",
             "set /a m=0",
             ":trymove",
             f"move {q(install)} {q(backup)} >nul 2>&1",
             "if not errorlevel 1 goto moved",
             "set /a m+=1",
             "if %m% GEQ 30 goto keepold",
             "ping -n 3 127.0.0.1 >nul",
             "goto trymove",
             ":moved",
             f"move {q(staging)} {q(install)} >nul 2>&1",
             "if not errorlevel 1 goto swapped",
             _say(log, "更新の手順: 新しい版を置けませんでした。前の版に戻します"),
             f"move {q(backup)} {q(install)} >nul 2>&1",
             "goto relaunch",
             ":keepold",
             _say(log, "更新の手順: 入れ替えられませんでした（フォルダを使っているソフトがあるかもしれません）。今の版のまま起動します"),
             "goto relaunch",
             ":swapped",
             _say(log, "更新の手順: 入れ替えました"),
             ":relaunch",
             *start_lines(task, argv, cwd, log),
             _say(log, "更新の手順: 起動しました"),
             '(goto) 2>nul & del "%~f0"']
    return "\r\n".join(lines) + "\r\n"


def restart_script(pid: int, task: str | None, argv: list[str], cwd: Path, log: Path) -> str:
    """起動し直すだけの .cmd の中身"""
    lines = ["@echo off", "chcp 65001 >nul", *_wait_lines(pid, log), *start_lines(task, argv, cwd, log),
             _say(log, "再起動の手順: 起動しました"), '(goto) 2>nul & del "%~f0"']
    return "\r\n".join(lines) + "\r\n"


def task_exists(task: str | None) -> bool:
    if not task or os.name != "nt":
        return False
    try:
        out = subprocess.run(["schtasks", "/query", "/tn", task], capture_output=True, timeout=20,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return out.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def launch(script: Path, cwd: Path) -> None:
    """.cmd を、この PC の LifeLog PC とは切り離して動かす（こちらが終わっても続くように）。
    窓の無い自分用の画面で動かすので、中で使う ping・tasklist の窓は出ない（start で起動する LifeLog PC には窓が出る）。"""
    flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(subprocess, "CREATE_NO_WINDOW", 0)
    breakaway = getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0)
    command = [os.environ.get("ComSpec", "cmd.exe"), "/d", "/c", str(script)]
    try:
        subprocess.Popen(command, cwd=str(cwd), creationflags=flags | breakaway, close_fds=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        # 切り離しが許されていないところ（ジョブの中）では、そのまま動かす
        subprocess.Popen(command, cwd=str(cwd), creationflags=flags, close_fds=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def https_context() -> ssl.SSLContext:
    """暗号の設定。SSLKEYLOGFILE が使えない場所を指していても落ちないよう、自分で作る。"""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_default_certs()
    return context


def self_command() -> list[str]:
    """今と同じ起動のしかた（exe と引数。Python なら python とファイルと引数）"""
    if getattr(sys, "frozen", False):
        return [sys.executable, *sys.argv[1:]]
    return [sys.executable, str(Path(sys.argv[0]).resolve()), *sys.argv[1:]]


# MARK: - 確かめる・取ってくる・入れ替える


class Updater:
    def __init__(self, home: Path, build: int, frozen: bool, install: Path, auto: bool,
                 busy: Callable[[], bool], pause: Callable[[], None], resume: Callable[[], None],
                 log: Callable[[str], None], task: str | None = TASK, api: str = API,
                 exit: Callable[[], None] | None = None) -> None:
        self.home = Path(home)
        self.folder = self.home / "update"
        self.build = build
        self.frozen = frozen
        self.install = Path(install)
        self.auto = auto
        self.busy = busy
        self.pause = pause
        self.resume = resume
        self.log = log
        self.task = task
        self.api = api
        self.exit = exit or (lambda: os._exit(0))
        self.cwd = Path.cwd()
        self.running = threading.Lock()
        self.state = "まだ確かめていません"
        self.checked: float | None = None
        self.latest: dict | None = None
        self.error: str | None = None
        self.import_urllib()

    @staticmethod
    def import_urllib() -> None:
        import urllib.request  # noqa: F401 — exe に入るように

    def status(self) -> dict:
        return {"build": self.build, "auto": self.auto, "frozen": self.frozen, "state": self.state,
                "checked": self.checked, "latest": (self.latest or {}).get("tag"), "error": self.error}

    def open(self, url: str, timeout: float = 30.0):
        import urllib.request

        request = urllib.request.Request(url, headers={"User-Agent": f"LifeLogPC/{self.build}",
                                                       "Accept": "application/vnd.github+json"})
        context = https_context() if url.startswith("https:") else None
        return urllib.request.urlopen(request, timeout=timeout, context=context)

    def fetch_releases(self) -> list:
        import urllib.error

        try:
            with self.open(self.api) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code in (403, 429) and error.headers.get("X-RateLimit-Remaining") == "0":
                reset = error.headers.get("X-RateLimit-Reset")
                when = time.strftime("%H:%M", time.localtime(int(reset))) if reset and reset.isdigit() else "しばらく"
                raise RuntimeError(f"GitHub に問い合わせられる回数を使い切りました（{when} まで待ちます）") from error
            raise

    def start(self) -> None:
        """起動して 10 分後に1回、そのあとは 6 時間ごとに確かめる（auto_update が false なら確かめない）"""
        if not self.auto:
            self.state = "自動の更新はオフです（見守りの画面のボタンで確かめられます）"
            self.log("自動の更新はオフです")
            return

        def loop() -> None:
            time.sleep(FIRST_CHECK)
            while True:
                self.run()
                time.sleep(CHECK_EVERY)

        threading.Thread(target=loop, name="updater", daemon=True).start()

    def trigger(self) -> bool:
        """見守りの画面のボタン。裏で確かめる。すでに確かめている最中なら False。"""
        if self.running.locked():
            return False
        threading.Thread(target=self.run, name="updater-now", daemon=True).start()
        return True

    def run(self) -> None:
        if not self.running.acquire(blocking=False):
            return
        try:
            self.check_and_apply()
        except Exception as error:  # noqa: BLE001 — 更新できなくても、いつもどおり動く
            self.error = str(error) or repr(error)
            self.state = "確かめられませんでした"
            self.log(f"更新: うまくいきませんでした: {error!r}")
        finally:
            self.running.release()

    def check_and_apply(self) -> None:
        self.state = "確かめています"
        self.log(f"更新: 新しい版があるか確かめます（今の番号 {self.build}）")
        releases = self.fetch_releases()
        self.checked = time.time()
        self.error = None
        release = pick_release(releases, self.build)
        self.latest = release
        if release is None:
            self.state = "今の版がいちばん新しい版です"
            self.log("更新: 今の版がいちばん新しい版です")
            return
        self.log(f"更新: 新しい版 {release['tag']} があります")
        if not self.frozen:
            self.state = f"新しい版 {release['tag']} があります（Python のまま動いているので、入れ替えません）"
            self.log("更新: Python のまま動いているので、入れ替えません")
            return
        staging = self.prepare(release, self.install)
        self.apply(staging, release)

    def download(self, release: dict) -> Path:
        """zip と sha256 を <home>/update/ に取ってきて、ハッシュを確かめる。合わなければ消して RuntimeError。"""
        self.folder.mkdir(parents=True, exist_ok=True)
        if release.get("zip_size") and shutil.disk_usage(self.folder).free < release["zip_size"] * 4:
            raise RuntimeError("ディスクの空きが足りないので、新しい版を取ってきません")
        with self.open(release["sha"]) as response:
            expected = parse_sha256(response.read(4096).decode("utf-8", "replace"))
        if not expected:
            raise RuntimeError("sha256 のファイルが読めませんでした")
        target = self.folder / f"LifeLogPC-{release['build']}.zip"
        if not verify_sha256(target, expected):
            for old in self.folder.glob("LifeLogPC-*.zip*"):
                old.unlink(missing_ok=True)
            self.state = f"新しい版 {release['tag']} を取ってきています"
            self.log(f"更新: {release['tag']} を取ってきます（{release.get('zip_size', 0) / 1e6:.0f}MB）")
            part = target.with_name(target.name + ".part")
            size = 0
            with self.open(release["zip"], timeout=120) as response, part.open("wb") as f:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > DOWNLOAD_MAX:
                        raise RuntimeError("新しい版の zip が大きすぎます")
                    f.write(chunk)
            part.replace(target)
        if not verify_sha256(target, expected):
            target.unlink(missing_ok=True)
            raise RuntimeError("取ってきた zip のハッシュが合いません（消しました）")
        (self.folder / SHA_NAME).write_text(f"{expected}  {ZIP_NAME}\n", encoding="utf-8")
        self.log(f"更新: ハッシュが合いました（{expected[:12]}…）")
        return target

    def prepare(self, release: dict, install: Path) -> Path:
        """取ってきて、入っているフォルダの隣（「<フォルダ> 新しい版」）に展開する。そのフォルダを返す。"""
        staging = staging_dir(install)
        if read_build(staging) == release["build"] and (staging / EXE_NAME).is_file():
            self.log(f"更新: 展開したものがもうあります（{staging}）")
            return staging
        archive = self.download(release)
        temp = staging.with_name(staging.name + ".tmp")
        for old in (temp, staging):
            if old.exists():
                shutil.rmtree(old)
        temp.mkdir(parents=True)
        self.state = f"新しい版 {release['tag']} を展開しています"
        safe_extract(archive, temp)
        root = find_root(temp)
        if root is None:
            shutil.rmtree(temp, ignore_errors=True)
            raise RuntimeError(f"zip の中に {EXE_NAME} がありません")
        root.replace(staging)
        if temp.exists():
            shutil.rmtree(temp, ignore_errors=True)
        got = read_build(staging)
        if got != release["build"]:
            shutil.rmtree(staging, ignore_errors=True)
            raise RuntimeError(f"展開した版の番号が {got} です（{release['build']} のはず）")
        archive.unlink(missing_ok=True)
        self.log(f"更新: 展開しました（{staging}）")
        return staging

    def apply(self, staging: Path, release: dict) -> None:
        """文字にしている最中のものが無くなるのを待ってから、.cmd に入れ替えを任せて終わる。"""
        self.state = f"新しい版 {release['tag']} に入れ替える時を待っています"
        while True:
            while self.busy():
                time.sleep(IDLE_RETRY)
            self.pause()
            if not self.busy():
                break
            self.resume()
        task = self.task if self.frozen and task_exists(self.task) else None
        log_file = self.home / "log.txt"
        script = self.install.parent / "LifeLogPC-update.cmd"
        try:
            text = update_script(os.getpid(), self.install, staging, backup_dir(self.install), task,
                                 self_command(), self.cwd if self.cwd.exists() else self.install, log_file)
            script.write_text(text, encoding="utf-8")
            launch(script, self.install.parent)
        except Exception:
            self.resume()
            raise
        self.state = f"{release['tag']} に入れ替えるため、終わります"
        self.log(f"更新: {release['tag']} に入れ替えるため、いったん終わります（手順: {script}、"
                 + (f"タスク {task} で起動し直します）" if task else "同じ引数で起動し直します）"))
        time.sleep(0.5)
        self.exit()


def restart(home: Path, task: str | None, log: Callable[[str], None], exit: Callable[[], None] | None = None,
            folder: Path | None = None) -> str:
    """終わってから起動し直す .cmd を動かし、終わる。exe でタスクがあればタスクで、無ければ（Python なら）同じ引数で。"""
    task = task if getattr(sys, "frozen", False) and task_exists(task) else None
    folder = Path(folder) if folder else (Path(sys.executable).parent.parent if getattr(sys, "frozen", False)
                                          else Path(home) / "update")
    try:
        folder.mkdir(parents=True, exist_ok=True)
        script = folder / "LifeLogPC-restart.cmd"
        script.write_text(restart_script(os.getpid(), task, self_command(), Path.cwd(), Path(home) / "log.txt"),
                          encoding="utf-8")
    except OSError:
        folder = Path(home) / "update"
        folder.mkdir(parents=True, exist_ok=True)
        script = folder / "LifeLogPC-restart.cmd"
        script.write_text(restart_script(os.getpid(), task, self_command(), Path.cwd(), Path(home) / "log.txt"),
                          encoding="utf-8")
    launch(script, folder)
    how = f"タスク {task} で" if task else "同じ引数で"
    log(f"見守りの画面から再起動します（{how}起動し直します）")
    threading.Thread(target=lambda: (time.sleep(1.0), (exit or (lambda: os._exit(0)))()), daemon=True).start()
    return how
