# tpi-site

`https://tpi.wanshushan.top` 的前台单页 —— **一句口号 + 当前版本号**。

同一个域名下同时跑着更新分发服务（`/update/*` 元数据、`/releases/download/*` 字节），
所以这个站必须与它**同源**：页面直接从 `/update/latest.json` 读版本号，
不用另建接口、不引入任何外部依赖。

- 风格：包豪斯（几何构造 + 三原色 + 纸白 + 无衬线黑体）
- 技术：Astro 静态输出，零运行时依赖、零外部请求
- 产物：`dist/` 共 6 个文件、约 29 KB（HTML 内联 CSS，字体子集化）

## 命令

```bash
npm install
npm run dev        # http://localhost:4321
npm run build      # → dist/
npm run preview    # 预览 dist/
npm run fonts      # 改了页面文案之后必须重跑（见下）
```

### 本地为什么能看到真实版本号

版本号来自 `/update/latest.json`，**这个文件只存在于服务器上**（`/srv/tpi-update/update/`）。
本地 dev / preview 服务器没有这条路由，不处理的话会 404、页面退到兑底态（`v—`）。

所以 `astro.config.mjs` 里把 `/update` 与 `/releases` 两个前缀**反代到生产域名**：

```js
const UPDATE_ORIGIN = 'https://tpi.wanshushan.top';
const proxy = {
	'/update':   { target: UPDATE_ORIGIN, changeOrigin: true },
	'/releases': { target: UPDATE_ORIGIN, changeOrigin: true },
};
// vite: { server: { proxy }, preview: { proxy } }
```

代理在 **dev server 侧**发出，浏览器看到的仍是同源请求 —— **整个过程不涉及 CORS**
（生产环境本来也是同源：Caddy 在同一域名下提供 `/update/*` 与 `/releases/*`）。

| 打开方式 | 版本号 | 说明 |
|---|---|---|
| `npm run dev` | ✅ 真实 | 走代理 |
| `npm run preview` | ✅ 真实 | 走代理 |
| 双击 `dist/index.html`（`file://`）| ❌ `v—` | 没有服务器。`/update/latest.json` 会被解析成 `file:///D:/update/latest.json`，必然失败 |
| 线上 | ✅ 真实 | Caddy 直接提供 |

> 兑底行为是故意的：拿不到元数据时版本号置灰（`data-state="na"`）、链接退回
> GitHub 发布页，**不显示假版本号**。

## 设计说明

**版式**：口号是两行四字（`src/pages/index.astro` 的 `SLOGAN`），字号同时受宽与高约束
（`min(21vw, 31vh)`），所以在超宽屏不会被上限卡住、在矮屏也不会顶穿底线。

**几何标记**：不是装饰性图形，是产品的核心机制 —— 三角闭环「生成 → 交叉质疑 → 裁决」，
三个节点用三原色区分，一段蓝色高亮沿闭环循环。

**构图规则**：宽且扁（≥ 16:9 且宽度 ≥ 1000px）时，标记挂在口号首行右侧；
其余比例（竖屏 / 方屏 / 窄屏）标记叠在口号上方。
这条规则是**结构上不会重叠**的——不要删掉那个媒体查询。

**版本号**：客户端 `fetch('/update/latest.json')` →
`artifacts['desktop-nsis'].mirrors[0]` 即下载地址。
拿不到就退到 GitHub 发布页并把版本号置灰（`data-state="na"`），**不显示假版本号**。

## 字体

不引 Google Fonts（中国大陆可达性不稳，且 Noto Sans SC 整族 101 个分片、数 MB）。
做法是 `scripts/build-fonts.mjs` 下载一次源字体（缓存在 `.fontsrc/`），
用 fontTools 按**页面实际用到的字符**切出单个 woff2：

| 文件 | 用途 | 体积 |
|---|---|---|
| `notosanssc-900.woff2` | 汉字（口号、品牌名）| ~14 KB |
| `jost-700.woff2` / `jost-900.woff2` | 拉丁字母与数字（`tutor_π`、版本号）| ~3.5 KB ×2 |

脚本只扫 `src/**/*.astro` 里**去掉标签、`<style>`、`<script>`、注释之后剩下的文本**，
所以中文注释不会把子集撑大。

> ⚠️ **改了页面上的任何文字（口号、品牌名、`sr-only` 文案、按钮字）都要重跑 `npm run fonts`**，
> 否则新字会掉到系统字体、字形和基线跟正文不一致。
>
> 依赖 Python 3 + `pip install fonttools brotli`。只在改文案时需要；
> `public/fonts/*.woff2` 与 `src/styles/fonts.css` 都是提交进仓库的，日常 build 不需要 Python。

## 部署（方案甲：Caddy 做门面，1Panel 只管这个站）

```
CF Tunnel ──► 127.0.0.1:5757 (Caddy，保持原样)
                ├── /releases/download/*  → 302 → Cloudflare R2
                ├── /update/*             → /srv/tpi-update/update/
                └── 其余（含 /）          → reverse_proxy 127.0.0.1:4477  ← 本站（1Panel 静态站）
```

### 0. 先确认现状

```bash
ssh myvps
sudo ss -ltnp | grep -E ':5757|:4477'     # 5757 应是 caddy 绑 127.0.0.1；4477 是 1Panel 静态站
sudo cat /etc/caddy/Caddyfile             # 确认末位是 handle { respond "not found" 404 }
```

### 1. 建站（1Panel）

网站 → 创建网站 → **静态网站**：
- 主域名 `tpi.wanshushan.top`，端口 **`4477`**，代号 **`tpi`**，其余默认（SSL / IPv6 / HTTPS 都不勾）
- 网站目录 = **`/opt/1panel/www/sites/tpi/index`**（1Panel v2 的布局；这个路径已挂进 OpenResty 容器）

### 2. 上传

本地：`npm run build && (cd dist && zip -qr ../dist.zip .)`

1Panel → 文件 → 进入上面那个「网站目录」→ 上传 `dist.zip` → 右键解压。
解压后该目录下应直接是 `index.html` / `favicon.svg` / `fonts/`。

### 3. 把它关回回环（重要）

1Panel 建站会生成 `listen 4477;`（= `0.0.0.0`）**并自动放行防火墙端口**。

- 站点 → **配置文件** → 把 `listen 4477;` 改成 `listen 127.0.0.1:4477;` → 保存
- 安全 → 防火墙 → **删掉 4477 的放行规则**
- 验证：`curl -sI http://127.0.0.1:4477/ | head -1` → 200；
  `sudo ss -ltnp | grep 4477` → 必须是 `127.0.0.1:4477`，不能是 `0.0.0.0:4477`

> ⚠️ **改完 `listen` 之后不要再在这个站的 UI 里改域名/端口** —— 1Panel 追加 `listen` 用的是端口字符串
> 全等比较（`Bind == "4477"`），认不出你手写的 `127.0.0.1:4477`，会再加一条导致 `nginx -t` 失败。
> 失败是**安全**的（1Panel 会自动回滚并报错，不会坏），但那个操作做不了。

### 4. 改 Caddy（**只动末位那一块**）

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)
sudo nano /etc/caddy/Caddyfile
```

把末位的

```caddyfile
	# ③ 其它一律 404（显式收口，避免路径穿越/误暴露）
	handle {
		respond "not found" 404
	}
```

换成

```caddyfile
	# ③ 其余交给简介页（1Panel 静态站，仅回环）
	handle {
		reverse_proxy 127.0.0.1:4477 {
			header_up Host {http.request.host}
		}
	}
```

> Caddy 的 `handle` 按路径具体度排序，`/releases/download/*` 与 `/update/*` 自动优先于兜底那一条，
> 所以在文件里写在前面还是后面都一样。**不要**借这次改站点地址或 `bind`。

### 5. 校验 + 重载 + 验证

```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

# 本地直连（两行都必须 200）
curl -sI http://127.0.0.1:5757/ | head -1
curl -sI -H 'Host: tpi.wanshushan.top' http://127.0.0.1:5757/ | head -1

# 分发链路没被动过（关键回归）
curl -s http://127.0.0.1:5757/update/latest.json | head -c 60
curl -sI http://127.0.0.1:5757/releases/download/v0.26.9/TutorPi-Setup-0.26.9.exe | head -1   # 302

# 公网
curl -sI https://tpi.wanshushan.top/ | head -3
```

版本号是 JS 取的，curl 拿不到——**用浏览器打开 https://tpi.wanshushan.top/ 看右下角**。

### 6. 回滚

```bash
sudo cp /etc/caddy/Caddyfile.bak-<日期> /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

1Panel 那个站可以留着不管。

### 不需要 CF purge

本次没动 `/update/*` 与 `/releases/*` 的任何响应，那 20 小时的 302 缓存与本改动无关。

### 以后更新页面

重新 `npm run build` → 覆盖那 6 个文件即可，**不需要再碰 Caddy**。

---

> **更简单的替代方案**（不要 1Panel 时）：让 Caddy 直接发文件，零新组件。
>
> 1. 本地 `npm run build`，把 `dist/` 传到 `/srv/tpi-site/`（`sudo chown -R caddy:caddy /srv/tpi-site`）
> 2. Caddy 末位改成：
>    ```caddyfile
>    	handle {
>    		root * /srv/tpi-site
>    		file_server
>    	}
>    ```
> 3. `sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy`
>
> 代价：没有 1Panel 的文件管理/日志界面。收益：少一个 Web 服务、少一个端口、少一层代理。
>
> 后续若要升级到「1Panel 做门面」（CF Tunnel 直接指 1Panel，再由 1Panel 反代到 Caddy），
> 那一步需要 CF purge —— 见交接文档的方案乙。
