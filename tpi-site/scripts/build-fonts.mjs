#!/usr/bin/env node
/**
 * 字体本地化（子集化）
 * ─────────────────────────────────────────────────────────
 * 这是个「一屏海报」页，全部文案只有十来个汉字。直接引 Google Fonts 有两个问题：
 * ① 中国大陆可达性不稳；② Noto Sans SC 整族 101 个分片、全量数 MB。
 *
 * 做法：下载一次完整字重的源字体（缓存到 .fontsrc/），用 fontTools 按**页面实际
 * 用到的字符**切出单个 woff2 —— 通常 10KB 上下，零外部依赖、一次请求。
 *
 *   用法：npm run fonts            （改了页面文案之后重跑）
 *         npm run fonts -- --refresh   （强制重新下载源字体）
 *
 * 依赖：Python 3 + fonttools（`pip install fonttools brotli`）。
 * 只在改文案时才需要；平时 build 直接用仓库里已生成的 public/fonts/*.woff2。
 */

import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CACHE = path.join(ROOT, '.fontsrc');
const OUT_DIR = path.join(ROOT, 'public', 'fonts');
const OUT_CSS = path.join(ROOT, 'src', 'styles', 'fonts.css');

/** 参与字符扫描的目录：`.astro` 是版面与组件，`.mdx` 是页面内容 */
const TEXT_DIRS = ['src'];

/** 固定补进来的字符：动态文本、符号、数字 */
const EXTRAS = ['0123456789', 'vV·。，,.—–-+×/%()[]', '下载最新版本', 'tutorπ_'].join('');

/** 源字体：只在这里写一次，之后都从 .fontsrc/ 缓存里取 */
const SOURCE_FONTS = {
	'NotoSansSC-Black.otf':
		'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Black.otf',
	'Jost-Bold.ttf':
		'https://fonts.gstatic.com/s/jost/v20/92zPtBhPNqw79Ij1E865zBUv7mxEIgVG.ttf',
	'Jost-Black.ttf':
		'https://fonts.gstatic.com/s/jost/v20/92zPtBhPNqw79Ij1E865zBUv7mwKIgVG.ttf',
};

/** 要产出哪些子集 */
const SUBSETS = [
	{ src: 'NotoSansSC-Black.otf', out: 'notosanssc-900.woff2', family: 'Noto Sans SC', weight: 900 },
	{ src: 'Jost-Bold.ttf', out: 'jost-700.woff2', family: 'Jost', weight: 700 },
	{ src: 'Jost-Black.ttf', out: 'jost-900.woff2', family: 'Jost', weight: 900 },
];

// ── 1. 收集「渲染出来的文案」里的码点 ─────────────────────────
// 两条来源缺一不可：
// ① 字符串字面量 —— `brand="tutor_π"`、`lines={['辩论求真', '因材施教']}` 这类写在
//    组件参数里的文案藏在标签内部，光把标签删掉是拿不到的；
// ② 去标签后剩下的文本节点 —— .mdx 的 frontmatter（title / description 会渲染进
//    <head>）与正文里的 Markdown 文字。
// 注释、<style>/<script>、import/export 里的中文不会显示在页面上，先去掉。
// 取向是**宁多勿少**：多收几个字符只是子集大几百字节，漏一个就是一个字掉到系统字体。
function visibleText(source, { astro = false } = {}) {
	// frontmatter：.astro 的是纯代码，一个字都不会显示（里面的文案由上一步的字面量
	// 收集拿走）；.mdx 的会被渲染进 <head>（title / description），要留 —— 但 YAML
	// 的 `#` 注释不会显示，先剔掉。
	let s = source.replace(/^(\s*)---\r?\n([\s\S]*?)\r?\n---[^\n]*\n/, (_, _lead, body) =>
		astro ? '' : `${body.replace(/^\s*#.*$/gm, '')}\n`,
	);

	s = s
		.replace(/^\s*(import|export)\b[^\n]*$/gm, '')
		.replace(/<script[\s\S]*?<\/script>/gi, '')
		.replace(/<style[\s\S]*?<\/style>/gi, '')
		// HTML 标签整体删掉：里面的 class="poster" / viewBox="0 0 112 100" /
		// d="M56 12 L100 82 Z" 都一个字不会显示。
		// JSX/组件标签（首字母大写）留着 —— 文案往往写在 props 里，
		// 比如 <Slogan lines={['辩论求真', …]} />。
		.replace(/<\/?[a-z][^>]*>/g, ' ')
		// 注释必须在抠字面量**之前**去：注释里常常有 `color="#0d0d0d"`
		// 这类示例，它一个字都不会显示，却会被字面量那一步收进子集。
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/\{\/\*[\s\S]*?\*\/\}/g, '') // MDX 注释 {/* … */}
		.replace(/\/\*[\s\S]*?\*\//g, '');

	const literals = [];
	s = s.replace(/(['"])(?:\\.|(?!\1)[^\\])*\1/g, (m) => {
		literals.push(m.slice(1, -1));
		return ' ';
	});

	// 剩下的就是文本节点
	return literals.join('') + s.replace(/<[^>]*>/g, ' ');
}

async function collectText() {
	const chars = new Set(EXTRAS);
	for (const rel of TEXT_DIRS) {
		const abs = path.join(ROOT, rel);
		if (!existsSync(abs)) continue;
		const files = (await readdir(abs, { recursive: true })).filter(
			(f) => f.endsWith('.astro') || f.endsWith('.mdx'),
		);
		for (const f of files) {
			const source = await readFile(path.join(abs, f), 'utf8');
			for (const ch of visibleText(source, { astro: f.endsWith('.astro') })) chars.add(ch);
		}
	}
	return [...chars].filter((c) => c.codePointAt(0) > 31).join('');
}

// ── 2. 找可用的 Python + fontTools ──────────────────────────
async function resolvePython() {
	const candidates = [process.env.PYTHON, 'python', 'python3', 'py'].filter(Boolean);
	for (const bin of candidates) {
		try {
			await run(bin, ['-c', 'import fontTools, brotli'], { timeout: 30_000 });
			return bin;
		} catch {
			/* 试下一个 */
		}
	}
	throw new Error(
		'找不到带 fontTools 的 Python。请先 `pip install fonttools brotli`，或用 PYTHON=<可执行文件> 指定。',
	);
}

// ── 3. 准备源字体（一次性缓存） ─────────────────────────────
async function ensureSourceFonts(refresh) {
	if (refresh) await rm(CACHE, { recursive: true, force: true });
	await mkdir(CACHE, { recursive: true });

	for (const [file, url] of Object.entries(SOURCE_FONTS)) {
		const dest = path.join(CACHE, file);
		if (!refresh && existsSync(dest)) continue;
		process.stdout.write(`  下载 ${file} … `);
		const res = await fetch(url);
		if (!res.ok) throw new Error(`${file} → HTTP ${res.status}`);
		await writeFile(dest, Buffer.from(await res.arrayBuffer()));
		process.stdout.write('ok\n');
	}
}

// ── 4. 子集化 ──────────────────────────────────────────────
async function subsetAll(python, text) {
	await mkdir(OUT_DIR, { recursive: true });
	for (const s of SUBSETS) {
		const dest = path.join(OUT_DIR, s.out);
		await run(python, [
			'-m',
			'fontTools.subset',
			path.join(CACHE, s.src),
			`--text=${text}`,
			'--flavor=woff2',
			`--output-file=${dest}`,
			'--layout-features=*',
			'--no-hinting',
			'--desubroutinize',
			'--name-IDs=*',
		]);
		const { size } = await import('node:fs').then((fs) => fs.statSync(dest));
		console.log(`  ${s.out.padEnd(24)} ${(size / 1024).toFixed(1)} KB`);
	}
}

function renderCss(entries) {
	return (
		'/* 由 scripts/build-fonts.mjs 生成 —— 请勿手改；改文案后重跑 `npm run fonts` */\n\n' +
		entries
			.map(
				(e) => `@font-face {
	font-family: '${e.family}';
	font-style: normal;
	font-weight: ${e.weight};
	font-display: swap;
	src: url('/fonts/${e.out}') format('woff2');
}
`,
			)
			.join('\n')
	);
}

// ── main ──────────────────────────────────────────────────
async function main() {
	const refresh = process.argv.includes('--refresh');

	const text = await collectText();
	console.log(`页面实际用到 ${[...text].length} 个字符`);

	const python = await resolvePython();
	await ensureSourceFonts(refresh);
	await subsetAll(python, text);
	await rm(OUT_CSS, { force: true });
	await writeFile(OUT_CSS, renderCss(SUBSETS), 'utf8');

	console.log(`\n写入 ${path.relative(ROOT, OUT_CSS)}`);
}

export { collectText, visibleText };

// 直接 `node scripts/build-fonts.mjs` 才跑；被 import 时可单独拿两个函数做调试
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	main().catch((err) => {
		console.error(`\n字体子集化失败：${err.message}`);
		process.exit(1);
	});
}
