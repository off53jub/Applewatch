"""App Store Connect の API を使う CI の手伝い（2026-11-07）。

    python asc.py cleanup-certs              CI が前に作った開発用の証明書（作られて2時間より前のもの）を片づける
    python asc.py revoke-own-cert            この CI の中で作った開発用の証明書を片づける（キーチェーンにあるもの）
    python asc.py wait-upload <番号>          送ったビルドの受け付け結果を待つ。弾かれたら理由を出して失敗にする。
                                            main のときは、内部テストのグループにそのビルドを渡す

環境変数: ASC_KEY_ID・ASC_ISSUER_ID と、ASC_KEY_PATH（.p8 のファイル）。
リポジトリは公開なので、人の名前・メールアドレス・証明書の名前は記録に出さない。
片づける証明書は「API で作られた（Created via API）開発用」だけ。Sideloadly などほかの作り方の証明書には触らない。
"""

from __future__ import annotations

import datetime
import os
import subprocess
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.off53jub.lifelog"
API_MADE = "Created via API"


def token() -> str:
    pem = open(os.environ["ASC_KEY_PATH"], encoding="utf-8").read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                      pem, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method: str, path: str, json: dict | None = None, **params):
    r = requests.request(method, BASE + path, headers={"Authorization": f"Bearer {token()}"},
                         json=json, params=params, timeout=60)
    if r.status_code >= 400:
        try:
            errs = [(e.get("code"), e.get("title")) for e in r.json().get("errors", [])]
        except ValueError:
            errs = []
        raise RuntimeError(f"{method} {path} → {r.status_code} {errs}")
    return r.json() if r.content else {}


def api_dev_certs() -> list[dict]:
    rows = call("GET", "/v1/certificates", limit=200,
                **{"fields[certificates]": "certificateType,displayName,expirationDate,serialNumber"}).get("data", [])
    return [c for c in rows
            if c["attributes"].get("certificateType") in ("DEVELOPMENT", "IOS_DEVELOPMENT")
            and c["attributes"].get("displayName") == API_MADE]


def made_at(cert: dict) -> datetime.datetime | None:
    """開発用の証明書は1年で切れるので、切れる日から作った日を出す"""
    text = cert["attributes"].get("expirationDate")
    if not text:
        return None
    try:
        end = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return end - datetime.timedelta(days=365)


def cleanup_certs() -> None:
    now = datetime.datetime.now(datetime.timezone.utc)
    certs = api_dev_certs()
    old = [c for c in certs if (made_at(c) or now) < now - datetime.timedelta(hours=2)]
    print(f"API で作られた開発用の証明書: {len(certs)} 枚。そのうち2時間より前のもの: {len(old)} 枚を片づけます")
    for c in old:
        try:
            call("DELETE", f"/v1/certificates/{c['id']}")
        except RuntimeError as error:
            print(f"::warning::証明書を片づけられませんでした: {error}")


def keychain_serials() -> set[str]:
    """この CI のキーチェーンにある Apple Development の証明書の番号"""
    try:
        pems = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                              capture_output=True, text=True, check=False).stdout
    except OSError:
        return set()
    serials = set()
    block = []
    for line in pems.splitlines():
        block.append(line)
        if line.startswith("-----END CERTIFICATE-----"):
            out = subprocess.run(["openssl", "x509", "-noout", "-serial"], input="\n".join(block) + "\n",
                                 capture_output=True, text=True, check=False).stdout
            if "=" in out:
                serials.add(out.split("=", 1)[1].strip().upper().lstrip("0"))
            block = []
    return serials


def revoke_own_cert() -> None:
    mine = keychain_serials()
    if not mine:
        print("この CI のキーチェーンに開発用の証明書はありません")
        return
    done = 0
    for c in api_dev_certs():
        serial = (c["attributes"].get("serialNumber") or "").upper().lstrip("0")
        if serial and serial in mine:
            try:
                call("DELETE", f"/v1/certificates/{c['id']}")
                done += 1
            except RuntimeError as error:
                print(f"::warning::証明書を片づけられませんでした: {error}")
    print(f"この CI で作った開発用の証明書を {done} 枚片づけました")


def app_id() -> str | None:
    apps = call("GET", "/v1/apps", **{"filter[bundleId]": BUNDLE_ID}).get("data", [])
    return apps[0]["id"] if apps else None


def give_to_testers(app: str, number: str) -> None:
    """内部テストのグループ（すべてのビルドを自動で受け取る設定は切る）に、このビルドを渡す"""
    build = None
    for _ in range(10):
        rows = call("GET", "/v1/builds", **{"filter[app]": app, "filter[version]": number, "limit": 5}).get("data", [])
        if rows:
            build = rows[0]["id"]
            break
        time.sleep(30)
    if build is None:
        print("::warning::ビルドが見つからないので、テスターに渡せませんでした")
        return
    for g in call("GET", f"/v1/apps/{app}/betaGroups", limit=50).get("data", []):
        if not g["attributes"].get("isInternalGroup"):
            continue
        try:
            call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", json={"data": [{"type": "builds", "id": build}]})
            print(f"内部テストのグループ「{g['attributes'].get('name')}」にビルド {number} を渡しました")
        except RuntimeError as error:
            print(f"::warning::ビルドをグループに渡せませんでした: {error}")


def stop_auto_distribution(app: str) -> None:
    """PR のビルドが本人に届かないよう、内部テストのグループの「すべてのビルドを自動で受け取る」を切る（main だけ CI が渡す）"""
    for g in call("GET", f"/v1/apps/{app}/betaGroups", limit=50).get("data", []):
        a = g["attributes"]
        if a.get("isInternalGroup") and a.get("hasAccessToAllBuilds"):
            try:
                call("PATCH", f"/v1/betaGroups/{g['id']}",
                     json={"data": {"type": "betaGroups", "id": g["id"], "attributes": {"hasAccessToAllBuilds": False}}})
                print(f"グループ「{a.get('name')}」は、main のビルドだけを受け取るようにしました")
            except RuntimeError as error:
                print(f"::warning::グループの設定を変えられませんでした: {error}")


def wait_upload(number: str) -> None:
    app = app_id()
    if app is None:
        print("::warning::App Store Connect にアプリが見つからないので、受け付け結果を確かめられません")
        return
    stop_auto_distribution(app)
    deadline = time.time() + 35 * 60
    while time.time() < deadline:
        ups = [u for u in call("GET", f"/v1/apps/{app}/buildUploads", limit=20).get("data", [])
               if str(u["attributes"].get("cfBundleVersion")) == number]
        if ups:
            state = ups[0]["attributes"].get("state") or {}
            name = state.get("state")
            print(time.strftime("%H:%M:%S"), "受け付けの状態:", name)
            if name == "FAILED":
                for e in state.get("errors", []):
                    print(f"::error::Apple に弾かれました（ITMS-{e.get('code')}）: {e.get('description')}")
                sys.exit(1)
            if name == "COMPLETE":
                for w in state.get("warnings", []):
                    print(f"::warning::Apple からの注意（ITMS-{w.get('code')}）: {w.get('description')}")
                print("Apple が受け付けました")
                on_main = os.environ.get("GITHUB_REF") == "refs/heads/main" \
                    and os.environ.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch")
                if on_main:
                    give_to_testers(app, number)
                else:
                    print("main ではないので、テスターには渡しません（TestFlight の一覧には出ます）")
                return
        time.sleep(60)
    print("::warning::35 分待っても受け付けの結果が出ませんでした。App Store Connect の TestFlight を見てください")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "cleanup-certs":
        cleanup_certs()
    elif command == "revoke-own-cert":
        revoke_own_cert()
    elif command == "wait-upload" and len(sys.argv) > 2:
        wait_upload(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
