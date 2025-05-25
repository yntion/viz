#version 450

layout(location = 0) out vec4 out_color;

#extension GL_EXT_debug_printf : enable

void main() {
    vec4 color = vec4(1.0, 0.0, 0.0, 0.0); 
    debugPrintfEXT("help me please11111111111111111111111[");
    out_color = color;
}
