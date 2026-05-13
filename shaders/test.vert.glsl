/*

        Copyright 2024 Etay Meiri

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/


#version 460
#extension GL_EXT_debug_printf : enable



struct VertexData
{

    vec3 position;
    vec3 normal;
    vec3 color;
    vec2 uv;
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

    debugPrintfEXT(
        "mesh=%u vert=%u idx=%u md(v=%u i=%u mat=%u) pos=(%f,%f,%f)\n",
        meshIdx,
        gl_VertexIndex,
        uint(Index),
        md.VertexOffset,
        md.IndexOffset,
        md.MaterialIndex,
        vtx.position.x,
        vtx.position.y,
        vtx.position.z
    );
    // gl_Position = vec4(vtx.position.xy, 0.0, 1.0);
    gl_Position = camera_Ubo.model * vec4(vtx.position.xyz, 1.0);
    // gl_Position = camera_Ubo.view * vec4(vtx.position.xyz, 1.0);
    // gl_Position = camera_Ubo.proj * camera_Ubo.view * camera_Ubo.model * vec4(vtx.position.xyz, 1.0);

    texCoord = vec2(vtx.uv.x, vtx.uv.y);
}
