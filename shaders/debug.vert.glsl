#version 460

layout(location = 0) in vec4 inPosition;
layout(location = 2) in vec4 inColor;

layout(set = 0, binding = 0) uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;

layout(location = 0) out vec3 outColor;

void main() {
    outColor = inColor.rgb;

    gl_Position =
        camera_Ubo.proj *
        camera_Ubo.view *
        inPosition;
}
