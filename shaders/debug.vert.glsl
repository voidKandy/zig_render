#version 460
layout(location = 0) in vec4 inPosition;
layout(location = 2) in vec4 inColor;
layout(set = 0, binding = 0) uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_ubo;

void main() {
    mat4 view_rotation = camera_ubo.view;
    view_rotation[3] = vec4(0, 0, -3.0, 1); // strip translation, keep Z pushback

    // scale down + offset to top-right corner in NDC
    mat4 corner = mat4(
        vec4(0.15, 0,    0, 0),
        vec4(0,    0.15, 0, 0),
        vec4(0,    0,    0.15, 0),
        vec4(0.75, -0.75, 0, 1)  // top-right; flip Y sign if needed
    );

    gl_Position = corner * camera_ubo.proj * view_rotation * vec4(inPosition.xyz, 1.0);
    outColor = inColor.rgb;
}
