import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

/**
 * 首页内容集合。
 *
 * 首页 = `src/content/index/index.mdx` 一个文件：frontmatter 管 <head> 里的元信息，
 * 正文就是整张海报的版面（用 src/components/ 里的组件拼）。
 * schema 在这里做**构建期校验** —— 少写一个字段会直接构建失败并指出是哪一行，
 * 而不是发一个标题空白的页面出去。
 */
const index = defineCollection({
	loader: glob({ pattern: '*.mdx', base: './src/content/index' }),
	schema: z.object({
		/** 浏览器标签页标题 / 搜索结果的标题 */
		title: z.string(),
		/** <meta name="description">，同时是分享卡片摘要 */
		description: z.string(),
	}),
});

export const collections = { index };
