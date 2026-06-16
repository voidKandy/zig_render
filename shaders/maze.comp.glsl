#version 450
#extension GL_EXT_debug_printf : enable
// run export DEBUG_PRINTF_TO_STDOUT=true to see
// unset DEBUG_PRINTF_TO_STDOUT to disable

struct MazeCell {
    uint walls;
};

layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_image;
layout(set = 0, binding = 1) readonly buffer CellBuffer {
    MazeCell cells[]; // packed wall bits
};

layout(push_constant) uniform PushConstants {
    uint maze_width;
    uint maze_height;
    uint pixels_per_cell;
};


void main() {
    uvec2 pixel = gl_GlobalInvocationID.xy;

    uint cell_x = pixel.x / pixels_per_cell;
    uint cell_y = pixel.y / pixels_per_cell;
    if (cell_x >= maze_width || cell_y >= maze_height) return;
    uint cellIdx = cell_y * maze_width + cell_x;
    if (gl_GlobalInvocationID.x == 37 && gl_GlobalInvocationID.y == 7) {
        debugPrintfEXT("maze_width=%u maze_height=%u pixels_per_cell=%u\n",
              maze_width, maze_height, pixels_per_cell);
        debugPrintfEXT("pixel=(%u, %u)\n", pixel.x, pixel.y);
        debugPrintfEXT("cellIdx=%u\n", cellIdx);
    }
    MazeCell cell = cells[cellIdx];
    bool north = (cell.walls & 1u) != 0u;
    bool south = (cell.walls & 2u) != 0u;
    bool east  = (cell.walls & 4u) != 0u;
    bool west  = (cell.walls & 8u) != 0u;

    uint local_x = pixel.x % pixels_per_cell;
    uint local_y = pixel.y % pixels_per_cell;
    if (cell_x == 3u && cell_y == 0u && local_x == 0u && local_y == 0u) {
        debugPrintfEXT("cell(0,3) walls=%u east=%u\n", cell.walls, uint(east));
    }
    uint wall_thickness = 1;
    bool is_wall =
        (south && local_y >= pixels_per_cell - wall_thickness) ||
        (east  && local_x >= pixels_per_cell - wall_thickness) ||
        (north && local_y < wall_thickness && cell_y == 0u) ||
        (west  && local_x < wall_thickness && cell_x == 0u);

    vec4 color = is_wall ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(1.0, 1.0, 1.0, 1.0);
    imageStore(out_image, ivec2(pixel), color);
}
