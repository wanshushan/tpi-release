#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tpi-update-sync —— 从上游同步「检查更新」元数据到本地静态目录（D′ 方案）

部署位置：/usr/local/bin/tpi-update-sync.py
执行者：systemd timer（每分钟一次），见 tpi-update-sync.timer
设计文档：design_doc/UPDATE_CHECK_DESIGN.md §6

为什么这样设计（而不是让 Caddy 实时反代 GitHub）：
  引入这条路之前，客户端的「每次检查更新」都要活着依赖 GitHub 可达。
  改成「timer 定时同步 + Caddy 只读本地文件」之后：
    · 客户端读的是本地磁盘，永不依赖上游
    · 上游挂了 → 旧元数据继续服务（stale-if-error），已发布的更新完全不受影响
    · 服务器只有出站拉取，没有任何入站写入口 → 不需要 Cloudflare Access
    · 服务器无法伪造元数据（不持有写权限），被攻破最多让更新检查失败

不可动摇的三条不变量：
  1. 任何失败都【绝不修改】现有生效文件 —— stale-if-error
  2. 只有全部校验通过才做原子替换（写 .tmp 再 os.replace）
  3. 关键资产（exe / zip）预检 404 时【拒绝提升】；仅网络抖动（超时/5xx）时放行并告警

用法：
  tpi-update-sync.py [--dry-run] [-v] [--force] [--dest DIR] [--skip-asset-check]

环境变量：
  TPI_SYNC_SOURCES        逗号分隔的上游 base URL 列表，按序回退
                          （默认 https://github.com/wanshushan/tpi-release/releases/latest/download）
  TPI_SYNC_DEST           本地目标目录（默认 /srv/tpi-update/update）
  TPI_SYNC_HISTORY_KEEP   历史保留份数（默认 5，0 = 不留历史）
  TPI_SYNC_ASSET_TIMEOUT  资产预检单次超时秒数（默认 20）
  TPI_SYNC_REQUIRE_HOST   yml 里每个 url 必须包含该子串（默认 releases/download/）
  TPI_SYNC_LOCK           锁文件路径（默认 <dest>/.sync.lock）

退出码：0 = 成功或无变化；1 = 出错（现有文件未被修改）
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

try:  # POSIX 才有；非 POSIX 下降级为不加锁（仅影响本机跑测试）
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None  # type: ignore[assignment]

DEFAULT_SOURCES = ["https://github.com/wanshushan/tpi-release/releases/latest/download"]
USER_AGENT = "tpi-update-sync/1.0 (+https://tpi.wanshushan.top)"
# 上游拉取超时。国内到 github.com 的建连可能很慢（实测首字节前可花 5s+），
# 所以默认给到 30s：宁可单轮慢一点，也不要因为超时把闸门静默卡死。
# 可用 TPI_SYNC_FETCH_TIMEOUT 覆盖。
FETCH_TIMEOUT = int(os.environ.get("TPI_SYNC_FETCH_TIMEOUT", "30"))

VERBOSE = False

# 控制台/journald 之外的环境可能是 ASCII 或 GBK；输出里的符号不应导致脚本崩溃
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001
    pass


# ---------------------------------------------------------------- 日志
def log(level: str, msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {level} {msg}", flush=True)


def info(msg: str) -> None:
    log("INFO ", msg)


def warn(msg: str) -> None:
    log("WARN ", msg)


def err(msg: str) -> None:
    log("ERROR", msg)


def dbg(msg: str) -> None:
    if VERBOSE:
        log("DEBUG", msg)


# ---------------------------------------------------------------- HTTP
def fetch(url: str, timeout: int = FETCH_TIMEOUT):
    """返回 (status, body_bytes)；HTTP 错误码作为 status 返回，网络异常抛 OSError"""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache", "Accept": "*/*"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        body = b""
        try:
            body = e.read()
        except Exception:
            pass
        return e.code, body


def probe_size(url: str, timeout: int):
    """
    探测资产是否可下载，并尽量取回总大小。
    用 `Range: bytes=0-0` 只请求首字节：
      · 服务端支持 Range（GitHub / S3 / R2）→ 206 + Content-Range: bytes 0-0/<total>
      · 不支持（会忽略 Range）→ 200 + Content-Length
    两种情况都能拿到大小，且正文只读 1 字节即断开。
    返回 (kind, status_or_None, total_or_None)
      kind: 'ok' | 'http' | 'net'
    """
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Range": "bytes=0-0", "Cache-Control": "no-cache"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            total = None
            cr = r.headers.get("Content-Range")
            if cr and "/" in cr:
                tail = cr.rsplit("/", 1)[-1].strip()
                if tail.isdigit():
                    total = int(tail)
            if total is None:
                cl = r.headers.get("Content-Length")
                if cl and cl.strip().isdigit():
                    total = int(cl.strip())
            print(f"      HTTP {r.status} size={total} range={cr or '-'} ctype={r.headers.get('Content-Type')}", flush=True)
            return "ok", r.status, total
    except urllib.error.HTTPError as e:
        print(f"      HTTP {e.code} {e.reason}", flush=True)
        return "http", e.code, None
    except Exception as e:  # noqa: BLE001  —— 网络类异常一律视为“抖动”
        print(f"      NET  {type(e).__name__}: {e}", flush=True)
        return "net", None, None


# ---------------------------------------------------------------- 解析 latest.yml
# 注意：electron-builder 生成的 latest.yml 里，files[].sha512 / files[].size 是【缩进】的：
#   files:
#     - url: TutorPi-Setup-0.26.3.exe
#       sha512: xxxx
#       size: 185510761
# 所以所有字段都允许前导空白（早期版本因为 ^size: 写死行首，直接把正常产物判为“size 缺失”而拒绝了）
RE_VERSION = re.compile(r"^\s*version:\s*(.+?)\s*$", re.M)
RE_URL = re.compile(r"^\s*-\s*url:\s*(\S+)\s*$", re.M)
RE_SHA512 = re.compile(r"^\s*sha512:\s*(\S+)\s*$", re.M)
RE_SIZE = re.compile(r"^\s*size:\s*(\d+)\s*$", re.M)
RE_RELDATE = re.compile(r"^\s*releaseDate:\s*'?([^'\r\n]+)'?", re.M)


def parse_yml(text: str):
    def one(rx):
        m = rx.search(text)
        return m.group(1) if m else None

    version = one(RE_VERSION)
    urls = RE_URL.findall(text)
    sha512 = one(RE_SHA512)
    size = one(RE_SIZE)
    return {
        "version": version.strip() if version else None,
        "urls": [u.strip() for u in urls],
        "sha512": sha512.strip() if sha512 else None,
        "size": int(size) if size and size.isdigit() else None,
        "releaseDate": (one(RE_RELDATE) or "").strip() or None,
    }


def validate(parsed, require_host: str) -> list:
    problems = []
    v = parsed["version"]
    if not v:
        problems.append("version 缺失")
    elif not re.match(r"^\d+(\.\d+){1,3}$", v):
        problems.append(f"version 格式可疑: {v!r}")
    if not parsed["urls"]:
        problems.append("没有任何 files[].url")
    if not parsed["sha512"]:
        problems.append("sha512 缺失")
    if not parsed["size"]:
        problems.append("size 缺失或非数字")
    for u in parsed["urls"]:
        if not u.startswith(("http://", "https://")):
            problems.append(f"url 不是绝对地址: {u}")
        elif require_host and require_host not in u:
            problems.append(f"url 未包含 {require_host!r}（防呆：确认 gen-update-meta.ts 用了正确基址）: {u}")
    return problems


# ---------------------------------------------------------------- 历史
def prune_history(history_dir: str, keep: int) -> None:
    if keep <= 0 or not os.path.isdir(history_dir):
        return
    entries = []
    for name in os.listdir(history_dir):
        p = os.path.join(history_dir, name)
        if os.path.isdir(p):
            entries.append((os.path.getmtime(p), p))
    entries.sort(reverse=True)
    for _, p in entries[keep:]:
        shutil.rmtree(p, ignore_errors=True)
        info(f"清理旧历史: {os.path.basename(p)}")


# ---------------------------------------------------------------- 主流程
def main() -> int:
    global VERBOSE

    ap = argparse.ArgumentParser(description="同步 tutor_pi 更新元数据到本地静态目录")
    ap.add_argument("--dest", default=os.environ.get("TPI_SYNC_DEST", "/srv/tpi-update/update"))
    ap.add_argument("--dry-run", action="store_true", help="只检查不写入")
    ap.add_argument("--force", action="store_true", help="内容相同时也重新安装")
    ap.add_argument("--skip-asset-check", action="store_true", help="跳过资产预检")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    VERBOSE = args.verbose
    dest = os.path.abspath(args.dest)
    sources = [s.strip().rstrip("/") for s in os.environ.get("TPI_SYNC_SOURCES", "").split(",") if s.strip()]
    if not sources:
        sources = DEFAULT_SOURCES
    history_keep = int(os.environ.get("TPI_SYNC_HISTORY_KEEP", "5"))
    asset_timeout = int(os.environ.get("TPI_SYNC_ASSET_TIMEOUT", "20"))
    require_host = os.environ.get("TPI_SYNC_REQUIRE_HOST", "releases/download/")
    lock_path = os.environ.get("TPI_SYNC_LOCK", os.path.join(dest, ".sync.lock"))

    if not os.path.isdir(dest):
        err(f"目标目录不存在: {dest}")
        return 1

    # ---- 防重叠：timer 每分钟一次，单次可能跑 20s+，用 flock 保证串行
    lock_fd = None
    if fcntl is not None:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            dbg("上一轮还在跑，跳过本次")
            os.close(lock_fd)
            return 0

    try:
        return run(args, dest, sources, history_keep, asset_timeout, require_host)
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def run(args, dest, sources, history_keep, asset_timeout, require_host) -> int:
    yml_path = os.path.join(dest, "latest.yml")
    json_path = os.path.join(dest, "latest.json")

    # ---------- 1. 从上游按序拉取 ----------
    got = None
    for base in sources:
        url = f"{base}/latest.yml"
        try:
            status, body = fetch(url)
        except Exception as e:  # noqa: BLE001
            warn(f"{url} 网络异常: {type(e).__name__}: {e}")
            continue
        if status == 404:
            dbg(f"{url} → 404（该仓库还没有非 prerelease 的 release，或闸门从未开启过）")
            continue
        if status != 200:
            warn(f"{url} → HTTP {status}")
            continue
        text = body.decode("utf-8", errors="replace")
        parsed = parse_yml(text)
        problems = validate(parsed, require_host)
        if problems:
            warn(f"{url} 内容不合法，拒绝采用: {'; '.join(problems)}")
            continue
        got = {"base": base, "url": url, "text": text, "parsed": parsed}
        info(f"上游 {url} → version={parsed['version']} sha512={parsed['sha512'][:16]}… size={parsed['size']}")
        break

    if got is None:
        # 上游不可用 / 还没发布 —— 保持现有文件，这就是 stale-if-error
        info("上游无可用元数据（404 / 网络异常 / 内容不合法）→ 保持现有文件不变")
        return 0

    parsed = got["parsed"]
    new_text = got["text"]

    # ---------- 2. 内容是否变化 ----------
    old_text = None
    if os.path.isfile(yml_path):
        with open(yml_path, "r", encoding="utf-8") as f:
            old_text = f.read()
    if not args.force and old_text == new_text:
        dbg(f"与本地完全一致（version={parsed['version']}），无需改动")
        return 0

    old_version = parse_yml(old_text)["version"] if old_text else None
    info(f"检测到变化: {old_version or '(无)'} → {parsed['version']}")

    # ---------- 3. 资产预检 ----------
    if asset_timeout > 0 and not args.skip_asset_check:
        # latest.json 里带 blockmap 名字；拿不到就从 url 推
        blockmap_names = []
        try:
            jstatus, jbody = fetch(f"{got['base']}/latest.json")
            if jstatus == 200:
                jmeta = json.loads(jbody.decode("utf-8"))
                for a in (jmeta.get("artifacts") or {}).values():
                    if a.get("blockmap"):
                        blockmap_names.append(a["blockmap"])
        except Exception as e:  # noqa: BLE001
            dbg(f"拉 latest.json 失败（不阻塞）: {e}")

        info(f"资产预检（共 {len(parsed['urls'])} 个关键 + {len(blockmap_names)} 个非关键，超时 {asset_timeout}s）")
        hard_fail = []
        for u in parsed["urls"]:
            print(f"    → {u}", flush=True)
            kind, status, total = probe_size(u, asset_timeout)
            if kind == "net":
                warn("      网络抖动 → 放行（内容已经上传，抖动不应把闸门卡死）")
                continue
            if status != 200 and status != 206:
                hard_fail.append(f"{os.path.basename(u)} → HTTP {status}")
                continue
            if total is not None and parsed["size"] and total != parsed["size"]:
                warn(f"      大小不一致: yml={parsed['size']} 实际={total}（若中转改写了 Content-Length 可忽略）")
            else:
                info(f"      ✓ 可下载，大小 {total if total is not None else '(未知)'}")

        for name in blockmap_names:
            u = f"{parsed['urls'][0].rsplit('/', 1)[0]}/{name}"
            print(f"    → {u}  [非关键]", flush=True)
            kind, status, _ = probe_size(u, asset_timeout)
            if kind == "ok" and status in (200, 206):
                info("      ✓ 可下载（差分下载可用）")
            else:
                warn(f"      {name} 不可用 → 只影响差分下载（每次全量），不阻塞发布")

        if hard_fail:
            err("关键资产不可下载 → 【拒绝提升】，现有文件保持不变：")
            for h in hard_fail:
                err(f"    · {h}")
            err("    处理：确认 GitHub release 里已上传这些资产，或将 release 设为 latest 的顺序调整为先传资产后开门")
            return 1
    elif args.skip_asset_check:
        warn("已跳过资产预检（--skip-asset-check）")

    if args.dry_run:
        info(f"[dry-run] 本应把 {old_version or '(无)'} 替换为 {parsed['version']}，未写入任何文件")
        return 0

    # ---------- 4. 备份现有版本 ----------
    history_dir = os.path.join(dest, "history")
    if history_keep > 0 and old_text is not None:
        hd = os.path.join(history_dir, old_version or "unknown")
        os.makedirs(hd, exist_ok=True)
        shutil.copy2(yml_path, os.path.join(hd, "latest.yml"))
        if os.path.isfile(json_path):
            shutil.copy2(json_path, os.path.join(hd, "latest.json"))
        info(f"已备份当前版本到 history/{old_version or 'unknown'}/")

    # ---------- 5. 原子写入 ----------
    # 先写 latest.json（非关键），再写 latest.yml（闸门文件本身）
    jstatus, jbody = fetch(f"{got['base']}/latest.json")
    if jstatus == 200:
        try:
            json.loads(jbody.decode("utf-8"))
            tmp = json_path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(jbody)
            os.chmod(tmp, 0o644)
            os.replace(tmp, json_path)
            info("已写入 latest.json")
        except Exception as e:  # noqa: BLE001
            warn(f"latest.json 不可用，跳过: {e}")
    else:
        # 上游没有 latest.json → 删掉本地的，避免客户端读到过期版本号
        if os.path.isfile(json_path):
            os.remove(json_path)
            warn("上游无 latest.json → 已移除本地 latest.json（避免读到过期版本）")

    tmp = yml_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(new_text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, yml_path)
    info(f"已写入 latest.yml（version={parsed['version']}，releaseDate={parsed['releaseDate']}）")

    prune_history(history_dir, history_keep)
    info(f"同步完成：{old_version or '(无)'} → {parsed['version']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
