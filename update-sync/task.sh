#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# tpi-release-sync —— 「更新元数据同步」的 1Panel 计划任务入口
# ══════════════════════════════════════════════════════════════════════
#
# 1Panel 计划任务里只写这一行（周期：每 1 分钟）：
#
#     /usr/local/bin/tpi-release-sync.sh
#
# 为什么是 1 分钟而不是 5 分钟：
#   这台服务器到 GitHub 的连通性实测约【5 次里通 1 次】（每次卡满 30 秒超时）。
#   1 分钟一次 → 平均约 5 分钟同步到；改成 5 分钟 → 平均约 25 分钟。
#   检查更新这条路对客户端是「永不失败」的要求，所以宁可多试。
#
# 为什么里面还要绕一层 systemd：
#   调度权 100% 在 1Panel，这里只借 systemd 的【只读沙箱】——
#   tpi-update-sync.service 带
#       ProtectSystem=strict + ReadWritePaths=/srv/tpi-update
#   这是全服务器唯一「从网络拉字节落到磁盘」的动作，沙箱保证它碰不到
#   latest.yml / latest.json 以外的任何地方（HANDOFF 决策 #14 的结构性安全）。
#
# 日志去哪：
#   · 1Panel 面板    —— 每次只留一行摘要（1 分钟一条，全量会把记录刷爆）
#   · /var/log/tpi/update-sync.log —— 全量，自动只保留最后 2000 行
#
set -uo pipefail

UNIT=tpi-update-sync.service
SHORT=tpi-update-sync
LOG=/var/log/tpi/update-sync.log
KEEP=2000

install -d -m 755 /var/log/tpi

SINCE="$(date '+%F %T')"
systemctl start "$UNIT"
rc=$?

# -o cat：只要日志正文，不要 systemd 加的时间戳/主机名前缀
#        （脚本自己每行都带 [时间] 前缀，已经够了）
OUT="$(journalctl -u "$SHORT" --since "$SINCE" -o cat --no-pager 2>/dev/null || true)"

# ── 全量日志落盘（自截断，不留增长文件）──────────────────────────────
{
	printf '\n===== %s  rc=%s =====\n' "$SINCE" "$rc"
	printf '%s\n' "$OUT"
} >> "$LOG"
tail -n "$KEEP" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# ── 面板里只留一行摘要 ───────────────────────────────────────────────
ver="$(printf '%s\n' "$OUT" | sed -n 's/.*→ *version=\([0-9][0-9.]*\).*/\1/p' | tail -1)"
if [ "$rc" -ne 0 ]; then
	printf '✗ 执行失败 rc=%s（完整日志 %s）\n' "$rc" "$LOG"
elif printf '%s\n' "$OUT" | grep -q ERROR; then
	printf '✗ 出错（完整日志 %s）\n' "$LOG"
elif [ -n "$ver" ]; then
	printf '✓ 上游 v%s 可达\n' "$ver"
else
	printf '· 上游不可达，保持现有文件（正常降级）\n'
fi

exit "$rc"
