struct CameraUniform {
    float4x4 view;
    float4x4 proj;
};

struct MazeCell {
    uint walls;
};

struct PushConstants {
    uint maze_width;
    uint maze_height;
    uint pixels_per_cell;
    float cell_size;
    float3 maze_origin;
    float3 cam_world_pos;
    float _;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> Pc;

[[vk::binding(0, 0)]]
ConstantBuffer<CameraUniform> CameraA;

[[vk::binding(0, 1)]]
RWTexture2D<float4> OutTexture;

[[vk::binding(0, 2)]]
StructuredBuffer<MazeCell> Cells;


[shader("compute")]
[numthreads(8, 8, 1)]
void mazeMain(uint3 dispatchId : SV_DispatchThreadID)
{
    uint2 pixel = dispatchId.xy;

    uint cell_x = pixel.x / Pc.pixels_per_cell;
    uint cell_y = pixel.y / Pc.pixels_per_cell;

    if (cell_x >= Pc.maze_width || cell_y >= Pc.maze_height) {
        return;
    }

    uint cellIdx = cell_y * Pc.maze_width + cell_x;

    MazeCell cell = Cells[cellIdx];

    bool north = (cell.walls & 1u) != 0u;
    bool south = (cell.walls & 2u) != 0u;
    bool east  = (cell.walls & 4u) != 0u;
    bool west  = (cell.walls & 8u) != 0u;

    uint local_x = pixel.x % Pc.pixels_per_cell;
    uint local_y = pixel.y % Pc.pixels_per_cell;

    uint wall_thickness = 1u;

    bool is_wall =
        (south && local_y >= Pc.pixels_per_cell - wall_thickness) ||
        (east  && local_x >= Pc.pixels_per_cell - wall_thickness) ||
        (north && local_y < wall_thickness && cell_y == 0u) ||
        (west  && local_x < wall_thickness && cell_x == 0u);

    // Camera world position from inverse view matrix.
    // float4x4 inverseView = inverse(CameraA.view);
    // float3 camWorldPos = inverseView[3].xyz;

    float2 playerGrid = ((Pc.cam_world_pos - Pc.maze_origin) / Pc.cell_size).xy;

    int2 playerCell = int2(clamp(
        floor(playerGrid),
        float2(0.0),
        float2(float(Pc.maze_width - 1u), float(Pc.maze_height - 1u))
    ));

    float4 color;

    if (int2(cell_x, cell_y).equals(playerCell)) {
        color = float4(1.0, 0.0, 0.0, 1.0);
    } else {
        color = is_wall
            ? float4(0.0, 0.0, 0.0, 1.0)
            : float4(1.0, 1.0, 1.0, 1.0);
    }

    // Mirror horizontally to match world/mesh orientation.
    uint image_width_px = Pc.maze_width * Pc.pixels_per_cell;

    uint2 out_pixel = uint2(
        image_width_px - 1u - pixel.x,
        pixel.y
    );

    OutTexture[out_pixel] = color;
}
