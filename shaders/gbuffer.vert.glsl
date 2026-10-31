#version 450
// run export DEBUG_PRINTF_TO_STDOUT=true to see
// unset DEBUG_PRINTF_TO_STDOUT to disable
 
struct Instance {
    vec3 position;
    uint meshIndex;
    vec4 rotation;
    vec3 scale;
    uint materialIndex;
    
};

struct VertexData {
    vec4 position;
    vec4 normal;
    vec4 color;
    vec2 uv;
    vec2 _;
};


layout(push_constant) uniform PushConstants {
    uint VertexOffset;
    uint IndexOffset;
} pc;

layout (set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;


layout (set = 1, binding = 0) readonly buffer Indices { int i[]; } in_Indices;
layout (std430, set = 1, binding = 1) readonly buffer Vertices { VertexData v[]; } in_Vertices;
layout(std430, set = 2, binding = 0) readonly buffer InstanceSSBO { Instance instances[]; } InstanceBuf;


layout(location = 0) out vec3 outWorldPos;
layout(location = 1) out vec3 outNormal;
layout(location = 2) out vec2 outUV;
layout(location = 3) out vec4 outVertexColor;
layout(location = 4) flat out uint outMaterialIndex;
out gl_PerVertex
{
	vec4 gl_Position;
};




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
    int Index = in_Indices.i[gl_VertexIndex];
    uint vertexDataIdx = Index + pc.VertexOffset;

    VertexData vtx = in_Vertices.v[vertexDataIdx];
       
    mat4 modelTransform = buildModelMatrix(instance.position, instance.rotation, instance.scale);
	vec4 worldPos = modelTransform * vec4(vtx.position.xyz, 1.0);
    mat3 normalMatrix = transpose(inverse(mat3(modelTransform)));

    gl_Position = camera_Ubo.proj * camera_Ubo.view * worldPos;
    outWorldPos = worldPos.xyz;
    outNormal = normalize(normalMatrix * vtx.normal.xyz);
    outUV = vtx.uv;
    outVertexColor = vtx.color;
    outMaterialIndex = instance.materialIndex;
}
