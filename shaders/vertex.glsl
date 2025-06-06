#version 450

layout(location = 0) out vec2 tex_coord;

const vec2 positions[6] = vec2[](
		vec2(-0.5, -0.5),
		vec2(0.5, -0.5),
		vec2(-0.5, 0.5),
		vec2(0.5, -0.5),
		vec2(0.5, 0.5),
		vec2(-0.5, 0.5)
);

const vec2 tex_coords[6] = vec2[](
		vec2(0, 0),
		vec2(0.5, 0),
		vec2(0, 0.5),
		vec2(0.5, 0),
		vec2(0.5, 0.5),
		vec2(0, 0.5)
);

#extension GL_EXT_debug_printf : enable

void main() {
    debugPrintfEXT("vertex index: %d", gl_VertexIndex);
    tex_coord = tex_coords[gl_VertexIndex];
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
