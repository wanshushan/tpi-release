#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# tpied_clear —— 一键清理「迁到 1Panel 之前」留下的残留
# ══════════════════════════════════════════════════════════════════════
#
# 用法（需要 root）：
#   sudo bash tpied_clear.sh --dry-run       # 只打印要做什么，一个字节都不动
#   sudo bash tpied_clear.sh                 # 停用旧 timer + 删公网可见的残留
#   sudo bash tpied_clear.sh --purge         # 连 .timer 单元文件一起删
#   sudo bash tpied_clear.sh --keep-timers   # 先别停 timer（1Panel 任务还没建好时用）
#
# 它【绝对不碰】的东西（写死在 guard_path 里，不是靠"忘了写"）：
#   /srv/tpi-update/update/**          客户端正在读的 latest.yml / latest.json
#   /srv/tpi-update/update/history/**  回滚用的历史版本
#   /usr/local/bin/tpi-*               干活的脚本本体
#   /etc/systemd/system/tpi-*.service  沙箱执行器（还要用）
#   /srv/tpi-site/src                  部署脚本的 git 工作副本
#
# 幂等：可以反复跑，第二次会告诉你"本来就没有"。
#
set -uo pipefail

WEB_ROOT="${TPI_SITE_WEB_ROOT:-/opt/1panel/www/sites/tpi/index}"
UNIT_DIR=/etc/systemd/system

DRY=0
PURGE=0
KEEP_TIMERS=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)      DRY=1 ;;
		--purge)        PURGE=1 ;;
		--keep-timers)  KEEP_TIMERS=1 ;;
		-h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "✗ 未知参数：$1（--help 看用法）" >&2; exit 1 ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || { echo "✗ 需要 root： sudo bash $0" >&2; exit 1; }

DID=0
say() { printf '  %s\n' "$*"; }
skip() { printf '  · %s\n' "$*"; }
hd()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# ── 硬护栏：线上元数据目录，任何人都别想删 ────────────────────────────
guard_path() {
	case "$1" in
		/srv/tpi-update/update|/srv/tpi-update/update/*)
			printf '  ✗ 护栏拦截：拒绝操作线上元数据 %s\n' "$1" >&2
			exit 1
			;;
	esac
}

do_del() {
	local p="$1"
	guard_path "$p"
	if [ ! -e "$p" ] && [ ! -L "$p" ]; then skip "本来就没有：$p"; return 0; fi
	if [ "$DRY" = 1 ]; then say "[dry-run] 删除 $p"; DID=$((DID + 1)); return 0; fi
	if rm -rf -- "$p"; then say "已删除 $p"; DID=$((DID + 1)); else printf '  ✗ 删除失败：%s\n' "$p" >&2; fi
}

echo
echo "════════ tpied_clear ════════"
echo "  网站目录 : ${WEB_ROOT}"
echo "  模式     : $( [ "$DRY" = 1 ] && echo '演练（--dry-run，不写盘）' || echo '实际执行' )"
[ "$PURGE" = 1 ] && echo "  --purge  : 会删除 .timer 单元文件"
[ "$KEEP_TIMERS" = 1 ] && echo "  --keep-timers : 保留旧 timer 不动"

# ══════════════════════════════════════════════════════════════════
hd "1/5  旧 systemd 定时器（调度权已交给 1Panel）"

if [ "$KEEP_TIMERS" = 1 ]; then
	skip "按 --keep-timers 跳过"
else
	for t in tpi-update-sync.timer tpi-site-deploy.timer; do
		if ! systemctl list-unit-files "$t" >/dev/null 2>&1; then
			skip "本来就没有：$t"
			continue
		fi
		if [ "$DRY" = 1 ]; then
			say "[dry-run] systemctl disable --now $t"
		else
			systemctl disable --now "$t" >/dev/null 2>&1 || true
			if [ "$(systemctl is-active "$t" 2>&1)" = inactive ] &&
				[ "$(systemctl is-enabled "$t" 2>&1)" != enabled ]; then
				say "已停用 $t"
			else
				printf '  · %s 现在是 enabled=%s active=%s（若仍启用请手动处理）\n' \
					"$t" "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t" 2>&1)"
			fi
			DID=$((DID + 1))
		fi
		if [ "$PURGE" = 1 ]; then
			do_del "${UNIT_DIR}/${t}"
		fi
	done
	# .service 不删 —— 它是沙箱执行器，1Panel 任务靠它干活
	skip "保留 tpi-*.service（1Panel 任务借它做只读沙箱，别删）"
fi

# ══════════════════════════════════════════════════════════════════
hd "2/5  网站目录里公网可见的残留"

do_del "${WEB_ROOT}/dist.zip"
do_del "${WEB_ROOT}/index.prev"
# 注意：/srv/tpi-site/www.prev 是新版的回滚备份，【不删】

if [ -d "$WEB_ROOT" ]; then
	UNEXPECTED="$(
		find "$WEB_ROOT" -mindepth 1 -maxdepth 1 \
			! -name index.html ! -name favicon.svg ! -name fonts \
			! -name 404.html ! -name '.well-known' ! -name dist.zip ! -name index.prev \
			-printf '%f\n' 2>/dev/null | sort
	)"
	if [ -n "$UNEXPECTED" ]; then
		printf '  ⚠ 网站目录里还有预期之外的东西，请自己看一眼：\n'
		printf '%s\n' "$UNEXPECTED" | sed 's/^/      /'
	else
		say "网站目录干净（index.html / favicon.svg / fonts/ / 404.html）"
	fi
fi

# ══════════════════════════════════════════════════════════════════
hd "3/5  服务器上的旧文档副本（运维说明已并入仓库 docs/）"

do_del "/srv/tpi-site/README-SITE.md"
do_del "/srv/tpi-update/README-SYNC.md"

# ══════════════════════════════════════════════════════════════════
hd "4/5  没用上的空目录"

if [ -d /srv/tpi-site/www ]; then
	if [ -z "$(ls -A /srv/tpi-site/www 2>/dev/null)" ]; then
		do_del /srv/tpi-site/www
	else
		skip "/srv/tpi-site/www 里有东西，保留不动"
	fi
else
	skip "本来就没有：/srv/tpi-site/www"
fi

# ══════════════════════════════════════════════════════════════════
hd "5/5  收尾"

if [ "$DRY" = 1 ]; then
	say "[dry-run] systemctl daemon-reload"
else
	systemctl daemon-reload
	say "已 daemon-reload"
fi

echo
echo "════════ 完成：处理了 ${DID} 项 ════════"

echo
echo "现在检查一遍状态："
printf '  %-24s %s\n' "tpi-update-sync.timer" "$(systemctl is-enabled tpi-update-sync.timer 2>&1) / $(systemctl is-active tpi-update-sync.timer 2>&1)"
printf '  %-24s %s\n' "tpi-site-deploy.timer" "$(systemctl is-enabled tpi-site-deploy.timer 2>&1) / $(systemctl is-active tpi-site-deploy.timer 2>&1)"
printf '  %-24s %s\n' "tpi-update-sync.service" "$(systemctl is-active tpi-update-sync.service 2>&1)"
printf '  %-24s %s\n' "tpi-site-deploy.service" "$(systemctl is-active tpi-site-deploy.service 2>&1)"

if [ "$KEEP_TIMERS" != 1 ] && [ "$DRY" != 1 ]; then
	cat <<'EOT'

⚠️  调度现在【完全依赖 1Panel 计划任务】了。请确认这两个任务已经建好并启用：

      任务名              周期         脚本内容
      ────────────────────────────────────────────────────────────
      tpi 元数据同步      每 1 分钟    /usr/local/bin/tpi-release-sync.sh
      tpi 简介页部署      每 5 分钟    /usr/local/bin/tpi-site-sync.sh

    （还没建任务就先跑： sudo bash tpied_clear.sh --keep-timers）

   回滚办法（想退回 systemd 调度）：
      sudo systemctl enable --now tpi-update-sync.timer tpi-site-deploy.timer
EOT
fi

echo
echo "其他可能想跑的："
echo "  sudo systemctl start tpi-site-deploy.service   # 手动部署一次简介页"
echo "  sudo systemctl start tpi-update-sync.service   # 手动同步一次元数据"
echo
