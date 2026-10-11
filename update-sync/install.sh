#!/usr/bin/env bash
# ============================================================
# tpi-update-sync 安装（Ubuntu 服务器，需要 root）
#
#   sudo bash install.sh [运行用户] [--with-timer]
#
#   默认运行用户 wanshushan；默认【不装 timer】—— 调度交给 1Panel 计划任务。
#
# 装完你会得到：
#   /usr/local/bin/tpi-update-sync.py          干活的（跑在只读沙箱里）
#   /usr/local/bin/tpi-release-sync.sh         计划任务入口 ← 贴进 1Panel 的就是它
#   /etc/systemd/system/tpi-update-sync.service 沙箱定义（它不是调度器）
#   /srv/tpi-update/README.md                  服务器上离线可查的运维说明
#
# ⚠️ 装完记得在 1Panel 建「每 1 分钟」的计划任务，否则元数据不会更新。
#
# 幂等，可反复跑。
# ============================================================
set -euo pipefail

TPI_SYNC_BASE="${TPI_SYNC_BASE:-https://cdn.jsdelivr.net/gh/wanshushan/tpi-release@main/update-sync}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
DEST="/srv/tpi-update/update"
UNIT_DIR="/etc/systemd/system"
UNIT="tpi-update-sync.service"
TIMER="tpi-update-sync.timer"

RUN_USER=""; WITH_TIMER=0
for a in "$@"; do
	case "$a" in
		--with-timer) WITH_TIMER=1 ;;
		-h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)           echo "✗ 未知参数：$a" >&2; exit 1 ;;
		*)            RUN_USER="$a" ;;
	esac
done
RUN_USER="${RUN_USER:-wanshushan}"

[ "$(id -u)" -eq 0 ] || { echo "✗ 需要 root： sudo bash $0 ${RUN_USER}" >&2; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { echo "✗ 用户不存在：$RUN_USER" >&2; exit 1; }

# ---- 配套文件兜底抓取 ----
REQUIRED=(tpi-update-sync.py tpi-update-sync.service task.sh)
need_fetch=0
for f in "${REQUIRED[@]}"; do [ -f "${SRC_DIR}/${f}" ] || need_fetch=1; done
if [ "$need_fetch" = 1 ]; then
	echo "-- 本目录缺配套文件 → 从 ${TPI_SYNC_BASE} 抓取 --"
	FETCH_DIR="$(mktemp -d)"
	for f in "${REQUIRED[@]}"; do
		curl -fsSL "${TPI_SYNC_BASE}/${f}" -o "${FETCH_DIR}/${f}" || { echo "✗ 下载失败：$f" >&2; exit 1; }
		echo "   ✓ $f"
	done
	SRC_DIR="$FETCH_DIR"
fi
DOCS_DIR="$(dirname "$SRC_DIR")/docs"

echo "== 安装 tpi-update-sync =="
echo "   源目录    : ${SRC_DIR}"
echo "   运行用户  : ${RUN_USER}"
echo "   元数据目录: ${DEST}"
echo "   调度      : $( [ "$WITH_TIMER" = 1 ] && echo 'systemd timer（每 1 分钟）' || echo '不装 timer —— 交给 1Panel 计划任务' )"
echo

# ---- 1) 目录与权限 ----
install -d -o "$RUN_USER" -g "$RUN_USER" -m 755 /srv/tpi-update "$DEST" "${DEST}/history"

# ---- 2) 两个脚本 ----
install -o root -g root -m 755 "${SRC_DIR}/tpi-update-sync.py" /usr/local/bin/tpi-update-sync.py
install -o root -g root -m 755 "${SRC_DIR}/task.sh"            /usr/local/bin/tpi-release-sync.sh

# ---- 3) systemd 单元（只借沙箱，不做调度）----
install -o root -g root -m 644 "${SRC_DIR}/tpi-update-sync.service" "${UNIT_DIR}/${UNIT}"
sed -i -e "s|^User=.*|User=${RUN_USER}|" -e "s|^Group=.*|Group=${RUN_USER}|" "${UNIT_DIR}/${UNIT}"

echo "-- 写进去的关键行 --"
grep -nE '^User=|^Environment=TPI_SYNC_|^ReadWritePaths=' "${UNIT_DIR}/${UNIT}" | sed 's/^/   /'

# ---- 4) 服务器上离线可查的运维说明 ----
if [ -f "${DOCS_DIR}/运维.md" ]; then
	install -o root -g root -m 644 "${DOCS_DIR}/运维.md" /srv/tpi-update/README.md
	[ -f "${DOCS_DIR}/架构.md" ] && install -o root -g root -m 644 "${DOCS_DIR}/架构.md" /srv/tpi-update/架构.md
	echo "   已放运维说明 → /srv/tpi-update/README.md"
fi

# ---- 5) 语法校验 ----
echo "-- 校验 systemd 单元 --"
systemd-analyze verify "${UNIT_DIR}/${UNIT}" 2>&1 | grep -v '^$' || true

# ---- 6) 生效 ----
systemctl daemon-reload
if [ "$WITH_TIMER" = 1 ]; then
	install -o root -g root -m 644 "${SRC_DIR}/legacy/${TIMER}" "${UNIT_DIR}/${TIMER}"
	systemctl enable --now "$TIMER"
else
	systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
fi

echo
echo "-- 试跑一次（上游不通时会打印「保持现有文件不变」并以 0 退出，这是正常的）--"
systemctl start "$UNIT" || true
sleep 1
journalctl -u tpi-update-sync -n 20 -o cat --no-pager || true

echo
echo "== 完成 =="
echo "   当前本地元数据："
ls -l "${DEST}" | sed 's/^/     /'

echo
if [ "$WITH_TIMER" = 1 ]; then
	echo "调度 = systemd timer（每 1 分钟）。停掉它改由 1Panel 管："
	echo "  sudo systemctl disable --now ${TIMER}"
else
	cat <<EOT
调度 = 1Panel 计划任务。去「计划任务 → 创建」，填：

  任务类型   Shell 脚本
  任务名称   tpi 元数据同步
  执行周期   每 1 分钟（或自定义 cron  * * * * *）
  保留份数   20
  脚本内容   /usr/local/bin/tpi-release-sync.sh

⚠️ 周期必须是 1 分钟。这台机到 GitHub 实测约 5 次里通 1 次，
   拉长到 5 分钟会让"发布后生效"的平均时间从约 5 分钟变成约 25 分钟。
详情见 /srv/tpi-update/README.md
EOT
fi

echo
echo "常用命令："
echo "  sudo systemctl start ${UNIT}                          # 手动同步一次"
echo "  journalctl -u tpi-update-sync -n 50 -o cat --no-pager  # 看日志"
echo "  tail -f /var/log/tpi/update-sync.log                   # 全量日志"
echo "  sudo /usr/local/bin/tpi-update-sync.py --dry-run -v    # 只检查不写入"
echo "  sudo /usr/local/bin/tpi-update-sync.py --force -v      # 内容相同也强制重装"
echo "  ls -l ${DEST}/history/                                 # 历史版本（回滚兜底）"
echo
