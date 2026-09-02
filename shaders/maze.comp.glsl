// It would be more efficient to implement
// this shader as a fragment shader
// however, this shader and the way it is used in the
// engine is a good example of using a compute shader

#version 450
#extension GL_EXT_debug_printf : enable
// run export DEBUG_PRINTF_TO_STDOUT=true to see
// unset DEBUG_PRINTF_TO_STDOUT to disable

struct MazeCell {
    uint walls;
};

layout(local_size_x = 8, local_size_y = 8) in;

layout (set = 0, binding = 0) readonly uniform CameraData {
    mat4 view;
    mat4 proj;
} camera_Ubo;
layout(set = 1, binding = 0, rgba8) uniform writeonly image2D out_image;
layout(set = 2, binding = 0) readonly buffer CellBuffer {
    MazeCell cells[]; // packed wall bits
};

layout(push_constant) uniform PushConstants {
    uint maze_width;
    uint maze_height;
    uint pixels_per_cell;
    float cell_size;
    vec3 maze_origin;
};


void main() {
    uvec2 pixel = gl_GlobalInvocationID.xy;
    uint cell_x = pixel.x / pixels_per_cell;
    uint cell_y = pixel.y / pixels_per_cell;
    if (cell_x >= maze_width || cell_y >= maze_height) return;
    uint cellIdx = cell_y * maze_width + cell_x;

    MazeCell cell = cells[cellIdx];
    bool north = (cell.walls & 1u) != 0u;
    bool south = (cell.walls & 2u) != 0u;
    bool east  = (cell.walls & 4u) != 0u;
    bool west  = (cell.walls & 8u) != 0u;

    uint local_x = pixel.x % pixels_per_cell;
    uint local_y = pixel.y % pixels_per_cell;

    uint wall_thickness = 1;
    bool is_wall =
        (south && local_y >= pixels_per_cell - wall_thickness) ||
        (east  && local_x >= pixels_per_cell - wall_thickness) ||
        (north && local_y < wall_thickness && cell_y == 0u) ||
        (west  && local_x < wall_thickness && cell_x == 0u);

    vec3 camWorldPos = inverse(camera_Ubo.view)[3].xyz;
    vec2 playerGrid = ((camWorldPos.xyz - maze_origin) / cell_size).xy;
    ivec2 playerCell = ivec2(clamp(
        floor(playerGrid),
        vec2(0.0),
        vec2(float(maze_width - 1u), float(maze_height - 1u))
    ));

    vec4 color;
    if (ivec2(cell_x, cell_y) == playerCell) {
        color = vec4(1.0, 0.0, 0.0, 1.0);
    } else {
        color = is_wall ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(1.0, 1.0, 1.0, 1.0);
    }


    // mirror horizontally so image orientation matches world/mesh orientation
    uint image_width_px = maze_width * pixels_per_cell;
    ivec2 out_pixel = ivec2(int(image_width_px - 1u - pixel.x), int(pixel.y));
    imageStore(out_image, out_pixel, color);
}
