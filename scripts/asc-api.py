#!/usr/bin/env python3
"""App Store Connect API 的只读查询工具（外加一个上传前的重号检查）。

用法:
    scripts/asc-api.py preflight            # 一把梭：把发 TestFlight 缺的东西列出来
    scripts/asc-api.py apps
    scripts/asc-api.py bundle-ids
    scripts/asc-api.py certs
    scripts/asc-api.py profiles
    scripts/asc-api.py builds
    scripts/asc-api.py check-build --version 0.3.27 --build 327

凭据(两样都要):
    Key ID     环境变量 PENDINGNET_ASC_KEY_ID，默认 9PS6Y7K4X9
    私钥       ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8
    Issuer ID  环境变量 PENDINGNET_ASC_ISSUER_ID，或 ~/.appstoreconnect/issuer_id

Issuer ID 不写进仓库 —— 它标识的是主人的开发者账号，和构建产物无关，
放在家目录里由脚本自己找。

这里**只读**（check-build 也只是查询后决定退出码）。建证书、建描述文件都不在
这儿做：那两件由 `xcodebuild -exportArchive -allowProvisioningUpdates` 连着同一把
API 密钥自动完成，比这里手搓 CSR 再导入钥匙串可靠得多。见
scripts/build-ios-testflight.sh 和 docs/ios-testflight.md。
"""

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "com.pendingname.pendingnet"
EXTENSION_BUNDLE_ID = "com.pendingname.pendingnet.extension"
APP_GROUP = "group.com.pendingname.pendingnet"
TEAM_ID = "M42BKJN82S"
API = "https://api.appstoreconnect.apple.com"


def die(msg, code=2):
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def credentials():
    key_id = os.environ.get("PENDINGNET_ASC_KEY_ID", "9PS6Y7K4X9")
    home = pathlib.Path.home()

    issuer = os.environ.get("PENDINGNET_ASC_ISSUER_ID", "").strip()
    issuer_file = home / ".appstoreconnect" / "issuer_id"
    if not issuer and issuer_file.is_file():
        issuer = issuer_file.read_text().strip()
    if not issuer:
        die(
            "缺 Issuer ID —— 设 PENDINGNET_ASC_ISSUER_ID，或把它写进 %s\n"
            "（App Store Connect →「用户和访问」→「集成 / 密钥」页右上角那一行）"
            % issuer_file
        )

    key_path = home / ".appstoreconnect" / "private_keys" / ("AuthKey_%s.p8" % key_id)
    if not key_path.is_file():
        die("找不到私钥 %s" % key_path)
    try:
        key = key_path.read_text()
    except OSError as exc:
        die(
            "读不了私钥 %s: %s\n"
            "如果它是指向「文稿」文件夹的软链，把真文件挪到 private_keys/ 下面 ——"
            "系统的隐私保护不让后台进程读「文稿」。" % (key_path, exc)
        )
    if "BEGIN PRIVATE KEY" not in key:
        die("私钥 %s 内容不像 .p8（缺 BEGIN PRIVATE KEY）" % key_path)
    return key_id, issuer, key


def token():
    try:
        import jwt  # PyJWT
    except ImportError:
        die("缺 PyJWT —— 跑 `python3 -m pip install --user pyjwt cryptography`")
    key_id, issuer, key = credentials()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def get(path, bearer, **params):
    """GET 一个端点，自动翻页，返回 (data, included)。"""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    data, included = [], []
    while url:
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + bearer})
        try:
            body = json.load(urllib.request.urlopen(req, timeout=30))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            if exc.code == 401:
                die("Apple 拒绝了这把密钥 (401)。Key ID / Issuer ID / 私钥三者对不上。\n" + detail)
            die("App Store Connect 接口报错 %s %s\n%s" % (exc.code, url, detail))
        except urllib.error.URLError as exc:
            die("连不上 App Store Connect: %s" % exc)
        payload = body.get("data")
        data.extend(payload if isinstance(payload, list) else [payload])
        included.extend(body.get("included") or [])
        url = (body.get("links") or {}).get("next")
    return data, included


def find_app(bearer, bundle_id=BUNDLE_ID):
    apps, _ = get("/v1/apps", bearer, **{"filter[bundleId]": bundle_id, "limit": 200})
    # filter[bundleId] 是模糊匹配，会把 .extension 之类的子 id 一起捞回来。
    for app in apps:
        if app and app["attributes"].get("bundleId") == bundle_id:
            return app
    return None


# ---------------------------------------------------------------- 子命令


def cmd_apps(args, bearer):
    apps, _ = get("/v1/apps", bearer, limit=200)
    if not apps or apps == [None]:
        print("这个账号下一个 App 记录都没有。")
        return 0
    for app in apps:
        a = app["attributes"]
        print("%-40s %-30s id=%s" % (a.get("bundleId"), a.get("name"), app["id"]))
    return 0


def cmd_bundle_ids(args, bearer):
    ids, included = get(
        "/v1/bundleIds", bearer, limit=200, include="bundleIdCapabilities"
    )
    caps = {c["id"]: c for c in included if c["type"] == "bundleIdCapabilities"}
    for b in ids:
        a = b["attributes"]
        if not a.get("identifier", "").startswith(BUNDLE_ID):
            continue
        rel = (b.get("relationships") or {}).get("bundleIdCapabilities") or {}
        names = sorted(
            caps[r["id"]]["attributes"]["capabilityType"]
            for r in (rel.get("data") or [])
            if r["id"] in caps
        )
        print("%-45s %s" % (a["identifier"], a.get("name")))
        print("    能力: %s" % (", ".join(names) if names else "（一个都没开）"))
    return 0


def cmd_certs(args, bearer):
    certs, _ = get("/v1/certificates", bearer, limit=200)
    for c in certs:
        a = c["attributes"]
        print(
            "%-28s %-45s 到期 %s"
            % (a.get("certificateType"), a.get("name"), a.get("expirationDate"))
        )
    return 0


def cmd_profiles(args, bearer):
    profiles, included = get("/v1/profiles", bearer, limit=200, include="bundleId")
    bundles = {b["id"]: b["attributes"]["identifier"] for b in included if b["type"] == "bundleIds"}
    for p in profiles:
        a = p["attributes"]
        rel = ((p.get("relationships") or {}).get("bundleId") or {}).get("data") or {}
        print(
            "%-30s %-22s %-10s %s"
            % (
                bundles.get(rel.get("id"), "?"),
                a.get("profileType"),
                a.get("profileState"),
                a.get("name"),
            )
        )
    return 0


def _builds(bearer):
    app = find_app(bearer)
    if app is None:
        return None, []
    builds, included = get(
        "/v1/builds",
        bearer,
        **{"filter[app]": app["id"], "limit": 200, "include": "preReleaseVersion"}
    )
    versions = {
        v["id"]: v["attributes"]["version"]
        for v in included
        if v["type"] == "preReleaseVersions"
    }
    rows = []
    for b in builds:
        if not b:
            continue
        rel = ((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
        rows.append(
            {
                "version": versions.get(rel.get("id"), "?"),
                "build": b["attributes"].get("version"),
                "state": b["attributes"].get("processingState"),
                "expired": b["attributes"].get("expired"),
                "uploaded": b["attributes"].get("uploadedDate"),
            }
        )
    return app, rows


def cmd_builds(args, bearer):
    app, rows = _builds(bearer)
    if app is None:
        print("App Store Connect 里还没有 %s 这个 App 记录。" % BUNDLE_ID)
        return 1
    if not rows:
        print("App 记录在（id=%s），但一个构建都还没传上去。" % app["id"])
        return 0
    for r in rows:
        print(
            "%-10s (%-6s) %-12s %s%s"
            % (
                r["version"],
                r["build"],
                r["state"],
                r["uploaded"],
                " [已过期]" if r["expired"] else "",
            )
        )
    return 0


def cmd_check_build(args, bearer):
    """上传前的重号检查：同一个 marketing version 下 build 号必须没用过。"""
    app, rows = _builds(bearer)
    if app is None:
        die(
            "App Store Connect 里没有 %s 的 App 记录 —— 传上去也无处可落。\n"
            "建记录只能在网页上点一次，步骤见 docs/ios-testflight.md。" % BUNDLE_ID,
            3,
        )
    for r in rows:
        if str(r["build"]) == str(args.build) and r["version"] == args.version:
            die(
                "版本 %s 的 build 号 %s 已经传过了（%s，状态 %s）—— Apple 会原样退回。\n"
                "先把 app/project.yml 里的 CURRENT_PROJECT_VERSION 往上加。"
                % (args.version, args.build, r["uploaded"], r["state"]),
                3,
            )
    print("build 号可用：%s (%s) 在 App Store Connect 上还没出现过。" % (args.version, args.build))
    return 0


def cmd_preflight(args, bearer):
    """把「离能发 TestFlight 还差什么」一次性列清楚。"""
    blocking = []

    print("== App 记录 ==")
    app = find_app(bearer)
    if app is None:
        print("  ✗ 没有 %s 的 App 记录" % BUNDLE_ID)
        blocking.append("在 App Store Connect 网页上新建 App 记录（只能手点，见 docs/ios-testflight.md）")
    else:
        a = app["attributes"]
        print("  ✓ %s（%s，id=%s）" % (a.get("name"), BUNDLE_ID, app["id"]))

    print("== 标识符与能力 ==")
    ids, included = get("/v1/bundleIds", bearer, limit=200, include="bundleIdCapabilities")
    caps_by_id = {c["id"]: c for c in included if c["type"] == "bundleIdCapabilities"}
    found = {}
    for b in ids:
        ident = b["attributes"].get("identifier")
        if ident in (BUNDLE_ID, EXTENSION_BUNDLE_ID):
            rel = (b.get("relationships") or {}).get("bundleIdCapabilities") or {}
            found[ident] = {
                caps_by_id[r["id"]]["attributes"]["capabilityType"]
                for r in (rel.get("data") or [])
                if r["id"] in caps_by_id
            }
    for ident, needed in (
        (BUNDLE_ID, {"NETWORK_EXTENSIONS", "APP_GROUPS", "ICLOUD"}),
        (EXTENSION_BUNDLE_ID, {"NETWORK_EXTENSIONS", "APP_GROUPS"}),
    ):
        if ident not in found:
            print("  ✗ 门户里没有标识符 %s" % ident)
            blocking.append("标识符 %s 不存在（archive 时带 -allowProvisioningUpdates 会自动建）" % ident)
            continue
        missing = needed - found[ident]
        if missing:
            print("  ✗ %s 缺能力: %s" % (ident, ", ".join(sorted(missing))))
            blocking.append("给 %s 打开 %s" % (ident, ", ".join(sorted(missing))))
        else:
            print("  ✓ %s: %s" % (ident, ", ".join(sorted(found[ident]))))

    print("== 分发证书 ==")
    certs, _ = get("/v1/certificates", bearer, limit=200)
    dist = [
        c
        for c in certs
        if c["attributes"].get("certificateType") in ("DISTRIBUTION", "IOS_DISTRIBUTION")
    ]
    if dist:
        for c in dist:
            print("  ✓ %s（到期 %s）" % (c["attributes"].get("name"), c["attributes"].get("expirationDate")))
    else:
        # 这里空着**不代表缺证书**。Xcode 的云托管签名用的是 DISTRIBUTION_MANAGED
        # 类型的证书和描述文件，走的是 appstoreconnect.apple.com/xcbuild 那套内部
        # 接口，公开的 /v1/certificates 和 /v1/profiles 一概看不到它们。
        # 能不能签成，只有导出那一步说了算 —— 所以这条不当作阻塞项。
        print("  · 公开接口里没有自建的分发证书；Xcode 云托管的那张这里看不见，")
        print("    导出时会自动取用或新建，不用手点")

    print("== TestFlight 构建 ==")
    if app is not None:
        _, rows = _builds(bearer)
        if rows:
            for r in rows[:5]:
                print("  · %s (%s) %s" % (r["version"], r["build"], r["state"]))
        else:
            print("  · 还没有任何构建")

    print()
    if blocking:
        print("还差这些才能发：")
        for i, item in enumerate(blocking, 1):
            print("  %d. %s" % (i, item))
        return 1
    print("门槛都过了 —— 可以跑 scripts/build-ios-testflight.sh")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("apps", "bundle-ids", "certs", "profiles", "builds", "preflight"):
        sub.add_parser(name)
    cb = sub.add_parser("check-build")
    cb.add_argument("--version", required=True)
    cb.add_argument("--build", required=True)

    args = parser.parse_args()
    handler = {
        "apps": cmd_apps,
        "bundle-ids": cmd_bundle_ids,
        "certs": cmd_certs,
        "profiles": cmd_profiles,
        "builds": cmd_builds,
        "check-build": cmd_check_build,
        "preflight": cmd_preflight,
    }[args.cmd]
    return handler(args, token())


if __name__ == "__main__":
    raise SystemExit(main())
