
#version 460

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint materialIndex;

struct MetaData {
    uint materialIndex;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};
layout(std430, set = 0, binding = 1) readonly buffer MetaSSBO { MetaData metas[]; } MetaBuf;

void main() {
    materialIndex = MetaBuf.metas[gl_InstanceIndex].materialIndex;
    texCoord = inUV;
    gl_Position = vec4(inPosition, 0.0, 1.0);
}
