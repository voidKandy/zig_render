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


struct MetaData {
    uint MaterialIndex;
    uint IndexOffset;
    uint IndexCount;
    uint VertexOffset;
    mat4 ModelTransform;
};

layout (set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;

layout(std430, set = 1, binding = 1) readonly buffer MetaSSBO { MetaData metas[]; } MetaBuf;
layout (std430, set = 2, binding = 0) readonly buffer Vertices { VertexData v[]; } in_Vertices;
layout (set = 2, binding = 1) readonly buffer Indices { int i[]; } in_Indices;

layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint MaterialIndex;

void main()
{
    uint meshIdx = uint(gl_InstanceIndex);
    MetaData md = MetaBuf.metas[meshIdx];
    MaterialIndex = md.MaterialIndex;

    int Index = in_Indices.i[gl_VertexIndex];

    VertexData vtx = in_Vertices.v[Index + md.VertexOffset];
    if (gl_VertexIndex == 0) {
        debugPrintfEXT(
            "mesh=%u vert=%u idx=%u md(v=%u i=%u mat=%u) pos=(%f,%f,%f) uv=(%f,%f)\n",
            meshIdx,
            gl_VertexIndex,
            uint(Index),
            md.VertexOffset,
            md.IndexOffset,
            md.MaterialIndex,
            vtx.position.x,
            vtx.position.y,
            vtx.position.z,
            vtx.uv.x,
            vtx.uv.y
        );

    }

    gl_Position = camera_Ubo.proj * camera_Ubo.view * md.ModelTransform * vec4(vtx.position.xyz, 1.0);

    texCoord = vec2(vtx.uv.x, vtx.uv.y);
}
