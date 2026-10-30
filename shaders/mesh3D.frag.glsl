#version 450

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput gDepth;
layout(input_attachment_index = 1, set = 0, binding = 1) uniform subpassInput gPosition;
layout(input_attachment_index = 2, set = 0, binding = 2) uniform subpassInput gNormal;
layout(input_attachment_index = 3, set = 0, binding = 3) uniform subpassInput gAlbedo;

layout(location = 0) out vec4 outColor;

void main()
{
    vec4 depth = subpassLoad(gDepth);
    // this allows us to passthrough the background image thats drawn to the final image before any graphics passes
    if (depth.x == 1.0) {
        discard;
    }
    vec3 normal = normalize(subpassLoad(gNormal).xyz);
    vec3 position = subpassLoad(gPosition).xyz;
    vec4 albedo = subpassLoad(gAlbedo);

    outColor = albedo;
}
