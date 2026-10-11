#!/usr/bin/env bash
# ============================================================
# tpi-site-deploy 安装（Ubuntu 服务器，需要 root）
#
#   sudo bash install.sh [运行用户] [选项]
#
# 选项：
#   --web-root <目录>   部署目标，默认 /srv/tpi-site/www
#                       交给 1Panel 管就填 /opt/1panel/www/sites/tpi/index
#   --repo <git地址>   换拉取源，默认 github.com
#                       （服务器到 GitHub 很慢/不通时用 Gitee 镜像或自建裸仓库。
#                        jsDelivr 不行：它没有 .git，且分支 URL 边缘缓存 12 小时）
#   --with-timer       额外装 systemd timer，默认【不装】—— 调度交给 1Panel
#
# 装完你会得到：
#   /usr/local/bin/tpi-site-deploy.sh            干活的（跑在只读沙箱里）
#   /usr/local/bin/tpi-site-sync.sh              计划任务入口 ← 贴进 1Panel 的就是它
#   /etc/systemd/system/tpi-site-deploy.service  沙箱定义（它不是调度器）
#   /srv/tpi-site/README.md                      服务器上离线可查的运维说明
#
# 幂等，可反复跑（升级脚本 / 换目标目录 / 换拉取源）。
# ============================================================
set -euo pipefail

# 只在本目录缺配套文件时才用（curl 单文件 / 管道执行的情况）
TPI_SITE_BASE="${TPI_SITE_BASE:-https://cdn.jsdelivr.net/gh/wanshushan/tpi-release@main/site-deploy}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
ROOT_DIR="/srv/tpi-site"
UNIT_DIR="/etc/systemd/system"
UNIT="tpi-site-deploy.service"
TIMER="tpi-site-deploy.timer"

RUN_USER=""; WEB_ROOT=""; REPO=""; WITH_TIMER=0
while [ $# -gt 0 ]; do
	case "$1" in
		--with-timer) WITH_TIMER=1 ;;
		--web-root)   WEB_ROOT="${2:?--web-root 后面要跟一个目录}"; shift ;;
		--web-root=*) WEB_ROOT="${1#*=}" ;;
		--repo)       REPO="${2:?--repo 后面要跟一个 git 地址}"; shift ;;
		--repo=*)     REPO="${1#*=}" ;;
		-h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)           echo "✗ 未知参数：$1" >&2; exit 1 ;;
		*)            RUN_USER="$1" ;;
	esac
	shift
done
RUN_USER="${RUN_USER:-wanshushan}"
WEB_ROOT="${WEB_ROOT:-/srv/tpi-site/www}"
PREV_DIR="${ROOT_DIR}/www.prev"

case "$WEB_ROOT" in /*) ;; *) echo "✗ --web-root 必须是绝对路径：$WEB_ROOT" >&2; exit 1 ;; esac
case "$REPO" in ""|http*|git@*|ssh://*|file://*) ;; *) echo "✗ --repo 不像 git 地址：$REPO" >&2; exit 1 ;; esac

[ "$(id -u)" -eq 0 ] || { echo "✗ 需要 root： sudo bash $0" >&2; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { echo "✗ 用户不存在：$RUN_USER" >&2; exit 1; }

# ---- 配套文件兜底抓取 ----
REQUIRED=(tpi-site-deploy.sh tpi-site-deploy.service task.sh)
need_fetch=0
for f in "${REQUIRED[@]}"; do [ -f "${SRC_DIR}/${f}" ] || need_fetch=1; done
if [ "$need_fetch" = 1 ]; then
	echo "-- 本目录缺配套文件 → 从 ${TPI_SITE_BASE} 抓取 --"
	FETCH_DIR="$(mktemp -d)"
	for f in "${REQUIRED[@]}"; do
		curl -fsSL "${TPI_SITE_BASE}/${f}" -o "${FETCH_DIR}/${f}" || { echo "✗ 下载失败：$f" >&2; exit 1; }
		echo "   ✓ $f"
	done
	SRC_DIR="$FETCH_DIR"
fi
DOCS_DIR="$(dirname "$SRC_DIR")/docs"

MODE="$(sed -n 's/^Environment=TPI_SITE_MODE=//p' "${SRC_DIR}/tpi-site-deploy.service" | head -1)"
MODE="${MODE:-pull}"

echo "== 安装 tpi-site-deploy =="
echo "   源目录    : ${SRC_DIR}"
echo "   运行用户  : ${RUN_USER}"
echo "   网站目录  : ${WEB_ROOT}"
echo "   回滚备份  : ${PREV_DIR}"
echo "   拉取源    : ${REPO:-（默认 github.com）}"
echo "   部署模式  : ${MODE}"
echo "   git 超时  : ${TPI_SITE_GIT_TIMEOUT:-120}s（拉不动就跳过本轮，不卡死）"
echo "   调度      : $( [ "$WITH_TIMER" = 1 ] && echo 'systemd timer（每 5 分钟）' || echo '不装 timer —— 交给 1Panel 计划任务' )"
echo

# ---- 1) 依赖 ----
missing=0
for c in git rsync flock timeout; do command -v "$c" >/dev/null || { echo "✗ 缺 $c"; missing=1; }; done
[ "$missing" = 1 ] && { echo "  装上： sudo apt-get install -y git rsync util-linux" >&2; exit 1; }
if [ "$MODE" = build ] && ! command -v docker >/dev/null; then
	echo "✗ build 模式需要 docker；不想装就把 TPI_SITE_MODE 改回 pull" >&2; exit 1
fi

# ---- 2) 目录 ----
install -d -o "$RUN_USER" -g "$RUN_USER" -m 755 "$ROOT_DIR" "${ROOT_DIR}/src"
install -d -m 755 "$WEB_ROOT"          # 可能是 1Panel 建好的，不抢属主

# ---- 3) 两个脚本 ----
install -o root -g root -m 755 "${SRC_DIR}/tpi-site-deploy.sh" /usr/local/bin/tpi-site-deploy.sh
install -o root -g root -m 755 "${SRC_DIR}/task.sh"            /usr/local/bin/tpi-site-sync.sh

# ---- 4) systemd 单元（只借沙箱，不做调度）----
install -o root -g root -m 644 "${SRC_DIR}/tpi-site-deploy.service" "${UNIT_DIR}/${UNIT}"
sed -i -e "s|^User=.*|User=${RUN_USER}|" -e "s|^Group=.*|Group=${RUN_USER}|" "${UNIT_DIR}/${UNIT}"
sed -i -e "s|^Environment=TPI_SITE_WEB_ROOT=.*|Environment=TPI_SITE_WEB_ROOT=${WEB_ROOT}|" "${UNIT_DIR}/${UNIT}"
sed -i -e "s|^Environment=TPI_SITE_PREV_DIR=.*|Environment=TPI_SITE_PREV_DIR=${PREV_DIR}|" "${UNIT_DIR}/${UNIT}"
if [ -n "$REPO" ]; then
	sed -i -e "s|^Environment=TPI_SITE_REPO=.*|Environment=TPI_SITE_REPO=${REPO}|" "${UNIT_DIR}/${UNIT}"
fi
# 可写白名单：工作目录 + 网站目录（后者不在 /srv/tpi-site 下时才需要单列）
case "$WEB_ROOT" in
	/srv/tpi-site|/srv/tpi-site/*) RW_PATHS="$ROOT_DIR" ;;
	*)                             RW_PATHS="$ROOT_DIR $WEB_ROOT" ;;
esac
sed -i -e "s|^ReadWritePaths=.*|ReadWritePaths=${RW_PATHS}|" "${UNIT_DIR}/${UNIT}"

echo "-- 写进去的关键行 --"
grep -nE '^User=|^Environment=TPI_SITE_(MODE|REPO|WEB_ROOT|PREV_DIR)=|^ReadWritePaths=' \
	"${UNIT_DIR}/${UNIT}" | sed 's/^/   /'

# ---- 5) 服务器上离线可查的运维说明 ----
if [ -f "${DOCS_DIR}/运维.md" ]; then
	install -o root -g root -m 644 "${DOCS_DIR}/运维.md" "${ROOT_DIR}/README.md"
	[ -f "${DOCS_DIR}/架构.md" ] && install -o root -g root -m 644 "${DOCS_DIR}/架构.md" "${ROOT_DIR}/架构.md"
	echo "   已放运维说明 → ${ROOT_DIR}/README.md"
fi

# ---- 6) 语法校验 ----
echo "-- 校验 systemd 单元 --"
systemd-analyze verify "${UNIT_DIR}/${UNIT}" 2>&1 | grep -v '^$' || true

# ---- 7) 生效 ----
systemctl daemon-reload
if [ "$WITH_TIMER" = 1 ]; then
	install -o root -g root -m 644 "${SRC_DIR}/legacy/${TIMER}" "${UNIT_DIR}/${TIMER}"
	systemctl enable --now "$TIMER"
else
	systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
fi

echo
echo "-- 试跑一次（首次会 clone 仓库，可能等 1 分钟左右）--"
systemctl start "$UNIT" || true
sleep 1
journalctl -u tpi-site-deploy -n 30 -o cat --no-pager || true

echo
echo "== 完成 =="
ls -la "$WEB_ROOT" 2>/dev/null || true

echo
if [ "$WITH_TIMER" = 1 ]; then
	echo "调度 = systemd timer（每 5 分钟）。停掉它改由 1Panel 管："
	echo "  sudo systemctl disable --now ${TIMER}"
else
	cat <<EOT
调度 = 1Panel 计划任务。去「计划任务 → 创建」，填：

  任务类型   Shell 脚本
  任务名称   tpi 简介页部署
  执行周期   每 5 分钟（或自定义 cron  */5 * * * *）
  保留份数   20
  脚本内容   /usr/local/bin/tpi-site-sync.sh

建完点「执行」跑一次，记录里应该能看到「发布完成」。
详情见 ${ROOT_DIR}/README.md
EOT
fi

echo
echo "常用命令："
echo "  sudo systemctl start ${UNIT}                      # 手动部署一次"
echo "  journalctl -u tpi-site-deploy -n 50 -o cat --no-pager   # 看日志"
echo "  tail -f /var/log/tpi/site-deploy.log                    # 全量日志"
echo "  sudo /usr/local/bin/tpi-site-deploy.sh --dry-run -v     # 只演练不写盘"
echo "  sudo /usr/local/bin/tpi-site-deploy.sh --force          # 忽略 commit 未变，强制重发"
echo "  ls -la ${PREV_DIR}                                      # 上一版（回滚用）"
echo
