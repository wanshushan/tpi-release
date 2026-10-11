#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# tpi-site-sync —— 「简介页部署」的 1Panel 计划任务入口
# ══════════════════════════════════════════════════════════════════════
#
# 1Panel 计划任务里只写这一行（周期：每 5 分钟）：
#
#     /usr/local/bin/tpi-site-sync.sh
#
# 真正干活的是 tpi-site-deploy.service。和 release 同步一样：
# 调度在 1Panel，systemd 只负责把脚本关进
#   ProtectSystem=strict + ReadWritePaths=/srv/tpi-site <网站目录>
# 沙箱里。部署脚本会 git fetch 仓库并把 tpi-site-dist/ 同步到网站目录，
# 它不需要、也拿不到除这两个目录之外的写权限。
#
# 部署任务的输出本来就只有几行（commit / 校验 / 发布完成 或 跳过），
# 所以面板里直接回显全过程，不做摘要。
#
# 日志去哪：
#   · 1Panel 面板    —— 本次执行的全过程
#   · /var/log/tpi/site-deploy.log —— 全量，自动只保留最后 2000 行
#
set -uo pipefail

UNIT=tpi-site-deploy.service
SHORT=tpi-site-deploy
LOG=/var/log/tpi/site-deploy.log
KEEP=2000

install -d -m 755 /var/log/tpi

SINCE="$(date '+%F %T')"
systemctl start "$UNIT"
rc=$?

# -o cat：只要日志正文，不要 systemd 加的时间戳/主机名前缀
OUT="$(journalctl -u "$SHORT" --since "$SINCE" -o cat --no-pager 2>/dev/null || true)"

# ── 全量日志落盘（自截断）────────────────────────────────────────────
{
	printf '\n===== %s  rc=%s =====\n' "$SINCE" "$rc"
	printf '%s\n' "$OUT"
} >> "$LOG"
tail -n "$KEEP" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# ── 面板里回显本次执行过程 ──────────────────────────────────────────
printf '%s\n' "$OUT" | grep -vE '^$|^Started |^Finished ' || true

if [ "$rc" -ne 0 ]; then
	printf '✗ 部署失败 rc=%s —— 完整日志 %s\n' "$rc" "$LOG"
fi

exit "$rc"
