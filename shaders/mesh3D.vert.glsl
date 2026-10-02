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
    vec3 position;
    uint meshIndex;
    vec4 rotation;
    vec3 scale;
    uint materialIndex;
    
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




// Builds a model matrix from a quaternion (x,y,z,w), a world-space position,
// and a per-axis scale. Scale is applied before rotation (local-space scale),
// matching the conventional TRS composition order.
mat4 buildModelMatrix(vec3 pos, vec4 rot, vec3 scale) {
    float x = rot.x, y = rot.y, z = rot.z, w = rot.w;

    float xx = x * x, yy = y * y, zz = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;

    vec3 col0 = vec3(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz),       2.0 * (xz - wy)) * scale.x;
    vec3 col1 = vec3(2.0 * (xy - wz),       1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx)) * scale.y;
    vec3 col2 = vec3(2.0 * (xz + wy),       2.0 * (yz - wx),       1.0 - 2.0 * (xx + yy)) * scale.z;

    return mat4(
        vec4(col0, 0.0),
        vec4(col1, 0.0),
        vec4(col2, 0.0),
        vec4(pos, 1.0)
    );
}

void main()
{

    Instance instance = InstanceBuf.instances[uint(gl_InstanceIndex)];
    MaterialIndex = instance.materialIndex;

    int Index = in_Indices.i[gl_VertexIndex];

    VertexData vtx = in_Vertices.v[Index + pc.VertexOffset];
    mat4 modelTransform = buildModelMatrix(instance.position, instance.rotation, instance.scale);
    
    gl_Position = camera_Ubo.proj * camera_Ubo.view * modelTransform * vec4(vtx.position.xyz, 1.0);

    texCoord = vec2(vtx.uv.x, vtx.uv.y);
}

