struct Instance {
    uint _;
    uint materialIndex;
    float2 screenPosition;
}

struct InstanceDrawInfo {
    float2 windowResolution;
    uint vertexOffset;
    uint indexOffset;
};

[[vk::push_constant]]
ConstantBuffer<InstanceDrawInfo> DrawInstance;
[[vk::binding(0, 0)]]
SamplerState Sampler;
[[vk::binding(0, 1)]]
Texture2D Textures[];
[[vk::binding(0, 2)]]
StructuredBuffer<Instance> InstanceBuf;

struct VertIn {
  float2 position;
  float2 uv;
}

struct VertOut {
    float4 position    : SV_Position;
    float2 uv          : TEXCOORD0;
    nointerpolation uint materialIdx : TEXCOORD4;
};

struct FragOut {
    float4 color : SV_Target0;
}


[shader("vertex")]
VertOut vertexMain(
    VertIn input,
    uint vertexID : SV_VertexID,
    uint instanceID : SV_InstanceID,
) {
    VertOut output;
    Instance instance = InstanceBuf[instanceID];

    output.uv = input.uv;


    float aspect = DrawInstance.windowResolution.x / DrawInstance.windowResolution.y;
    float2 local = input.position;
    local.x /= aspect;
    float2 screenPos = instance.screenPosition + local;

    float2 ndc;
    ndc.x = screenPos.x * 2.0 - 1.0;
    ndc.y = -(screenPos.y * 2.0 - 1.0);


    output.position = float4(ndc, 0.0, 1.0);
    output.materialIdx = instance.materialIndex;

    return output;
}


[shader("fragment")]
FragOut fragmentMain(VertOut input) {
    FragOut output;
    output.color = sampleAlbedo(input.materialIdx, input.uv) ;
    return output;
}


float4 sampleAlbedo(uint materialIndex, float2 uv) {
    return Textures[NonUniformResourceIndex(materialIndex)].Sample(
       Sampler,
       uv
    );
}
