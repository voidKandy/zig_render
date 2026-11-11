// clang-format off
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

[[vk::input_attachment_index(4)]]
[[vk::binding(4, 0)]]
SubpassInput<float4> gSSAO;

[[vk::push_constant]]
ConstantBuffer<DitherParams> Dither;

// clang-format on
struct FragOut {
    float4 color : SV_Target0;
};

struct DitherParams {
    float2 resolution;
    float gridSize;
    uint invertColor;
    uint grayscaleOnly;
    uint _;
};

bool getValue(float brightness, float ao, float2 pos) {
    float gridSize = clamp(Dither.gridSize * max(ao, 0.1), 1.0, 20.0);
    // float gridSize = Dither.gridSize;

    if (brightness > 16.0 / 17.0)
        return false;
    if (brightness < 1.0 / 17.0)
        return true;

    float2 pixel = floor(fmod(pos / gridSize, 4.0));
    int x = int(pixel.x);
    int y = int(pixel.y);

    if (x == 0) {
        if (y == 0)
            return brightness < 16.0 / 17.0;
        if (y == 1)
            return brightness < 5.0 / 17.0;
        if (y == 2)
            return brightness < 13.0 / 17.0;
        return brightness < 1.0 / 17.0;
    } else if (x == 1) {
        if (y == 0)
            return brightness < 8.0 / 17.0;
        if (y == 1)
            return brightness < 12.0 / 17.0;
        if (y == 2)
            return brightness < 4.0 / 17.0;
        return brightness < 9.0 / 17.0;
    } else if (x == 2) {
        if (y == 0)
            return brightness < 14.0 / 17.0;
        if (y == 1)
            return brightness < 2.0 / 17.0;
        if (y == 2)
            return brightness < 15.0 / 17.0;
        return brightness < 3.0 / 17.0;
    } else {
        if (y == 0)
            return brightness < 6.0 / 17.0;
        if (y == 1)
            return brightness < 10.0 / 17.0;
        if (y == 2)
            return brightness < 7.0 / 17.0;
        return brightness < 11.0 / 17.0;
    }
}

// clang-format off
[shader("fragment")]
FragOut fragmentMain(float4 fragCoord : SV_Position) {
    // clang-format on
    FragOut output;

    float depth = gDepth.SubpassLoad().x;

    if (depth >= 1.0) {
        discard;
    }

    float3 normal = normalize(gNormal.SubpassLoad().xyz);
    float3 position = gPosition.SubpassLoad().xyz;
    float3 albedo = gAlbedo.SubpassLoad().rgb;
    float ao = gSSAO.SubpassLoad().r;

    float aoStrength = 1.0;
    float3 baseColor = albedo * lerp(1.0, ao, aoStrength);

    float luminance = dot(baseColor, float3(1.0, 1.0, 1.0));

    if (Dither.grayscaleOnly > 0) {
        baseColor = float3(luminance);
    }

    bool dithered = false;
    // bool dithered = getValue(dot(baseColor, float3(0.2126, 0.7152, 0.0722)), ao, fragCoord.xy);
    baseColor = dithered ? float3(0.0) : baseColor;

    if (Dither.invertColor > 0) {
        baseColor = 1.0 - baseColor;
    }

    output.color = float4(baseColor, 1.0);
    return output;
}

    // clang-format off
[shader("vertex")]
float4 vertexMain(uint vertexID : SV_VertexID) : SV_Position {
    // clang-format on
    float2 pos = float2(vertexID & 2, (vertexID << 1) & 2) * 2.0 - 1.0;
    return float4(pos, 0.0, 1.0);
}
