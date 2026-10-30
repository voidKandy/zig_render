#version 450

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput gPosition;
layout(input_attachment_index = 1, set = 0, binding = 1) uniform subpassInput gNormal;
layout(input_attachment_index = 2, set = 0, binding = 2) uniform subpassInput gAlbedo;

layout(location = 0) out vec4 outColor;

void main()
{
    vec3 normal = normalize(subpassLoad(gNormal).xyz);
    vec3 position = subpassLoad(gPosition).xyz;
    vec4 albedo = subpassLoad(gAlbedo);

    // Temporary output until lighting is implemented
    outColor = albedo;
    // outColor = vec4(subpassLoad(gPosition).xyz, 1.0);
    // outColor = vec4(subpassLoad(gNormal).xyz * 0.5 + 0.5, 1.0);
}
