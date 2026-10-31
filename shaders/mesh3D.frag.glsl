#version 450

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput gDepth;
layout(input_attachment_index = 1, set = 0, binding = 1) uniform subpassInput gPosition;
layout(input_attachment_index = 2, set = 0, binding = 2) uniform subpassInput gNormal;
layout(input_attachment_index = 3, set = 0, binding = 3) uniform subpassInput gAlbedo;

layout(location = 0) out vec4 outColor;

void main()
{
    float depth = subpassLoad(gDepth).x;

    // Preserve the background image.
    if (depth >= 1.0) {
        discard;
    }

    vec3 normal = normalize(subpassLoad(gNormal).xyz);
    vec3 position = subpassLoad(gPosition).xyz;
    vec3 albedo = subpassLoad(gAlbedo).rgb;

    vec3 lightDirection = normalize(vec3(-1.0, -1.0, 2.0));
    vec3 lightColor = vec3(1.0, 0.95, 0.85);

    float ambientStrength = 0.4;
    vec3 ambient = ambientStrength * albedo;

    float diffuseStrength = max(dot(normal, lightDirection), 0.0);
    vec3 diffuse = diffuseStrength * lightColor * albedo * 1.5;

    outColor = vec4(ambient + diffuse, 1.0);
    
}
