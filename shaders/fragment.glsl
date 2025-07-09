#version 450

layout(location = 0) in vec2 tex_coord;

layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 1) uniform sampler2D tex_sampler;

#extension GL_EXT_debug_printf : enable

void main() {
    out_color = texture(tex_sampler, tex_coord);
    out_color.a = 1;
}
