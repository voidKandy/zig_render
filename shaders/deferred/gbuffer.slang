
struct CameraUniform {
  float4x4 view;
  float4x4 proj;
}

struct Instance {
    float3 position;
    uint meshIndex;
    float4 rotation;
    float3 scale;
    uint materialIndex;
    float4x4 inverseModelMatrix;
}

struct VertexData {
    float4 position;
    float4 normal;
    float4 color;
    float2 uv;
    float2 _;
}

struct InstanceMeshOffsets {
  uint vertex;
  uint index;
  
}


[[vk::push_constant]]
ConstantBuffer<InstanceMeshOffsets> instanceOffsets;

[[vk::binding(0,0)]]
ConstantBuffer<CameraUniform> Camera;

[[vk::binding(0, 1)]]
StructuredBuffer<int> Indices;

[[vk::binding(1, 1)]]
StructuredBuffer<VertexData> Vertices;

[[vk::binding(0, 2)]]
StructuredBuffer<Instance> InstanceBuf;

[[vk::binding(0, 3)]]
SamplerState Sampler;

[[vk::binding(0, 4)]]
Texture2D Textures[];

struct VertOut {
    float4 position    : SV_Position;
    float3 worldPos    : TEXCOORD0;
    float3 normal      : TEXCOORD1;
    float2 uv          : TEXCOORD2;
    float4 vertexColor : TEXCOORD3;
    nointerpolation uint materialIdx : TEXCOORD4;
};

struct FragOut {
    float4 position : SV_Target0;
    float4 normal   : SV_Target1;
    float4 albedo   : SV_Target2;
}

[shader("vertex")]
VertOut vertexMain(
    uint vertexID : SV_VertexID,
    uint instanceID : SV_InstanceID
) {
    VertOut output;

    Instance instance = InstanceBuf[instanceID];
    int index = Indices[vertexID];

    uint vertexDataIdx = uint(index) + instanceOffsets.vertex;

    VertexData vtx = Vertices[vertexDataIdx];

    float4x4 model = buildModelMatrix(
        instance.position,
        instance.rotation,
        instance.scale
    );

    float4 worldPos = mul(model, float4(vtx.position.xyz, 1.0));


    float3x3 normalMatrix = transpose(float3x3(instance.inverseModelMatrix));

    output.position = mul(Camera.proj, mul(Camera.view, worldPos));
    output.worldPos = worldPos.xyz;
    output.normal = normalize(mul(normalMatrix, vtx.normal.xyz));
    output.uv = vtx.uv;
    output.vertexColor = vtx.color;
    output.materialIdx = instance.materialIndex;

    return output;

  
}

[shader("fragment")]
FragOut fragmentMain(VertOut input) {
    FragOut output;

    output.position = float4(input.worldPos, 1.0);
    output.normal = float4(normalize(input.normal), 1.0);
    
    output.albedo = sampleAlbedo(input.materialIdx, input.uv) *  input.vertexColor;

    return output;
}


float4 sampleAlbedo(uint materialIndex, float2 uv) {
    return Textures[NonUniformResourceIndex(materialIndex)].Sample(
       Sampler,
       uv
    );
}

float4x4 buildModelMatrix(float3 pos, float4 rot, float3 scale) {
    float x = rot.x, y = rot.y, z = rot.z, w = rot.w;

    float xx = x * x, yy = y * y, zz = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;

    float3 col0 = float3(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz),       2.0 * (xz - wy)) * scale.x;
    float3 col1 = float3(2.0 * (xy - wz),       1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx)) * scale.y;
    float3 col2 = float3(2.0 * (xz + wy),       2.0 * (yz - wx),       1.0 - 2.0 * (xx + yy)) * scale.z;

    // Rows here represent the GLSL column vectors.
    return transpose(float4x4(
        float4(col0, 0.0),
        float4(col1, 0.0),
        float4(col2, 0.0),
        float4(pos, 1.0)
    ));
}
