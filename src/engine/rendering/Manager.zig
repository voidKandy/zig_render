const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.RenderingManager);
const vk = core.clibs.vk;
const util = core.bindings.vulkan_util;
const vki = core.bindings.vulkan_init;
const checkVk = vki.checkVk;
const Meshes3DResource = core.resources.Meshes3D;
const Allocator = std.mem.Allocator;

pub const Swapchain = @import("./Swapchain.zig");
pub const Meshes3D = @import("./Meshes3D.zig");
pub const Meshes2D = @import("./Meshes2D.zig");
pub const PhysicsDebug = @import("./PhysicsDebug.zig");

meshes3D: ?Meshes3D = null,
meshes2D: ?Meshes2D = null,
physics_debug: ?PhysicsDebug = null,

main_render_pass: vk.RenderPass = undefined,

pub const MAIN_RENDER_PASS_IMAGE_FORMAT = vk.FORMAT_R16G16B16A16_SFLOAT;

pub const CreateInfo = struct {
    physics_debug: ?*const core.engine.Physics.DebugContext,
    meshes3D: bool,
    meshes2D: bool,
};

pub fn init(
    ci: CreateInfo,
) Allocator.Error!@This() {
    const meshes3D =
        if (ci.meshes3D) Meshes3D{} else null;
    const meshes2D =
        if (ci.meshes2D) Meshes2D{} else null;
    const physics_debug =
        if (ci.physics_debug) |db| PhysicsDebug{ .debug_ctx_ptr = db } else null;

    if (meshes2D == null and meshes3D == null)
        @panic("attempted to create empty renderer??");

    return .{
        .meshes2D = meshes2D,
        .meshes3D = meshes3D,
        .physics_debug = physics_debug,
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (self.meshes2D) |*m| m.deinit(allocs, device, alloc_cbs);
    if (self.meshes3D) |*m| m.deinit(allocs, device, alloc_cbs);
    if (self.physics_debug) |*p| p.deinit(allocs, device, alloc_cbs);
    vk.DestroyRenderPass(device, self.main_render_pass, alloc_cbs);
}

pub fn updateSets(
    self: @This(),
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    if (self.meshes2D != null) Meshes2D.updateSets(device, allocated_resources);
    if (self.meshes3D != null) Meshes3D.updateSets(device, allocated_resources);
    if (self.physics_debug != null) PhysicsDebug.updateSets(device, allocated_resources);
}

pub fn registerSetsAndBuffers(
    self: @This(),
    a: Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Allocator.Error!void {
    if (self.meshes2D != null) try Meshes2D.registerSetsAndBuffers(a, device, resources, alloc_cbs);
    if (self.meshes3D != null) try Meshes3D.registerSetsAndBuffers(a, device, resources, alloc_cbs);
    if (self.physics_debug != null) try PhysicsDebug.registerSetsAndBuffers(a, device, resources, alloc_cbs);
}

pub fn getInstances(self: *@This(), a: Allocator, world: *core.engine.world.GameWorld) Allocator.Error!void {
    if (self.meshes2D) |*m| try m.getInstances(a, world);
    if (self.meshes3D) |*m| try m.getInstances(a, world);
}

pub fn syncResources(self: @This(), alloc_resources: *const core.resources.Manager.AllocatedData) void {
    if (self.meshes2D) |m| m.syncResources(alloc_resources);
    if (self.meshes3D) |m| m.syncResources(alloc_resources);
    if (self.physics_debug) |p| p.syncResources(alloc_resources);
}

pub fn initPipelines(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: *const core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (self.meshes2D) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.meshes3D) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.physics_debug) |*p| p.initPipeline(common, resources, alloc_cbs);
}

pub fn recordCommands(
    self: @This(),
    swapchain: *const Swapchain,
    resources: *const core.resources.Manager,
    allocated_resources: *const core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    if (self.meshes3D) |m| m.recordCommands(resources, allocated_resources, cmd);
    if (self.physics_debug) |p| p.recordCommands(allocated_resources, cmd);
    if (self.meshes2D) |m| m.recordCommands(swapchain, resources, allocated_resources, cmd);
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    if (self.meshes2D) |*m| m.drawImgui(ctx);
    if (self.meshes3D) |*m| m.drawImgui(ctx);
    if (self.physics_debug) |*p| p.drawImgui(ctx);
}

pub fn createMainRenderPass(self: *@This(), log_device: vk.Device, phys_device: vki.PhysicalDevice, alloc_cbs: ?*vk.AllocationCallbacks) void {
    const color_attachment = vk.AttachmentDescription{
        .format = MAIN_RENDER_PASS_IMAGE_FORMAT,
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const depth_attachment = vk.AttachmentDescription{
        .format = util.findDepthFormat(phys_device),
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        .finalLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const subpass = vk.SubpassDescription{
        .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachment_ref,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    const all_attachments = &[_]vk.AttachmentDescription{ color_attachment, depth_attachment };

    const ci = vk.RenderPassCreateInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = all_attachments.len,
        .pAttachments = all_attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dpendencyCount = 1,
        .pDependencies = &dependency,
    };

    checkVk(vk.CreateRenderPass(log_device, &ci, alloc_cbs, &self.main_render_pass)) catch @panic("failed to create render pass");
}
pub fn createMainRenderPassNew(
    self: *@This(),
    swapchain: *const Swapchain,
    log_device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const attachment_descriptions = swapchain.attachments.attachmentDescriptions();
    const attachment_references = Swapchain.Attachments.attachmentReferences();

    // const input_attachments = attachment_references.values[@intFromEnum(Swapchain.Attachments.Tags.position)..];

    const subpass_descriptions = [_]vk.SubpassDescription{
        .{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment_references.get(.final),
            .pDepthStencilAttachment = &attachment_references.get(.depth),
            // .inputAttachmentCount = input_attachments.len,
            // .pInputAttachments = &input_attachments,
        },
        // .{
        //     .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
        //     .colorAttachmentCount = 1,
        //     .pColorAttachments = &color_attachment_ref,
        //     .pDepthStencilAttachment = &depth_attachment_ref,
        // },
        // .{
        //     .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
        //     .colorAttachmentCount = 1,
        //     .pColorAttachments = &final_color_attachment_ref,
        //     .inputAttachmentCount = input_references.len,
        //     .pInputAttachments = &input_references,
        // },
    };

    // const subpass = vk.SubpassDescription{
    //     .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
    //     .colorAttachmentCount = 1,
    //     .pColorAttachments = &color_attachment_ref,
    //     .pDepthStencilAttachment = &depth_attachment_ref,
    // };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    // const all_attachments = &[_]vk.AttachmentDescription{ color_attachment, depth_attachment };

    const ci = vk.RenderPassCreateInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachment_descriptions.values.len,
        .pAttachments = &attachment_descriptions.values,
        .subpassCount = subpass_descriptions.len,
        .pSubpasses = &subpass_descriptions,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    checkVk(vk.CreateRenderPass(log_device, &ci, alloc_cbs, &self.main_render_pass)) catch @panic("failed to create render pass");
}
const Resource = struct {
    name: []const u8,
    /// Pixel format (RGBA8, Depth24Stencil8, etc.)
    format: vk.Format,
    /// Dimensions in pixels for 2D resources
    extent: vk.Extent2D,
    /// How this resource will be used (color attachment, texture, etc.)
    usage: vk.ImageUsageFlags,
    /// Expected layout when the frame begins
    initial_layout: vk.ImageLayout,
    /// Required layout when the frame ends
    final_layout: vk.ImageLayout,

    allocated: core.bindings.vma_usage.AllocatedImage = undefined,

    // I assume at a certain point, resources.Manager will hold multiple Meshes3D objects
    // sinces the current implementation batches a bunch of meshes into a single set of buffers for the whole batch
    // when this happens this will likely need to becomes a tupe of []const u8 and Binding to reference a specific buffer
    // for a specific set of meshes
    // meshes3D: Meshes3DResource.Bindings,
    // meshes2D: void,
    // material: []const u8,
    // mapped_buffer: []const u8,
    // For now depth is not stored in resource manager
    // it is instead stored in Swapchain as a vma_usage.AllocatedImage
    // this *should* change down the line
    // depth: void,
};

const Pass = struct {
    name: []const u8, // Descriptive name for debugging and profiling
    inputs: [][]const u8, // Resources this pass reads from (dependencies)
    outputs: [][]const u8, // Resources this pass writes to (products)
    context: *anyopaque,
    execute_func: *const fn (*anyopaque, *vk.CommandBuffer) void,
    deinit_func: *const fn (*anyopaque, Allocator) void,

    pub fn deinit(self: *@This(), a: Allocator) void {
        self.deinit_func(self.context, a);
    }
    pub fn execute(self: *@This(), cmd: *vk.CommandBuffer) void {
        self.execute_func(self.context, cmd);
    }
};

const RenderGraph = struct {
    resources: std.StringHashMapUnmanaged(Resource) = .empty, // All resources referenced in the graph
    passes: std.ArrayListUnmanaged(Pass) = .empty, // All rendering passes in definition order
    execution_order: std.ArrayListUnmanaged(usize) = .empty, // Computed optimal execution sequence

    // Automatic synchronization management
    // These objects ensure correct GPU execution order without manual barriers
    semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .empty, // GPU synchronization primitives
    semaphore_signal_wait_pairs: std.ArrayListUnmanaged(struct { usize, usize }) = .empty,

    /// each `Pass` corresponds to a subpass of the only render pass
    /// this may change later
    render_pass: vk.RenderPass = undefined,

    const Error = (Allocator.Error | error{CycleDetected});

    fn deinit(self: *@This(), a: Allocator) void {
        for (self.passes.items) |*p| p.deinit(a);
        self.resources.deinit(a);
        self.passes.deinit(a);
        self.execution_order.deinit(a);
        self.semaphores.deinit(a);
        self.semaphore_signal_wait_pairs.deinit(a);
    }

    fn addResource(
        self: *@This(),
        a: Allocator,
        name: []const u8,
        resource: Resource,
    ) Allocator.Error!void {
        try self.resources.putNoClobber(a, name, resource);
    }

    fn addPass(
        self: *@This(),
        PassContext: type,
        a: Allocator,
        name: []const u8,
        context: PassContext,
        inputs: [][]const u8,
        outputs: [][]const u8,
    ) Allocator.Error!void {
        const ctx = try a.create(PassContext);
        ctx.* = context;
        const pass = Pass{
            .context = @ptrCast(ctx),
            .inputs = inputs,
            .outputs = outputs,
            .name = name,

            .deinit_func = struct {
                fn d(p: *anyopaque, alloc: Allocator) void {
                    var c: *PassContext = @ptrCast(@alignCast(p));
                    if (@hasDecl(PassContext, "deinit"))
                        c.deinit(alloc);
                    alloc.destroy(c);
                }
            }.d,
            .execute_func = if (@hasDecl(PassContext, "execute"))
                struct {
                    fn e(p: *anyopaque, cmd: *vk.CommandBuffer) void {
                        var c: *PassContext = @ptrCast(@alignCast(p));
                        c.execute(cmd);
                    }
                }.e
            else
                @compileError(std.fmt.comptimePrint(
                    \\ type '{s}' has no public `execute` function?
                , .{@typeName(PassContext)})),
        };
        try self.passes.append(a, pass);
    }

    fn visit(
        self: *@This(),
        alloc: Allocator,
        dependencies: []std.ArrayListUnmanaged(usize),
        node: usize,
        in_stack: *[]bool,
        visited: *[]bool,
    ) Error!void {
        // Cycle detection - circular dependency found
        if (in_stack[node])
            return Error.CycleDetected;

        if (visited[node])
            return; // Already processed this node and its dependencies

        in_stack[node] = true; // Mark as currently being processed
        // Recursively process all passes this one depends on first (post-order traversal),
        // so a producer is always pushed onto executionOrder before its consumers.
        for (dependencies[node].items) |dep| {
            try self.visit(alloc, dependencies, dep, in_stack, visited);
        }

        in_stack[node] = false; // Remove from current path
        visited[node] = true; // Mark as completely processed
        try self.execution_order.append(alloc, node); // Add to execution sequence

    }

    fn compile(
        self: *@This(),
        allocs: core.engine.Allocators,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) Error!void {
        // Dependency Graph Construction
        // Build bidirectional dependency relationships between passes
        var dependencies: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty; // What each pass depends on
        var dependents: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty; // What depends on each pass
        try dependencies.resize(allocs.std, self.passes.items.len);
        try dependents.resize(allocs.std, self.passes.items.len);

        // Track which pass produces each resource (write-after-write dependencies)
        var resource_writers: std.StringHashMapUnmanaged(usize) = .empty;

        defer {
            for (dependencies.items) |d| d.deinit(allocs.std);
            dependencies.deinit(allocs.std);
            for (dependents.items) |d| d.deinit(allocs.std);
            dependents.deinit(allocs.std);
            resource_writers.deinit(allocs.std);
        }
        // Resource Production Registration
        // Register every pass's outputs *before* looking at any inputs, in its own pass over
        // `passes`. Producers and consumers can appear in any order in the `passes` vector -
        // a pass added later might produce a resource a pass added earlier consumes - so
        // dependency discovery below must not assume producers come first positionally.
        for (self.passes.items, 0..) |pass, i| {
            for (pass.outputs) |output| {
                try resource_writers.put(allocs.std, output, i);
            }
        }

        // Dependency Discovery Through Resource Usage Analysis
        // Now that every producer is known, analyze each pass's inputs to determine data flow
        // relationships, regardless of where the producer sits in the passes vector.
        for (self.passes.items, 0..) |pass, i| {
            for (pass.inputs) |input| {
                if (resource_writers.get(input)) |pass_idx| {
                    try dependencies.items[i].append(allocs.std, pass_idx); // This pass depends on the producer
                    try dependents.items[pass_idx].append(allocs.std, i); // Producer has this as dependent
                }
            }
        }

        // Topological Sort for Optimal Execution Order
        // Use depth-first search to compute valid execution sequence while detecting cycles
        var visited: std.ArrayListUnmanaged(bool) = .empty; // Track completed nodes
        var in_stack: std.ArrayListUnmanaged(bool) = .empty; // Track current recursion path

        defer {
            visited.deinit(allocs.std);
            in_stack.deinit(allocs.std);
        }
        {
            try visited.resize(allocs.std, self.passes.items.len);
            try in_stack.resize(allocs.std, self.passes.items.len);
            for (visited.items) |it| it = false;
            for (in_stack.items) |it| it = false;
        }
        // Process all unvisited nodes to handle disconnected graph components
        for (0..self.passes.items.len) |i| {
            if (visited.items[i])
                self.visit(allocs.std, dependencies.items, i, &in_stack.items, &visited.items);
        }

        const semaphore_ci = vk.SemaphoreCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        // Automatic Synchronization Object Creation
        // Generate semaphores for all dependencies identified during analysis
        for (0..self.passes.items.len) |i| {
            for (dependencies.items[i].items) |dep| {
                var semaphore: vk.Semaphore = undefined;

                checkVk(vk.CreateSemaphore(device, &semaphore_ci, alloc_cbs, &semaphore)) catch @panic("failed to create semaphore");
                // Create a GPU semaphore for this dependency relationship
                // The dependent pass will wait on this semaphore before executing
                try self.semaphores.append(allocs.std, semaphore);
                try self.semaphore_signal_wait_pairs.append(allocs.std, .{ dep, i }); // (producer, consumer) pair
            }
        }

        // Physical Resource Allocation and Creation
        // Transform resource descriptions into actual GPU objects
        var rs_iter = self.resources.iterator();
        while (rs_iter.next()) |entry| {
            const resource = entry.value_ptr;
            const ci = vk.ImageCreateInfo{
                .imageType = vk.IMAGE_TYPE_2D,
                .format = resource.format,
                .extent = vk.Extent3D{
                    .width = resource.extent.width,
                    .height = resource.extent.height,
                    .depth = 1,
                },
                .mipLevels = 1,
                .arrayLayers = 1,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .tiling = vk.IMAGE_TILING_OPTIMAL,
                .usage = resource.usage,
                .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
            };

            resource.allocated = core.bindings.vma_usage.AllocatedImage.initWithInfo(allocs.vma, ci);

            const view_ci = vk.ImageViewCreateInfo{
                .image = resource.allocated.image,
                .viewType = vk.IMAGE_VIEW_TYPE_2D,
                .format = resource.format,
                .subresourceRange = vk.ImageSubresourceRange{
                    .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            resource.allocated.createView(view_ci, device, alloc_cbs);
        }
    }

    fn execute(
        self: *const @This(),
        alloc: Allocator,
        cmd: *vk.CommandBuffer,
        queue: vk.Queue,
    ) Error!void {
        _ = cmd;
        _ = queue;
        // Execution state management for dynamic synchronization

        const cmd_buffers: std.ArrayListUnmanaged(vk.CommandBuffer) = .empty; // Command buffer storage
        _ = cmd_buffers;
        const wait_semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .empty; // Synchronization dependencies for current pass
        const wait_stages: std.ArrayListUnmanaged(vk.PipelineStageFlags) = .empty; // Pipeline stages to wait on
        const signal_semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .empty; // Semaphores to signal after current pass

        // Ordered Pass Execution with Automatic Dependency Management
        // Execute each pass in the computed dependency-safe order
        for (self.execution_order.items) |pass_idx| {
            const pass = self.passes.items[pass_idx];
            _ = pass;
            // Synchronization Setup - Collect Dependencies for Current Pass
            // Determine what this pass must wait for before executing

            wait_semaphores.clearRetainingCapacity();
            wait_stages.clearRetainingCapacity();

            for (self.semaphore_signal_wait_pairs.items, 0..) |wait_pair, i| {
                if (wait_pair.@"1" == pass_idx) {
                    try wait_semaphores.append(alloc, self.semaphores.items[i]);
                    try wait_stages.append(alloc, vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
                }
            }

            signal_semaphores.clearRetainingCapacity();

            for (self.semaphore_signal_wait_pairs.items, 0..) |wait_pair, i| {
                if (wait_pair.@"0" == pass_idx) {
                    // Signal completion for dependents
                    try signal_semaphores.append(alloc, self.semaphores.items[i]);
                }
            }

            const pass_info = vk.RenderPassBeginInfo{
                .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            };
            _ = pass_info;
        }

        // Command Buffer Preparation and Resource Layout Transitions
        // Set up command recording and transition resources to appropriate layouts
        // commandBuffer.begin({});                                                   // Begin command recording

        //         // Transition input resources to shader-readable layouts
        //         for (const auto& input : pass.inputs) {
        //             auto& resource = resources[input];

        //             vk::ImageMemoryBarrier barrier;
        //             barrier.setOldLayout(resource.initialLayout)                           // Current resource layout
        //                    .setNewLayout(vk::ImageLayout::eShaderReadOnlyOptimal)          // Target layout for reading
        //                    .setSrcQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)                // No queue family transfer
        //                    .setDstQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)
        //                    .setImage(*resource.image)                                      // Target image
        //                    .setSubresourceRange({vk::ImageAspectFlagBits::eColor, 0, 1, 0, 1})  // Full image range
        //                    .setSrcAccessMask(vk::AccessFlagBits::eMemoryWrite)             // Previous write access
        //                    .setDstAccessMask(vk::AccessFlagBits::eShaderRead);             // Required read access

        //             // Insert pipeline barrier for safe layout transition
        //             commandBuffer.pipelineBarrier(
        //                 vk::PipelineStageFlagBits::eAllCommands,                           // Wait for all previous work
        //                 vk::PipelineStageFlagBits::eFragmentShader,                        // Enable fragment shader access
        //                 vk::DependencyFlagBits::eByRegion,                                 // Region-local dependency
        //                 0, nullptr, 0, nullptr, 1, &barrier                               // Image barrier only
        //             );
        //         }

        //         // Transition output resources to render target layouts
        //         for (const auto& output : pass.outputs) {
        //             auto& resource = resources[output];

        //             vk::ImageMemoryBarrier barrier;
        //             barrier.setOldLayout(resource.initialLayout)                           // Current layout state
        //                    .setNewLayout(vk::ImageLayout::eColorAttachmentOptimal)         // Optimal for color output
        //                    .setSrcQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)
        //                    .setDstQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)
        //                    .setImage(*resource.image)
        //                    .setSubresourceRange({vk::ImageAspectFlagBits::eColor, 0, 1, 0, 1})
        //                    .setSrcAccessMask(vk::AccessFlagBits::eMemoryRead)              // Previous read access
        //                    .setDstAccessMask(vk::AccessFlagBits::eColorAttachmentWrite);   // Required write access

        //             // Insert barrier for safe transition to writable state
        //             commandBuffer.pipelineBarrier(
        //                 vk::PipelineStageFlagBits::eAllCommands,
        //                 vk::PipelineStageFlagBits::eColorAttachmentOutput,                 // Enable color attachment writes
        //                 vk::DependencyFlagBits::eByRegion,
        //                 0, nullptr, 0, nullptr, 1, &barrier
        //             );
        //         }

        //         // Pass Execution - Execute the Actual Rendering Logic
        //         // Call the user-provided rendering function with prepared command buffer
        //         pass.executeFunc(commandBuffer);                                           // Execute pass-specific rendering

        //         // Final Layout Transitions - Prepare Resources for Subsequent Use
        //         // Transition output resources to their final required layouts
        //         for (const auto& output : pass.outputs) {
        //             auto& resource = resources[output];

        //             vk::ImageMemoryBarrier barrier;
        //             barrier.setOldLayout(vk::ImageLayout::eColorAttachmentOptimal)         // Current writable layout
        //                    .setNewLayout(resource.finalLayout)                             // Required final layout
        //                    .setSrcQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)
        //                    .setDstQueueFamilyIndex(VK_QUEUE_FAMILY_IGNORED)
        //                    .setImage(*resource.image)
        //                    .setSubresourceRange({vk::ImageAspectFlagBits::eColor, 0, 1, 0, 1})
        //                    .setSrcAccessMask(vk::AccessFlagBits::eColorAttachmentWrite)    // Previous write operations
        //                    .setDstAccessMask(vk::AccessFlagBits::eMemoryRead);             // Enable subsequent reads

        //             // Insert final barrier for layout transition
        //             commandBuffer.pipelineBarrier(
        //                 vk::PipelineStageFlagBits::eColorAttachmentOutput,                 // After color writes complete
        //                 vk::PipelineStageFlagBits::eAllCommands,                           // Before any subsequent work
        //                 vk::DependencyFlagBits::eByRegion,
        //                 0, nullptr, 0, nullptr, 1, &barrier
        //             );
        //         }

        //         // Command Submission with Synchronization
        //         // Submit command buffer with appropriate dependency and signaling semaphores
        //         commandBuffer.end();                                                       // Finalize command recording

        //         vk::SubmitInfo submitInfo;
        //         submitInfo.setWaitSemaphoreCount(static_cast<uint32_t>(waitSemaphores.size()))      // Dependencies to wait for
        //                   .setPWaitSemaphores(waitSemaphores.data())                                 // Dependency semaphores
        //                   .setPWaitDstStageMask(waitStages.data())                                   // Pipeline stages to wait at
        //                   .setCommandBufferCount(1)                                                  // Single command buffer
        //                   .setPCommandBuffers(&*commandBuffer)                                      // Command buffer to execute
        //                   .setSignalSemaphoreCount(static_cast<uint32_t>(signalSemaphores.size()))  // Semaphores to signal
        //                   .setPSignalSemaphores(signalSemaphores.data());                           // Signal semaphores

        //         queue.submit(1, &submitInfo, nullptr);                                              // Submit to GPU queue
        //     }
    }
};

const MyPass = struct {
    fn execute(self: *@This(), cmd: *vk.CommandBuffer) void {
        _ = self;
        _ = cmd;
    }
    fn deinit(self: *@This(), a: Allocator) void {
        _ = self;
        _ = a;
    }
};
// https://docs.vulkan.org/tutorial/latest/Building_a_Simple_Engine/Engine_Architecture/05_rendering_pipeline.html#_deferred_renderer_setup_g_buffer_resource_configuration
test "gbuffer resource config" {
    const a = std.testing.allocator;

    var graph = RenderGraph{};
    defer graph.deinit(a);

    const mp = MyPass{};
    try graph.addPass(
        MyPass,
        a,
        "my pass",
        mp,
        &[_][]const u8{},
        &[_][]const u8{},
    );

    // const render_3d_pass = Pass{
    //     .name = "render3d",
    //     .inputs = [_][]const u8{},
    //     .outputs = [_][]const u8{},
    //     .execute_func = struct {
    //         fn run(cmd: *vk.CommandBuffer) void {}
    //     },
    // };
}
