#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tpi-update-sync 的本地端到端测试台：起一个假上游 HTTP 服务，跑真实同步脚本。"""

import base64
import hashlib
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading

def _find_repo_root(start):
    """向上找带 package.json 的目录 —— 这样本文件放在 scripts/ 还是 scripts/server/ 都不会算错根目录"""
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "package.json")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.abspath(start)
        d = parent


ROOT = _find_repo_root(os.path.dirname(__file__))

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

SYNC = os.path.join(ROOT, "scripts", "server", "tpi-update-sync.py")
BASE = os.path.join(ROOT, "tmp", "_synctest")
UP = os.path.join(BASE, "upstream")
DEST = os.path.join(BASE, "dest")
PORT = 18877

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'[OK]  ' if cond else '[FAIL]'} {name}{('  ' + detail) if detail else ''}")


def sha512_b64(path):
    h = hashlib.sha512()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()


def make_asset(version, size=100_000, content=None):
    """生成一个假安装包 + blockmap，返回 (yml_url, sha512, size, blockmap_name)"""
    d = os.path.join(UP, "releases", "download", f"v{version}")
    os.makedirs(d, exist_ok=True)
    name = f"TutorPi-Setup-{version}.exe"
    p = os.path.join(d, name)
    with open(p, "wb") as f:
        f.write(content if content is not None else os.urandom(size))
    bm = name + ".blockmap"
    with open(os.path.join(d, bm), "wb") as f:
        f.write(b"blockmap")
    url = f"http://127.0.0.1:{PORT}/releases/download/v{version}/{name}"
    return url, sha512_b64(p), os.path.getsize(p), bm


def write_upstream(version, url, sha, size, bm, omit_asset=False):
    if omit_asset:
        # 指向一个不存在的文件，模拟“忘了上传资产”
        url = f"http://127.0.0.1:{PORT}/releases/download/v{version}/NOT-UPLOADED.exe"
    yml = (
        f"version: {version}\n"
        f"files:\n"
        f"  - url: {url}\n"
        f"    sha512: {sha}\n"
        f"    size: {size}\n"
        f"path: {url}\n"
        f"sha512: {sha}\n"
        f"releaseDate: '2026-09-28T00:00:00.000Z'\n"
    )
    with open(os.path.join(UP, "latest.yml"), "w", encoding="utf-8", newline="") as f:
        f.write(yml)
    meta = {
        "schema": 1,
        "channel": "stable",
        "version": version,
        "tag": f"v{version}",
        "mandatory": False,
        "minSupported": None,
        "notes": f"test {version}",
        "artifacts": {
            "desktop-nsis": {"file": os.path.basename(url), "size": size, "sha512": sha, "blockmap": bm},
        },
    }
    with open(os.path.join(UP, "latest.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)


def run_sync(label, extra_env=None, args=None):
    env = dict(os.environ)
    env["TPI_SYNC_SOURCES"] = f"http://127.0.0.1:{PORT}"
    env["TPI_SYNC_DEST"] = DEST
    env["TPI_SYNC_REQUIRE_HOST"] = "releases/download/"
    env["TPI_SYNC_HISTORY_KEEP"] = "3"
    env["TPI_SYNC_ASSET_TIMEOUT"] = "10"
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    if extra_env:
        env.update(extra_env)
    cmd = [sys.executable, SYNC, "-v"] + (args or [])
    print(f"\n--- {label} ---")
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=ROOT, timeout=180)
    for line in r.stdout.strip().splitlines():
        print("   |", line)
    if r.stderr.strip():
        for line in r.stderr.strip().splitlines()[-12:]:
            print("   !", line)
    if r.returncode != 0:
        print(f"   [exit {r.returncode}]")
    return r


def read_dest(name):
    p = os.path.join(DEST, name)
    return open(p, encoding="utf-8").read() if os.path.isfile(p) else None


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(UP, exist_ok=True)
    os.makedirs(DEST, exist_ok=True)

    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=UP, **k)  # noqa: E731
    socketserver.TCPServer.allow_reuse_address = True  # 重复跑测试时避免 TIME_WAIT 绑不上
    httpd = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"假上游已启动: http://127.0.0.1:{PORT}  →  {UP}")

    # 让日志干净点：屏蔽 http.server 的每请求输出
    logging = http.server.SimpleHTTPRequestHandler.log_message
    http.server.SimpleHTTPRequestHandler.log_message = lambda *a, **k: None

    # ---------- S1 首次同步 ----------
    url, sha, size, bm = make_asset("1.2.3")
    write_upstream("1.2.3", url, sha, size, bm)
    r = run_sync("S1 首次同步 1.2.3")
    check("S1 退出码 0", r.returncode == 0)
    yml = read_dest("latest.yml") or ""
    check("S1 latest.yml 写入且版本正确", "version: 1.2.3" in yml)
    check("S1 latest.json 写入", (read_dest("latest.json") or "").find('"1.2.3"') > 0)
    check("S1 首次不产生 history", not os.path.isdir(os.path.join(DEST, "history")) or
          not os.listdir(os.path.join(DEST, "history")))

    # ---------- S2 幂等 ----------
    r = run_sync("S2 上游未变 → 应无动作")
    check("S2 退出码 0", r.returncode == 0)
    check("S2 日志显示无需改动", "无需改动" in r.stdout)

    # ---------- S3 版本提升 + 历史备份 ----------
    url2, sha2, size2, bm2 = make_asset("1.2.4", content=b"new-version-payload")
    write_upstream("1.2.4", url2, sha2, size2, bm2)
    r = run_sync("S3 提升到 1.2.4")
    check("S3 退出码 0", r.returncode == 0)
    check("S3 latest.yml 更新", "version: 1.2.4" in (read_dest("latest.yml") or ""))
    hdir = os.path.join(DEST, "history", "1.2.3")
    check("S3 旧版本进 history/1.2.3", os.path.isfile(os.path.join(hdir, "latest.yml")))
    if os.path.isfile(os.path.join(hdir, "latest.yml")):
        check(
            "S3 history 里是旧版本",
            "version: 1.2.3" in open(os.path.join(hdir, "latest.yml"), encoding="utf-8").read(),
        )

    # ---------- S4 关键资产 404 → 拒绝提升 ----------
    url3, sha3, size3, bm3 = make_asset("1.2.5")
    write_upstream("1.2.5", url3, sha3, size3, bm3, omit_asset=True)
    r = run_sync("S4 关键资产 404 → 应拒绝提升")
    check("S4 退出码非 0", r.returncode != 0, f"exit={r.returncode}")
    check("S4 明确写了拒绝提升", "拒绝提升" in r.stdout)
    check("S4 现有元数据【未被改动】", "version: 1.2.4" in (read_dest("latest.yml") or ""))

    # ---------- S5 上游整体不可用 → stale-if-error ----------
    os.rename(os.path.join(UP, "latest.yml"), os.path.join(UP, "latest.yml.hidden"))
    r = run_sync("S5 上游 404 → 应保持现有文件")
    check("S5 退出码 0（不算错误）", r.returncode == 0)
    check("S5 保持现有文件不变", "version: 1.2.4" in (read_dest("latest.yml") or ""))

    # ---------- S6 上游 latest.json 缺失 → 移除本地 json ----------
    write_upstream("1.2.6", *make_asset("1.2.6"))
    os.remove(os.path.join(UP, "latest.json"))
    r = run_sync("S6 上游无 latest.json → 应移除本地 json 但保留 yml")
    check("S6 退出码 0", r.returncode == 0)
    check("S6 yml 已更新到 1.2.6", "version: 1.2.6" in (read_dest("latest.yml") or ""))
    check("S6 本地 latest.json 已移除", read_dest("latest.json") is None)

    # ---------- S7 dry-run 不写文件 ----------
    url7, sha7, size7, bm7 = make_asset("1.2.7")
    write_upstream("1.2.7", url7, sha7, size7, bm7)
    r = run_sync("S7 --dry-run", args=["--dry-run"])
    check("S7 退出码 0", r.returncode == 0)
    check("S7 未改动文件", "version: 1.2.6" in (read_dest("latest.yml") or ""))

    http.server.SimpleHTTPRequestHandler.log_message = logging
    httpd.shutdown()

    print("\n══════════════════ 结果 ══════════════════")
    print(f"\n通过 {len(PASS)} / {len(PASS) + len(FAIL)}")
    for f in FAIL:
        print(f"  [FAIL] {f}")
    print("══════════════════════════════════════════")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
