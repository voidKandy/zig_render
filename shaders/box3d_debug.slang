struct CameraUniform {
  float4x4 view;
  float4x4 proj;
}

struct VertexData {
  float3 position;
  float _;
  float4 color;
}

[[vk::binding(0, 0)]]
ConstantBuffer<CameraUniform> Camera;

[[vk::binding(0, 1)]]
StructuredBuffer<VertexData> Vertices;

struct VertOut {
    float4 position : SV_Position;
    float4 color    : TEXCOORD0;
}


struct FragOut {
  float4 color : SV_Target0;
}

[shader("vertex")]
VertOut vertexMain(
    uint vertexID : SV_VertexID,
    uint instanceID : SV_InstanceID
) {
  VertOut output;
  VertexData vtx = Vertices[vertexID];
  output.position = mul(Camera.proj, mul(Camera.view ,float4(vtx.position, 1.0)));
  output.color = vtx.color;
  return output;
}


[shader("fragment")]
FragOut fragmentMain(VertOut input) {
  FragOut output;
  output.color = input.color;
  return output;
}
