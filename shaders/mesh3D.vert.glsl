#version 460
#extension GL_EXT_debug_printf : enable
// run export DEBUG_PRINTF_TO_STDOUT=true to see
// unset DEBUG_PRINTF_TO_STDOUT to disable

struct VertexData {
    vec4 position;
    vec4 normal;
    vec4 color;
    vec2 uv;
    vec2 _;
};


struct Instance {
    uint p0;
    uint MaterialIndex;
    uint p1;
    uint p2;
    mat4 ModelTransform;
};

layout(push_constant) uniform PushConstants {
    uint VertexOffset;
    uint IndexOffset;
} pc;


layout (set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;

layout (std430, set = 3, binding = 0) readonly buffer Vertices { VertexData v[]; } in_Vertices;
layout (set = 3, binding = 1) readonly buffer Indices { int i[]; } in_Indices;

layout(std430, set = 4, binding = 0) readonly buffer InstanceSSBO { Instance instances[]; } InstanceBuf;

layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint MaterialIndex;

void main()
{

    Instance instance = InstanceBuf.instances[uint(gl_InstanceIndex)];
    MaterialIndex = instance.MaterialIndex;

    int Index = in_Indices.i[gl_VertexIndex];

    VertexData vtx = in_Vertices.v[Index + pc.VertexOffset];
    if (gl_VertexIndex == 0) {
        debugPrintfEXT(
            "instance=%u material=%u pos=(%f,%f,%f) w=%f\n",
            gl_InstanceIndex,
            MaterialIndex,
            instance.ModelTransform[3].x,
            instance.ModelTransform[3].y,
            instance.ModelTransform[3].z,
            instance.ModelTransform[3].w
        );
    }
    gl_Position = camera_Ubo.proj * camera_Ubo.view * instance.ModelTransform * vec4(vtx.position.xyz, 1.0);

    texCoord = vec2(vtx.uv.x, vtx.uv.y);
}
