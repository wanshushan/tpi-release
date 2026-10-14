#!/usr/bin/env bash
#
# tpi-site-deploy —— 把 tpi-site 从 GitHub 拉到服务器并发布
# ══════════════════════════════════════════════════════════════════════
#
# 两种模式（env: TPI_SITE_MODE）：
#
#   pull   （默认，推荐）仓库里已经有构建好的产物目录，服务器只拉 + 复制。
#          服务器上【没有】Node、没有 npm、不执行仓库里的任何代码。
#
#   build  服务器上构建：clone 源码 → 在 Docker 容器里 npm ci && npm run build。
#          ⚠️ 这会引入一条「GitHub 仓库 → 服务器代码执行」的路径，
#          与 tpi-update-sync 建立的「服务器只读」性质相冲突，详见 README-SITE.md。
#
# 三条硬性行为（与 tpi-update-sync 同款约束）：
#   1. 失败不动线上。任何一步出错都在 rsync 之前中止，网站目录一个字节不变。
#   2. 产物先校验再发布。index.html 必须存在、必须是本站页面、字体必须在。
#   3. 内容没变就不干活。commit 与上次相同 → 直接退出，不构建、不写盘。
#
# 配置只有一个来源：systemd 单元里的 Environment=TPI_SITE_*（见下面「0. 配置来源对齐」）。
# 手跑本脚本时那些变量不会自己出现 —— 脚本会自己去单元文件里补，
# 否则会退回内置默认值 /srv/tpi-site/www（在 1Panel 静态站场景下那是个没人服务的目录）。
#
set -euo pipefail

# ── 0.0 配置来源对齐：手跑也必须和 systemd 单元一致 ────────────
# 这台机器上 TPI_SITE_* 的唯一真相是 `/etc/systemd/system/tpi-site-deploy.service`
# 里的 Environment= 行。而「手跑」这条路（install.sh 结尾的常用命令、运维文档都这么写：
#   sudo -u <部署用户> /usr/local/bin/tpi-site-deploy.sh --force）
# 拿不到那些变量 —— 脚本会退回内置默认值 TPI_SITE_WEB_ROOT=/srv/tpi-site/www。
# 在 1Panel 场景下（Caddy → 127.0.0.1:4477 → /opt/1panel/www/sites/tpi/index）
# 那个默认目录【没有任何人服务】：脚本一路绿勾、页面一个字节不变。
# 2026-10-14 就是这么踩的：1Panel 任务的脚本内容写成了本脚本（而不是入口
# /usr/local/bin/tpi-site-sync.sh），以 root 直跑 → 发到了 /srv/tpi-site/www。
# 所以：凡是没有被显式设置的变量，一律从单元文件里补齐（显式设置的优先）。
UNIT_FILE="${TPI_SITE_UNIT_FILE:-/etc/systemd/system/tpi-site-deploy.service}"
ENV_NOTE=""
if [ -r "$UNIT_FILE" ]; then
	_inherited=""
	while IFS= read -r _line; do
		# 两种写法都收：Environment=TPI_SITE_X=v 与 Environment="TPI_SITE_X=v"
		case "$_line" in Environment=TPI_SITE_*|Environment=\"TPI_SITE_*) ;; *) continue ;; esac
		_kv="${_line#Environment=}"
		# 容忍 Environment="TPI_SITE_X=..." 这种整体带引号的写法
		_kv="${_kv#\"}"
		_kv="${_kv%\"}"
		_kv="${_kv%$'\r'}"
		_key="${_kv%%=*}"
		_value="${_kv#*=}"
		case "$_key" in TPI_SITE_*) ;; *) continue ;; esac
		if [ -n "${!_key:-}" ]; then continue; fi   # 显式给的优先，不覆盖
		export "$_key=$_value"
		_inherited="${_inherited:+$_inherited }${_key#TPI_SITE_}"
	done < "$UNIT_FILE"
	if [ -n "$_inherited" ]; then
		ENV_NOTE="未显式设置的配置已从 $(basename "$UNIT_FILE") 补齐：$_inherited"
	fi
	unset _line _kv _key _value _inherited
fi

# ── 配置（都用环境变量覆盖）────────────────────────────────────
REPO_URL="${TPI_SITE_REPO:-https://github.com/wanshushan/tpi-release.git}"
BRANCH="${TPI_SITE_BRANCH:-main}"
SRC_DIR="${TPI_SITE_SRC_DIR:-/srv/tpi-site/src}"
WEB_ROOT="${TPI_SITE_WEB_ROOT:-/srv/tpi-site/www}"
SITE_SUBDIR="${TPI_SITE_SUBDIR:-tpi-site}"
DIST_SUBDIR="${TPI_SITE_DIST_SUBDIR:-tpi-site-dist}"
MODE="${TPI_SITE_MODE:-pull}"
NODE_IMAGE="${TPI_SITE_NODE_IMAGE:-node:22-alpine}"
STATE_FILE="${TPI_SITE_STATE:-/srv/tpi-site/.deploy-state}"
KEEP_PREV="${TPI_SITE_KEEP_PREV:-1}"
# 回滚备份放哪。默认是 ${WEB_ROOT}.prev —— 但那个位置在网站目录的【父目录】下，
# 而 systemd 的 ReadWritePaths 只放行网站目录本身，所以父目录是只读的，
# 在那里 mkdir/cp 会以「只读文件系统」失败。
# 因此 1Panel 场景下必须显式设 TPI_SITE_PREV_DIR=/srv/tpi-site/www.prev
# （放在部署工作目录里，也更干净：1Panel 的文件列表不会多出一个 index.prev）。
PREV_DIR="${TPI_SITE_PREV_DIR:-${WEB_ROOT}.prev}"
LOCK_FILE="${TPI_SITE_LOCK:-/srv/tpi-site/.deploy.lock}"
# git 操作的单次超时。上游是 GitHub，而这台服务器到 GitHub 是【间歇性】可达的，
# 没有这个上限时一次卡死要等 135 秒（已实测）。
GIT_TIMEOUT="${TPI_SITE_GIT_TIMEOUT:-120}"

DRY_RUN=0
FORCE=0
VERBOSE=0

# ── 日志 ──────────────────────────────────────────────────────
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
err()  { log ERROR "$@" >&2; }
debug(){ [ "$VERBOSE" = 1 ] && log DEBUG "$@" || true; }
die()  { err "$@"; exit 1; }

# ── 参数 ──────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--force)   FORCE=1 ;;
		-v|--verbose) VERBOSE=1 ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			echo
			echo "选项：--dry-run  --force（忽略 commit 未变）  -v"
			echo "环境变量：TPI_SITE_{REPO,BRANCH,SRC_DIR,WEB_ROOT,PREV_DIR,SUBDIR,DIST_SUBDIR,MODE,NODE_IMAGE,STATE,KEEP_PREV,LOCK,GIT_TIMEOUT}"
			echo "          没设的那些会从 systemd 单元（TPI_SITE_UNIT_FILE，默认 /etc/systemd/system/tpi-site-deploy.service）的 Environment= 里补齐"
			exit 0
			;;
		*) die "未知参数：$1" ;;
	esac
	shift
done

# ── 单实例锁（防定时器与手跑重叠）──────────────────────────────
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	info "已有一次部署在跑（$LOCK_FILE），本次跳过"
	exit 0
fi

# ── 0. 依赖检查 ───────────────────────────────────────────────
command -v git >/dev/null || die "缺 git"
command -v rsync >/dev/null || die "缺 rsync（apt install rsync）"
if [ "$MODE" = "build" ]; then
	command -v docker >/dev/null || die "模式 build 需要 docker；不想装就把 TPI_SITE_MODE 改成 pull"
fi
case "$MODE" in pull|build) ;; *) die "TPI_SITE_MODE 只能是 pull 或 build（当前 $MODE）" ;; esac

# ── 0.5 身份对齐：别让“运行用户 ≠ 仓库属主”把 git 卡死 ──────
# 沙箱和运行用户本来都来自 systemd 单元（User= 部署用户）。但如果有人（或某个任务）
# 直接 `sudo 本脚本`，就会以 root 跑 git，而仓库属于部署用户 → git 2.35+ 直接拒绝：
#   fatal: detected dubious ownership in repository at '…'
# 而且就算用 safe.directory 绕过读检查，还会把 state / lock / rsync 出的文件写成
# root 属主，下一次以部署用户跑的自动任务又写不了 —— 属主混乱会连锁。
# 所以：以 root 跑但仓库不属于 root 时，**自我降级重跑**（保持属主一致）。
if [ "$(id -u)" -eq 0 ] && [ -d "$SRC_DIR" ]; then
	SRC_OWNER="$(stat -c '%U' "$SRC_DIR" 2>/dev/null || echo root)"
	if [ "$SRC_OWNER" != "root" ] && id "$SRC_OWNER" >/dev/null 2>&1; then
		info "以 root 运行、但 $SRC_DIR 属于 $SRC_OWNER → 降级为 $SRC_OWNER 重跑"
		exec sudo -u "$SRC_OWNER" -- "$0" "$@"
	fi
	# 降级不了（仓库本身就是 root 属主）：本次能发出去，但产物、state、lock 都会是 root 属主，
	# 下一次以部署用户跑的自动部署会在 git / 写 state 那一步炸（属主混乱连锁）。
	warn "以 root 运行，且 $SRC_DIR 属于 root → 本次写出的文件都会是 root 属主"
	warn "    修：sudo chown -R <单元 User= 那个用户> /srv/tpi-site"
fi

info "=========== tpi-site-deploy 开始（mode=$MODE）==========="
if [ -n "$ENV_NOTE" ]; then info "$ENV_NOTE"; fi

# ── 0.6 运行方式告警：不是 systemd 单元拉起的，就是「裸跑」────────
# systemd 拉起服务时会设 INVOCATION_ID；没有它 = 手跑，或者 1Panel 任务的脚本
# 内容里直接写了本脚本（应为 /usr/local/bin/tpi-site-sync.sh）。那条路没有沙箱，
# 写出的文件属主 = 调用者 —— 以 root 跑会把下一次走单元的自动部署顶出
# “dubious ownership” / permission denied。配置已在上边补齐，所以这里只是告警。
if [ -z "${INVOCATION_ID:-}" ]; then
	warn "不是 systemd 单元拉起的（无 INVOCATION_ID）→ 裸跑：没有沙箱，产物属主 = $(id -un)"
	warn "    1Panel 计划任务的脚本内容应是：/usr/local/bin/tpi-site-sync.sh"
	warn "    手跑建议：sudo systemctl start tpi-site-deploy.service（要带参数才直接跑本脚本）"
fi

# ── 1. 检出代码 ───────────────────────────────────────────────
# 上游是 GitHub，而这台服务器到它是【间歇性】可达的：好的时候 0.45 秒返回 200，
# 坏的时候 TCP 连接卡 135 秒才失败。所以：
#   · 所有 git 操作都套 timeout —— 不允许卡死整轮
#   · 拉取失败 = 【正常降级】（exit 0，线上一个字节不变），下一轮自动重试
#     这里不能 die：网络抖动不该在面板里显示成一片红叉，它和
#     tpi-update-sync 的「上游无可用元数据 → 保持现有文件」是同一个哲学。
if [ -d "$SRC_DIR/.git" ]; then
	info "拉取上游 $BRANCH …（超时 ${GIT_TIMEOUT}s）"
	git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
	# 浅拉 + 硬重置：不产生 merge commit，也不会有本地改动导致 pull 失败
	if ! timeout "$GIT_TIMEOUT" git -C "$SRC_DIR" fetch --quiet --depth 1 origin "$BRANCH"; then
		warn "上游不可达（git fetch 失败或超过 ${GIT_TIMEOUT}s）→ 跳过本轮，线上不变"
		warn "    这是正常降级，1Panel 任务的下一轮会自动重试"
		exit 0
	fi
	git -C "$SRC_DIR" reset --quiet --hard FETCH_HEAD
	git -C "$SRC_DIR" clean -qfd -e node_modules -e .npm-cache
else
	info "首次 clone $REPO_URL …（超时 ${GIT_TIMEOUT}s，实测顺利时约 73 秒）"
	mkdir -p "$(dirname "$SRC_DIR")"
	if ! timeout "$GIT_TIMEOUT" git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"; then
		warn "首次 clone 失败或超时 → 跳过本轮，线上不变（下一轮会重试）"
		exit 0
	fi
fi

COMMIT="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
info "上游 commit：$COMMIT"

# ── 2. 内容没变就不干活 ───────────────────────────────────────
if [ "$FORCE" != 1 ] && [ -f "$STATE_FILE" ]; then
	prev_commit="$(sed -n 's/^commit=//p' "$STATE_FILE" | head -1)"
	prev_mode="$(sed -n 's/^mode=//p' "$STATE_FILE" | head -1)"
	if [ "$prev_commit" = "$COMMIT" ] && [ "$prev_mode" = "$MODE" ]; then
		info "与上次部署相同（$COMMIT, $MODE）→ 无需操作"
		exit 0
	fi
fi

case "$SITE_SUBDIR" in
	*..*|/*) die "TPI_SITE_SUBDIR 不合法：$SITE_SUBDIR" ;;
esac
SITE_DIR="$SRC_DIR/$SITE_SUBDIR"
[ -d "$SITE_DIR" ] || die "仓库里没有 $SITE_SUBDIR/ 目录"

# ── 3. 拿到构建产物目录 ───────────────────────────────────────
if [ "$MODE" = "pull" ]; then
	DIST_DIR="$SRC_DIR/$DIST_SUBDIR"
	[ -d "$DIST_DIR" ] || die "模式 pull 需要仓库里有 $DIST_SUBDIR/（先跑 npm run publish 并 push）"
	info "使用仓库内预构建产物 $DIST_SUBDIR/"
else
	[ -f "$SITE_DIR/package-lock.json" ] || die "缺少 $SITE_SUBDIR/package-lock.json，无法复现构建"
	LOCK_HASH="$(sha256sum "$SITE_DIR/package-lock.json" | cut -c1-16)"
	prev_lock="$(sed -n 's/^lock=//p' "$STATE_FILE" 2>/dev/null | head -1 || true)"

	if [ "$prev_lock" != "$LOCK_HASH" ] || [ ! -d "$SITE_DIR/node_modules" ]; then
		info "依赖有变化（lock=$LOCK_HASH）→ 在容器内 npm ci …"
		if [ "$DRY_RUN" = 1 ]; then
			info "[dry-run] docker run $NODE_IMAGE npm ci"
		else
			# --user 让产物归部署用户所有：否则 root 建出来的 node_modules / dist
			# 会让下一次 git reset --hard、git clean 因权限失败
			docker run --rm --user "$(id -u):$(id -g)" \
				-v "$SITE_DIR":/app -w /app -e HOME=/app -e npm_config_cache=/app/.npm-cache \
				"$NODE_IMAGE" sh -c 'npm ci --no-audit --no-fund' || die "npm ci 失败"
		fi
	else
		info "依赖未变（lock=$LOCK_HASH）→ 跳过 npm ci"
	fi

	info "在容器内构建 …"
	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] docker run $NODE_IMAGE npm run build"
	else
		# --user 同上：让 dist 归部署用户所有，git 后续操作才不会被 root 属主挡住
		docker run --rm --user "$(id -u):$(id -g)" \
			-v "$SITE_DIR":/app -w /app -e HOME=/app -e npm_config_cache=/app/.npm-cache \
			"$NODE_IMAGE" sh -c 'npm run build' || die "构建失败"
	fi
	DIST_DIR="$SITE_DIR/dist"
fi

# ── 4. 产物校验（不过关绝不发布）──────────────────────────────
if [ "$DRY_RUN" != 1 ]; then
	[ -f "$DIST_DIR/index.html" ] || die "产物里没有 index.html → 拒绝发布"
	grep -q 'class="poster"' "$DIST_DIR/index.html" || die "index.html 不像本站页面 → 拒绝发布"
	grep -q '/update/latest.json' "$DIST_DIR/index.html" || die "index.html 里缺少版本号取数逻辑 → 拒绝发布"
	[ -f "$DIST_DIR/fonts/notosanssc-900.woff2" ] || die "产物缺少中文字体 → 拒绝发布"
	[ -f "$DIST_DIR/favicon.svg" ] || die "产物缺少 favicon.svg → 拒绝发布"
	FILES="$(find "$DIST_DIR" -type f | wc -l)"
	SIZE="$(du -sh "$DIST_DIR" | cut -f1)"
	info "产物校验通过：$FILES 个文件 / $SIZE"

	# 体积失控守卫：单页站正常 ~0.4MB（含背景那个 WebGPU 客户端岛），
	# 超过 5MB 说明误把 node_modules 之类同步进来了
	BYTES="$(du -sb "$DIST_DIR" | cut -f1)"
	[ "$BYTES" -lt 5242880 ] || die "产物 $SIZE 明显异常（>5MB）→ 拒绝发布"
fi

# ── 5. 发布（原子 + 保留上一版）───────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
	info "[dry-run] rsync $DIST_DIR/ → $WEB_ROOT/（并保留上一版）"
	info "[dry-run] 全部通过，未写任何文件"
	exit 0
fi

mkdir -p "$WEB_ROOT"

if [ "$KEEP_PREV" = 1 ] && [ -n "$(ls -A "$WEB_ROOT" 2>/dev/null || true)" ]; then
	rm -rf "$PREV_DIR"
	mkdir -p "$(dirname "$PREV_DIR")"
	cp -a "$WEB_ROOT" "$PREV_DIR"
	info "已保留上一版到 ${PREV_DIR}"
fi

# --delay-updates：先写临时名、最后统一改名 —— 每个文件是原子替换，不会出现半个文件
# --delete：清掉线上已不存在的陈旧文件。两条 exclude 是不能被它删掉的共用文件：
#   404.html     1Panel 生成的错误页，不是我们的产物（少这一条，每次部署都会删掉它）
#   .well-known  约定目录（将来若直接在 OpenResty 上签证书会用到）
rsync -a --delete --delay-updates \
	--exclude '404.html' \
	--exclude '.well-known' \
	"$DIST_DIR/" "$WEB_ROOT/" || die "rsync 失败（线上目录可能只更新了一部分，用 ${PREV_DIR} 回滚）"

# ── 6. 记录状态 ───────────────────────────────────────────────
{
	echo "commit=$COMMIT"
	echo "mode=$MODE"
	echo "deployed_at=$(date -Is)"
	echo "lock=${LOCK_HASH:-}"
} > "$STATE_FILE"

info "发布完成：$COMMIT → $WEB_ROOT"
info "=========== tpi-site-deploy 结束 ==========="
