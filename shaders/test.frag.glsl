

#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 texCoord;
layout(location = 1) flat in uint MaterialIndex;

layout(location = 0) out vec4 out_Color;

layout(set = 1, binding = 0) uniform sampler2D Textures[];

vec4 TextureBindless2D(uint MaterialIndex, vec2 uv)
{
     return texture(Textures[nonuniformEXT(MaterialIndex)], uv);
}


void main()
{
    out_Color = TextureBindless2D(MaterialIndex, texCoord);
    // out_Color = vec4(1,0,0,1);
}
