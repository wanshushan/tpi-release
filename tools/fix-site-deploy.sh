#!/usr/bin/env bash
# ============================================================
# fix-site-deploy.sh —— 把 tpi 简介页部署一次性修好并验证
#
#   sudo bash tools/fix-site-deploy.sh
#
# 幂等，可反复执行。它做五件事：
#   1) 诊断：unit 里的部署用户 / 目标目录 / 仓库与目标目录的实际属主
#   2) 修属主：整棵工作副本（含 .git）+ 网站目录都归部署用户
#              （只 chown 顶层目录会留下 git 的 "dubious ownership" —— 踩过）
#   3) 修 git：写系统级 safe.directory（/etc/gitconfig，不受单元 ProtectHome=true 影响）
#   4) 等锁 → 跑一次部署（优先走 systemd 单元；没发出去就【带着单元里的
#      Environment=】以部署用户手跑 --force —— 不带那套配置就会退回默认
#      目录，页面照样不变）
#   5) 拉公网首页验证是否真上线，并给出结论
#
# 为什么需要它：这条链路上有四处"成功假象"——
#   · 部署目标写错目录（脚本一路绿勾，页面一个字节不变）
#   · 运行用户与仓库属主不一致（git 直接拒绝，报 dubious ownership）
#   · 目标目录没有写权限（rsync 那一步才炸）
#   · 绕过 systemd 单元跑：1Panel 任务的脚本内容写成了 tpi-site-deploy.sh
#     （应是 /usr/local/bin/tpi-site-sync.sh），或手跑时没拿到单元的
#     Environment= → 配置退回默认值 /srv/tpi-site/www，而 1Panel 静态站
#     服务的是 /opt/1panel/www/sites/tpi/index（2026-10-14 就这么踩的）
# 这个脚本把四处一次性摆平。
# ============================================================
set -uo pipefail

UNIT="tpi-site-deploy.service"
UNIT_FILE="/etc/systemd/system/${UNIT}"
ROOT_DIR="/srv/tpi-site"
SRC="${ROOT_DIR}/src"
DEPLOY_SH="/usr/local/bin/tpi-site-deploy.sh"
SITE_URL="${TPI_SITE_URL:-https://tpi.wanshushan.top/}"

[ "$(id -u)" -eq 0 ] || { echo "✗ 需要 root： sudo bash $0"; exit 1; }

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m·\033[0m %s\n' "$*"; }
bad() { printf '   \033[31m✗\033[0m %s\n' "$*"; }

# ── 1. 诊断 ─────────────────────────────────────────────────
say "1/5 现状"
DEPLOY_USER="$(grep -oP '^User=\K.*' "$UNIT_FILE" 2>/dev/null || true)"
DEPLOY_USER="${DEPLOY_USER:-wanshushan}"
WEB_ROOT="$(grep -oP '^Environment=TPI_SITE_WEB_ROOT=\K.*' "$UNIT_FILE" 2>/dev/null || true)"
WEB_ROOT="${WEB_ROOT:-${ROOT_DIR}/www}"
PREV_DIR="$(grep -oP '^Environment=TPI_SITE_PREV_DIR=\K.*' "$UNIT_FILE" 2>/dev/null || true)"
id "$DEPLOY_USER" >/dev/null 2>&1 || { bad "用户不存在：$DEPLOY_USER"; exit 1; }
printf '   部署用户 (User=) : %s\n' "$DEPLOY_USER"
printf '   工作副本         : %s  [%s]\n' "$SRC" "$(stat -c '%U:%G' "$SRC" 2>/dev/null || echo 不存在)"
printf '   网站目录         : %s  [%s]\n' "$WEB_ROOT" "$(stat -c '%U:%G' "$WEB_ROOT" 2>/dev/null || echo 不存在)"
printf '   回滚备份         : %s  [%s]\n' "${PREV_DIR:-${ROOT_DIR}/www.prev}" "$(stat -c '%U:%G' "${PREV_DIR:-${ROOT_DIR}/www.prev}" 2>/dev/null || echo 不存在)"
printf '   ReadWritePaths   : %s\n' "$(grep -oP '^ReadWritePaths=\K.*' "$UNIT_FILE" 2>/dev/null || echo '(未设置)')"

# 单元里没有 TPI_SITE_WEB_ROOT 就等于在用脚本内置默认值。1Panel 静态站的目录一般是
# /opt/1panel/www/sites/tpi/index —— 两者不相等时页面永远看不到新产物，而部署一路绿勾。
if [ "$WEB_ROOT" = "${ROOT_DIR}/www" ]; then
	bad "单元的 TPI_SITE_WEB_ROOT 是脚本默认值：$WEB_ROOT"
	bad "    若页面由 1Panel 静态站服务（Caddy → 127.0.0.1:4477），这里必须是 /opt/1panel/www/sites/tpi/index"
fi

# 单元的 Environment= 是唯一配置来源。下面那个手跑降级分支是【新进程】+
# sudo 的 env_reset，不会自动带上它们 → 先抄成 env 参数备用。
ENV_ARGS=()
if [ -r "$UNIT_FILE" ]; then
	while IFS= read -r _line; do
		case "$_line" in Environment=TPI_SITE_*|Environment=\"TPI_SITE_*) ;; *) continue ;; esac
		_kv="${_line#Environment=}"
		_kv="${_kv#\"}"
		_kv="${_kv%\"}"
		ENV_ARGS+=("${_kv%$'\r'}")
	done < "$UNIT_FILE"
fi
unset _line _kv

# ── 2. 修属主（整棵树）──────────────────────────────────────
say "2/5 修属主（递归，含 .git / state / lock / www.prev）"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$ROOT_DIR" && ok "$ROOT_DIR"
if [ -d "$WEB_ROOT" ]; then
	chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$WEB_ROOT" && ok "$WEB_ROOT"
else
	mkdir -p "$WEB_ROOT" && chown "${DEPLOY_USER}:${DEPLOY_USER}" "$WEB_ROOT" && ok "$WEB_ROOT（新建）"
fi

# ── 3. 修 git 的属主防呆 ────────────────────────────────────
say "3/5 修 git 的属主防呆"
git config --system --replace-all safe.directory "$SRC" 2>/dev/null || true
ok "/etc/gitconfig: $(grep -h safe.directory /etc/gitconfig 2>/dev/null | tail -1)"
if sudo -u "$DEPLOY_USER" git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	ok "git 以 $DEPLOY_USER 可用"
else
	bad "git 以 $DEPLOY_USER 仍不可用，先看这几行："
	sudo -u "$DEPLOY_USER" git -C "$SRC" status 2>&1 | head -5 | sed 's/^/     /'
fi
if sudo -u "$DEPLOY_USER" test -w "$WEB_ROOT"; then
	ok "$DEPLOY_USER 可写网站目录"
else
	bad "$DEPLOY_USER 不能写 $WEB_ROOT —— rsync 会失败"
	exit 1
fi

# ── 4. 等锁 → 跑一次部署 ────────────────────────────────────
say "4/5 跑一次部署"
for i in $(seq 1 36); do
	pgrep -f 'tpi-site-deploy\.sh' >/dev/null || break
	warn "已有部署在跑，等 5s（$i/36）"
	sleep 5
done
systemctl daemon-reload
LOG=""
if systemctl start "$UNIT"; then
	LOG="$(journalctl -u "$UNIT" -n 200 -o cat --no-pager)"
fi
if ! grep -q '发布完成' <<<"$LOG"; then
	warn "单元这条路没有发布出去（可能「无需操作」或「上游不可达」），降级为以 $DEPLOY_USER 手跑 --force"
	if [ "${#ENV_ARGS[@]}" -gt 0 ]; then
		warn "    带上单元里的配置（${#ENV_ARGS[@]} 项，网站目录=$WEB_ROOT）—— 否则会退回默认目录"
		LOG="$(sudo -u "$DEPLOY_USER" env "${ENV_ARGS[@]}" "$DEPLOY_SH" --force -v 2>&1)"
	else
		bad "单元里没有任何 Environment=TPI_SITE_* —— 手跑会退回默认目录，这里故意不发。先修单元："
		bad "    sudo bash ${SRC}/site-deploy/install.sh --web-root /opt/1panel/www/sites/tpi/index"
	fi
fi
tail -n 20 <<<"$LOG" | sed 's/^/   /'

# ── 5. 验证公网 ─────────────────────────────────────────────
say "5/5 验证公网"
HTML="$(curl -s --max-time 25 "${SITE_URL}?cb=$RANDOM" || true)"
ISLAND="$(grep -o 'component-url="[^"]*"' <<<"$HTML" | head -1 || true)"
THEME="$(grep -o 'theme-color" content="[^"]*"' <<<"$HTML" | head -1 || true)"
printf '   %s\n' "${ISLAND:-（首页里没有 component-url → 还是旧产物）}"
printf '   %s\n' "${THEME:-（没读到 theme-color）}"

if grep -q '发布完成' <<<"$LOG" && [ -n "$ISLAND" ]; then
	printf '\n\033[32m✅ 上线成功：首页已经是带客户端岛的新产物\033[0m\n'
	printf '   回滚上一版： sudo rsync -a --delete --exclude 404.html --exclude .well-known \\\n                 %s/ %s/\n' "${PREV_DIR:-${ROOT_DIR}/www.prev}" "$WEB_ROOT"
else
	printf '\n\033[31m❌ 还没上线\033[0m\n'
	cat <<'TIP'
   按这个顺序查：
   1) 上游真的有新 commit 吗（服务器是从 GitHub 拉的）：
        sudo -u <部署用户> git -C /srv/tpi-site/src log --oneline -1
        sudo -u <部署用户> git -C /srv/tpi-site/src fetch --no-tags origin main -v
   2) 部署目标对不对（必须等于 Caddy 实际服务的目录）：
        grep -n 'reverse_proxy' /etc/caddy/Caddyfile            # / 交给谁
        grep TPI_SITE_WEB_ROOT /etc/systemd/system/tpi-site-deploy.service
        ls -la /opt/1panel/www/sites/tpi/index/ | head         # index.html 的时间戳应等于线上的 Last-Modified
   3) 把上面 4/5 的日志（tail -20）发出来
TIP
fi
