#version 460

layout(location = 0) in vec3 outColor;
layout(location = 0) out vec4 fragColor;

void main() {
    /// makes the fragment depth always 0, so it renders on top of everything
    gl_FragDepth = 0.0;
    fragColor = vec4(outColor, 1.0);
}
