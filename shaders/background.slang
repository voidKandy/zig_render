struct EffectData {
  float4 data1;
  float4 data2;
  float4 data3;
  float4 data4;  
}

[[vk::push_constant]]
ConstantBuffer<EffectData> Effect;

[[vk::binding(0, 0)]]
RWTexture2D Image;


[shader("compute")]
[numthreads(16, 16, 1)]
func gradientMain(
	uint3 dispatchId: SV_DispatchThreadID  
) {
   int2 pixelCoord = int2(dispatchId.xy);
   int width, height;
   Image.GetDimensions(width, height);


   float4 topColor = Effect.data1;
   float4 bottomColor = Effect.data2;

   if(pixelCoord.x < width && pixelCoord.y < height)
   {
       float blend = float(pixelCoord.y)/(height); 
       Image.Store(pixelCoord, lerp(topColor,bottomColor, blend));
   }
   
}

float Noise2d(float2 x)
{
    float xhash = cos(x.x * 37.0);
    float yhash = cos(x.y * 57.0);
    return frac(415.92653 * (xhash + yhash));
}

float NoisyStarField(float2 samplePos, float threshold)
{
    float starVal = Noise2d(samplePos);

    if (starVal >= threshold) {
        starVal = pow(
            (starVal - threshold) / (1.0 - threshold),
            6.0
        );
    } else {
        starVal = 0.0;
    }

    return starVal;
}

float StableStarField(float2 samplePos, float threshold)
{
    float fractX = frac(samplePos.x);
    float fractY = frac(samplePos.y);
    float2 floorSample = floor(samplePos);

    float v1 = NoisyStarField(floorSample, threshold);
    float v2 = NoisyStarField(floorSample + float2(0.0, 1.0), threshold);
    float v3 = NoisyStarField(floorSample + float2(1.0, 0.0), threshold);
    float v4 = NoisyStarField(floorSample + float2(1.0, 1.0), threshold);

    return
        v1 * (1.0 - fractX) * (1.0 - fractY) +
        v2 * (1.0 - fractX) * fractY +
        v3 * fractX * (1.0 - fractY) +
        v4 * fractX * fractY;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void starsMain(uint3 dispatchId : SV_DispatchThreadID)
{
    uint width, height;
    Image.GetDimensions(width, height);

    uint2 pixelCoord = dispatchId.xy;

    if (pixelCoord.x >= width || pixelCoord.y >= height) {
        return;
    }

    float2 fragCoord = float2(pixelCoord);
    float2 resolution = float2(width, height);

    float3 color = Effect.data1.xyz * fragCoord.y / resolution.y;

    float threshold = Effect.data1.w;

    float xRate = 0.2;
    float yRate = -0.06;

    float2 samplePos = fragCoord + float2(xRate, yRate);

    float starVal = StableStarField(samplePos, threshold);
    color += float3(starVal);

    Image.Store(pixelCoord, float4(color, 1.0));
}
