# tpi-release

tpi公开资产仓库

server：
```bash
安装:
  curl -fsSLO https://cdn.jsdelivr.net/gh/wanshushan/tpi-release@main/server/install-sync.sh
  sudo bash install-sync.sh wanshushan
常用命令：
  systemctl list-timers tpi-update-sync.timer     # 下次触发时间
  journalctl -u tpi-update-sync -n 50 --no-pager  # 看同步日志
  journalctl -u tpi-update-sync -f                # 实时跟踪
  systemctl start tpi-update-sync.service         # 手动立刻同步一次
  sudo /usr/local/bin/tpi-update-sync.py --dry-run -v   # 只检查不写入
```

## tpi-site（tpi.wanshushan.top 的简介页）

| 目录 | 是什么 |
|---|---|
| `tpi-site/` | Astro 源码（改这里） |
| `tpi-site-dist/` | **预构建产物**，由 `npm run publish` 生成；服务器只拉它，不在服务器上构建 |
| `server/tpi-site-deploy.sh` | 服务器侧部署脚本（拉取 → 校验 → 原子替换，失败不动线上） |
| `server/README-SITE.md` | 部署运维说明（含 `pull` / `build` 两种模式的安全取舍） |

日常更新：
```bash
cd tpi-site && npm run publish    # = build + 同步到 ../tpi-site-dist
cd .. && git add -A && git commit -m "site: …" && git push
ssh myvps "sudo systemctl start tpi-site-deploy"   # 想立刻生效（否则最多 5 分钟自动）
```

> ⚠️ 改了页面文案要先 `npm run fonts`（字体是按实际用到的字符切子集的）。
>
> ⚠️ `.gitattributes` 把 `tpi-site-dist/**` 与所有字体标成 `-text` —— 没有它，
> Windows 上 `core.autocrlf=true` 会把 woff2 的字节改坏。
