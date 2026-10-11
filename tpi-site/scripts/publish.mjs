#!/usr/bin/env node
/**
 * 把 dist/ 同步到仓库里的 tpi-site-dist/，让服务器只 pull 不 build。
 *
 *   npm run publish      # = npm run build + 本脚本 + 打印后续 git 命令
 *
 * 为什么要有这个目录：服务器的 tpi-site-deploy 默认跑 pull 模式 ——
 * 它只做 `git pull` + `rsync`，不在服务器上执行仓库里的任何代码。
 * 代价是产物要进仓库（6 个文件、约 30KB）。
 */

import { cp, mkdir, readdir, rm, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST = path.join(ROOT, 'dist');
const OUT = path.resolve(ROOT, '..', 'tpi-site-dist');

if (!existsSync(path.join(DIST, 'index.html'))) {
	console.error('✗ dist/index.html 不存在 —— 先跑 npm run build');
	process.exit(1);
}

// 产物守卫：单页站是 6 个文件、几十 KB；数量或体积失控说明构建出了问题
const walk = async (dir) => {
	const out = [];
	for (const e of await readdir(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) out.push(...(await walk(p)));
		else out.push(p);
	}
	return out;
};

const files = await walk(DIST);
const bytes = (await Promise.all(files.map(async (f) => (await stat(f)).size))).reduce((a, b) => a + b, 0);
if (files.length > 64) {
	console.error(`✗ dist/ 里有 ${files.length} 个文件，明显不是本站产物 —— 拒绝发布`);
	process.exit(1);
}
if (bytes > 5 * 1024 * 1024) {
	console.error(`✗ dist/ 共 ${(bytes / 1024 / 1024).toFixed(1)} MB，明显不是本站产物 —— 拒绝发布`);
	process.exit(1);
}

await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });
await cp(DIST, OUT, { recursive: true });

console.log(`\n已同步 dist/ → ${path.relative(process.cwd(), OUT)}/`);
console.log(`  ${files.length} 个文件，共 ${(bytes / 1024).toFixed(1)} KB`);

// 顺带打一个 dist.zip，给「1Panel 文件管理器上传 + 解压」这条手动路径用。
// 注意：PowerShell 的 Compress-Archive 与 Linux 的 zip 都要保证压缩包根就是 index.html，
// 不能多套一层目录，否则解压到网站目录后会变成 /index/dist/index.html。
const ZIP = path.join(ROOT, 'dist.zip');
await rm(ZIP, { force: true });
try {
	if (process.platform === 'win32') {
		execFileSync(
			'powershell',
			['-NoProfile', '-Command', 'Compress-Archive -Path dist\\* -DestinationPath dist.zip -Force'],
			{ cwd: ROOT, stdio: 'pipe' },
		);
	} else {
		execFileSync('zip', ['-qr', ZIP, '.', '-x', '.*'], { cwd: DIST, stdio: 'pipe' });
	}
	console.log(`  dist.zip  ${((await stat(ZIP)).size / 1024).toFixed(1)} KB\n`);
} catch (e) {
	console.warn(`  打 dist.zip 失败（不影响部署）：${String(e.message).split('\n')[0]}\n`);
}

console.log('接下来：');
console.log('  git -C .. add -A && git -C .. commit -m "site: 更新简介页产物" && git -C .. push');
console.log('  ssh myvps "sudo systemctl start tpi-site-deploy"     # 想立刻生效');
console.log('  （装了定时器的话，最多 5 分钟自己会发）\n');
