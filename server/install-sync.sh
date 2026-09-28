#!/usr/bin/env bash
# ============================================================
# tpi-update-sync 一次性安装（在 Ubuntu 服务器上以 root 运行）
#
# 用法：
#   1) 把 scripts/server/ 整个目录拷到服务器（只需要一次）：
#        scp -r scripts/server myvps:/tmp/tpi-sync
#   2) 在服务器上：
#        sudo bash /tmp/tpi-sync/install-sync.sh [运行用户，默认 wanshushan]
#
# 幂等：可以重复执行，用于升级脚本或改运行用户。
# 装完之后，日常发布【完全不需要 SSH】—— 闸门操作全在 GitHub 网页上。
# ============================================================
set -euo pipefail

# 配套文件的兑底来源（只在“本目录下没有配套文件”时才用到）
# 例如只 curl 了这一个脚本： curl -fsSL <base>/install-sync.sh | sudo bash
# 后续想换成 R2 / 自建 CDN，改这个环境变量即可
TPI_SYNC_BASE="${TPI_SYNC_BASE:-https://cdn.jsdelivr.net/gh/wanshushan/tpi-release@main/server}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
RUN_USER="${1:-wanshushan}"
DEST="/srv/tpi-update/update"
UNIT_DIR="/etc/systemd/system"
REQUIRED=(tpi-update-sync.py tpi-update-sync.service tpi-update-sync.timer README-SYNC.md)

if [[ "${EUID}" -ne 0 ]]; then
	echo "✗ 请用 root 运行： sudo bash $0 ${RUN_USER}" >&2
	exit 1
fi

# 本目录缺配套文件（git clone 路径下不会缺；curl 单文件和管道执行时会缺）
need_fetch=0
for f in "${REQUIRED[@]}"; do
	[[ -f "${SRC_DIR}/${f}" ]] || need_fetch=1
done
if [[ "${need_fetch}" -eq 1 ]]; then
	echo "-- 本目录缺配套文件 → 从 ${TPI_SYNC_BASE} 抓取 --"
	FETCH_DIR="$(mktemp -d)"
	for f in "${REQUIRED[@]}"; do
		curl -fsSL "${TPI_SYNC_BASE}/${f}" -o "${FETCH_DIR}/${f}" || {
			echo "✗ 下载失败: ${f}" >&2
			exit 1
		}
		echo "   ✓ ${f}"
	done
	SRC_DIR="${FETCH_DIR}"
fi

echo "== 安装 tpi-update-sync =="
echo "   源目录    : ${SRC_DIR}"
echo "   运行用户  : ${RUN_USER}"
echo "   目标目录  : ${DEST}"
echo

id "${RUN_USER}" >/dev/null 2>&1 || {
	echo "✗ 用户不存在: ${RUN_USER}" >&2
	exit 1
}

# ---- 1) 目录与权限 ----
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 755 /srv/tpi-update
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 755 "${DEST}"
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 755 "${DEST}/history"
chmod 755 /srv/tpi-update "${DEST}" "${DEST}/history"

# ---- 2) 同步脚本 ----
install -o root -g root -m 755 "${SRC_DIR}/tpi-update-sync.py" /usr/local/bin/tpi-update-sync.py

# ---- 3) systemd 单元（把占位符替换成实际用户）----
install -o root -g root -m 644 "${SRC_DIR}/tpi-update-sync.service" "${UNIT_DIR}/tpi-update-sync.service"
sed -i -e "s|^User=.*|User=${RUN_USER}|" -e "s|^Group=.*|Group=${RUN_USER}|" "${UNIT_DIR}/tpi-update-sync.service"
install -o root -g root -m 644 "${SRC_DIR}/tpi-update-sync.timer" "${UNIT_DIR}/tpi-update-sync.timer"

# ---- 4) 服务器侧运维说明（service 的 Documentation= 指向它）----
if [[ -f "${SRC_DIR}/README-SYNC.md" ]]; then
	install -o root -g root -m 644 "${SRC_DIR}/README-SYNC.md" /srv/tpi-update/README-SYNC.md
fi

# ---- 5) 校验单元文件语法 ----
echo "-- 校验 systemd 单元 --"
systemd-analyze verify "${UNIT_DIR}/tpi-update-sync.service" 2>&1 | grep -v '^$' || true

# ---- 6) 启动 ----
systemctl daemon-reload
systemctl enable --now tpi-update-sync.timer

echo
echo "-- 立刻跑一次，看看输出（上游还没发布时应当打印“保持现有文件不变”并以 0 退出）--"
systemctl start tpi-update-sync.service || true
sleep 1
journalctl -u tpi-update-sync -n 25 --no-pager || true

echo
echo "== 完成 =="
systemctl list-timers tpi-update-sync.timer --no-pager | head -4
echo
echo "常用命令："
echo "  systemctl list-timers tpi-update-sync.timer     # 下次触发时间"
echo "  journalctl -u tpi-update-sync -n 50 --no-pager  # 看同步日志"
echo "  journalctl -u tpi-update-sync -f                # 实时跟踪"
echo "  systemctl start tpi-update-sync.service         # 手动立刻同步一次"
echo "  sudo /usr/local/bin/tpi-update-sync.py --dry-run -v   # 只检查不写入"
