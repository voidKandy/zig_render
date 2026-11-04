// global uniform sampler2D dither_texture: filter_nearest;
// global uniform float dither_scale;
// global uniform float dither_strength;
// global uniform float dither_levels;

// void light() {
//     float light = (dot(NORMAL, LIGHT) + 1.0) * 0.5;
//     vec2 ts = vec2(textureSize(dither_texture, 0)) * dither_scale;
//     vec2 uv = mod(FRAGCOORD.xy, ts) / ts;
//     light += (texture(dither_texture, uv).r) * dither_strength;
//     light = floor(light * dither_levels) / dither_levels;

//     DIFFUSE_LIGHT += (light * LIGHT_COLOR) * ATTENUATION;

// }


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



struct FragOut {
    float4 color : SV_Target0;
};

struct DitherParams {
    float2 resolution;
    float gridSize;
    float pixelSizeRatio;
    uint invertColor;
    uint grayscaleOnly;
};

bool getValue(float brightness, float2 pos) {
    float gridSize = Dither.gridSize;

    if (brightness > 16.0 / 17.0) return false;
    if (brightness < 1.0 / 17.0) return true;

    float2 pixel = floor(fmod(pos / gridSize, 4.0));
    int x = int(pixel.x);
    int y = int(pixel.y);

    if (x == 0) {
        if (y == 0) return brightness < 16.0 / 17.0;
        if (y == 1) return brightness < 5.0 / 17.0;
        if (y == 2) return brightness < 13.0 / 17.0;
        return brightness < 1.0 / 17.0;
    }
    else if (x == 1) {
        if (y == 0) return brightness < 8.0 / 17.0;
        if (y == 1) return brightness < 12.0 / 17.0;
        if (y == 2) return brightness < 4.0 / 17.0;
        return brightness < 9.0 / 17.0;
    }
    else if (x == 2) {
        if (y == 0) return brightness < 14.0 / 17.0;
        if (y == 1) return brightness < 2.0 / 17.0;
        if (y == 2) return brightness < 15.0 / 17.0;
        return brightness < 3.0 / 17.0;
    }
    else {
        if (y == 0) return brightness < 6.0 / 17.0;
        if (y == 1) return brightness < 10.0 / 17.0;
        if (y == 2) return brightness < 7.0 / 17.0;
        return brightness < 11.0 / 17.0;
    }
}


[shader("fragment")]
FragOut fragmentMain(float4 fragCoord : SV_Position) {
    FragOut output;

    float depth = gDepth.SubpassLoad().x;

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

    // Final lighting result
    // float3 baseColor = ambient;
    float3 baseColor = ambient + diffuse;

    // Dithering
    float luminance = dot(baseColor, float3(1.0, 1.0, 1.0));

    if (Dither.grayscaleOnly > 0) {
        baseColor = float3(luminance);
    }
    bool Dithered = getValue(luminance, fragCoord.xy);
    // bool Dithered = getValue(dot(albedo.rgb, float3(0.2126, 0.7152, 0.0722)), fragCoord.xy);
    baseColor = Dithered ? float3(0.0) : baseColor;

    if (Dither.invertColor > 0) {
        baseColor = 1.0 - baseColor;
    }

    output.color = float4(baseColor, 1.0);
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


