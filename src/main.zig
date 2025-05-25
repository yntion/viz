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

    var renderer: Renderer = try .init(gpa, display, wl_surface);
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

    while (true) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;

        if (state.flags.resize) {
            state.flags.resize = false;

            try renderer.resize(gpa, state.width, state.height);

            debug.print("rendered aaaaaaaaaaaaaaaaa\n", .{});

            try renderer.render(state.width, state.height);
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

const Renderer = struct {
    instance: vk.Instance,
    iw: InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    dw: DeviceWrapper,
    queue: vk.Queue,
    surface: vk.SurfaceKHR,
    frame: Frame,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    swapchain: vk.SwapchainKHR,
    images: std.ArrayListUnmanaged(vk.Image),
    views: std.ArrayListUnmanaged(vk.ImageView),

    const Frame = struct {
        command_pool: vk.CommandPool,
        command_buffer: vk.CommandBuffer,
        image_acquired: vk.Semaphore,
        submitted: vk.Semaphore,
        rendered: vk.Fence,

        fn init(dw: DeviceWrapper, device: vk.Device, queue_family_index: u32) !Frame {
            const command_pool = try dw.createCommandPool(device, &.{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = queue_family_index,
            }, null);
            errdefer dw.destroyCommandPool(device, command_pool, null);

            var command_buffers: [1]vk.CommandBuffer = undefined;
            try dw.allocateCommandBuffers(device, &.{
                .command_pool = command_pool,
                .level = .primary,
                .command_buffer_count = command_buffers.len,
            }, &command_buffers);

            const image_acquired = try dw.createSemaphore(device, &.{}, null);
            errdefer dw.destroySemaphore(device, image_acquired, null);

            const submitted = try dw.createSemaphore(device, &.{}, null);
            errdefer dw.destroySemaphore(device, submitted, null);

            const rendered = try dw.createFence(device, &.{}, null);

            return .{
                .image_acquired = image_acquired,
                .submitted = submitted,
                .rendered = rendered,
                .command_pool = command_pool,
                .command_buffer = command_buffers[0],
            };
        }

        fn deinit(self: Frame, dw: DeviceWrapper, device: vk.Device) void {
            dw.destroySemaphore(device, self.submitted, null);
            dw.destroySemaphore(device, self.image_acquired, null);
            dw.destroyCommandPool(device, self.command_pool, null);
        }
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
        gpa: mem.Allocator,
        display: *wl.Display,
        wl_surface: *wl.Surface,
    ) !Renderer {
        const base = try vk.BaseWrapper(&.{.{ .base_commands = .{ .createInstance = true } }}).load(vkGetInstanceProcAddr);

        const instance = blk: {
            const layers: [1][*:0]const u8 = .{"VK_LAYER_KHRONOS_validation"};
            const extensions: [2][*:0]const u8 = .{ vk.extensions.khr_surface.name, vk.extensions.khr_wayland_surface.name };

            break :blk try base.createInstance(&.{
                .p_application_info = &.{
                    .application_version = 1,
                    .engine_version = 1,
                    .api_version = @bitCast(vk.API_VERSION_1_3),
                },
                .enabled_layer_count = layers.len,
                .pp_enabled_layer_names = &layers,
                .enabled_extension_count = extensions.len,
                .pp_enabled_extension_names = &extensions,
            }, null);
        };

        const iw: InstanceWrapper = try .load(instance, vkGetInstanceProcAddr);
        errdefer iw.destroyInstance(instance, null);

        const physical_devices = try iw.enumeratePhysicalDevicesAlloc(instance, gpa);
        defer gpa.free(physical_devices);

        debug.print("physical devices: {any}\n", .{physical_devices});

        const physical_device = physical_devices[0];
        const queue_families = try iw.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, gpa);
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

        const device = blk: {
            const extensions: [1][*:0]const u8 = .{vk.extensions.khr_swapchain.name};
            const features: vk.PhysicalDeviceVulkan13Features = .{
                .synchronization_2 = vk.TRUE,
                .dynamic_rendering = vk.TRUE,
            };

            break :blk try iw.createDevice(physical_device, &.{
                .p_next = &features,
                .queue_create_info_count = queue_create_infos.len,
                .p_queue_create_infos = &queue_create_infos,
                .enabled_extension_count = extensions.len,
                .pp_enabled_extension_names = &extensions,
            }, null);
        };

        const dw: DeviceWrapper = try .load(device, iw.dispatch.vkGetDeviceProcAddr);
        errdefer dw.destroyDevice(device, null);

        const surface = try iw.createWaylandSurfaceKHR(instance, &.{
            .display = @ptrCast(display),
            .surface = @ptrCast(wl_surface),
        }, null);
        errdefer iw.destroySurfaceKHR(instance, surface, null);

        const frame: Frame = try .init(dw, device, queue_family);
        errdefer frame.deinit(dw, device);

        debug.assert(iw.getPhysicalDeviceWaylandPresentationSupportKHR(physical_device, queue_family, @ptrCast(display)) > 0);

        const queue = dw.getDeviceQueue(device, queue_family, 0);

        const layout, const pipeline = pipeline: {
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

                break :blk try dw.createShaderModule(device, &.{
                    .code_size = vertex_bytecode.len,
                    .p_code = @ptrCast(&vertex_bytecode),
                }, null);
            };
            defer dw.destroyShaderModule(device, vertex_module, null);

            const fragment_module = blk: {
                const fragment_bytecode align(@alignOf(u32)) = @embedFile("fragment").*;

                break :blk try dw.createShaderModule(device, &.{
                    .code_size = fragment_bytecode.len,
                    .p_code = @ptrCast(&fragment_bytecode),
                }, null);
            };
            defer dw.destroyShaderModule(device, fragment_module, null);

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
                .front_face = .counter_clockwise,
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

            const layout = try dw.createPipelineLayout(device, &.{}, null);
            errdefer dw.destroyPipelineLayout(device, layout, null);

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
                    .layout = layout,
                    .subpass = 0,
                    .base_pipeline_index = 0,
                },
            };
            var pipelines: [1]vk.Pipeline = undefined;
            _ = try dw.createGraphicsPipelines(device, .null_handle, create_infos.len, &create_infos, null, &pipelines);

            break :pipeline .{ layout, pipelines[0] };
        };
        errdefer dw.destroyPipelineLayout(device, layout, null);
        errdefer dw.destroyPipeline(device, pipeline, null);

        return .{
            .instance = instance,
            .iw = iw,
            .physical_device = physical_device,
            .device = device,
            .dw = dw,
            .queue = queue,
            .surface = surface,
            .frame = frame,
            .pipeline_layout = layout,
            .pipeline = pipeline,
            .swapchain = .null_handle,
            .images = .empty,
            .views = .empty,
        };
    }

    fn deinit(self: *Renderer, gpa: mem.Allocator) void {
        self.dw.destroyPipeline(self.device, self.pipeline, null);
        self.dw.destroyPipelineLayout(self.device, self.pipeline_layout, null);

        for (self.views.items) |view| {
            self.dw.destroyImageView(self.device, view, null);
        }

        self.views.deinit(gpa);
        self.images.deinit(gpa);

        self.frame.deinit(self.dw, self.device);

        self.dw.destroySwapchainKHR(self.device, self.swapchain, null);
        self.iw.destroySurfaceKHR(self.instance, self.surface, null);
        self.dw.destroyDevice(self.device, null);
        self.iw.destroyInstance(self.instance, null);
    }

    fn resize(
        self: *Renderer,
        gpa: mem.Allocator,
        width: u32,
        height: u32,
    ) !void {
        const capabilities = try self.iw.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);
        debug.print("capabilities: {}\n", .{capabilities});

        const image_count = blk: {
            const image_count = capabilities.min_image_count + 1;
            break :blk if (capabilities.max_image_count == 0) image_count else @min(image_count, capabilities.max_image_count);
        };

        const formats = try self.iw.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface, gpa);
        defer gpa.free(formats);

        debug.print("formats: {any}\n", .{formats});

        const present_modes = try self.iw.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, self.surface, gpa);
        defer gpa.free(present_modes);

        debug.print("present_modes: {any}\n", .{present_modes});

        const swapchain = try self.dw.createSwapchainKHR(self.device, &.{
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
        errdefer self.dw.destroySwapchainKHR(self.device, swapchain, null);

        var images_len: u32 = undefined;
        debug.assert(try self.dw.getSwapchainImagesKHR(self.device, swapchain, &images_len, null) == .success);
        try self.images.resize(gpa, images_len);
        debug.assert(try self.dw.getSwapchainImagesKHR(self.device, swapchain, &images_len, self.images.items[0..images_len].ptr) == .success);
        debug.assert(self.images.items.len == images_len);

        try self.views.ensureTotalCapacity(gpa, images_len);

        while (self.views.pop()) |view| {
            self.dw.destroyImageView(self.device, view, null);
        }

        for (self.images.items) |image| {
            self.views.appendAssumeCapacity(try self.dw.createImageView(self.device, &.{
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

        self.swapchain = swapchain;
    }

    fn render(self: Renderer, width: u32, height: u32) !void {
        debug.assert(self.swapchain != .null_handle);
        debug.assert(self.images.items.len > 0);

        const image_index = (try self.dw.acquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.frame.image_acquired, .null_handle)).image_index;
        const command_buffer = self.frame.command_buffer;

        {
            try self.dw.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
            defer self.dw.endCommandBuffer(command_buffer) catch {};

            {
                const image_barriers: [1]vk.ImageMemoryBarrier2 = .{
                    .{
                        .src_stage_mask = .{ .color_attachment_output_bit = true },
                        .dst_stage_mask = .{ .color_attachment_output_bit = true },
                        .dst_access_mask = .{ .color_attachment_write_bit = true },
                        .old_layout = .undefined,
                        .new_layout = .attachment_optimal,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = self.images.items[image_index],
                        .subresource_range = subresource_range,
                    },
                };
                self.dw.cmdPipelineBarrier2(command_buffer, &.{
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
                            .color = .{ .float_32 = .{ 0.2, 0, 0.3, 0 } },
                        },
                    },
                };
                self.dw.cmdBeginRendering(command_buffer, &.{
                    .render_area = .{
                        .offset = .{ .x = 0, .y = 0 },
                        .extent = .{ .width = width, .height = height },
                    },
                    .layer_count = subresource_range.layer_count,
                    .view_mask = 0,
                    .color_attachment_count = color_attachments.len,
                    .p_color_attachments = &color_attachments,
                });
                defer self.dw.cmdEndRendering(command_buffer);

                self.dw.cmdBindPipeline(command_buffer, .graphics, self.pipeline);

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
                self.dw.cmdSetViewport(command_buffer, 0, viewports.len, &viewports);

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
                self.dw.cmdSetScissor(command_buffer, 0, scissors.len, &scissors);

                self.dw.cmdDraw(command_buffer, 3, 1, 0, 0);
            }

            const image_barriers: [1]vk.ImageMemoryBarrier2 = .{
                .{
                    .src_stage_mask = .{ .color_attachment_output_bit = true },
                    .src_access_mask = .{ .color_attachment_write_bit = true },
                    .old_layout = .attachment_optimal,
                    .new_layout = .present_src_khr,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.images.items[image_index],
                    .subresource_range = subresource_range,
                },
            };
            self.dw.cmdPipelineBarrier2(command_buffer, &.{
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
        try self.dw.queueSubmit2(self.queue, submits.len, &submits, self.frame.rendered);

        const semaphores: [1]vk.Semaphore = .{self.frame.submitted};
        const swapchains: [1]vk.SwapchainKHR = .{self.swapchain};
        const images: [1]u32 = .{image_index};
        _ = try self.dw.queuePresentKHR(self.queue, &.{
            .wait_semaphore_count = semaphores.len,
            .p_wait_semaphores = &semaphores,
            .swapchain_count = swapchains.len,
            .p_swapchains = &swapchains,
            .p_image_indices = &images,
        });

        const fences: [1]vk.Fence = .{self.frame.rendered};
        _ = try self.dw.waitForFences(self.device, fences.len, &fences, vk.TRUE, std.math.maxInt(u64));
        try self.dw.resetFences(self.device, fences.len, &fences);
    }
};

const InstanceWrapper = vk.InstanceWrapper(
    &.{
        .{
            .instance_commands = .{
                .destroyInstance = true,
                .enumeratePhysicalDevices = true,
                .getPhysicalDeviceQueueFamilyProperties = true,
                .createDevice = true,
                .getDeviceProcAddr = true,
                .createWaylandSurfaceKHR = true,
                .destroySurfaceKHR = true,
                .getPhysicalDeviceWaylandPresentationSupportKHR = true,
                .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
                .getPhysicalDeviceSurfaceFormatsKHR = true,
                .getPhysicalDeviceSurfacePresentModesKHR = true,
            },
        },
    },
);

const DeviceWrapper = vk.DeviceWrapper(&.{.{ .device_commands = .{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,
    .createImageView = true,
    .destroyImageView = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .createSemaphore = true,
    .createFence = true,
    .destroySemaphore = true,
    .acquireNextImageKHR = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .cmdPipelineBarrier2 = true,
    .cmdBeginRendering = true,
    .cmdEndRendering = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .queueSubmit2 = true,
    .queuePresentKHR = true,
    .waitForFences = true,
    .resetFences = true,
} }});

const debug = std.debug;

const vk = @import("vulkan");
extern "vulkan" fn vkGetInstanceProcAddr(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

comptime {
    std.testing.refAllDeclsRecursive(@import("renderer/Atlas.zig"));
}
