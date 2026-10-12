/**
 * 首页背景岛（我们自己的薄壳，挂在 index.mdx 上的就是它）
 * ─────────────────────────────────────────────────────────
 * 它只有一个职责：把「组件」这两个字从 MDX 里递进 ShapeWaves。
 *
 * 为什么需要这一层：`client:only` 的岛，props 要序列化进 HTML ——
 * **函数/组件没法从 MDX 直接传进去**。所以 MDX 里 `text` 支持两种写法：
 *
 *   text="  TPi"                     纯文本（Path 和组件原本完全一样，行为不变）
 *   text={{ component: 'tutorPi' }}  “填入一个组件”：这里是名字，
 *                                    真身是 wordmarks.js 里的绘制函数，由本文件查表映射
 *   还可以带调参：text={{ component: 'tutorPi', stackX: 0.7, stackStep: 0.2 }}
 *
 * 换组件时用 key 重挂一次 —— 字模是在 canvas 上画的，重画比“改参数”可靠。
 */
import ShapeWaves from './ShapeWaves.jsx';
import { WORDMARKS } from './wordmarks.js';

export default function WaveBackground({ text = '', ...props }) {
	const spec = typeof text === 'object' && text !== null ? text : null;
	const name = spec?.component;
	const drawer = name ? WORDMARKS[name] : undefined;

	if (name && !drawer) {
		// 拼错名字不该让整个背景消失 —— 退回纯文本模式，并在控制台点名
		console.warn(
			`[WaveBackground] 没有名为 "${name}" 的字模，可用：${Object.keys(WORDMARKS).join(' / ')} —— 已退回文本模式`,
		);
	}

	// 其余键（除 component 外）当作字模的调参传进去
	const options = spec ? Object.fromEntries(Object.entries(spec).filter(([k]) => k !== 'component')) : undefined;

	return (
		<ShapeWaves
			key={name ?? 'text'}
			{...props}
			text={spec ? '' : String(text ?? '')}
			maskDrawer={drawer ? (ctx, info) => drawer(ctx, { ...info, options }) : undefined}
		/>
	);
}
