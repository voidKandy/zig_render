#version 460
#extension GL_EXT_debug_printf : enable

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint materialIndex;


/// maybe move to UBO?
layout(push_constant) uniform PushConstants {
    vec2 inverse_window_resolution;
};

struct MetaData {
    uint materialIndex;
    vec2 screenCoordinates;
};
layout(std430, set = 1, binding = 1) readonly buffer MetaSSBO { MetaData metas[]; } MetaBuf;

void main() {
    MetaData metaData = MetaBuf.metas[gl_InstanceIndex];
    materialIndex = metaData.materialIndex;
    texCoord = inUV;


    float aspect = inverse_window_resolution.y / inverse_window_resolution.x;
    vec2 local = inPosition;
    local.x /= aspect;

    vec2 screenPos = metaData.screenCoordinates + local;

    vec2 ndc;
    ndc.x = screenPos.x * 2.0 - 1.0;
    ndc.y = screenPos.y * 2.0 - 1.0;


    if (gl_VertexIndex == 0 && gl_InstanceIndex == 0) {
         debugPrintfEXT("inPosition: %f %f\n", inPosition.x, inPosition.y);
         debugPrintfEXT("screenCoordinates: %f %f\n", metaData.screenCoordinates.x, metaData.screenCoordinates.y);
         debugPrintfEXT("inverse_window_resolution: %f %f\n", inverse_window_resolution.x, inverse_window_resolution.y);
         debugPrintfEXT("aspect: %f\n", aspect);
         debugPrintfEXT("screenPos: %f %f\n", screenPos.x, screenPos.y);
         debugPrintfEXT("ndc: %f %f\n", ndc.x, ndc.y);
     }
    gl_Position = vec4(ndc, 0.0, 1.0);
}
