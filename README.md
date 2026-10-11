# tpi-release

`tpi.wanshushan.top` 这个域名后面的一切：**更新元数据分发** + **简介页**。

客户端只认这一个域名（`electron/updater.cjs` 里写死的 `ALLOWED_FEED_PREFIXES`），
所以这个仓库的职责就是：**让 `tpi.wanshushan.top` 上永远有正确的元数据和简介页。**

---

## 30 秒看懂链路

```
                          tpi.wanshushan.top
                                  │
                    Cloudflare Edge （Tunnel `vps`）
                                  │
                        127.0.0.1:5757  Caddy  ← 唯一入口
                                  │
      ┌───────────────────────────┼───────────────────────────┐
      │                           │                           │
 /update/latest.{yml,json}   /releases/download/*        其余（含 /）
      │                           │                           │
 /srv/tpi-update/update/     302 跳转                         │
 （Caddy 发本地文件）            ▼                    127.0.0.1:4477
      ▲                tpirelease.wanshushan.top     （1Panel OpenResty）
      │                Cloudflare R2（存 185MB 安装包）        │
      │                                                 简介页 index.html
      │
 tpi-update-sync.py ← 1Panel 计划任务「tpi 元数据同步」每 1 分钟
                       从 GitHub releases/latest 拉取
```

**两条路分工**（这是整套设计的地基）：

| | 元数据（几百字节） | 字节（185MB） |
|---|---|---|
| 谁发 | Caddy 发**本地文件** | 302 到 **R2** |
| 依赖 GitHub 吗 | ❌ 不依赖（本地化了） | ❌ 不依赖（在 R2 上） |
| 为什么 | 客户端**检查更新**这条路必须永不失败 | 大文件走 CF 边缘，中国访问明显快 |

---

## 🔧 运维速查表

> 所有自动任务都在 **1Panel → 计划任务** 里。看日志、手动跑、改周期都是同一个地方。

| 任务 | 周期 | 在 1Panel 的名字 | 日志 | 手动跑一次 |
|---|---|---|---|---|
| 元数据同步 | **每 1 分钟** | `tpi 元数据同步` | 执行记录 · 或 `tail -f /var/log/tpi/update-sync.log` | 1Panel 里点「执行」 |
| 简介页部署 | **每 5 分钟** | `tpi 简介页部署` | 执行记录 · 或 `tail -f /var/log/tpi/site-deploy.log` | 1Panel 里点「执行」 |
| 入口（Caddy） | 常驻服务 | —（不是定时任务） | `journalctl -u caddy -n 50` | `systemctl reload caddy` |

**命令行手动跑**（等价于面板上的「执行」按钮）：

```bash
sudo /usr/local/bin/tpi-release-sync.sh    # 同步元数据
sudo /usr/local/bin/tpi-site-sync.sh       # 部署简介页
```

**当前线上状态自查**：

```bash
curl -s http://127.0.0.1:5757/update/latest.json | head -c 80   # 元数据版本
curl -sI http://127.0.0.1:5757/releases/download/v0.26.9/TutorPi-Setup-0.26.9.exe | head -1   # 期望 302
curl -sI https://tpi.wanshushan.top/ | head -1                   # 期望 200
```

---

## 日常操作

### 改简介页

```bash
cd tpi-site
npm run publish          # build + 同步到 ../tpi-site-dist + 打 dist.zip
cd ..
git add -A && git commit -m "site: 改了什么" && git push
```

最多 5 分钟自动上线。想立刻上线 → 1Panel → 计划任务 → `tpi 简介页部署` → **执行**。

> ⚠️ 改了页面**文案**要先 `npm run fonts` —— 字体是按页面实际用到的字符切子集的
> （`.fontsrc/` 是源字体缓存，不用提交）。

### 发新版客户端

**完全不用 SSH**。在 GitHub 上：

1. 建 release，**勾 prerelease**，传上 `TutorPi-Setup-*.exe` / `TutorPi-*-win.zip` / `.blockmap` / `latest.yml` / `latest.json`
2. 确认无误后点 **Set as the latest release**（或取消 prerelease 勾选）

最多 1 分钟（平均约 5 分钟，见下）同步到服务器，**闸门就开了**。想回滚就在旧 release 上再点一次。

> **为什么是"平均约 5 分钟"**：这台服务器到 GitHub 实测约 **5 次里通 1 次**
> （每次卡满 30 秒超时）。1 分钟跑一次、通了就成功，所以平均约 5 分钟。
> 失败时脚本什么都不改，线上继续用旧元数据 —— 这是设计意图，不是 bug。

---

## 目录结构

```
tpi-release/
├── README.md                  你在这
├── docs/
│   ├── 运维.md                ★ 每个任务：怎么跑、怎么看、怎么回滚、怎么排障
│   └── 架构.md                ★ 为什么这样设计（三条硬性行为 / 安全性质 / 两种模式）
│
├── update-sync/               【套 1】更新元数据同步
│   ├── tpi-update-sync.py     干活的脚本
│   ├── tpi-update-sync.service  只读沙箱定义（不是调度器！）
│   ├── task.sh                ★ 计划任务入口 → 装成 /usr/local/bin/tpi-release-sync.sh
│   ├── install.sh             安装
│   ├── test.py                本地端到端测试台（20 断言）
│   └── legacy/                systemd timer（已退役，留着回滚）
│
├── site-deploy/               【套 2】简介页部署
│   ├── tpi-site-deploy.sh     干活的脚本
│   ├── tpi-site-deploy.service  只读沙箱定义
│   ├── task.sh                ★ 计划任务入口 → 装成 /usr/local/bin/tpi-site-sync.sh
│   ├── install.sh             安装
│   ├── test.sh                本地端到端测试台（28 断言）
│   └── legacy/                systemd timer（已退役）
│
├── tools/
│   └── tpied_clear.sh         一键清理旧部署的残留
│
├── tpi-site/                  Astro 源码（改页面改这里）
└── tpi-site-dist/             ★ 预构建产物 —— 服务器只拉它，不在服务器上构建
```

**为什么 `task.sh` 和 `tpi-*-deploy.sh` 是两个文件**：调度用 1Panel，执行要 systemd 的只读沙箱。
`task.sh` 是"给 1Panel 的那一行"，`tpi-*-deploy.sh` 是真正干活的。详见 `docs/架构.md`。

---

## 安装 / 重装

```bash
# 服务器上（第一次装、或换目标目录/换拉取源时重跑，幂等）
sudo bash update-sync/install.sh  wanshushan
sudo bash site-deploy/install.sh  root --web-root /opt/1panel/www/sites/tpi/index
```

装完按打印出来的提示，在 1Panel 建那两个计划任务。

**清理旧部署残留**：

```bash
sudo bash tools/tpied_clear.sh --dry-run   # 先看要做什么
sudo bash tools/tpied_clear.sh             # 停旧 timer + 删公网可见的残留
```

---

## 更新这个仓库时注意

- `.gitattributes` 把 `tpi-site-dist/**` 和所有字体标成 `-text`。
  **没有它**，Windows 上 `core.autocrlf=true` 会把 `.woff2` 的字节改坏，页面字体直接崩。
- `tpi-site-dist/` 必须和 `tpi-site/` 同步提交（`npm run publish` 会一起做）。
  服务器只读 `tpi-site-dist/`，它和源码不一致时线上就是旧页面。
