[[vk::input_attachment_index(0)]]
[[vk::binding(0, 0)]]
SubpassInput<float4> gDepth;

[[vk::input_attachment_index(1)]]
[[vk::binding(1, 0)]]
SubpassInput<float4> gPosition;

[[vk::input_attachment_index(2)]]
[[vk::binding(2, 0)]]
SubpassInput<float4> gNormal;

[[vk::input_attachment_index(3)]]
[[vk::binding(3, 0)]]
SubpassInput<float4> gAlbedo;

struct VertOut {
};
struct FragOut {
    float4 color : SV_Target0;
};
[shader("vertex")]
VertOut vertexMain(float4 fragCoord : SV_Position) {
  VertOut output;
  return output;
}

[shader("fragment")]
FragOut fragmentMain(float4 fragCoord : SV_Position) {
  FragOut output;
  return output;
}
