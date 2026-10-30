#version 450

void main() {
    // generates fullscreen triangle
    vec2 pos = vec2(
        gl_VertexIndex & 2,
        (gl_VertexIndex << 1) & 2
    ) * 2.0 - 1.0;

    gl_Position = vec4(pos, 0.0, 1.0);
}
