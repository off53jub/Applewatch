"""LifeLog PC: s26 結4（2026-11-25。担当 P）。写真に写っている人を、家の PC の中だけで顔のまとまりにする。**初めはオフ**。

- config.json の "s26p_faces": true のときだけ、夜 00:00〜05:00 に動く。
- 顔の数字（顔の特徴の数の並び）は **この PC の HOME/s26p/faces/ の中だけ**に置く。母艦・ドライブ・リポジトリ・ログには出さない。
- モデル: OpenCV の公式（Hugging Face の opencv 組織）の YuNet（顔を探す）と SFace（顔の特徴）。夜の仕事の中で初めてのときだけ取ってくる。
  部品の opencv-python は入っていない（requirements に足していない）。入っていなければ「部品がありません」と数えて何もしない。
- 写真: 母艦の archive/photos/YYYY/MM/DD.md の索引（「## フォルダ」と「- HH:MM:SS 📷 名前」）から、写真の置き場
  （config.json の "photo_root"。既定 P:\\）の .jpg・.jpeg・.png を読む（HEIC は読めない＝数えるだけ）。1 晩 FACE_NIGHT 枚まで。
- まとまり: 顔の近さ（cos）が FACE_LINK（仮）以上なら同じまとまり。2 枚以上の写真に出たまとまりだけを
  HOME/s26p/faces/clusters.json に（数の並びは入れない。写真の名前・日・枚数だけ）。
- 名前: 本人が 1 回、まとまりに名前を付ける（POST /face-name {"cluster": id, "name": str}。この PC の中（127.0.0.1）からだけ）。
  名前の付いたまとまりは、母艦 inbox/pc-faces/s26p_faces.json に {名前: [{"day","photo"}]}（顔の数字は入れない）を置く。
  母艦の人のページ・「誰といたか」に使うのは M（母艦）。人物ノートを新しく作るのは事実 2 件以上の決まりのまま。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import time
from pathlib import Path

import numpy as np

FACES = Path("s26p") / "faces"
DETECT = ("opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx")
RECOG = ("opencv/face_recognition_sface", "face_recognition_sface_2021dec.onnx")
FACE_NIGHT = 400
FACE_LINK = 0.45          # 仮（SFace の cos の目安は 0.363）
FACE_SCORE = 0.9
FACE_DAYS = 14
PHOTO_LINE = re.compile(r"^- (\d{2}:\d{2}:\d{2})(?:-\d{2}:\d{2}:\d{2})? \S+ (.+?\.(?:jpe?g|png|heic|heif))\b", re.IGNORECASE)
HEAD = re.compile(r"^## (.+)$")
POSTS = ("/face-name",)


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


def on(config: dict) -> bool:
    return (config or {}).get("s26p_faces") is True


def photos_of(base: Path, day: str, root: Path) -> list[tuple[str, Path]]:
    """その日の写真 [(名前, 置き場のファイル)]（索引の順）"""
    path = Path(base) / "archive" / "photos" / day[:4] / day[5:7] / f"{day[8:10]}.md"
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    out, folder = [], None
    for raw in lines:
        head = HEAD.match(raw)
        if head:
            folder = head.group(1).strip()
            continue
        m = PHOTO_LINE.match(raw)
        if m and folder:
            name = m.group(2).strip()
            out.append((name, Path(root) / folder.replace("\\", os.sep) / name))
    return out


class Models:
    def __init__(self, home: Path) -> None:
        import importlib

        try:
            self.cv2 = importlib.import_module("cv2")
        except Exception as error:  # noqa: BLE001
            raise RuntimeError(f"opencv-python の部品がありません（{type(error).__name__}）") from error
        from huggingface_hub import hf_hub_download

        place = Path(home) / FACES / "models"
        detect = hf_hub_download(repo_id=DETECT[0], filename=DETECT[1], local_dir=str(place))
        recog = hf_hub_download(repo_id=RECOG[0], filename=RECOG[1], local_dir=str(place))
        self.detector = self.cv2.FaceDetectorYN.create(detect, "", (320, 320), FACE_SCORE)
        self.recognizer = self.cv2.FaceRecognizerSF.create(recog, "")

    def faces(self, path: Path) -> list[np.ndarray]:
        image = self.cv2.imread(str(path))
        if image is None:
            return []
        h, w = image.shape[:2]
        scale = min(1.0, 1280 / max(h, w))
        if scale < 1.0:
            image = self.cv2.resize(image, (int(w * scale), int(h * scale)))
            h, w = image.shape[:2]
        self.detector.setInputSize((w, h))
        _, found = self.detector.detect(image)
        out = []
        for face in found if found is not None else []:
            aligned = self.recognizer.alignCrop(image, face)
            feature = np.asarray(self.recognizer.feature(aligned), dtype=np.float32).reshape(-1)
            norm = float(np.linalg.norm(feature))
            if norm > 0:
                out.append(feature / norm)
        return out


def embed_night(home: Path, base: Path | None, config: dict, today: datetime.date, models=None,
                deadline: float | None = None) -> dict:
    """まだ見ていない写真の顔を数える（数の並びは HOME/s26p/faces/vectors.npz だけ）。{"photos","faces","heic","missing"}"""
    out = {"photos": 0, "faces": 0, "heic": 0, "missing": 0}
    if base is None:
        return out
    store = Path(home) / FACES / "vectors.npz"
    keys, vecs = [], []
    try:
        with np.load(store, allow_pickle=False) as data:
            keys, vecs = [str(k) for k in data["keys"]], list(np.asarray(data["vecs"], dtype=np.float32))
    except (OSError, KeyError, ValueError):
        pass
    seen_path = Path(home) / FACES / "seen.json"
    seen = set((_read(seen_path, {}) or {}).get("photos") or [])
    root = Path(str(config.get("photo_root") or "P:\\"))
    models = models or Models(home)
    for back in range(1, FACE_DAYS + 1):
        day = (today - datetime.timedelta(days=back)).isoformat()
        for name, path in photos_of(base, day, root):
            ident = f"{day}|{name}"
            if ident in seen:
                continue
            if out["photos"] >= FACE_NIGHT or (deadline is not None and time.time() > deadline):
                break
            if path.suffix.lower() in (".heic", ".heif"):
                out["heic"] += 1
                seen.add(ident)
                continue
            if not path.is_file():
                out["missing"] += 1
                continue
            for i, vector in enumerate(models.faces(path)):
                keys.append(f"{ident}|{i}")
                vecs.append(vector)
                out["faces"] += 1
            seen.add(ident)
            out["photos"] += 1
    store.parent.mkdir(parents=True, exist_ok=True)
    part = store.with_name("vectors.part.npz")
    np.savez(part, keys=np.array(keys, dtype=str),
             vecs=np.stack(vecs).astype(np.float32) if vecs else np.zeros((0, 128), np.float32))
    os.replace(part, store)
    _write(seen_path, {"photos": sorted(seen)})
    return out


def cluster(keys: list[str], vecs: np.ndarray, link: float = FACE_LINK) -> list[list[int]]:
    """近い顔から束へ（束の真ん中との近さが link 以上なら入れる）"""
    centers, sums, members = [], [], []
    for i, v in enumerate(vecs):
        if centers:
            sims = np.stack(centers) @ v
            k = int(np.argmax(sims))
            if sims[k] >= link:
                sums[k] = sums[k] + v
                centers[k] = sums[k] / max(float(np.linalg.norm(sums[k])), 1e-9)
                members[k].append(i)
                continue
        centers.append(v)
        sums.append(v.copy())
        members.append([i])
    return members


def build_clusters(home: Path, base: Path | None) -> dict:
    """HOME/s26p/faces/clusters.json（写真 2 枚以上のまとまりだけ。数の並びは入れない）と、名前の付いたものを母艦へ"""
    try:
        with np.load(Path(home) / FACES / "vectors.npz", allow_pickle=False) as data:
            keys, vecs = [str(k) for k in data["keys"]], np.asarray(data["vecs"], dtype=np.float32)
    except (OSError, KeyError, ValueError):
        keys, vecs = [], np.zeros((0, 128), np.float32)
    names = (_read(Path(home) / FACES / "names.json", {}) or {}).get("keys") or {}
    clusters = []
    for group in cluster(keys, vecs):
        photos = sorted({"|".join(keys[i].split("|")[:2]) for i in group})
        if len(photos) < 2:
            continue
        ident = "fc-" + hashlib.sha256(min(keys[i] for i in group).encode("utf-8")).hexdigest()[:12]
        named = [names[keys[i]] for i in group if keys[i] in names]
        clusters.append({"id": ident, "photos": len(photos), "faces": len(group),
                         "days": sorted({p.split("|")[0] for p in photos}),
                         "samples": [p.split("|")[1] for p in photos[:3]], "name": named[0] if named else None,
                         "_members": [keys[i] for i in group], "_photos": photos})
    clusters.sort(key=lambda c: -c["photos"])
    public = [{k: v for k, v in c.items() if not k.startswith("_")} for c in clusters]
    _write(Path(home) / FACES / "clusters.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                                  "clusters": public, "note": "s26 結4（仮）。この PC の中だけ"})
    _write(Path(home) / FACES / "members.json", {c["id"]: c["_members"] for c in clusters})
    people: dict[str, list] = {}
    for c in clusters:
        if c["name"]:
            people.setdefault(c["name"], []).extend({"day": p.split("|")[0], "photo": p.split("|")[1]} for p in c["_photos"])
    if base is not None and Path(base).is_dir() and people:
        try:
            _write(Path(base) / "inbox" / "pc-faces" / "s26p_faces.json",
                   {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                    "people": people, "note": "家の PC の顔のまとまりに本人が付けた名前（顔の数字は入れない）"})
        except OSError:
            pass
    return {"clusters": len(public), "named": sum(1 for c in public if c["name"])}


def name_cluster(home: Path, cluster_id: str, name: str) -> bool:
    members = (_read(Path(home) / FACES / "members.json", {}) or {}).get(cluster_id)
    if not members or not isinstance(name, str) or not name.strip() or len(name) > 40:
        return False
    path = Path(home) / FACES / "names.json"
    body = _read(path, {}) or {}
    keys = body.get("keys") if isinstance(body.get("keys"), dict) else {}
    keys[members[0]] = name.strip()
    _write(path, {"keys": keys})
    return True


def http_post(handler, home: Path, base: Path | None) -> None:
    """POST /face-name（この PC の中から・合言葉は lifelog_pc.py が確かめてから）"""
    if handler.client_address[0] not in ("127.0.0.1", "::1"):
        handler.send_json(403, {"ok": False, "error": "この PC の中からだけです"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
        body = json.loads(handler.rfile.read(length).decode("utf-8")) if 0 < length <= 4096 else None
    except (ValueError, UnicodeDecodeError):
        body = None
    if not isinstance(body, dict) or not name_cluster(home, str(body.get("cluster") or ""), body.get("name")):
        handler.send_json(400, {"ok": False, "error": "cluster と name（40 字まで）を確かめてください"})
        return
    build_clusters(home, base)
    handler.send_json(200, {"ok": True})
