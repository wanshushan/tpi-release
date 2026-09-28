# tpi-update-sync —— 服务器侧运维说明

> 这份文件由 `install-sync.sh` 部署到 `/srv/tpi-update/README-SYNC.md`

## 它在做什么

每 60 秒从上游（默认 GitHub 的 `releases/latest/download/`）拉取两个小文件，校验通过后**原子替换**本地静态文件：

```
上游  https://github.com/wanshushan/tpi-release/releases/latest/download/latest.yml
      https://github.com/wanshushan/tpi-release/releases/latest/download/latest.json
   │
   │  tpi-update-sync.timer（每分钟）+ tpi-update-sync.service（oneshot）
   ▼
本地  /srv/tpi-update/update/latest.yml       ← Caddy 只读服务这个目录
      /srv/tpi-update/update/latest.json
      /srv/tpi-update/update/history/<版本>/  ← 提升前的旧版本备份
```

**客户端永远只读本地文件，不依赖上游可用性。** 上游挂了（404 / 超时 / 内容不合法）时，脚本什么都不改，线上继续用旧元数据 —— 已经发布出去的更新检查完全不受影响。

## 闸门在哪

不在服务器上，在 GitHub 上：

| 动作 | 后果 |
|---|---|
| 建 release 时勾 `prerelease` | `releases/latest` 会跳过它 → 客户端看不到 |
| 点 **Set as the latest release** | ≤60 秒后服务器同步到 → **闸门打开** |
| 在旧 release 上再点一次 **Set as the latest release** | ≤60 秒后回滚 |

所以：**日常发布不需要 SSH，也不需要任何 token**。服务器只有出站拉取，没有任何入站写入口。

## 常用命令

```bash
systemctl list-timers tpi-update-sync.timer     # 下次触发时间 / 上次触发时间
journalctl -u tpi-update-sync -n 50 --no-pager  # 看同步日志
journalctl -u tpi-update-sync -f                # 实时跟踪
systemctl start tpi-update-sync.service         # 手动立刻同步一次（想秒级生效就用这个）

# 只检查不写入（调试用）
sudo /usr/local/bin/tpi-update-sync.py --dry-run -v
# 忽略内容相同也强制重装
sudo /usr/local/bin/tpi-update-sync.py --force -v
# 跳过资产预检（上游探测有问题时的应急开关）
sudo /usr/local/bin/tpi-update-sync.py --skip-asset-check -v

# 历史备份（回滚的兜底手段之一；正常回滚请用 GitHub 的 Set as latest）
ls -l /srv/tpi-update/update/history/
```

## 环境变量（改在 `/etc/systemd/system/tpi-update-sync.service`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `TPI_SYNC_DEST` | `/srv/tpi-update/update` | 本地目标目录 |
| `TPI_SYNC_SOURCES` | GitHub `releases/latest/download` | 上游列表，**逗号分隔、按序回退**。加 R2/Gist 备用源就填在这里 |
| `TPI_SYNC_HISTORY_KEEP` | `5` | 历史保留份数，`0` = 不留 |
| `TPI_SYNC_ASSET_TIMEOUT` | `20` | 资产预检单次超时秒数，`0` = 跳过预检 |
| `TPI_SYNC_REQUIRE_HOST` | `releases/download/` | yml 里每个 url 必须包含该子串（防呆） |
| `TPI_SYNC_LOCK` | `<dest>/.sync.lock` | 防重叠锁文件 |

改完执行 `sudo systemctl daemon-reload && sudo systemctl restart tpi-update-sync.timer`。

## 三条硬性行为（排查时对照）

1. **失败不动现有文件**。任何异常 → 退出码非 0 且 `/srv/tpi-update/update/` 时间戳不变。看日志里的 `ERROR` / `WARN`。
2. **资产预检 404 → 拒绝提升**。日志会明确写 `关键资产不可下载 → 【拒绝提升】`。这通常意味着你在 GitHub 上忘了传 `TutorPi-Setup-*.exe` / `TutorPi-*-win.zip`，或者漏了 `.blockmap`（漏 blockmap 只告警不阻塞）。
   网络抖动（超时）不会阻塞 —— 免得把闸门卡死。
3. **`latest.yml` 是最后写入的**（先写 `latest.json`），且两者都用 `.tmp` + `os.replace` 原子替换。

## 未来的第二个上游（R2 / Gist）

在 service 里加一行即可，脚本会按序回退：

```ini
Environment=TPI_SYNC_SOURCES=https://github.com/wanshushan/tpi-release/releases/latest/download,https://dl2.wanshushan.top/meta
```

第二个源的目录里放同名的 `latest.yml` / `latest.json` 就行（R2 控制台支持直接拖文件上传对象，等于一条不用 SSH 的文件写入通道）。
