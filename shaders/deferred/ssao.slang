struct CameraUniform {
  float4x4 view;
  float4x4 proj;
}

[[vk::binding(0,0)]]
ConstantBuffer<CameraUniform> Camera;

[[vk::binding(0, 1)]]
SamplerState Sampler;

[[vk::binding(0, 2)]]
Texture2D Textures[];

// maybe these should be passed in a uniform buffer?
// these reflect the enum created by attachments.CreateManager
static int DEPTH_TEXTURE_INDEX = 0;
static int POSITIONS_TEXTURE_INDEX = 1;
static int NORMALS_TEXTURE_INDEX = 2;


float4 sampleMaterial(uint materialIndex, float2 uv) {
    return Textures[NonUniformResourceIndex(materialIndex)].Sample(
       Sampler,
       uv
    );
}



struct VertOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

struct FragOut {
    float4 color : SV_Target0;
 };

static const uint KERNEL_SIZE = 16;
static const float radius = 0.5;
static const float bias = 0.001;


#define KERNEL_SIZE 16
#define PI 3.14159265359

static const uint BAYER4[16] = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5
};

float getDitherRotation(float2 pixel) {
    uint2 p = uint2(pixel) & 3;
    uint index = p.x + p.y * 4;

    return (float(BAYER4[index]) / 16.0) * (2.0 * PI);
}

float radicalInverse(uint bits) {
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);

    return float(bits) * 2.3283064365386963e-10;
}

float3 getKernelSample(uint i) {
    float u = (float(i) + 0.5) / float(KERNEL_SIZE);
    float v = radicalInverse(i);

    float phi = 2.0 * PI * v;

    float3 sample;
    sample.x = cos(phi) * sqrt(1.0 - u * u);
    sample.y = sin(phi) * sqrt(1.0 - u * u);
    sample.z = u;

    float scale = float(i) / float(KERNEL_SIZE);
    scale = lerp(0.1, 1.0, scale * scale);

    return sample * scale;
}

float LinearizeDepth(float2 uv)
{
    float A = Camera.proj[2][2];
    float B = Camera.proj[2][3];

    float z = sampleMaterial(DEPTH_TEXTURE_INDEX, uv).r;

    return B / (z + A);
}

[shader("vertex")]
VertOut vertexMain(uint vertexID : SV_VertexID) {
  VertOut output;
  float2 pos = float2(
    vertexID & 2,
    (vertexID << 1) & 2
);

  output.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
  output.uv = pos;
  return output;
}

[shader("fragment")]
FragOut fragmentMain(VertOut input)
{
    FragOut output;

    // Read G-buffer.
    float3 fragPos = sampleMaterial(
        POSITIONS_TEXTURE_INDEX,
        input.uv
    ).xyz;

    float3 normal = normalize(
        sampleMaterial(
            NORMALS_TEXTURE_INDEX,
            input.uv
        ).xyz
    );

    float depth = sampleMaterial(DEPTH_TEXTURE_INDEX, input.uv).r;
    if (depth >= 0.999999)
    {
        output.color = float4(1.0, 1.0, 1.0, 1.0);
        return output;
    }

    // Dither rotation.
    float2 pixel = input.position.xy;
    float angle = getDitherRotation(pixel);

    float s = sin(angle);
    float c = cos(angle);

    // Construct TBN in world space.
    float3 randomVec = float3(1.0, 0.0, 0.0);

    if (abs(dot(randomVec, normal)) > 0.99)
        randomVec = float3(0.0, 1.0, 0.0);

    float3 tangent = normalize(
        randomVec - normal * dot(randomVec, normal)
    );

    float3 bitangent = cross(normal, tangent);
    float3x3 TBN       = float3x3(tangent, bitangent, normal);  

    
    float occlusion = 0.0;

    for (uint i = 0; i < KERNEL_SIZE; ++i)
    {
        float3 sample = getKernelSample(i);

        float2 rotated = float2(
            sample.x * c - sample.y * s,
            sample.x * s + sample.y * c
        );

        sample.x = rotated.x;
        sample.y = rotated.y;

        // Tangent space -> world space.
        float3 sampleOffset =
            tangent * sample.x +
            bitangent * sample.y +
            normal * sample.z;

        float3 sampleWorldPos =
            fragPos + sampleOffset * radius;

        // World space -> view space.
        float3 sampleViewPos = mul(
            Camera.view,
            float4(sampleWorldPos, 1.0)
        ).xyz;

        // View space -> clip space.
        float4 sampleClip = mul(
            Camera.proj,
            float4(sampleViewPos, 1.0)
        );

        if (sampleClip.w <= 0.0)
            continue;

        // Clip space -> UV.
        float2 sampleUV = sampleClip.xy / sampleClip.w;
        // sampleUV.y = 1.0 - sampleUV.y;
        sampleUV = sampleUV * 0.5 + 0.5;

        if (any(sampleUV < 0.0) || any(sampleUV > 1.0))
            continue;

        // Actual scene depth at projected sample location.
        float sampledDepth = LinearizeDepth(sampleUV);

        // Expected sample depth.
        float expectedDepth = -sampleViewPos.z;
        float fragmentDepth = -mul(
            Camera.view,
            float4(fragPos, 1.0)
        ).z;

        float rangeCheck = smoothstep(
            0.0,
            1.0,
            radius / max(abs(fragmentDepth - sampledDepth), 0.0001)
        );
        float occluded = 1.0 - smoothstep(
            expectedDepth - bias,
            expectedDepth + bias,
            sampledDepth
        );
        occlusion += occluded * rangeCheck;
      
    }

    occlusion = 1.0 - occlusion / float(KERNEL_SIZE);

    output.color = float4(
        occlusion,
        occlusion,
        occlusion,
        1.0
    );

    return output;
}


