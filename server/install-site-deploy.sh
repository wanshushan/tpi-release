#!/usr/bin/env bash
# ============================================================
# tpi-site-deploy 一次性安装（在 Ubuntu 服务器上以 root 运行）
#
# 用法：
#   sudo bash install-site-deploy.sh [运行用户] [--with-timer] [--web-root <目录>]
#
#   默认运行用户 wanshushan；默认【不装定时器】（先手动发一次，确认没问题再开）。
#
#   --web-root 是给「把简介页交给 1Panel 管」用的 —— 直接把部署目标指向 1Panel
#   的站点目录（容器看得见那些文件），例如：
#     --web-root /opt/1panel/www/sites/tpi/index
#   没给就用默认的 /srv/tpi-site/www（Caddy 直接发文件的那种走法）。
#
# 幂等：可以重复执行，用于升级脚本 / 改用户 / 改模式。
#
# 装完做什么：见 README-SITE.md
# ============================================================
set -euo pipefail

TPI_SITE_BASE="${TPI_SITE_BASE:-https://cdn.jsdelivr.net/gh/wanshushan/tpi-release@main/server}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
RUN_USER=""
WITH_TIMER=0
WEB_ROOT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--with-timer) WITH_TIMER=1 ;;
		--web-root)
			shift
			[ -n "${1:-}" ] || { echo "✗ --web-root 后面要跟一个目录" >&2; exit 1; }
			WEB_ROOT="$1"
			;;
		--web-root=*) WEB_ROOT="${1#*=}" ;;
		-*) echo "✗ 未知参数：$1" >&2; exit 1 ;;
		*) RUN_USER="$1" ;;
	esac
	shift
done
RUN_USER="${RUN_USER:-wanshushan}"
WEB_ROOT="${WEB_ROOT:-/srv/tpi-site/www}"
case "$WEB_ROOT" in /*) ;; *) echo "✗ --web-root 必须是绝对路径：$WEB_ROOT" >&2; exit 1 ;; esac

UNIT_DIR="/etc/systemd/system"
ROOT_DIR="/srv/tpi-site"
REQUIRED=(tpi-site-deploy.sh tpi-site-deploy.service tpi-site-deploy.timer README-SITE.md)

if [[ "${EUID}" -ne 0 ]]; then
	echo "✗ 请用 root 运行： sudo bash $0 ${RUN_USER} [--with-timer]" >&2
	exit 1
fi

# 本目录缺配套文件时从仓库抓（curl 单文件 / 管道执行的情况）
need_fetch=0
for f in "${REQUIRED[@]}"; do
	[[ -f "${SRC_DIR}/${f}" ]] || need_fetch=1
done
if [[ "${need_fetch}" -eq 1 ]]; then
	echo "-- 本目录缺配套文件 → 从 ${TPI_SITE_BASE} 抓取 --"
	FETCH_DIR="$(mktemp -d)"
	for f in "${REQUIRED[@]}"; do
		curl -fsSL "${TPI_SITE_BASE}/${f}" -o "${FETCH_DIR}/${f}" || { echo "✗ 下载失败: ${f}" >&2; exit 1; }
		echo "   ✓ ${f}"
	done
	SRC_DIR="${FETCH_DIR}"
fi

# 读出要用的模式（service 文件里的默认值），据此提示缺什么依赖
MODE="$(sed -n 's/^Environment=TPI_SITE_MODE=//p' "${SRC_DIR}/tpi-site-deploy.service" | head -1)"
MODE="${MODE:-pull}"

echo "== 安装 tpi-site-deploy =="
echo "   源目录    : ${SRC_DIR}"
echo "   运行用户  : ${RUN_USER}"
echo "   网站目录  : ${WEB_ROOT}"
echo "   部署模式  : ${MODE}"
echo "   定时器    : $([[ ${WITH_TIMER} -eq 1 ]] && echo '启用（每 5 分钟）' || echo '不启用（手动触发）')"
echo

id "${RUN_USER}" >/dev/null 2>&1 || { echo "✗ 用户不存在: ${RUN_USER}" >&2; exit 1; }

# ---- 1) 依赖检查 ----
missing=0
for c in git rsync flock; do
	command -v "$c" >/dev/null || { echo "✗ 缺 $c"; missing=1; }
done
if [[ "$missing" -eq 1 ]]; then
	echo "  装上： sudo apt-get update && sudo apt-get install -y git rsync util-linux" >&2
	exit 1
fi
if [[ "$MODE" == "build" ]] && ! command -v docker >/dev/null; then
	echo "✗ build 模式需要 docker。不想装就把 service 里的 TPI_SITE_MODE 改成 pull" >&2
	exit 1
fi

# ---- 2) 目录与权限 ----
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 755 "${ROOT_DIR}"
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 755 "${ROOT_DIR}/src"
# 网站目录可能是 1Panel 建好的（root 属主），不要抢它的属主，只保证存在
install -d -m 755 "${WEB_ROOT}"

# ---- 3) 部署脚本 ----
install -o root -g root -m 755 "${SRC_DIR}/tpi-site-deploy.sh" /usr/local/bin/tpi-site-deploy.sh

# ---- 4) systemd 单元（替换占位符 + 把网站目录写进去）----
install -o root -g root -m 644 "${SRC_DIR}/tpi-site-deploy.service" "${UNIT_DIR}/tpi-site-deploy.service"
sed -i -e "s|^User=.*|User=${RUN_USER}|" -e "s|^Group=.*|Group=${RUN_USER}|" "${UNIT_DIR}/tpi-site-deploy.service"
sed -i -e "s|^Environment=TPI_SITE_WEB_ROOT=.*|Environment=TPI_SITE_WEB_ROOT=${WEB_ROOT}|" \
	"${UNIT_DIR}/tpi-site-deploy.service"
# 网站目录不在默认位置时，把它加进 systemd 的写白名单（ProtectSystem=strict 需要）
case "${WEB_ROOT}" in
	/srv/tpi-site/*|/srv/tpi-site) RW_PATHS="/srv/tpi-site" ;;
	*) RW_PATHS="/srv/tpi-site ${WEB_ROOT}" ;;
esac
sed -i -e "s|^ReadWritePaths=.*|ReadWritePaths=${RW_PATHS}|" "${UNIT_DIR}/tpi-site-deploy.service"
grep -n '^Environment=TPI_SITE_WEB_ROOT\|^ReadWritePaths\|^User=' "${UNIT_DIR}/tpi-site-deploy.service"
install -o root -g root -m 644 "${SRC_DIR}/tpi-site-deploy.timer" "${UNIT_DIR}/tpi-site-deploy.timer"

# ---- 5) 运维说明（service 的 Documentation= 指向它）----
[[ -f "${SRC_DIR}/README-SITE.md" ]] && install -o root -g root -m 644 "${SRC_DIR}/README-SITE.md" "${ROOT_DIR}/README-SITE.md"

# ---- 6) 校验单元语法 ----
echo "-- 校验 systemd 单元 --"
systemd-analyze verify "${UNIT_DIR}/tpi-site-deploy.service" 2>&1 | grep -v '^$' || true

# ---- 7) 启动 ----
systemctl daemon-reload
if [[ "${WITH_TIMER}" -eq 1 ]]; then
	systemctl enable --now tpi-site-deploy.timer
else
	systemctl disable --now tpi-site-deploy.timer 2>/dev/null || true
fi

echo
echo "-- 先跑一次（首次会 clone 仓库）--"
systemctl start tpi-site-deploy.service || true
sleep 1
journalctl -u tpi-site-deploy -n 30 --no-pager || true

echo
echo "== 完成 =="
ls -la "${WEB_ROOT}" 2>/dev/null || true
echo
echo "常用命令："
echo "  systemctl start tpi-site-deploy.service            # 手动部署一次（拉 + 发布）"
echo "  journalctl -u tpi-site-deploy -n 50 --no-pager     # 看部署日志"
echo "  sudo /usr/local/bin/tpi-site-deploy.sh --dry-run -v   # 只演练不写盘"
echo "  sudo /usr/local/bin/tpi-site-deploy.sh --force        # 忽略 commit 未变，强制重发"
echo "  ls -la ${WEB_ROOT}.prev                            # 上一版（回滚用）"
echo
if [[ "${WITH_TIMER}" -eq 0 ]]; then
	echo "定时器没开。要开： sudo systemctl enable --now tpi-site-deploy.timer"
fi
echo
if [[ "${WEB_ROOT}" == /srv/tpi-site/www ]]; then
	echo "⚠️ 网站目录还是默认的 /srv/tpi-site/www —— 记得先把它接到入口上："
	echo "   Caddy: handle { root * ${WEB_ROOT} \n            file_server }"
	echo "   或者改成交给 1Panel 管：重跑本脚本并加 --web-root <1Panel 站点目录>"
else
	echo "⚠️ 网站目录已指向 ${WEB_ROOT}"
	echo "   确认入口已经反代到 1Panel 站点（Caddy 的 handle → reverse_proxy 127.0.0.1:<1Panel端口>）"
fi
echo "   sudo cat /etc/caddy/Caddyfile   # 见 README-SITE.md 第 3 步"
