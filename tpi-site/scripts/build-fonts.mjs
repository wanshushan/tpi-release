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
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CACHE = path.join(ROOT, '.fontsrc');
const OUT_DIR = path.join(ROOT, 'public', 'fonts');
const OUT_CSS = path.join(ROOT, 'src', 'styles', 'fonts.css');

/** 参与字符扫描的目录：`.astro` 里去掉标签后剩下的就是页面文案 */
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
// frontmatter、<style>/<script>、注释（含 CSS 注释）里的中文不会显示在页面上，
// 扫进去只会让字子集无谓变大。
function visibleText(source) {
	return source
		.replace(/^---[\s\S]*?\n---/, '') // frontmatter
		.replace(/<script[\s\S]*?<\/script>/gi, '')
		.replace(/<style[\s\S]*?<\/style>/gi, '')
		.replace(/\/\*[\s\S]*?\*\//g, '')
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/<[^>]+>/g, ''); // 只剩文本节点
}

async function collectText() {
	const chars = new Set(EXTRAS);
	for (const rel of TEXT_DIRS) {
		const abs = path.join(ROOT, rel);
		if (!existsSync(abs)) continue;
		// 只要 .astro：样式表里的中文是注释、组件里的中文是代码，都不会显示在页面上
		const files = (await readdir(abs, { recursive: true })).filter((f) => f.endsWith('.astro'));
		for (const f of files) {
			for (const ch of visibleText(await readFile(path.join(abs, f), 'utf8'))) chars.add(ch);
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

main().catch((err) => {
	console.error(`\n字体子集化失败：${err.message}`);
	process.exit(1);
});
