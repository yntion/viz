void main() {
	// 0 -> vec2(0.5, 0.5)
	// 1 -> vec2(0, -0.5)
	// 3 -> vec2(-0.5, 0.5)
	const float x = (1 - gl_VertexIndex) * 0.5; // 0, 1, 2
	const float y = (1 - (gl_VertexIndex & 0x1) * 2) * 0.5;

	gl_Position = vec4(x, y, 0, 1);
}
