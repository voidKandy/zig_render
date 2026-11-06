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
// uniform sampler2D gPosition;
// uniform sampler2D gNormal;
// uniform sampler2D texNoise;

// uniform vec3 samples[64];
 
// maybe these should be passed in a uniform buffer?
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
static const float bias = 0.025;

static const float3 samples[KERNEL_SIZE] = {
    float3( 0.1,  0.1,  0.1),
    float3(-0.2,  0.1,  0.2),
    float3( 0.1, -0.3,  0.1),
    float3(-0.3, -0.1,  0.2),
    float3( 0.2,  0.2,  0.3),
    float3(-0.1,  0.3,  0.2),
    float3( 0.3, -0.2,  0.1),
    float3(-0.2, -0.2,  0.3),
    float3( 0.1,  0.1,  0.5),
    float3(-0.3,  0.1,  0.4),
    float3( 0.2, -0.3,  0.4),
    float3(-0.1, -0.2,  0.5),
    float3( 0.3,  0.2,  0.4),
    float3(-0.2,  0.3,  0.5),
    float3( 0.1, -0.1,  0.6),
    float3(-0.3, -0.2,  0.6)
};

// tile noise texture over screen, based on screen dimensions divided by noise size
// const float2 noise_scale = float2(800.0/4.0, 600.0/4.0);

[shader("vertex")]
VertOut vertexMain(uint vertexID : SV_VertexID) {
  VertOut output;
  float2 uv = float2(
          vertexID & 2,
          (vertexID << 1) & 2
      );

  output.uv = uv * 0.5;
  output.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);

  return output;
}

[shader("fragment")]
FragOut fragmentMain(VertOut input) {
  FragOut output;

  float3 fragPos   = sampleMaterial(POSITIONS_TEXTURE_INDEX, input.uv).xyz;
  float3 normal    = sampleMaterial(NORMALS_TEXTURE_INDEX, input.uv).rgb;
  // float3 randomVec = sampleMaterial(texNoise, TexCoords * noiseScale).xyz; 

  float3 randomVec = float3(1.0, 0.0, 0.0);

  if (abs(dot(randomVec, normal)) > 0.99) {
      randomVec = float3(0.0, 1.0, 0.0);
  }

  float3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
  float3 bitangent = cross(normal, tangent);
  float3x3 TBN = float3x3(tangent, bitangent, normal);
  
  float occlusion = 0.0;

  for (uint i = 0; i < KERNEL_SIZE; ++i) {
      // Tangent space -> view space
      float3 samplePos = fragPos + mul(TBN, samples[i]) * radius;

      // View space -> clip space
      float4 offset = mul(Camera.proj, float4(samplePos, 1.0));

      // Perspective divide
      offset.xyz /= offset.w;

      // NDC -> texture coordinates
      float2 sampleUV = offset.xy * 0.5 + 0.5;

      // Get the view-space depth at the projected sample location
      float sampleDepth = sampleMaterial(
          POSITIONS_TEXTURE_INDEX,
          sampleUV
      ).z;

      float rangeCheck = smoothstep(
          0.0,
          1.0,
          radius / abs(fragPos.z - sampleDepth)
      );

      occlusion += (
          sampleDepth >= samplePos.z + bias ? 1.0 : 0.0
      ) * rangeCheck;
  }

  occlusion = 1.0 - (occlusion / KERNEL_SIZE);

  output.color = float4(occlusion, occlusion, occlusion, 1.0);

  
  return output;
}
