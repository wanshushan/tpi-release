# tpi-site

`https://tpi.wanshushan.top` 的前台单页 —— **一句口号 + 当前版本号**。

同一个域名下同时跑着更新分发服务（`/update/*` 元数据、`/releases/download/*` 字节），
所以这个站必须与它**同源**：页面直接从 `/update/latest.json` 读版本号，
不用另建接口、不引入任何外部依赖。

- 风格：包豪斯（几何构造 + 三原色 + 纯白 + 无衬线黑体）
- 技术：Astro 静态输出。正文零运行时依赖、零外部请求；只有背景那一个客户端岛（React + WebGPU）要跑 JS
- 产物：`dist/` 共 8 个文件、约 413 KB（HTML 内联 CSS，字体子集化；413KB 里约 365KB 是背景那个岛）

**首页内容全部在 `src/content/index/index.mdx`** —— 改文案只改那一个文件，不用碰 Astro 语法。

## 命令

```bash
npm install
npm run dev        # http://localhost:4321
npm run build      # → dist/
npm run preview    # 预览 dist/
npm run fonts      # 改了页面文案之后必须重跑（见下）
npm run publish    # build + 同步到 ../tpi-site-dist + 打 dist.zip（发布走这条）
```

## 改内容（首页 = 一个 MDX 文件）

```
src/content/index/index.mdx      ← 只改这里
src/components/                  版面组件（一般不用动）
  ├ islands/ShapeWaves.jsx       背景那个客户端岛（React Bits 原件，别改）
  ├ islands/WaveBackground.jsx   岛壳：把名字映射成字模函数
  └ islands/wordmarks.js         镂空画什么（改字标就改这里）
src/pages/index.astro            壳：<head> 元信息 + 把 MDX 渲染进 <body>
```

`index.mdx` 的 frontmatter 管 `<head>` 的两个字段（`title` / `description`，少了会构建失败 ——
schema 在 `src/content.config.ts`），正文就是整张海报的版面：

```mdx
<Poster>                                    ← 版面外壳（顶栏 + 主区两层网格）
	<VersionRail brand="tutor_π" />            ← 顶栏：品牌名 + 版本号
	<div class="bg"><ShapeWaves … /></div>   ← 背景：WebGPU 点阵波场（绝对定位，不吃网格行）
	<Stage>                                   ← 主区：吃掉剩余高度的那一大块
		<Slogan lines={['辩论求真', '因材施教']} /> ← 口号，一行一条，几行都行
		<Mark />                                ← 三角闭环标记
		可以接着写 Markdown / 其它组件
	</Stage>
</Poster>
```

所以「改口号 / 改品牌名 / 加一段说明文字」都只是编辑 `index.mdx`；
不靠文档也能看懂 —— 组件的职责与约束都写在组件文件顶部的注释里。

> 📝 **一次完整发布**：改 `index.mdx` → `npm run fonts`（新增汉字必须跑）→ `npm run publish` →
> `git add -A && git commit && git push`。服务器最多 5 分钟自己上线。

## 背景：ShapeWaves（WebGPU 点阵波场）

整页背景是 [React Bits](https://reactbits.dev) 的 `ShapeWaves`：一片几何原语（三角 / 圆 / 方）
按噪声波场组成点阵，鼠标划过会溅起涟漪、图形轮转、并向品牌蓝过渡。选它是因为
"几何原语拼成的网格"本来就在包豪斯语言里，而不是贴上去的装饰。

- 组件：`src/components/islands/ShapeWaves.jsx` + `.css`（上游原件，相对上游只动两处：删掉 `'use client'`、加一个可选 `maskDrawer` 扩展点）
- 岛壳：`src/components/islands/WaveBackground.jsx`（我们的）—— 它把 MDX 里那个**名字**映射成真正的字模函数
- 字模：`src/components/islands/wordmarks.js`（我们的）—— 镂空画什么，就写在这里
- 调用：`src/content/index/index.mdx` 里的 `<WaveBackground client:only="react" … />`
- `client:only` 是必须的 —— 组件一跑就在摸 `navigator.gpu`，放到构建期会直接报错

### 镂空的字有两种写法

```mdx
text="  TPi"                        纯文本：组件原本的单行文本镂空，行为一字不变
text={{ component: 'tutorPi' }}      “填入组件”：查 wordmarks.js 里的绘制函数
text={{ component: 'tutorPi', stackSize: 0.38, stackX: 0.83 }}   ← 还能带调参
```

为什么这里传的是**名字**而不是组件本身：`client:only` 的岛，props 要序列化进 HTML，
函数/组件传不进去。所以中间多一层 `WaveBackground`，由它在岛内部把名字查表变成函数。
名字拼错不会让背景消失 —— 退回文本模式，并在控制台点名可用名字。

当前的字模 `tutorPi`：大字 `TPi` **与文本模式逐行等价**（同一套度量口径、同一套超宽回缩），
再把 `utor` **整行水平写一次、整体旋转 90°**（顺时针，首字母在上）摆在 T 竖笔右侧的凹口里。
不是逐字堆叠 —— 那样字母是直立的，不是竖排文字。

| 旋钮 | 含义 | 当前值 |
|---|---|---|
| `stackSize` | 竖排字号（× 主字 em）→ 决定小写字母高 | 0.38（≈ T 半臂长） |
| `stackX` | 竖排列在 T 宽度内的位置 | 0.83（竖笔右缘 ≈ 0.65） |
| `stackTop` | 列顶端距 T 顶部（× 大写高） | 0.28（刚好让过横梁） |
| `stackRotate` | 整行旋转角度（度） | 90 = 顺时针、首字母在上 |

想要新的字模：在 `wordmarks.js` 里写个 `(ctx, { width, height, size, family, weight, options }) => void`
（白 = 镂空），加进 `WORDMARKS` 表，MDX 里写它的名字就行。

> ⚠️ **`fontWeight` 写 400/500 目前无效**（实测三种字重下 T 竖笔都是 82px）：站内 Jost 只切了
> 700/900 两档，CSS 字体匹配会把 400 解析到 700。要真能调细，得给 `build-fonts.mjs`
> 加一个 Jost 400/500 源字体（每个约 +3.5KB）—— 竖笔变窄后，竖排还能再放大一档。

> ⚠️ **镂空细节要过点阵量化**：着色器是按格中心采样 mask（一格全有或全无），
> 所以 1 格宽的笔画会被切成点。调小字时请用 `cellSize` 反推：竖排笔画建议 ≥ 2 格宽。

### 三个必须知道的约束

1. **vgpu 必须锁 0.4.x**（`package.json` 写的是 `^0.4.1`）。vgpu 0.5.0 给 `device.createTexture`
   加了强制校验：必须显式传 `kind`，而且明确**拒绝**旧的 `dimension`。组件里的 `createMaskTexture`
   只传了 `size/format/usage/label` → 上 0.5.0 会在第一张纹理就报
   `ValidationError: Texture kind must be explicit`。
2. **失败是静默的**。任何 WebGPU 错误都走组件的 `onError` → canvas 保持 `opacity:0`，
   页面只剩白底（就是没有背景的样子）。所以「背景不见了」先去控制台看
   `powerPreference` 之类的警告和 `ValidationError`，再对照上面那条锁版本。
3. **它很贵，而且不会自己停**。成本 = `画布像素数 × 帧率` 的全屏逐像素 FBM 噪声；
   只要 `speed > 0`，rAF 就不会停（组件只在标签页隐藏、`prefers-reduced-motion: reduce` 时自己停）。

### 为什么 reactbits 上“没那么卡”（实测数）

拿本机 headless Chrome 量过两边：

| | 画布缓冲 | 像素数 | 每帧 passes |
|---|---|---|---|
| reactbits.dev 的组件预览框 | 892 × 598 | **0.53 M** | 4（`glow=0.35`：scene→target + 2 次 blur + composite） |
| 本页背景（1080p 整屏） | 1920 × 1080 | **2.07 M** | 1（我们 `glow={0}`） |
| 本页背景（2560×1440） | 2560 × 1440 | **3.69 M** | 1 |

也就是说：**他们那边是一个预览小框，我们这边是整屏出血**（3.9× / 6.9× 的像素）。
组件本身没有任何“我们应该更省”的地方 —— 反而我们已经比他省：同一个跑分环境里
我们 1418×802 / 149 fps，他们 892×598 / 109 fps，换算成“每秒像素×passes”两边同量级，
而我们是靠关掉 `glow` 抵掉的那 2.25× 像素。

（他们的**首页**同样是整屏出血，所以那里的开销和我们一样 —— 你看到的差距来自**预览框**。）

### 真要降开销，只有四个杆杆

| 杆杆 | 效果 | 代价 |
|---|---|---|
| `paused={true}` | 闲置时 GPU 占用**归零**（只在鼠标划过时渲染） | 波场不再自己演化 |
| 降渲染分辨率 | 像素数按平方降 | 点阵变软；组件里 `MAX_DPR` 写死 2，要额外改组件或外套一层 scale |
| 缩小场地 | 按面积线性降 | 不再整屏出血 |
| `glow={0}` | **已经做了**，省 3 趟渲染 | 无（这组蓝色本来就几乎不产生光晕） |
| `interactive={false}` | 省掉鼠标移动时的全网格波动模拟 + 每帧上传 charges 缓冲 | 没涟漪 |

> 降分辨率那个“不碰组件”的做法：`.bg` 做成 `width:50%; height:50%; transform: scale(2);
> transform-origin: 0 0`，同时把 `cellSize` 减半 —— 像素数减到 1/4、观感基本一致（边缘略软）。
> 但它把“1 CSS px 对应多少设备像素”这件事藏起来了，改参数时很容易忘，慎用。

### 怎么调 / 怎么关

参数全在 `index.mdx`（改动只需 `npm run publish`；**改了 `text` 必须重跑 `npm run fonts`**，见下）。
当前就是 reactbits 官方 demo 那一套，只动了两处：

```
color="#5b95f3" / hoverColor="#5b96f7" / backgroundColor="#ffffff"   ← 官方 demo 的蓝 + 白底
text={{ component: 'tutorPi' }}       ← 镂空画什么：见上文“镂空的字有两种写法”
cellSize={10} / dotSize={0.75} / scale={1} / contrast={1}
brightness={0.4} / fade={0.25} / speed={1} / shapes="mixed"
glow={0}                          ← 唯一的功能改动：省 3 趟渲染，视觉上无差别
fontFamily/fontWeight=Jost        ← 唯一的外观改动：镂空用站内字体（跟着页脚 tutor_π 同族）
```

| 想要的效果 | 改哪个 |
|---|---|
| 不要镂空字 | `text=""` |
| 让镂空当主角（标题退成屏读） | `<Slogan lines={[...]} visuallyHidden />` —— h1 变成 `sr-only`，屏读/SEO 还在，画面上就只剩镂空的 TPi |
| 镂空别的字 | 回到文本模式：`text="…"`，然后**必须重跑 `npm run fonts`**（新字的字形要进子集） |
| 改字模的比例 | 在 MDX 参数里覆盖旋钮，如 `text={{ component:'tutorPi', stackSize: 0.45 }}` |
| 静止场 + 鼠标涟漪（省电） | `paused={true}` |
| 场更温 / 更淡 | `color` 换浅灰（如 `#c9c2b2`）、`dotSize` 降到 0.5 |
| 不要背景 | 删掉 `index.mdx` 里那个 `<div class="bg">…</div>` 整块 |

> 底色是**纯白**：`src/styles/global.css` 的 `--paper`（同时作为 `theme-color` 与组件的
> `backgroundColor`）—— 三处要一起改，组件不读 CSS 变量，它自己往 canvas 上画底色。
> 镂空字的**尺度取决于格大小**：拉丁大写字母（TPi）在 10px 格下很清晰；
> 八个汉字挤成一行时每字只有 ~14 格，笔画比格子还细 → 镂空出来是一团糊，**别这么用**。

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

**版式**：口号是两行四字（`src/content/index/index.mdx` 里 `<Slogan lines={[...]} />` 的数组），
尺度**故意压到标题级**（`min(9vw, 12.5vh)`，约占宽度 1/3）并靠下贴住版面底边 —— 因为画面的主视觉
是背景里镂空的 `TPi`，口号不能再撞满整屏（旧版是 `min(21vw, 31vh)` 的 24rem 巨字）。
改那两个数之前，先看一眼 1440×900 与 390×844 两个尺寸。

**几何标记**：不是装饰性图形，是产品的核心机制 —— 三角闭环「生成 → 交叉质疑 → 裁决」，
三个节点用三原色区分，一段蓝色高亮沿闭环循环。

**构图规则**：标记现在是**显式摆放**的 —— 它是 `<Poster>` 的直系子元素，
`place` 的四个角/居中相对整页，再叠 `offset` 微调（当前：右下角，`offset="5vw 17vh"`）。
`size` / `rotate` 同理可调。

> CSS 里那条「宽扁屏（≥16:9）时自动挂到主区右上」的规则**只对 `place="inline"` 生效** ——
> 把标记放回 `<Stage>` 里并去掉 `place`，就回到旧构图。

**版本号**：客户端 `fetch('/update/latest.json')` →
`artifacts['desktop-nsis'].mirrors[0]` 即下载地址。
拿不到就退到 GitHub 发布页并把版本号置灰（`data-state="na"`），**不显示假版本号**。

**背景**：`ShapeWaves` 点阵波场，绝对定位铺满版面，压在 `.stage` / `.rail` 之下
（见 `src/styles/poster.css` 里 `.bg` 那段注释 —— 不给 `.rail` 抬 `z-index` 就会被
不透明的 canvas 盖掉）。详见上文“背景”一节。

## 字体

不引 Google Fonts（中国大陆可达性不稳，且 Noto Sans SC 整族 101 个分片、数 MB）。
做法是 `scripts/build-fonts.mjs` 下载一次源字体（缓存在 `.fontsrc/`），
用 fontTools 按**页面实际用到的字符**切出单个 woff2：

| 文件 | 用途 | 体积 |
|---|---|---|
| `notosanssc-900.woff2` | 汉字（口号、品牌名、`sr-only` 文案）| ~20 KB |
| `jost-700.woff2` / `jost-900.woff2` | 拉丁字母与数字：700 给**镂空的 `TPi` / `utor`**，900 给页脚 `tutor_π` 与版本号 | ~4 KB ×2 |

扫描规则（`visibleText()`，改之前先读那段注释）：

- 扫 `src/**/*.astro` 与 `src/**/*.mdx` 两类文件；
- **HTML 标签整体丢掉**（`class="poster"` / `viewBox` / `d="M56 12…"` 都不是给人看的字），
  但 **JSX/组件标签保留** —— 文案往往写在 props 里，比如 `<Slogan lines={['…']} />`；
- `.mdx` 的 frontmatter **要扫**（`title` / `description` 会渲染进 `<head>`），
  但里面的 `#` 注释不扫；
- `<style>` / `<script>` / `import` / 各类注释一律不扫；
- `.jsx` 也不扫，但**不影响镂空字**：`text="  TPi"` 或 `text={{ component: 'tutorPi' }}`
  里的字串都写在 `index.mdx` 的 props 里，属于“字符串字面量”会被收进子集 ——
  所以**改了 text 或改了字模里的字（如 `RATIO.stack`）都必须重跑 `npm run fonts`**，
  否则镂空出来的字会掉到系统字体、笔画粗细和页脚对不上。

> 这个脚本以前只扫 `.astro`、并且把 frontmatter 整块删掉 —— 结果就是口号那 8 个汉字
> （`SLOGAN` 常量正好写在 frontmatter 里）从未进入子集，线上一直是用系统字体兜底渲染的。
> 现在既扫 `.mdx`、也只把真正不显示的整块剔掉。

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

重新 `npm run build` → 覆盖那几个文件即可，**不需要再碰 Caddy**。

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
