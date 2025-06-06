#version 450

layout(location = 0) in vec2 tex_coord;

layout(location = 0) out vec4 out_color;

layout(binding = 0) uniform sampler2D tex_sampler;

#extension GL_EXT_debug_printf : enable

void main() {
    debugPrintfEXT("help me please11111111111111111111111[");
    out_color = vec4(1, 1, 1, 1) * texture(tex_sampler, tex_coord).r;
}
