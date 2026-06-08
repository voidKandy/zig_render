#version 460

layout(local_size_x = 16, local_size_y = 16) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D outImage;

layout(std430, set = 0, binding = 1) readonly buffer MazeState {
    uint cells[];
} maze;

layout(push_constant) uniform PushConstants {
    uint width;
    uint height;
} pc;

void main() {
    // ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    // if (coord.x >= int(pc.width) || coord.y >= int(pc.height)) return;

    // uint idx = coord.y * pc.width + coord.x;
    // uint state = maze.cells[idx];

    // vec4 color;
    // switch (state) {
    //     case 0:  color = vec4(0.08, 0.08, 0.08, 1.0); break; // blank
    //     case 1:  color = vec4(0.78, 0.31, 0.31, 1.0); break; // a
    //     case 2:  color = vec4(0.31, 0.78, 0.31, 1.0); break; // b
    //     case 3:  color = vec4(0.31, 0.31, 0.78, 1.0); break; // active
    //     case 4:  color = vec4(0.94, 0.94, 0.94, 1.0); break; // in
    //     default: color = vec4(1.0,  0.0,  1.0,  1.0); break; // error — magenta
    // }
    // imageStore(outImage, coord, color);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
       if (coord.x >= int(pc.width) || coord.y >= int(pc.height)) return;

       // sanity check — write solid magenta
       imageStore(outImage, coord, vec4(1.0, 0.0, 1.0, 1.0));
}
