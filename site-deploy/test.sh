#!/usr/bin/env bash
# ============================================================
# tpi-site-deploy 测试台
#
#   bash test-site-deploy.sh
#
# 用一个临时 git 仓库当「上游」，把 rsync / flock 换成桩（它们本身是被充分
# 验证过的工具，这里要验的是我们自己的逻辑：拉取 → 变更判定 → 产物校验 →
# 发布 → 状态记录 → 失败不动线上）。
#
# 注意：部署脚本会「从 systemd 单元补齐没被显式设置的配置」，所以下面的用例
# 都把 TPI_SITE_UNIT_FILE 指向一个不存在的路径 —— 否则开发机/服务器上真有一个
# 单元时会把用例带偏。这条兜底本身由 J 单独验。
#
# 只依赖 git。在开发机和服务器上都能跑。
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEPLOY="${HERE}/tpi-site-deploy.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  （$2）"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

UPSTREAM="$T/upstream"
SRC="$T/src"
WEB="$T/www"
STATE="$T/.deploy-state"
LOCK="$T/.deploy.lock"
STUB="$T/stub"

# ── rsync / flock 桩 ─────────────────────────────────────────
mkdir -p "$STUB" "$WEB"
cat > "$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
# 只实现本脚本用到的那几个开关：-a --delete --delay-updates --exclude X
set -euo pipefail
args=(); exclude=()
while [ $# -gt 0 ]; do
	case "$1" in
		-a|--delete|--delay-updates) ;;
		--exclude) shift; exclude+=("$1") ;;
		--) ;;
		*) args+=("$1") ;;
	esac
	shift
done
src="${args[0]}"; dst="${args[1]}"
rm -rf "$dst"; mkdir -p "$dst"
if [ ${#exclude[@]} -gt 0 ]; then
	cp -a "$src." "$dst/"
	for e in "${exclude[@]}"; do rm -rf "${dst:?}/${e#/}"; done
else
	cp -a "$src." "$dst/"
fi
EOF
cat > "$STUB/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB/rsync" "$STUB/flock"

# ── 造一个「上游」仓库 ────────────────────────────────────────
make_upstream() {
	local msg="$1" poster="${2:-yes}" with_index="${3:-yes}"
	rm -rf "$UPSTREAM"; mkdir -p "$UPSTREAM/tpi-site" "$UPSTREAM/tpi-site-dist/fonts"
	printf '{}\n' > "$UPSTREAM/tpi-site/package.json"
	printf '{}\n' > "$UPSTREAM/tpi-site/package-lock.json"
	if [ "$with_index" = "yes" ]; then
		{
			echo '<!doctype html><html><body><main class="poster">x</main>'
			echo '<script>fetch("/update/latest.json")</script></body></html>'
		} > "$UPSTREAM/tpi-site-dist/index.html"
	fi
	printf '<svg/>\n' > "$UPSTREAM/tpi-site-dist/favicon.svg"
	printf 'FONT\n'  > "$UPSTREAM/tpi-site-dist/fonts/notosanssc-900.woff2"
	[ "$poster" = "yes" ] || sed -i 's/class="poster"/class="xyz"/' "$UPSTREAM/tpi-site-dist/index.html"
	git -C "$UPSTREAM" init -q -b main
	git -C "$UPSTREAM" add -A
	git -C "$UPSTREAM" -c user.email=t@t -c user.name=t commit -qm "$msg"
}

deploy() {
	env PATH="$STUB:$PATH" \
		TPI_SITE_UNIT_FILE="$T/no-unit.service" \
		TPI_SITE_REPO="file://$UPSTREAM" \
		TPI_SITE_BRANCH=main \
		TPI_SITE_SRC_DIR="$SRC" \
		TPI_SITE_WEB_ROOT="$WEB" \
		TPI_SITE_STATE="$STATE" \
		TPI_SITE_LOCK="$LOCK" \
		TPI_SITE_MODE=pull \
		bash "$DEPLOY" "$@" 2>&1
}

# 和 deploy() 一样，但故意【不】给 TPI_SITE_WEB_ROOT / PREV_DIR，改用一个假的
# 单元文件 —— 验的是「手跑时从单元补齐配置」那条兜底（J）。
# 额外传进来的 VAR=值 会当成 env 赋值（显式给的优先，不该被单元覆盖）。
deploy_via_unit() {
	env PATH="$STUB:$PATH" \
		TPI_SITE_UNIT_FILE="$UNIT_FILE" \
		TPI_SITE_REPO="file://$UPSTREAM" \
		TPI_SITE_BRANCH=main \
		TPI_SITE_SRC_DIR="$SRC" \
		TPI_SITE_STATE="$STATE" \
		TPI_SITE_LOCK="$LOCK" \
		TPI_SITE_MODE=pull \
		"$@" \
		bash "$DEPLOY" --force 2>&1
}

echo "== A. 首次部署 =="
make_upstream "init"
out="$(deploy)"
check "退出码 0"                    "[ $? -eq 0 ]"
check "线上目录有 index.html"        "[ -f '$WEB/index.html' ]"
check "字体已同步"                   "[ -f '$WEB/fonts/notosanssc-900.woff2' ]"
check "写入了 state（commit=）"      "grep -q '^commit=' '$STATE'"
check "state 记录了模式"             "grep -q '^mode=pull' '$STATE'"
check "日志写了发布完成"             "grep -q '发布完成' <<< '$out'"

echo
echo "== B. 幂等：commit 未变 =="
before="$(cat "$WEB/index.html")"
out="$(deploy)"
check "退出码 0"                     "[ $? -eq 0 ]"
check "识别出「与上次部署相同」"      "grep -q '无需操作' <<< '$out'"
check "线上内容未变"                  "[ \"\$(cat '$WEB/index.html')\" = \"\$before\" ]"

echo
echo "== C. --force 强制重发 =="
out="$(deploy --force)"
check "没有走「无需操作」分支"        "! grep -q '无需操作' <<< '$out'"
check "仍然发布完成"                  "grep -q '发布完成' <<< '$out'"

echo
echo "== D. 上游更新 → 自动重新发布 =="
sleep 0.2
make_upstream "update"
printf 'MARK2\n' >> "$UPSTREAM/tpi-site-dist/index.html"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" -c user.email=t@t -c user.name=t commit -qm "update2"
out="$(deploy)"
check "重新发布了"                    "grep -q '发布完成' <<< '$out'"
check "线上拿到新内容"                "grep -q 'MARK2' '$WEB/index.html'"
check "保留了上一版 www.prev"          "[ -d '${WEB}.prev' ]"

echo
echo "== E. 产物非法（缺 class=\"poster\"）→ 拒绝且不动线上 =="
snapshot="$(cat "$WEB/index.html")"
make_upstream "bad-poster" no
out="$(deploy --force)"
code=$?
check "退出码非 0"                    "[ $code -ne 0 ]"
check "日志指出拒绝原因"              "grep -q '拒绝发布' <<< '$out'"
check "线上一个字节没动"              "[ \"\$(cat '$WEB/index.html')\" = \"\$snapshot\" ]"

echo
echo "== F. 产物缺失 index.html → 拒绝 =="
make_upstream "no-index" yes no
out="$(deploy --force)"
check "退出码非 0"                    "[ $? -ne 0 ]"
check "日志指出没有 index.html"        "grep -q '没有 index.html' <<< '$out'"
check "线上仍未变"                    "[ \"\$(cat '$WEB/index.html')\" = \"\$snapshot\" ]"

echo
echo "== G. 体积守卫（>5MB 拒绝）=="
make_upstream "huge"
head -c 6000000 /dev/zero > "$UPSTREAM/tpi-site-dist/big.bin"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" -c user.email=t@t -c user.name=t commit -qm huge
out="$(deploy --force)"
check "退出码非 0"                    "[ $? -ne 0 ]"
check "日志指出体积异常"              "grep -q '明显异常' <<< '$out'"
check "线上仍未变"                    "[ \"\$(cat '$WEB/index.html')\" = \"\$snapshot\" ]"

echo
echo "== H. 仓库里没有 tpi-site-dist/ → 明确报错 =="
make_upstream "nodist"
rm -rf "$UPSTREAM/tpi-site-dist"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" -c user.email=t@t -c user.name=t commit -qm nodist
out="$(deploy --force)"
check "退出码非 0"                    "[ $? -ne 0 ]"
check "提示先跑 npm run publish"      "grep -q 'npm run publish' <<< '$out'"

echo
echo "== I. --dry-run 不写盘 =="
make_upstream "dry"
before="$(cat "$WEB/index.html")"
out="$(deploy --dry-run --force)"
check "退出码 0"                      "[ $? -eq 0 ]"
check "提示未写任何文件"              "grep -q '未写任何文件' <<< '$out'"
check "线上未变"                      "[ \"\$(cat '$WEB/index.html')\" = \"\$before\" ]"

echo
echo "== J. 手跑：配置从 systemd 单元补齐（显式给的优先）=="
make_upstream "unit-env"
UNIT_WEB="$T/unit-www"
UNIT_FILE="$T/unit.service"
{
	echo '[Service]'
	echo "Environment=TPI_SITE_WEB_ROOT=$UNIT_WEB"
	echo "Environment=TPI_SITE_PREV_DIR=$T/unit.prev"
	echo 'Environment=TPI_SITE_MODE=pull'
	echo "# Environment=TPI_SITE_WEB_ROOT=$T/should-be-ignored"
} > "$UNIT_FILE"

# J1：单元里有 WEB_ROOT，但显式给了另一个 → 显式优先（不能发到单元那个目录）
EXPLICIT_WEB="$T/explicit-www"
out="$(deploy_via_unit TPI_SITE_WEB_ROOT="$EXPLICIT_WEB")"
check "显式给的优先：发到显式目录"      "[ -f '$EXPLICIT_WEB/index.html' ]"
check "没有发到单元声明的目录"          "[ ! -e '$UNIT_WEB/index.html' ]"

# J2：不显式给 → 从单元补齐（注释掉的 Environment 不算）
mkdir -p "$UNIT_WEB"
printf 'stale\n' > "$UNIT_WEB/index.html"      # 先把目录弄非空，让「保留上一版」那条分支也走到
out="$(deploy_via_unit)"
check "日志说明配置取自单元"            "grep -q '已从 unit.service 补齐' <<< '$out'"
check "发布到单元声明的目录"            "[ -f '$UNIT_WEB/index.html' ] && [ \"\$(cat '$UNIT_WEB/index.html')\" != 'stale' ]"
check "回滚备份也用单元里的设置"        "[ -d '$T/unit.prev' ]"
check "裸跑会打告警"                    "grep -q '不是 systemd 单元拉起的' <<< '$out'"

echo
echo "────────────────────────────────────────"
printf '通过 %d / 失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
