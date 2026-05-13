#version 460
#extension GL_EXT_debug_printf : enable

struct VertexData {
    vec4 position;
    vec4 normal;
    vec4 color;
    vec2 uv;
    vec2 _;
};

layout (std430, set = 0, binding = 0) readonly buffer Vertices { VertexData v[]; } in_Vertices;
layout (set = 0, binding = 1) readonly buffer Indices { int i[]; } in_Indices;
layout (set = 0, binding = 2) readonly uniform CameraData {
    mat4 model;
    mat4 view;
    mat4 proj;
} camera_Ubo;

struct MetaData {
    uint MaterialIndex;
    uint IndexOffset;
    uint IndexCount;
    uint VertexOffset;
};
layout(std430, set = 1, binding = 1) readonly buffer MetaSSBO { MetaData metas[]; } MetaBuf;
layout(location = 0) out vec2 texCoord;
layout(location = 1) flat out uint MaterialIndex;

void main()
{

    uint meshIdx = uint(gl_InstanceIndex);

    MetaData md = MetaBuf.metas[meshIdx];

    MaterialIndex = md.MaterialIndex;

    int Index = in_Indices.i[gl_VertexIndex];

    VertexData vtx = in_Vertices.v[Index];
    if (gl_VertexIndex == 0) {
        debugPrintfEXT("model[0]=(%f,%f,%f,%f)\n", camera_Ubo.model[0].x, camera_Ubo.model[0].y, camera_Ubo.model[0].z, camera_Ubo.model[0].w);
        debugPrintfEXT("model[1]=(%f,%f,%f,%f)\n", camera_Ubo.model[1].x, camera_Ubo.model[1].y, camera_Ubo.model[1].z, camera_Ubo.model[1].w);
        debugPrintfEXT("model[2]=(%f,%f,%f,%f)\n", camera_Ubo.model[2].x, camera_Ubo.model[2].y, camera_Ubo.model[2].z, camera_Ubo.model[2].w);
        debugPrintfEXT("model[3]=(%f,%f,%f,%f)\n", camera_Ubo.model[3].x, camera_Ubo.model[3].y, camera_Ubo.model[3].z, camera_Ubo.model[3].w);
        debugPrintfEXT("view[0]=(%f,%f,%f,%f)\n", camera_Ubo.view[0].x, camera_Ubo.view[0].y, camera_Ubo.view[0].z, camera_Ubo.view[0].w);
        debugPrintfEXT("view[1]=(%f,%f,%f,%f)\n", camera_Ubo.view[1].x, camera_Ubo.view[1].y, camera_Ubo.view[1].z, camera_Ubo.view[1].w);
        debugPrintfEXT("view[2]=(%f,%f,%f,%f)\n", camera_Ubo.view[2].x, camera_Ubo.view[2].y, camera_Ubo.view[2].z, camera_Ubo.view[2].w);
        debugPrintfEXT("view[3]=(%f,%f,%f,%f)\n", camera_Ubo.view[3].x, camera_Ubo.view[3].y, camera_Ubo.view[3].z, camera_Ubo.view[3].w);
        debugPrintfEXT("proj[0]=(%f,%f,%f,%f)\n", camera_Ubo.proj[0].x, camera_Ubo.proj[0].y, camera_Ubo.proj[0].z, camera_Ubo.proj[0].w);
        debugPrintfEXT("proj[1]=(%f,%f,%f,%f)\n", camera_Ubo.proj[1].x, camera_Ubo.proj[1].y, camera_Ubo.proj[1].z, camera_Ubo.proj[1].w);
        debugPrintfEXT("proj[2]=(%f,%f,%f,%f)\n", camera_Ubo.proj[2].x, camera_Ubo.proj[2].y, camera_Ubo.proj[2].z, camera_Ubo.proj[2].w);
        debugPrintfEXT("proj[3]=(%f,%f,%f,%f)\n", camera_Ubo.proj[3].x, camera_Ubo.proj[3].y, camera_Ubo.proj[3].z, camera_Ubo.proj[3].w);


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

    // gl_Position = vec4(vtx.position.xy, 0.0, 1.0);
    // gl_Position = camera_Ubo.model * vec4(vtx.position.xyz, 1.0);
    // gl_Position = camera_Ubo.view * vec4(vtx.position.xyz, 1.0);
    gl_Position = camera_Ubo.proj * camera_Ubo.view * camera_Ubo.model * vec4(vtx.position.xyz, 1.0);

    texCoord = vec2(vtx.uv.x, vtx.uv.y);
}
