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

struct FragOut {
    float4 color : SV_Target0;
};

[shader("fragment")]
FragOut fragmentMain() {
    FragOut output;

    float depth = gDepth.SubpassLoad().x;

    // Preserve the background image.
    if (depth >= 1.0) {
        discard;
    }

    float3 normal = normalize(gNormal.SubpassLoad().xyz);
    float3 position = gPosition.SubpassLoad().xyz;
    float3 albedo = gAlbedo.SubpassLoad().rgb;

    float3 lightDirection = normalize(float3(-1.0, -1.0, 2.0));
    float3 lightColor = float3(1.0, 0.95, 0.85);

    float ambientStrength = 0.4;
    float3 ambient = ambientStrength * albedo;

    float diffuseStrength = max(dot(normal, lightDirection), 0.0);
    float3 diffuse = diffuseStrength * lightColor * albedo * 1.5;

    output.color = float4(ambient + diffuse, 1.0);
    // output.color = float4(normal, 0.0);
    // output.color = float4(albedo, 0.0);
    return output;
}

[shader("vertex")]
float4 vertexMain(uint vertexID : SV_VertexID) : SV_Position {
    float2 pos = float2(
        vertexID & 2,
        (vertexID << 1) & 2
    ) * 2.0 - 1.0;

    return float4(pos, 0.0, 1.0);
}
