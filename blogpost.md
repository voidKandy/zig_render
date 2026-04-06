# Journey into vulkan
Since September of 2025 I've been trying to learn Vulkan. I've learned a fair bit about the API, and I'd like to document the current state of my project. There are some fatal design flaws that I need to fix, but I would like to use this post as an excersize in code explanation and also as a way to solidify my understanding of the API and the abstracstions I've built around it. This way I can get a better understanding of how I can fix the project. Some need to go, but some seem good.


## It began with a clone
Since I'm working in Zig, the first step was getting the vulkan C library working with Zig. Looking back, it's a fairly trivial task, but I had never done any C interop with zig at the time. I started by cloning [this repo](https://github.com/spanzeri/vkguide-zig). This repo showed me how to hook up arbitrary C libraries, to a zig project. Out of the box it comes with the C libraries `imgui`, `sdl3`, `stb`, `vma`, linked and wrapped. The Vulkan library is also wrapped, but it assumes that the user has a working Vulkan installation. It also included a great example of how to compile shaders as a part of the build system and how to link them to the project. Once I had Vulkan intalled on my Mac, there were a few build errors due to the version difference between the Zig used in the project and the Zig I had installed, but once I smoothed those over, all of the examples were working as expected.

The main module of the repo I cloned was `src/VulkanEngine.zig`. It was the only import into the main binary. So I began by creating my own `src/NewVulkanEngine.zig`, and imported that into main instead. I then used `NewVulkanEngine` as the only module I actually would change as I worked through the [vulkan tutorial](https://vulkan-tutorial.com/). The rest of the repo worked as a reference for me. Some of the ways certain things were done in the tutorial were done differently by the repo. This was a little annoying but honestly a great way to learn the vulkan API and VMA. 
> VMA is an allocation library for vulkan that just makes memory management a little easier. It isn't used in vulkan tutorial, so being forced to port code from the tutorial to use the allocator used in the repo was a great way to learn the vulkan API a little more thoroughly.

Eventually I ended up with a triangle rendered to the screen, with code only I wrote. From there I continued to work through the tutorial until I eventually had a compute shader for rendering the background and a depth buffer.
The next step was building out the project in a way that made it easier to mutate. In this step I made a lot of mistakes, but I also learned alot. It is also the step I am just now coming out of, with the intention of going in and doing it again.

## The current state of the project
I will start with the build system, go into the main binary, and then explore the library code.

### `build.zig`
This file builds three libraries: core, imgui and tools. Imgui needs to built as it's own library so it can be linked to the core and used. Core is everything within the `src` directory. The tools library is a consumer of `core`, it is meant for creating things like Camera systems, specific pipelines, and anything else that would require the consumption of the core library but shouldn't leak into core itself (this is one place that needs significant improvemenent).
Shaders are compiled and linked directly into the core library. This is actually really nice, because shaders can be written in an language that can compile to SPV format, the SPV files aren't actually built into the file system, but are instead build artifacts that are embedded directly into the library itself.
Despite the fact that currently there is only one `main` binary file, the build system actually builds any `.zig` file in the `bins` folder. This is so I can eventually have multiple binaries for testing or any other reason. The binary is given access the `core` library and any tools in the `tools` folder.


### `main.zig` - the only binary currently
Since it's a reasonable size, I'll just share the entire `main` function defined in `main.zig`: 
```zig
pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("Leaked memory");
    
    var api_version: u32 = undefined;
    _ = vk.EnumerateInstanceVersion(&api_version);
    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    var engine = core.VulkanEngine.init(
        gpa.allocator(),
        null,
        &initDescriptors,
        &initResources,
        &initPipelineObjects,
    );
    defer engine.deinit();

    engine.run();
}
```
You might notice that `VulkanEngine.init` takes 3 function pointers as initialization arguments:
```zig
pub fn init(
    a: std.mem.Allocator,
    alloc_cbs: ?*vk.AllocationCallbacks,
    createBoundDescriptorsFn: *const fn (*@This()) anyerror!std.StringHashMap(BoundDescriptor),
    createResourcesFn: *const fn (*@This()) anyerror!ResourceManager,
    createPipelineObjectsFn: *const fn (*@This()) anyerror!PipelineObjManager,
) VulkanEngine {
    // ...
}
```
> This is how I give control of pipelines, resources and descriptors to the consumer of the library. This is one of the fatal flaws with the current state of the project, but we'll get into that more later.


The rest of `main.zig` is just the declaration of these three functions ( `initDescriptors`, `initResources`, `initPipelineObjects`) and some other helper functions that are broken out just for readability's sake. 
As a first step into the library, let's dive into how each of these functions work and the objects they return.

### `BoundDescriptor`
My intentions going into creating this abstraction was to create a way for me to describe some data that has been mapped to data on the GPU and a function that is run every frame in order to update that data. I am also able to associate arbitrary data with the struct that may be needed for the per-frame function but isn't needed on the GPU side.
```zig
data: root.vma_usage.AllocatedBuffer = .{ .buffer = null, .allocation = null },
mapped: ?*anyopaque = undefined,
descriptor_type: vk.DescriptorType,
descriptor_stage: vk.ShaderStageFlags,

updateFn: *const fn (@This(), root.VulkanEngine, *Self) void,
state_ptr: *anyopaque,
deinitStateFn: *const fn (*@This(), std.mem.Allocator) void,
```
If you read my [type smuggling](https://www.voidkandy.space/Blog?post=smuggling-types-through-function-pointers) article, this might look vaguely familiar. I use `state_ptr` to associate any arbitrary type with the concrete `BoundDescriptor` and then construct functions at initialization time to coerce that pointer to some other opaque type. I'm not going to go into it much deeper, so if you're confused check out that blog post.
The rest of these fields have to do with vulkan memory management and descriptors. 
Here is the `init` method signature: 
```zig
pub fn init(
    comptime T: type,
    comptime State: type,
    allocs: *root.VulkanEngine.Allocators,
    typ: vk.DescriptorType,
    stage_flags: vk.ShaderStageFlags,
    buffer_usage: vk.BufferUsageFlags,
    memory_usage: vma.MemoryUsage,
    state: State,
    comptime update: *const fn (*State, root.VulkanEngine, *Self) void,
) BoundDescriptor {
    // ...
}
```
Along with wrapping the the update function and constructing a deinit function, this function will also create the `data` field by initializing a vma buffer with the `buffer_usage` and `memory_usage` and then mapping that memory to `mapped`. This way, whatever function is passed as `update` can mutate that mapped data. 
This may seem a little confusing, so lets go over the only place this abstraction is currently used; in the Camera system. In `main`, the camera system is inialized like so: 
```zig
const bound_camera = core.BoundDescriptor.init(
    tools.Camera.GPUData,
    tools.Camera,
    &engine.allocs,
    vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    vk.SHADER_STAGE_VERTEX_BIT,
    vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    c.vma.MEMORY_USAGE_CPU_TO_GPU,
    camera,
    &tools.Camera.control,
);
```
You might notice that `Camera` is in the `tools` module, this is because this system *consumes* the core library, and does not (and should not) ask anything of the library itself. The `Camera` has it's own data, which is passsed as the `State` argument, this isn't data that actually needs to be on the GPU but is fine on the cpu, the member `GPUData` is the actual camera data that lives on the GPU:
```zig
pub const GPUData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

near_plane: f32 = 0.1,
far_plane: f32 = 100.0,
fov: f32 = 45.0,

eye: Vec3 = DEFAULT_EYE,
target: Vec3 = DEFAULT_TARGET,
distance: f32 = DEFAULT_EYE.eucDist(DEFAULT_TARGET),

mode: Mode = .user_input,
```
The model, view and projection matrices all need to exist on the GPU because they are actually used by the shaders, however all the other fields outside of `GPUData` are used either for initialization or are used in the update loop. I won't share it because it's a little long, but the `control` method that exists on camera facilitates camera movement via user input by taking in the input state and mutating the `mapped` data accordingly.

### `ResourceManager`
Of the three, I would say this is the *least* flawed system, but it is still fairly flawed. The resource manager is simply a struct with maps for resources, currently that is `mesh`, `texture`, `sampler`, `image`, `buffer`. The only thing I don't like about it is that resources need to be put on the GPU at some point, that is why a function creating a Resource manager needs to be passed to `VulkanEngine.init` rather than a manager itself. I would like to move towards using a resource manager that has state, or that works in stages. One stage where it converts assets in the file system into data structures that can be uploaded to the GPU, and then a stage where it actually uploads it to the gpu. That way the engine could just be passed a folder path at initialization time that includes all the assets that are to be used by the engine.


### `PipelineObjManager`
> By far the most flawed 


The `PipelineObjManager` is just two hashmaps: 
```zig
const Type = enum { single, map };

pub const Entry = union(Type) {
    single: PipelineObject,
    map: std.StringHashMap(PipelineObject),
};

all_graphics: std.StringHashMap(Entry),
all_compute: std.StringHashMap(Entry),
```
This allows me to have `PipelineObject`s associated with either compute or graphics, this way I know where to call them. But lets dive into what a `PipelineObject` actually is: 
```zig

const DrawImguiFunc = fn (*anyopaque) void;
const DrawFunc = fn (*anyopaque, DrawData, vk.CommandBuffer) void;
const DeinitFunc = fn (*anyopaque, *Allocators, vk.Device, ?*vk.AllocationCallbacks) void;
const InitFunc = fn (
    *anyopaque,
    *Allocators,
    InitData,
    []const ResourceManager.ResourceID,
    vki.LogicalDevice,
    ?*vk.AllocationCallbacks,
) anyerror!void;

drawFunc: *const DrawFunc,
drawImguiFunc: ?*const DrawImguiFunc,
initializeFunc: *const InitFunc,
cleanupFunc: *const DeinitFunc,
data_ptr: *anyopaque,
```
> I'm doing more type smuggling here.

As a background; zig doesn't have an abstraction for creating interfaces, so if one wants something like an interface, they have to implement it themselves. That is essentially what I've done here with the `PipelineObject`. It defines a vtable that the interface object needs to fill when it is created. As an example look at the `create` function: 
```zig

pub fn create(
    comptime T: type,
    allocator: Allocator,
) Allocator.Error!@This() {
    comptime validateT(T);
    const ptr = try allocator.create(T);
    ptr.* = T{};

    return .{
        .data_ptr = @ptrCast(ptr),
        .drawFunc = &struct {
            fn d(p: *anyopaque, dat: DrawData, cmd: vk.CommandBuffer) void {
                @as(*T, @ptrCast(@alignCast(p))).draw(dat, cmd);
            }
        }.d,
        .drawImguiFunc = if (@hasDecl(T, "drawImgui")) &struct {
            fn d(p: *anyopaque) void {
                @as(*T, @ptrCast(@alignCast(p))).drawImgui();
            }
        }.d else null,
        .initializeFunc = &struct {
            fn i(p: *anyopaque, allocs: *Allocators, idat: InitData, r: []const ResourceManager.ResourceID, logi: vki.LogicalDevice, cbs: ?*vk.AllocationCallbacks) anyerror!void {
                try @as(*T, @ptrCast(@alignCast(p))).init(allocs, idat, r, logi, cbs);
            }
        }.i,
        .cleanupFunc = &struct {
            fn c(p: *anyopaque, allocs: *Allocators, d: vk.Device, cbs: ?*vk.AllocationCallbacks) void {
                const pt: *T = @ptrCast(@alignCast(p));
                defer allocs.std.destroy(pt);
                pt.deinit(allocs, d, cbs);
            }
        }.c,
    };
}
```
If you look at the declarations of each of the functions being passed to the function pointers, you'll see that I am calling functions on the object that has been coerced to `T`. This is unsafe, if I end up sticking with this abstraction I will create some comptime code that validates `T` *can* be made into a `PipelineObject`, but for now I just populate the V-table in an unsafe way.

The idea behind the `PipelineObject` was to be able to encapsulate everything associated with a given pipeline into single types. These types would be created within `tools`, ensuring that they don't leak into the engine itself. However, this was not a good idea. The more I've used this abstraction, the more I've realized that pipelines *should* be baked into the Engine, and having a consumer describe pipelines creates all kinds of dependency cycles with `tools`. Because of the way this is created, I have to know that meshes will be inserted into the engine via the initResources function and then actually access those meshes when the PipelineObject that manages the rendering of those meshes is also initialized. In short; a mess.

## Possible ways forward
As I've been saying throughout this post, many of these systems and the engine architecture are flawed, I don't know the solution to all issues, but I have some ideas.

### `PipelineObject`
As I said `PipelineObject` requires that pipelines be described by *consumers* of `core`, but I need to change that so pipelines are baked into the engine. A way forward for pipeline objects would look something like the following: 
1. Move the creation & declaration of pipelines into `core`
2. Have those pipelines be easily accessible in a human readable by consumers (a `StringHashMap` comes to mind)
3. Have the abstraction that replaces `PipelineObject` have a contract with `core` where they describe what pipeline(s?) they are to be associated with
This introduces a new issue where I need to manage the lifetimes of `PipelineLayout` and `Pipeline` objects. I could just create a single struct that stores both, but Layouts have a longer lifetime that pipelines themselves.. SO i forsee needing to write some way to manager that. I don't think it will need to be particularly complex, but something will need to be done.

### `BoundDescriptor`
An issue with these is that they require code to match places that it doesnt really touch... In other words, the data associated with these is not encapsulated well. Currently, the engine only updates descriptor sets *once* when initialized. This is incorrect. Descriptor sets often need to be updated between draw functions in a single frame, for example, I might have a single descriptor set binding for an image on the GPU that I need to update between calls to draw a texture to a mesh, so i dont need to bind for every single asset I have. This is completely ignored in the current implementation. 
Off the top of my head I think I need to do something similar to what I need to do with pipelines; DescriptorSets and their bindings should be baked into core, and whatevwer abstraction that will replace `BoundDescriptor` needs to tell `core` which set and bindings it is associated with. I am honestly unsure about how to move forward, this will be the last thing I change.

### `ResourceManager`
The `ResourceManager` just needss to be change to manage the mapping of resources to the GPU. I mentioned this earlier but this will probably look like adding some kind of state management to the manager, likely via an enum, to control what the manager should do at certain points in the engine. I would like to remove the resource manager iniliazation function as a parameter to `VulkanEngine.init` and just have the engine take a `ResourceManager` object in its initial state constructed from some assets folder path.

## Conclusion
There is still *so* much work to be done, but I'm proud of where the project is at and I'm excited to move forward. Thank you for reading this post :)
