#version 460
#extension GL_EXT_debug_printf : enable

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint MaterialIndex;

layout(push_constant) uniform PushConstants {
    vec2 InverseWindowResolution;
    uint VertexOffset;
    uint IndexOffset;
};

struct Instance {
    uint p0;
    uint MaterialIndex;
    vec2 ScreenPosition;
};

layout(std430, set = 2, binding = 0) readonly buffer InstanceSSBO { Instance instances[]; } InstanceBuf;

void main() {
    Instance instance = InstanceBuf.instances[uint(gl_InstanceIndex)];
    texCoord = inUV;


    float aspect = InverseWindowResolution.y / InverseWindowResolution.x;
    vec2 local = inPosition;
    local.x /= aspect;

    vec2 screenPos = instance.ScreenPosition + local;

    vec2 ndc;
    ndc.x = screenPos.x * 2.0 - 1.0;
    ndc.y = -(screenPos.y * 2.0 - 1.0);

    gl_Position = vec4(ndc, 0.0, 1.0);

    MaterialIndex = instance.MaterialIndex;
}
