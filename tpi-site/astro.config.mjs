// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import react from '@astrojs/react';

/**
 * 更新分发服务的地址。页面里的版本号与下载地址都来自它的 `/update/latest.json`，
 * 生产环境是同源（Caddy 在同一个域名下提供 /update/* 与 /releases/*），
 * 所以运行时的 fetch 永远不会跨域。
 *
 * 但本地 dev / preview 服务器上没有这两个路径，会 404 → 页面退回兜底态（v—）。
 * 下面把这两个前缀反向代理到生产，本地就能看到真实版本号。
 * 代理在 dev server 侧发出，浏览器仍是同源请求 —— 依然不涉及 CORS。
 */
const UPDATE_ORIGIN = 'https://tpi.wanshushan.top';
const proxy = {
	'/update': { target: UPDATE_ORIGIN, changeOrigin: true },
	'/releases': { target: UPDATE_ORIGIN, changeOrigin: true },
};

// https://astro.build/config
export default defineConfig({
	site: UPDATE_ORIGIN,
	// 首页内容由 src/content/index/index.mdx 渲染（见 content.config.ts）
	// react 只为背景那一个客户端岛（components/islands/ShapeWaves.jsx）而存在
	integrations: [mdx(), react()],
	// 单页海报，CSS 很小：直接内联，省一次往返
	build: { inlineStylesheets: 'always' },
	vite: {
		server: { proxy },
		preview: { proxy },
	},
});
