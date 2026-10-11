# tpi-site-deploy —— 简介页自动部署（服务器侧运维说明）

> 这份文件由 `install-site-deploy.sh` 部署到 `/srv/tpi-site/README-SITE.md`

## 它在做什么

```
GitHub  wanshushan/tpi-release  (public)
   │
   │  git fetch --depth 1 + reset --hard（每 5 分钟一次，或手动触发）
   ▼
/srv/tpi-site/src/            ← 浅克隆的工作副本
   │
   │  pull 模式：直接取仓库里的 tpi-site-dist/
   │  build 模式：docker run node:22-alpine → npm ci && npm run build
   ▼
  产物校验（index.html / 取数逻辑 / 字体 / 体积守卫）
   │
   │  rsync --delay-updates --delete
   ▼
/srv/tpi-site/www/            ← 线上目录（Caddy 的 root 或 1Panel 站点目录）
/srv/tpi-site/www.prev/       ← 上一版，回滚用
```

**日常更新只需要 `git push`**，服务器最多 5 分钟内自己发；急的话 `sudo systemctl start tpi-site-deploy`。

---

## ⚠️ 两种模式的安全取舍（读这一节再选）

| | `pull`（默认，推荐） | `build` |
|---|---|---|
| 服务器需要 Node/npm 吗 | 不需要 | 不需要（用 Docker，不污染宿主） |
| 服务器执行仓库里的代码吗 | **不执行** | 执行 `npm ci`（含 postinstall）+ `npm run build` |
| 仓库里放的 | 源码 + 预构建产物 `tpi-site-dist/` | 只要源码 |
| 本地要做的 | `npm run publish` + push | 只 push |
| GitHub 账号被盗的后果 | 能改网站内容、能伪造更新包 | 同左，**外加能在服务器上执行任意代码** |
| 服务器被攻破的后果 | **改不了 `latest.yml`**（无写入口） | 能改 —— 构建脚本就在服务器上跑 |

`tpi-update-sync` 建立的核心性质是「**服务器只读**：被攻破也无法伪造 `latest.yml`」。
`build` 模式会在服务器上开出一条「外部仓库 → 代码执行」的路径，**这是对那条性质的实质回退**。

所以默认是 `pull`。真要切 `build`，见下面「切换成 build 模式」。

---

## 三条硬性行为（排查时对照）

1. **失败不动线上**。任何一步出错都在 `rsync` 之前中止 —— 网站目录一个字节不变。看 `journalctl` 里的 `ERROR`。
2. **产物先校验再发布**。`index.html` 必须存在、必须含 `class="poster"` 与 `/update/latest.json`、中文字体与 favicon 必须在；产物 >5MB 或文件数异常一律拒绝。
3. **内容没变就不干活**。commit 与上次相同 → 直接退出，不构建、不写盘。

---

## 安装

```bash
# 本地
scp -r tpi-release/server myvps:/tmp/tpi-site-server

# 服务器
sudo bash /tmp/tpi-site-server/install-site-deploy.sh wanshushan          # 只装，不开定时器
sudo bash /tmp/tpi-site-server/install-site-deploy.sh wanshushan --with-timer   # 开每 5 分钟
```

依赖：`git` `rsync` `flock`（`sudo apt-get install -y git rsync util-linux`）。

---

## 第 3 步：把网站目录接到入口上（**装完必须做**）

脚本只负责把文件写到 `TPI_SITE_WEB_ROOT`，**不会**动任何 Web 服务配置。二选一：

### A. Caddy 直接发文件（推荐 —— 零新组件、零权限问题）

`/etc/caddy/Caddyfile` 里把末位的兜底块换成：

```caddyfile
	# ③ 其余交给简介页
	handle {
		root * /srv/tpi-site/www
		file_server
	}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

`/srv/tpi-site/www` 属于部署用户，Caddy 以 `caddy` 用户运行 —— 需要目录可读：

```bash
sudo chmod -R a+rX /srv/tpi-site/www
```

### B. 保留 1Panel 管这个站

⚠️ **1Panel 的 OpenResty 跑在容器里**（`network_mode: host` 但文件系统是容器的），
宿主上的 `/srv/tpi-site/www` 在容器里**看不见**。所以不能把站点 `root` 指过去。

只能反过来 —— 让脚本直接写进 1Panel 的站点目录（那个目录是挂进容器的）：

1. 1Panel 建静态站（域名 `tpi.wanshushan.top`、端口 **`4477`**、代号 **`tpi`**）。
   实测网站目录 = **`/opt/1panel/www/sites/tpi/index`**（1Panel v2.3.2 布局，
   这个路径已挂进 OpenResty 容器）
2. 装部署脚本时直接用 `--web-root` 指过去（它会同时改好 `TPI_SITE_WEB_ROOT`
   与 systemd 的 `ReadWritePaths`）：

   ```bash
   sudo bash install-site-deploy.sh root \
     --web-root /opt/1panel/www/sites/tpi/index --with-timer
   ```

   注意运行用户给 **`root`** —— 1Panel 的站点目录属于 root，普通用户写不进去。
3. 把 `listen 4477;` 改成 `listen 127.0.0.1:4477;`，并删掉防火墙里 4477 的放行
   （改完**不要**再在 UI 里改这个站的域名/端口，原因见 `tpi-site/README.md`）
5. Caddy 再反代过去：

   ```caddyfile
   	handle {
   		reverse_proxy 127.0.0.1:4477 {
   			header_up Host {http.request.host}
   		}
   	}
   ```

---

## 日常更新（pull 模式）

```bash
# 本地（tpi-release/tpi-site/）
npm run publish          # = build + 同步到 ../tpi-site-dist + 打印后续命令
cd .. && git add -A && git commit -m "site: …" && git push

# 想立刻生效（不等定时器）
ssh myvps "sudo systemctl start tpi-site-deploy"
```

> ⚠️ **改了页面文案记得先 `npm run fonts`**（字体子集是按实际用到的字符切的），
> 否则新字会掉到系统字体。

---

## 切换成 build 模式

1. 改 `/etc/systemd/system/tpi-site-deploy.service`：

   ```ini
   Environment=TPI_SITE_MODE=build
   ```

2. **把加固段换成下面这组**（`ProtectSystem=strict` 与 docker 冲突）：

   ```ini
   ProtectSystem=full
   ReadWritePaths=/srv/tpi-site
   PrivateTmp=true
   PrivateDevices=true
   RestrictSUIDSGID=true
   LockPersonality=true
   NoNewPrivileges=true
   ```

3. `sudo systemctl daemon-reload`，然后手动跑一次

   首次 `npm ci` 会往 `/srv/tpi-site/src/tpi-site/node_modules` 拉约 400MB，确认磁盘够。

4. 退出 build 模式：把 `TPI_SITE_MODE` 改回 `pull` 并把加固段换回去。

---

## 回滚

```bash
# 单版本回滚（上一版在 www.prev）
sudo rsync -a --delete /srv/tpi-site/www.prev/ /srv/tpi-site/www/

# 回到某个历史 commit
sudo /usr/local/bin/tpi-site-deploy.sh --force        # 先把 src 对齐到最新
cd /srv/tpi-site/src && sudo git reset --hard <commit> && sudo cp -a ...   # 或直接改仓库 + force
```

改 Caddy/1Panel 那部分配置的回滚见 `tpi-site/README.md`。

---

## 环境变量

改在 `/etc/systemd/system/tpi-site-deploy.service`，改完 `daemon-reload` + 重启 timer。

| 变量 | 默认 | 说明 |
|---|---|---|
| `TPI_SITE_REPO` | `https://github.com/wanshushan/tpi-release.git` | 仓库地址（public，拉取不需要凭证） |
| `TPI_SITE_BRANCH` | `main` | 分支 |
| `TPI_SITE_SRC_DIR` | `/srv/tpi-site/src` | 浅克隆工作副本 |
| `TPI_SITE_WEB_ROOT` | `/srv/tpi-site/www` | **线上网站目录** |
| `TPI_SITE_SUBDIR` | `tpi-site` | 仓库里的站点源码目录 |
| `TPI_SITE_DIST_SUBDIR` | `tpi-site-dist` | 仓库里的预构建产物目录（pull 模式用） |
| `TPI_SITE_MODE` | `pull` | `pull` / `build` |
| `TPI_SITE_NODE_IMAGE` | `node:22-alpine` | build 模式用的镜像 |
| `TPI_SITE_STATE` | `/srv/tpi-site/.deploy-state` | 记录已部署 commit / lock hash |
| `TPI_SITE_KEEP_PREV` | `1` | 是否保留上一版到 `www.prev` |
| `TPI_SITE_LOCK` | `/srv/tpi-site/.deploy.lock` | 防重叠锁 |

> `www.prev` 与 `.deploy-state` 不在 `www` 里，所以 `rsync --delete` 不会误删它们。

---

## 排障

```bash
systemctl list-timers tpi-site-deploy.timer --no-pager   # 下次触发时间
journalctl -u tpi-site-deploy -n 50 --no-pager           # 看日志
journalctl -u tpi-site-deploy -f
sudo /usr/local/bin/tpi-site-deploy.sh --dry-run -v      # 只演练：拉取 + 校验，不写盘
sudo /usr/local/bin/tpi-site-deploy.sh --force -v        # 忽略「commit 未变」强制重发
cat /srv/tpi-site/.deploy-state                          # 当前部署的 commit / 模式
```

| 症状 | 原因 |
|---|---|
| 日志停在 `与上次部署相同` | 正常（内容没变）。要强发用 `--force` |
| `模式 pull 需要仓库里有 tpi-site-dist/` | 本地忘了 `npm run publish` 就 push |
| `产物里没有 index.html` | 构建失败或 `dist` 被 `.gitignore` 挡住没提交 |
| `git fetch 失败` | 服务器出网被挡，或仓库地址写错 |
| 页面 502 / 404，但 `www` 里有文件 | 入口没接上 —— 见「第 3 步」 |
| 网页还是旧内容 | 定时器没开；或浏览器/CF 缓存（强刷） |
