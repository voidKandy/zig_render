#version 460

struct VertexData {
    vec3 position;
    float _pad;
    vec4 color;
};

layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;

layout(std430, set = 1, binding = 0) readonly buffer Vertices { VertexData v[]; } in_Vertices;

void main()
{
    VertexData vtx = in_Vertices.v[gl_VertexIndex];
    gl_Position = camera_Ubo.proj * camera_Ubo.view * vec4(vtx.position, 1.0);
    outColor = vtx.color;
}
