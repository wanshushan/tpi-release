/**
 * 镂空字模（mask wordmarks）
 * ─────────────────────────────────────────────────────────
 * ShapeWaves 原本只支持一行文本镂空：内部就是一次 `fillText(text)`。
 * 想要「T 里嵌一竖排 utor + Pi」这种拼字，单行文本画不出来，
 * 所以这里放一组**绘制函数**：拿到 mask 的 2D context，自己在上面画什么都可以。
 *
 * 用法（见 index.mdx）：`text={{ component: 'tutorPi' }}`
 *   —— 不填组件时 `text` 仍是普通字符串，走组件原本那套单行文本逻辑，行为不变。
 *
 * 绘制函数的签名：
 *   (ctx, { width, height, size, family, weight, options }) => void
 *     width/height : mask 画布尺寸（px），按它换算比例
 *     size         : 组件 textSize（字号占容器高度的比例）
 *     family/weight: 组件 fontFamily / fontWeight
 *     options      : 从 MDX 额外传进来的调参（可序列化），
 *                    如 text={{ component:'tutorPi', stackSize:0.38, stackX:0.83 }}
 *
 * 画法约定：底色已经填黑，**画白就是镂空**。别去动 ctx 的 fillStyle 之外的全局状态。
 */

/** 可调排字比例。改这几个数比改下面的布局代码安全。 */
const RATIO = {
	/**
	 * 竖排小字号（× 主字 em）。它同时决定两件事：
	 *   · 列的“宽”（= 小写字母高）→ 目标：跟 T 的半臂长（≈ 0.5 横梁 ≈ 137px）接近
	 *   · 列的长（“utor”整行宽度转 90°）→ 会给到 T 下方去，这是要的效果
	 * 与 TPi 同一个 family / weight（同一个 ctx.font 字符串），只是字号不同。
	 */
	stackSize: 0.38,
	/** 竖排列的水平位置：T 宽度内的比例（竖笔右缘在 0.65，凹口中线 ≈ 0.83） */
	stackX: 0.83,
	/** 竖排列的顶端：距 T 顶部多少（× 大写高）—— 0.28 就是刚好让过横梁 */
	stackTop: 0.28,
	/**
	 * 竖排方式：**整行水平旋转**的角度（度）。
	 *   90  = 顺时针，首字母在上，从上往下读（等于 CSS 的 writing-mode: vertical-rl）
	 *   -90 = 逆时针，首字母在下，从下往上读
	 * 不是把每个字母直立着一个个往下堆 —— 那样字母自己没转，不是竖排文字。
	 */
	stackRotate: 90,
	/** 竖排内容 */
	stack: 'utor',
};

/** 主字（大字母）—— 想换拼写就改这里，同时改 ID（在文件末尾的注册表里） */
const MAIN = 'TPi';

/**
 * TutorPi 字标：大写 T / P / i，把 utor 竖排嵌在 T 的内侧右下方。
 *
 * 关键：**大字的尺度与位置完全照抄组件原本的单行文本逻辑**
 * （同样的度量口径、同样的最大宽度回缩），所以和 `text="TPi"` 是同一套几何 ——
 * 我们只额外叠了一列小字，不会出现“换成组件后字忽大忽小”。
 */
export function drawTutorPi(ctx, { width, height, size, family, weight, options = {} }) {
	const r = { ...RATIO, ...options };
	ctx.textAlign = 'center';
	ctx.textBaseline = 'alphabetic';

	// ── 1. 主字：与组件 text 模式逐行等价 ──────────────────────
	let fontPx = Math.max(1, size * height);
	ctx.font = `${weight} ${fontPx}px ${family}`;
	const measured = ctx.measureText(MAIN).width;
	const maxWidth = width * 0.9;
	if (measured > maxWidth) {
		fontPx = Math.max(1, (fontPx * maxWidth) / measured);
		ctx.font = `${weight} ${fontPx}px ${family}`;
	}
	const metrics = ctx.measureText(MAIN);
	const x = (width + metrics.actualBoundingBoxLeft - metrics.actualBoundingBoxRight) / 2;
	const y = (height + metrics.actualBoundingBoxAscent - metrics.actualBoundingBoxDescent) / 2;

	ctx.fillStyle = '#fff';
	ctx.fillText(MAIN, x, y);

	// ── 2. 量出首字 T 的盒子（竖排要贴着它摆）──────────────────
	// 主串整体居中，且只有一次 fillText，所以 T 的左边就是“整串的左边”
	const advances = [...MAIN].map((ch) => ctx.measureText(ch).width);
	const totalAdvance = advances.reduce((a, b) => a + b, 0);
	const tBox = {
		left: x - totalAdvance / 2,
		width: advances[0],
		ascent: ctx.measureText(MAIN[0]).actualBoundingBoxAscent,
		descent: ctx.measureText(MAIN[0]).actualBoundingBoxDescent,
	};
	const tTop = y - tBox.ascent;

	// ── 3. 竖排 utor：与大字同为白色（也是镂空），摆在 T 竖笔的**外侧** ──
	// 即 T 与 P 之间那片场区（不是挖在 T 里，也不是压在竖笔上）。
	// 旋转方式：整行水平写一次、再整体旋转 90°（不是逐字堆叠）。
	ctx.fillStyle = '#fff';
	const stackEm = Math.max(1, fontPx * r.stackSize);
	ctx.font = `${weight} ${stackEm}px ${family}`;
	const stemRightX = tBox.left + tBox.width * r.stackX;
	const stackTopY = tTop + tBox.ascent * r.stackTop;
	const wordLength = ctx.measureText(r.stack).width;
	const clockwise = r.stackRotate >= 0;
	ctx.save();
	ctx.textAlign = 'left';
	ctx.textBaseline = 'middle'; // 列中线对齐：字的“高”就是列的宽
	// 逆时针时从列的底部起笔（旋转后 +x 朝上），顺时针时从顶部起笔（+x 朝下）
	ctx.translate(stemRightX, clockwise ? stackTopY : stackTopY + wordLength);
	ctx.rotate((r.stackRotate * Math.PI) / 180);
	ctx.fillText(r.stack, 0, 0);
	ctx.restore();
}

/** 注册表：MDX 里写 `text={{ component: '名字' }}` 时按这里的键查 */
export const WORDMARKS = {
	tutorPi: drawTutorPi,
};
