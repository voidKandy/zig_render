#version 460

layout(location = 0) in vec2 texCoord;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D hudTex;

void main() {
    outColor = texture(hudTex, texCoord);
}
