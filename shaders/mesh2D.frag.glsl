#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 texCoord;
layout(location = 1) flat in uint MaterialIndex;

layout(location = 0) out vec4 outColor;

layout(set = 1, binding = 0) uniform sampler TextureSampler;
layout(set = 2, binding = 0) uniform texture2D Textures[];

void main() {
     outColor = texture(sampler2D(Textures[nonuniformEXT(MaterialIndex)], TextureSampler), texCoord);
}
