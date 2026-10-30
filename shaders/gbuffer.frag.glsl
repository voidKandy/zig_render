#version 450
#extension GL_EXT_nonuniform_qualifier : require


layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
layout(location = 3) in vec4 inVertexColor;
layout(location = 4) flat in uint inMaterialIndex;

layout (location = 0) out vec4 outPosition;
layout (location = 1) out vec4 outNormal;
layout (location = 2) out vec4 outAlbedo;

layout(set = 3, binding = 0) uniform sampler TextureSampler;
layout(set = 4, binding = 0) uniform texture2D Textures[];

vec4 sampleAlbedo(uint materialIndex, vec2 uv) {
    return texture(
        sampler2D(Textures[nonuniformEXT(materialIndex)], TextureSampler),
        uv
    );
}

void main() 
{
	outAlbedo = sampleAlbedo(inMaterialIndex, inUV) * inVertexColor;
    outPosition = vec4(inWorldPos, gl_FragCoord.z);
    outNormal = vec4(normalize(inNormal), 1.0);
}
