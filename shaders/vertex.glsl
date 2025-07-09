#version 460

#extension GL_EXT_debug_printf : enable

struct Cell {
	uvec2 position;
	vec2 uv;
	uint width;
	uint height;
};

layout(set = 0, binding = 0) readonly buffer Cells {
	Cell cells[];
};

struct Transform {
	float scale_x;
	float translate_x;
	float scale_y;
	float translate_y;
};

layout(push_constant) uniform constants {
	Transform transform;
	float atlas_side;
};

layout(location = 0) out vec2 tex_coord;

void main() {
	const mat3 projection = mat3(
			transform.scale_x, 0, transform.translate_x,
			transform.scale_y, 0, transform.translate_y,
			0, 0, 1
			);

	const Cell cell = cells[gl_VertexIndex / 6];
	const uint bit = 1 << (gl_VertexIndex % 6);
	const uint width_factor = uint((bit & 0xe) != 0);
	const uint height_factor = uint((bit & 0x1c) != 0);
	const uvec2 offset = uvec2(width_factor * cell.width, height_factor * cell.height);

	tex_coord = cell.uv + vec2(offset) / atlas_side;
	const vec2 position = cell.position + offset;
	debugPrintfEXT("glp: %v2f, tex: %v2f", position, tex_coord);

	gl_Position = vec4(projection * vec3(position, 1), 1);
	gl_Position.z = 0;
}
