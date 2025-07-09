pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const compositor, const wm_base = globals: {
        var globals: Globals = .{
            .compositor = null,
            .wm_base = null,
        };

        const registry = try display.getRegistry();
        registry.setListener(*Globals, registryListener, &globals);

        if (display.roundtrip() != .SUCCESS) return error.DispatchFailed;

        break :globals .{ globals.compositor.?, globals.wm_base.? };
    };

    const wl_surface = try compositor.createSurface();
    defer wl_surface.destroy();

    const xdg_surface = try wm_base.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    defer {
        toplevel.destroy();
        xdg_surface.destroy();
    }

    wl_surface.commit();
    debug.print("kek\n", .{});

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer debug.assert(debug_allocator.deinit() == .ok);

    const gpa = debug_allocator.allocator();

    const instance_handle, const instance_wrapper = try setupInstance();
    const instance: vk.InstanceProxy = .init(instance_handle, &instance_wrapper);

    const physical_device, const device_handle, const device_wrapper = try setupDevice(gpa, instance);

    var renderer: Renderer = try .init(
        instance,
        device_handle,
        &device_wrapper,
        physical_device,
        display,
        wl_surface,
    );
    defer renderer.deinit(gpa);

    var state: XdgSurfaceState = .{
        .configure = .{
            .flags = .{ .resize = false },
            .width = 0,
            .height = 0,
        },
        .flags = .{ .resize = false },
        .width = 800,
        .height = 600,
    };

    toplevel.setListener(*XdgSurfaceState, toplevelListener, &state);
    xdg_surface.setListener(*XdgSurfaceState, xdgSurfaceListener, &state);

    const lib: @import("freetype").Library = try .init();
    defer lib.deinit();

    const face = try lib.createFace("/usr/share/fonts/noto/NotoSansMono-Regular.ttf", 0);
    defer face.deinit();

    const font_size = 11.25;
    try face.setCharSize(@round((1 << 6) * font_size * 1.25), 0, 0, 0);

    const global_metrics = face.size().metrics();
    debug.print("face size metrics: {}\n", .{global_metrics});

    const cell_width: u32 = blk: {
        try face.loadChar('e', .{});
        const glyph = face.glyph();
        const metrics = glyph.metrics();
        debug.print("glyph metrics: {}\n", .{metrics});
        debug.assert(glyph.advance().x == metrics.horiAdvance);

        break :blk @intCast(metrics.horiAdvance);
    };
    const cell_height: u32 = @intCast(global_metrics.height >> 6);
    const ascender: u32 = @intCast(global_metrics.ascender >> 6);

    while (true) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;

        if (state.flags.resize) {
            state.flags.resize = false;

            try renderer.resize(gpa, state.width, state.height);

            const row = 0;
            for (renderer.cells.items, "abcdefghij", 0..) |*cell, b, col| {
                try face.loadChar(b, .{
                    .render = true,
                });

                const glyph = face.glyph();
                debug.assert(glyph.format() == .bitmap);

                debug.print("glyph advance: {}\n", .{glyph.advance()});

                const bitmap = glyph.bitmap();
                debug.assert(bitmap.pixelMode() == .gray);
                debug.print("glyph bitmap: {}\n", .{bitmap});

                const glyph_x: u32 = @intCast(col * cell_width + @as(usize, @intCast(glyph.bitmapLeft())));
                const glyph_y: u32 = @intCast(row * cell_height + ascender - @as(usize, @intCast(glyph.bitmapTop())));
                const pitch: u32 = @intCast(bitmap.pitch());
                const uv = try renderer.atlas.insert(bitmap.buffer().?, bitmap.width(), bitmap.rows(), pitch);

                cell.* = .{
                    .position = .{ glyph_x, glyph_y },
                    .uv = uv,
                    .width = bitmap.width(),
                    .height = bitmap.rows(),
                };
            }

            try renderer.render(state.width, state.height);

            debug.print("rendered aaaaaaaaaaaaaaaaa\n", .{});
        }
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            const interface = mem.span(global.interface);

            if (mem.eql(u8, interface, mem.span(wl.Compositor.interface.name)))
                globals.compositor = registry.bind(global.name, wl.Compositor, global.version) catch @panic("expect to bind")
            else if (mem.eql(u8, interface, mem.span(xdg.WmBase.interface.name)))
                globals.wm_base = registry.bind(global.name, xdg.WmBase, global.version) catch @panic("expect to bind");
        },
        .global_remove => {},
    }
}

const Globals = struct {
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
};

fn toplevelListener(toplevel: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *XdgSurfaceState) void {
    _ = toplevel;
    debug.print("toplevel event: {}\n", .{event});

    switch (event) {
        .configure => |configure| {
            state.configure.width = @intCast(configure.width);
            state.configure.height = @intCast(configure.height);
        },
        else => {},
    }
}

fn xdgSurfaceListener(surface: *xdg.Surface, event: xdg.Surface.Event, state: *XdgSurfaceState) void {
    debug.print("xdg surface event: {}\n", .{event});

    switch (event) {
        .configure => |configure| {
            surface.ackConfigure(configure.serial);

            if (state.configure.width == 0 or state.configure.height == 0) {
                state.flags.resize = true;
            } else {
                if (state.configure.width != state.width or state.configure.height != state.height) {
                    state.width = state.configure.width;
                    state.height = state.configure.height;
                    state.flags.resize = true;
                }
            }
        },
    }
}

const XdgSurfaceState = struct {
    configure: struct {
        flags: Flags,
        width: u32,
        height: u32,
    },
    flags: Flags,
    width: u32,
    height: u32,

    const Flags = packed struct { resize: bool };
};

const wl = client.wl;
const xdg = client.xdg;
const client = @import("wayland").client;

const mem = std.mem;
const std = @import("std");

fn setupInstance() !struct { vk.Instance, vk.InstanceWrapper } {
    const instance_handle = blk: {
        const base: vk.BaseWrapper = .load(vkGetInstanceProcAddr);
        const layers: [1][*:0]const u8 = .{"VK_LAYER_KHRONOS_validation"};
        const instance_extensions: [2][*:0]const u8 = .{ vk.extensions.khr_surface.name, vk.extensions.khr_wayland_surface.name };

        break :blk try base.createInstance(&.{
            .p_application_info = &.{
                .application_version = 1,
                .engine_version = 1,
                .api_version = @bitCast(vk.API_VERSION_1_3),
            },
            .enabled_layer_count = layers.len,
            .pp_enabled_layer_names = &layers,
            .enabled_extension_count = instance_extensions.len,
            .pp_enabled_extension_names = &instance_extensions,
        }, null);
    };

    const instance_wrapper: vk.InstanceWrapper = .load(instance_handle, vkGetInstanceProcAddr);
    return .{ instance_handle, instance_wrapper };
}

fn setupDevice(gpa: mem.Allocator, instance: vk.InstanceProxy) !struct { vk.PhysicalDevice, vk.Device, vk.DeviceWrapper } {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(physical_devices);

    debug.print("physical devices: {any}\n", .{physical_devices});

    const physical_device = physical_devices[0];
    const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, gpa);
    defer gpa.free(queue_families);

    debug.print("queue families: {any}\n", .{queue_families});

    const queue_family = 0;
    const queue_priorities: [1]f32 = .{1};
    const queue_create_infos: [1]vk.DeviceQueueCreateInfo = .{
        .{
            .queue_family_index = queue_family,
            .queue_count = queue_priorities.len,
            .p_queue_priorities = &queue_priorities,
        },
    };

    const device_handle = blk: {
        const device_extensions: [1][*:0]const u8 = .{vk.extensions.khr_swapchain.name};
        const features: vk.PhysicalDeviceVulkan13Features = .{
            .synchronization_2 = vk.TRUE,
            .dynamic_rendering = vk.TRUE,
        };

        break :blk try instance.createDevice(physical_device, &.{
            .p_next = &features,
            .queue_create_info_count = queue_create_infos.len,
            .p_queue_create_infos = &queue_create_infos,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .p_enabled_features = &.{
                .sampler_anisotropy = vk.TRUE,
            },
        }, null);
    };

    const device_wrapper: vk.DeviceWrapper = .load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    return .{ physical_device, device_handle, device_wrapper };
}

const Renderer = struct {
    instance: vk.InstanceProxy,
    physical_device: vk.PhysicalDevice,
    vma: c.VmaAllocator,
    atlas: Atlas,
    device: vk.DeviceProxy,
    queue: vk.Queue,
    surface: vk.SurfaceKHR,
    frame: Frame,
    transform: PushConstant.Transform,
    cells: Cells,
    descriptor_set: vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    swapchain: vk.SwapchainKHR,
    images: std.ArrayListUnmanaged(vk.Image),
    views: std.ArrayListUnmanaged(vk.ImageView),

    const Cells = struct {
        buffer: vk.Buffer,
        allocation: c.VmaAllocation,
        items: []Cell,
    };

    const Frame = struct {
        command_pool: vk.CommandPool,
        command_buffer: vk.CommandBuffer,
        image_acquired: vk.Semaphore,
        submitted: vk.Semaphore,
        rendered: vk.Fence,

        fn init(device: vk.DeviceProxy, queue_family_index: u32) !Frame {
            const command_pool = try device.createCommandPool(&.{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = queue_family_index,
            }, null);
            errdefer device.destroyCommandPool(command_pool, null);

            var command_buffers: [1]vk.CommandBuffer = undefined;
            try device.allocateCommandBuffers(&.{
                .command_pool = command_pool,
                .level = .primary,
                .command_buffer_count = command_buffers.len,
            }, &command_buffers);

            const image_acquired = try device.createSemaphore(&.{}, null);
            errdefer device.destroySemaphore(image_acquired, null);

            const submitted = try device.createSemaphore(&.{}, null);
            errdefer device.destroySemaphore(submitted, null);

            const rendered = try device.createFence(&.{}, null);

            return .{
                .image_acquired = image_acquired,
                .submitted = submitted,
                .rendered = rendered,
                .command_pool = command_pool,
                .command_buffer = command_buffers[0],
            };
        }

        fn deinit(self: Frame, device: vk.DeviceProxy) void {
            device.destroySemaphore(self.submitted, null);
            device.destroySemaphore(self.image_acquired, null);
            device.destroyCommandPool(self.command_pool, null);
        }
    };

    const PushConstant = extern struct {
        transform: Transform,
        atlas_side: f32,

        const Transform = extern struct {
            scale_x: f32,
            translate_x: f32,
            scale_y: f32,
            translate_y: f32,
        };
    };

    const format: vk.Format = .b8g8r8a8_srgb;
    const subresource_range: vk.ImageSubresourceRange = .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    fn init(
        instance: vk.InstanceProxy,
        device_handle: vk.Device,
        device_wrapper: *const vk.DeviceWrapper,
        physical_device: vk.PhysicalDevice,
        display: *wl.Display,
        wl_surface: *wl.Surface,
    ) !Renderer {
        const device: vk.DeviceProxy = .init(device_handle, device_wrapper);
        errdefer device.destroyDevice(null);

        var vma: c.VmaAllocator = undefined;
        const res = c.vmaCreateAllocator(&.{
            .physicalDevice = @ptrFromInt(@as(usize, @intFromEnum(physical_device))),
            .device = @ptrFromInt(@as(usize, @intFromEnum(device_handle))),
            .instance = @ptrFromInt(@as(usize, @intFromEnum(instance.handle))),
            .vulkanApiVersion = @bitCast(vk.API_VERSION_1_3),
        }, &vma);
        debug.print("vmaCreateAllocator: {}\n", .{@as(vk.Result, @enumFromInt(res))});
        errdefer c.vmaDestroyAllocator(vma);

        const atlas: Atlas = try .init(vma, 10);
        const atlas_image_view = try device.createImageView(&.{
            .image = atlas.image,
            .view_type = .@"2d",
            .format = .r8_srgb,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = subresource_range,
        }, null);

        const physical_device_properties = instance.getPhysicalDeviceProperties(physical_device);
        const sampler = try device.createSampler(&.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0,
            .anisotropy_enable = vk.TRUE,
            .max_anisotropy = physical_device_properties.limits.max_sampler_anisotropy,
            .compare_enable = vk.FALSE,
            .compare_op = .never,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
        }, null);
        errdefer device.destroySampler(sampler, null);

        const surface = try instance.createWaylandSurfaceKHR(&.{
            .display = @ptrCast(display),
            .surface = @ptrCast(wl_surface),
        }, null);
        errdefer instance.destroySurfaceKHR(surface, null);

        const queue_family = 0;
        const frame: Frame = try .init(device, queue_family);
        errdefer frame.deinit(device);

        debug.assert(instance.getPhysicalDeviceWaylandPresentationSupportKHR(physical_device, queue_family, @ptrCast(display)) > 0);

        const queue = device.getDeviceQueue(queue_family, 0);

        const transform: PushConstant.Transform = .{
            .scale_x = 1,
            .translate_x = 0,
            .scale_y = 1,
            .translate_y = 0,
        };

        const cells: Cells = cells: {
            const buffer_info: vk.BufferCreateInfo = .{
                .size = 10 * @sizeOf(Cell),
                .usage = .{ .storage_buffer_bit = true },
                .sharing_mode = .exclusive,
            };
            const allocation_create_info: c.VmaAllocationCreateInfo = .{
                .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                .usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
            };
            var buffer: vk.Buffer = undefined;
            var allocation: c.VmaAllocation = undefined;
            var allocation_info: c.VmaAllocationInfo = undefined;
            debug.assert(c.vmaCreateBuffer(
                vma,
                @ptrCast(&buffer_info),
                &allocation_create_info,
                @ptrCast(&buffer),
                &allocation,
                &allocation_info,
            ) >= 0);
            const items: []Cell = @as([*]Cell, @alignCast(@ptrCast(allocation_info.pMappedData.?)))[0..10];
            break :cells .{
                .buffer = buffer,
                .allocation = allocation,
                .items = items,
            };
        };

        const descriptor_set_layout, const descriptor_set, const pipeline_layout, const pipeline = pipeline: {
            const attachment_formats: [1]vk.Format = .{format};
            const rendering: vk.PipelineRenderingCreateInfo = .{
                .view_mask = 0,
                .color_attachment_count = attachment_formats.len,
                .p_color_attachment_formats = &attachment_formats,
                .depth_attachment_format = .undefined,
                .stencil_attachment_format = .undefined,
            };

            const vertex_module = blk: {
                const vertex_bytecode align(@alignOf(u32)) = @embedFile("vertex").*;

                break :blk try device.createShaderModule(&.{
                    .code_size = vertex_bytecode.len,
                    .p_code = @ptrCast(&vertex_bytecode),
                }, null);
            };
            defer device.destroyShaderModule(vertex_module, null);

            const fragment_module = blk: {
                const fragment_bytecode align(@alignOf(u32)) = @embedFile("fragment").*;

                break :blk try device.createShaderModule(&.{
                    .code_size = fragment_bytecode.len,
                    .p_code = @ptrCast(&fragment_bytecode),
                }, null);
            };
            defer device.destroyShaderModule(fragment_module, null);

            const stages: [2]vk.PipelineShaderStageCreateInfo = .{ .{
                .stage = .{ .vertex_bit = true },
                .module = vertex_module,
                .p_name = "main",
            }, .{
                .stage = .{ .fragment_bit = true },
                .module = fragment_module,
                .p_name = "main",
            } };

            const dynamic_states: [2]vk.DynamicState = .{ .viewport, .scissor };
            const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
                .dynamic_state_count = dynamic_states.len,
                .p_dynamic_states = &dynamic_states,
            };

            const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{};

            const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };

            const viewport: vk.PipelineViewportStateCreateInfo = .{
                .viewport_count = 1,
                .scissor_count = 1,
            };

            const rasterization: vk.PipelineRasterizationStateCreateInfo = .{
                .depth_clamp_enable = vk.FALSE,
                .rasterizer_discard_enable = vk.FALSE,
                .polygon_mode = .fill,
                .line_width = 1,
                .front_face = .clockwise,
                .depth_bias_enable = vk.FALSE,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
            };

            const multisample: vk.PipelineMultisampleStateCreateInfo = .{
                .rasterization_samples = .{ .@"1_bit" = true },
                .sample_shading_enable = vk.FALSE,
                .min_sample_shading = 0,
                .alpha_to_coverage_enable = vk.FALSE,
                .alpha_to_one_enable = vk.FALSE,
            };

            const attachments: [1]vk.PipelineColorBlendAttachmentState = .{
                .{
                    .blend_enable = vk.FALSE,
                    .src_color_blend_factor = .zero,
                    .dst_color_blend_factor = .zero,
                    .color_blend_op = .add,
                    .src_alpha_blend_factor = .zero,
                    .dst_alpha_blend_factor = .zero,
                    .alpha_blend_op = .add,
                    .color_write_mask = .{
                        .r_bit = true,
                        .g_bit = true,
                        .b_bit = true,
                        .a_bit = true,
                    },
                },
            };
            const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
                .logic_op_enable = vk.FALSE,
                .logic_op = .copy,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .blend_constants = .{ 0, 0, 0, 0 },
            };

            const bindings: [2]vk.DescriptorSetLayoutBinding = .{
                .{
                    .binding = 0,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .vertex_bit = true },
                },
                .{
                    .binding = 1,
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = 1,
                    .stage_flags = .{ .fragment_bit = true },
                },
            };
            const descriptor_set_layouts: [1]vk.DescriptorSetLayout = .{
                try device.createDescriptorSetLayout(
                    &.{
                        .binding_count = bindings.len,
                        .p_bindings = &bindings,
                    },
                    null,
                ),
            };
            errdefer device.destroyDescriptorSetLayout(descriptor_set_layouts[0], null);

            const descriptor_pool = blk: {
                const sizes: [2]vk.DescriptorPoolSize = .{
                    .{
                        .type = .storage_buffer,
                        .descriptor_count = 1,
                    },
                    .{
                        .type = .combined_image_sampler,
                        .descriptor_count = 1,
                    },
                };

                break :blk try device.createDescriptorPool(
                    &.{
                        .pool_size_count = sizes.len,
                        .p_pool_sizes = &sizes,
                        .max_sets = 1,
                    },
                    null,
                );
            };
            errdefer device.destroyDescriptorPool(descriptor_pool, null);

            var descriptor_sets: [1]vk.DescriptorSet = undefined;
            try device.allocateDescriptorSets(&.{
                .descriptor_pool = descriptor_pool,
                .descriptor_set_count = descriptor_sets.len,
                .p_set_layouts = &descriptor_set_layouts,
            }, &descriptor_sets);

            const descriptor_writes: [2]vk.WriteDescriptorSet = .{ .{
                .dst_set = descriptor_sets[0],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = &.{
                    .{
                        .sampler = sampler,
                        .image_view = atlas_image_view,
                        .image_layout = .shader_read_only_optimal,
                    },
                },
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            }, .{
                .dst_set = descriptor_sets[0],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = &.{},
                .p_buffer_info = &.{.{
                    .buffer = cells.buffer,
                    .offset = 0,
                    .range = cells.items.len * @sizeOf(Cell),
                }},
                .p_texel_buffer_view = &.{},
            } };
            device.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, null);

            const push_constant_ranges: [1]vk.PushConstantRange = .{
                .{
                    .stage_flags = .{ .vertex_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PushConstant),
                },
            };

            const pipeline_layout = try device.createPipelineLayout(
                &.{
                    .set_layout_count = descriptor_set_layouts.len,
                    .p_set_layouts = &descriptor_set_layouts,
                    .push_constant_range_count = push_constant_ranges.len,
                    .p_push_constant_ranges = &push_constant_ranges,
                },
                null,
            );
            errdefer device.destroyPipelineLayout(pipeline_layout, null);

            const create_infos: [1]vk.GraphicsPipelineCreateInfo = .{
                .{
                    .p_next = &rendering,
                    .stage_count = stages.len,
                    .p_stages = &stages,
                    .p_vertex_input_state = &vertex_input,
                    .p_input_assembly_state = &input_assembly,
                    .p_viewport_state = &viewport,
                    .p_rasterization_state = &rasterization,
                    .p_multisample_state = &multisample,
                    .p_color_blend_state = &color_blend,
                    .p_dynamic_state = &dynamic_state,
                    .layout = pipeline_layout,
                    .subpass = 0,
                    .base_pipeline_index = 0,
                },
            };
            var pipelines: [1]vk.Pipeline = undefined;
            _ = try device.createGraphicsPipelines(.null_handle, create_infos.len, &create_infos, null, &pipelines);

            break :pipeline .{ descriptor_set_layouts[0], descriptor_sets[0], pipeline_layout, pipelines[0] };
        };
        errdefer device.destroyDescriptorSetLayout(descriptor_set_layout, null);
        errdefer device.destroyDescriptorSet(descriptor_set, null);
        errdefer device.destroyPipelineLayout(pipeline_layout, null);
        errdefer device.destroyPipeline(pipeline, null);

        return .{
            .instance = instance,
            .physical_device = physical_device,
            .vma = vma,
            .atlas = atlas,
            .device = device,
            .queue = queue,
            .surface = surface,
            .frame = frame,
            .transform = transform,
            .cells = cells,
            .descriptor_set = descriptor_set,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .swapchain = .null_handle,
            .images = .empty,
            .views = .empty,
        };
    }

    fn deinit(self: *Renderer, gpa: mem.Allocator) void {
        self.device.destroyPipeline(self.pipeline, null);
        self.device.destroyPipelineLayout(self.pipeline_layout, null);

        for (self.views.items) |view| {
            self.device.destroyImageView(view, null);
        }

        self.views.deinit(gpa);
        self.images.deinit(gpa);

        self.frame.deinit(self.device);

        self.device.destroySwapchainKHR(self.swapchain, null);
        self.instance.destroySurfaceKHR(self.surface, null);
        c.vmaDestroyAllocator(self.vma);
        self.device.destroyDevice(null);
        self.instance.destroyInstance(null);
    }

    fn resize(
        self: *Renderer,
        gpa: mem.Allocator,
        width: u32,
        height: u32,
    ) !void {
        const capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);
        debug.print("capabilities: {}\n", .{capabilities});

        const image_count = blk: {
            const image_count = capabilities.min_image_count + 1;
            break :blk if (capabilities.max_image_count == 0) image_count else @min(image_count, capabilities.max_image_count);
        };

        const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface, gpa);
        defer gpa.free(formats);

        debug.print("formats: {any}\n", .{formats});

        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, self.surface, gpa);
        defer gpa.free(present_modes);

        debug.print("present_modes: {any}\n", .{present_modes});

        const swapchain = try self.device.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = format,
            .image_color_space = .srgb_nonlinear_khr,
            .image_extent = .{
                .width = width,
                .height = height,
            },
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = .mailbox_khr,
            .clipped = vk.TRUE,
            .old_swapchain = self.swapchain,
        }, null);
        errdefer self.device.destroySwapchainKHR(swapchain, null);

        var images_len: u32 = undefined;
        debug.assert(try self.device.getSwapchainImagesKHR(swapchain, &images_len, null) == .success);
        try self.images.resize(gpa, images_len);
        debug.assert(try self.device.getSwapchainImagesKHR(swapchain, &images_len, self.images.items[0..images_len].ptr) == .success);
        debug.assert(self.images.items.len == images_len);

        try self.views.ensureTotalCapacity(gpa, images_len);

        while (self.views.pop()) |view| {
            self.device.destroyImageView(view, null);
        }

        for (self.images.items) |image| {
            self.views.appendAssumeCapacity(try self.device.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = subresource_range,
            }, null));
        }

        debug.assert(self.views.items.len == self.images.items.len);

        self.transform = .{
            .scale_x = 2 / @as(f32, @floatFromInt(width)),
            .translate_x = -1,
            .scale_y = -2 / @as(f32, @floatFromInt(height)),
            .translate_y = 1,
        };

        self.swapchain = swapchain;
    }

    fn render(self: *Renderer, width: u32, height: u32) !void {
        debug.assert(self.swapchain != .null_handle);
        debug.assert(self.images.items.len > 0);

        const image_index = (try self.device.acquireNextImageKHR(self.swapchain, std.math.maxInt(u64), self.frame.image_acquired, .null_handle)).image_index;
        const command_buffer = self.frame.command_buffer;

        {
            try self.device.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
            defer self.device.endCommandBuffer(command_buffer) catch {};

            {
                const atlas_image_transfer: vk.ImageMemoryBarrier2 = .{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .copy_bit = true },
                    .dst_access_mask = .{ .transfer_write_bit = true },
                    .old_layout = .undefined,
                    .new_layout = .transfer_dst_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.atlas.image,
                    .subresource_range = subresource_range,
                };

                const image_barriers: [2]vk.ImageMemoryBarrier2 = .{
                    .{
                        .src_stage_mask = .{},
                        .src_access_mask = .{},
                        .dst_stage_mask = .{ .color_attachment_output_bit = true },
                        .dst_access_mask = .{ .color_attachment_write_bit = true },
                        .old_layout = .undefined,
                        .new_layout = .attachment_optimal,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = self.images.items[image_index],
                        .subresource_range = subresource_range,
                    },
                    atlas_image_transfer,
                };

                self.device.cmdPipelineBarrier2(command_buffer, &.{
                    .image_memory_barrier_count = image_barriers.len,
                    .p_image_memory_barriers = &image_barriers,
                });
            }

            {
                const regions: [1]vk.BufferImageCopy = .{
                    .{
                        .buffer_offset = 0,
                        .buffer_row_length = 0,
                        .buffer_image_height = 0,
                        .image_subresource = .{
                            .aspect_mask = .{ .color_bit = true },
                            .mip_level = 0,
                            .base_array_layer = 0,
                            .layer_count = 1,
                        },
                        .image_offset = .{
                            .x = 0,
                            .y = 0,
                            .z = 0,
                        },
                        .image_extent = .{
                            .width = self.atlas.width,
                            .height = self.atlas.height,
                            .depth = 1,
                        },
                    },
                };

                self.device.cmdCopyBufferToImage(
                    command_buffer,
                    self.atlas.buffer,
                    self.atlas.image,
                    .transfer_dst_optimal,
                    regions.len,
                    &regions,
                );

                const atlas_image_shader_read: vk.ImageMemoryBarrier2 = .{
                    .src_stage_mask = .{
                        .copy_bit = true,
                    },
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_stage_mask = .{ .fragment_shader_bit = true },
                    .dst_access_mask = .{ .shader_sampled_read_bit = true },
                    .old_layout = .transfer_dst_optimal,
                    .new_layout = .shader_read_only_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.atlas.image,
                    .subresource_range = subresource_range,
                };

                const image_barriers: [1]vk.ImageMemoryBarrier2 = .{
                    atlas_image_shader_read,
                };

                self.device.cmdPipelineBarrier2(command_buffer, &.{
                    .image_memory_barrier_count = image_barriers.len,
                    .p_image_memory_barriers = &image_barriers,
                });
            }

            {
                const color_attachments: [1]vk.RenderingAttachmentInfo = .{
                    .{
                        .image_view = self.views.items[image_index],
                        .image_layout = .attachment_optimal,
                        .resolve_mode = .{},
                        .resolve_image_layout = .undefined,
                        .load_op = .clear,
                        .store_op = .store,
                        .clear_value = .{
                            .color = .{ .float_32 = .{ 0, 0, 0, 0} },
                        },
                    },
                };
                self.device.cmdBeginRendering(command_buffer, &.{
                    .render_area = .{
                        .offset = .{ .x = 0, .y = 0 },
                        .extent = .{ .width = width, .height = height },
                    },
                    .layer_count = subresource_range.layer_count,
                    .view_mask = 0,
                    .color_attachment_count = color_attachments.len,
                    .p_color_attachments = &color_attachments,
                });
                defer self.device.cmdEndRendering(command_buffer);

                self.device.cmdBindPipeline(command_buffer, .graphics, self.pipeline);

                const viewports: [1]vk.Viewport = .{
                    .{
                        .x = 0,
                        .y = 0,
                        .width = @floatFromInt(width),
                        .height = @floatFromInt(height),
                        .min_depth = 0,
                        .max_depth = 1,
                    },
                };
                self.device.cmdSetViewport(command_buffer, 0, viewports.len, &viewports);

                const scissors: [1]vk.Rect2D = .{
                    .{
                        .offset = .{
                            .x = 0,
                            .y = 0,
                        },
                        .extent = .{
                            .width = width,
                            .height = height,
                        },
                    },
                };
                self.device.cmdSetScissor(command_buffer, 0, scissors.len, &scissors);

                const descriptor_sets: [1]vk.DescriptorSet = .{
                    self.descriptor_set,
                };
                self.device.cmdBindDescriptorSets(
                    command_buffer,
                    .graphics,
                    self.pipeline_layout,
                    0,
                    descriptor_sets.len,
                    &descriptor_sets,
                    0,
                    null,
                );

                const push_constant = mem.asBytes(&@as(
                    PushConstant,
                    .{
                        .transform = self.transform,
                        .atlas_side = @floatFromInt(self.atlas.width),
                    },
                ));
                self.device.cmdPushConstants(
                    command_buffer,
                    self.pipeline_layout,
                    .{ .vertex_bit = true },
                    0,
                    push_constant.len,
                    push_constant,
                );

                self.device.cmdDraw(command_buffer, @intCast(self.cells.items.len * 6), 1, 0, 0);
            }

            const image_barriers: [1]vk.ImageMemoryBarrier2 = .{
                .{
                    .src_stage_mask = .{ .color_attachment_output_bit = true },
                    .src_access_mask = .{ .color_attachment_write_bit = true },
                    .dst_stage_mask = .{},
                    .dst_access_mask = .{},
                    .old_layout = .attachment_optimal,
                    .new_layout = .present_src_khr,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.images.items[image_index],
                    .subresource_range = subresource_range,
                },
            };
            self.device.cmdPipelineBarrier2(command_buffer, &.{
                .image_memory_barrier_count = image_barriers.len,
                .p_image_memory_barriers = &image_barriers,
            });
        }

        const command_buffer_infos: [1]vk.CommandBufferSubmitInfo = .{
            .{
                .command_buffer = command_buffer,
                .device_mask = 0,
            },
        };
        const wait_semaphores: [1]vk.SemaphoreSubmitInfo = .{
            .{
                .semaphore = self.frame.image_acquired,
                .value = 0,
                .stage_mask = .{ .color_attachment_output_bit = true },
                .device_index = 0,
            },
        };
        const signal_semaphores: [1]vk.SemaphoreSubmitInfo = .{.{
            .semaphore = self.frame.submitted,
            .value = 0,
            .device_index = 0,
        }};
        const submits: [1]vk.SubmitInfo2 = .{
            .{
                .wait_semaphore_info_count = wait_semaphores.len,
                .p_wait_semaphore_infos = &wait_semaphores,
                .command_buffer_info_count = command_buffer_infos.len,
                .p_command_buffer_infos = &command_buffer_infos,
                .signal_semaphore_info_count = signal_semaphores.len,
                .p_signal_semaphore_infos = &signal_semaphores,
            },
        };
        try self.device.queueSubmit2(self.queue, submits.len, &submits, self.frame.rendered);

        const semaphores: [1]vk.Semaphore = .{self.frame.submitted};
        const swapchains: [1]vk.SwapchainKHR = .{self.swapchain};
        const images: [1]u32 = .{image_index};
        _ = try self.device.queuePresentKHR(self.queue, &.{
            .wait_semaphore_count = semaphores.len,
            .p_wait_semaphores = &semaphores,
            .swapchain_count = swapchains.len,
            .p_swapchains = &swapchains,
            .p_image_indices = &images,
        });

        const fences: [1]vk.Fence = .{self.frame.rendered};
        _ = try self.device.waitForFences(fences.len, &fences, vk.TRUE, std.math.maxInt(u64));
        try self.device.resetFences(fences.len, &fences);
    }

    const Cell = extern struct {
        position: @Vector(2, u32),
        uv: @Vector(2, f32),
        width: u32,
        height: u32,
    };
};

const debug = std.debug;
const vk = @import("vulkan");
const c = @import("Renderer/vma.zig").c;
extern "vulkan" fn vkGetInstanceProcAddr(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;
const Atlas = @import("Renderer/Atlas.zig");

comptime {
    std.testing.refAllDeclsRecursive(@import("Renderer/Atlas.zig"));
}
