width: u16,
height: u16,
row_extent: u32,
row_baseline: u32,
row_height: u32,
image: vk.Image,
buffer: vk.Buffer,
mapping: []u8,

pub fn init(vma: c.VmaAllocator, power: u4) !Atlas {
    const side = @as(u16, 1) << power;
    const size = @as(u32, side) << power;

    var buffer: vk.Buffer = undefined;
    var buffer_allocation: c.VmaAllocation = undefined;
    var buffer_allocation_info: c.VmaAllocationInfo = undefined;

    const buffer_info: vk.BufferCreateInfo = .{
        .size = size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    };

    var res = c.vmaCreateBuffer(
        vma,
        @ptrCast(&buffer_info),
        &.{
            .flags = c.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT | c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
            .usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
        },
        @ptrCast(&buffer),
        @ptrCast(&buffer_allocation),
        @ptrCast(&buffer_allocation_info),
    );
    debug.print("vmaCreateBuffer: {}\n", .{@as(vk.Result, @enumFromInt(res))});
    errdefer c.vmaDestroyBuffer(vma, buffer, buffer_allocation);

    const mapping = blk: {
        const mapping: [*]u8 = @ptrCast(buffer_allocation_info.pMappedData);
        break :blk mapping[0..size];
    };

    var image: vk.Image = undefined;
    var image_allocation: c.VmaAllocation = undefined;
    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = .r8_srgb,
        .extent = .{ .width = side, .height = side, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };

    res = c.vmaCreateImage(
            vma,
            @ptrCast(&image_info),
            &.{
                .usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
            },
            @ptrCast(&image),
            @ptrCast(&image_allocation),
            null,
    );
    errdefer c.vmaDestroyImage(vma, image, image_allocation);
    debug.print("vmaCreateImage: {}\n", .{@as(vk.Result, @enumFromInt(res))});

//    const memory_properties = instance.getPhysicalDeviceMemoryProperties(physical_device);
//    const memory_types = memory_properties.memory_types[0..memory_properties.memory_type_count];
//    const memory_heaps = memory_properties.memory_heaps[0..memory_properties.memory_heap_count];
//
//    debug.print("memory_types: {any}\n", .{memory_types});
//    debug.print("memory_heaps: {any}\n", .{memory_heaps});
//
//    const buffer = try device.createBuffer(&.{
//        .size = size,
//        .usage = .{ .transfer_src_bit = true },
//        .sharing_mode = .exclusive,
//    }, null);
//    errdefer device.destroyBuffer(buffer, null);
//
//    const image = try device.createImage(&.{
//        .image_type = .@"2d",
//        .format = .r8_srgb,
//        .extent = .{ .width = side, .height = side, .depth = 1 },
//        .mip_levels = 1,
//        .array_layers = 1,
//        .samples = .{ .@"1_bit" = true },
//        .tiling = .optimal,
//        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
//        .sharing_mode = .exclusive,
//        .initial_layout = .undefined,
//    }, null);
//
//    const buffer_memory_requirements = device.getBufferMemoryRequirements(buffer);
//    const image_memory_requirements = device.getImageMemoryRequirements(image);
//
//    debug.print("buffer_memory_requirements: {}\n", .{buffer_memory_requirements});
//    debug.print("image_memory_requirements: {}\n", .{image_memory_requirements});
//
//    const memory_property_flags: vk.MemoryPropertyFlags = .{ .host_visible_bit = true, .host_coherent_bit = true };
//    const memory_type_idx: u32 = for (memory_types, 0..) |memory_type, i| {
//        const bits: u32 = @bitCast(memory_type.property_flags);
//        const mask: u32 = @bitCast(memory_property_flags);
//
//        if (buffer_memory_requirements.memory_type_bits & 1 << 1 > 0 and bits & mask == mask) {
//            break @intCast(i);
//        }
//    } else @panic("f");
//
//    const buffer_memory = try device.allocateMemory(&.{
//        .allocation_size = buffer_memory_requirements.size,
//        .memory_type_index = memory_type_idx,
//    }, null);
//    errdefer device.freeMemory(buffer_memory, null);
//
//    try device.bindBufferMemory(buffer, buffer_memory, 0);
//
//    const mapping: [*]u8 = blk: {
//        const mapping = try device.mapMemory(buffer_memory, 0, size, .{});
//        break :blk @ptrCast(mapping.?);
//    };
//
//    return .{
//        .width = side,
//        .height = side,
//        .buffer = buffer,
//        .buffer_memory = buffer_memory,
//        .mapping = mapping[0..size],
//        .row_extent = 0,
//        .row_baseline = 0,
//        .row_height = 0,
//    };

    return .{
        .width = side,
        .height = side,
        .row_extent = 0,
        .row_baseline = 0,
        .row_height = 0,
        .image = image,
        .buffer = buffer,
        .mapping = mapping,
    };
}

fn deinit(self: Atlas) void {
    _ = self;
}

pub fn insert(self: *Atlas, bitmap: []const u8, width: u32, height: u32, pitch: u32) !struct { f32, f32 } {
    debug.assert(bitmap.len == height * pitch);
    debug.assert(self.width == self.height);

    if (width > self.width - self.row_extent) {
        self.row_extent = 0;
        self.row_baseline += self.row_height;
        self.row_height = 0;
    }

    debug.assert(height <= self.height - self.row_baseline);
    debug.assert(width <= self.width - self.row_extent);

    const side: f32 = @floatFromInt(self.width);
    const u = @as(f32, @floatFromInt(self.row_baseline)) / side;
    const v = @as(f32, @floatFromInt(self.row_extent)) / side;

    for (0..height) |y| {
        const dst = self.mapping[(self.row_baseline + y) * self.width + self.row_extent..][0..width];
        const src = bitmap[y * pitch..][0..width];

        @memcpy(dst, src);
    }

    if (height > self.row_height) self.row_height = height;
    self.row_extent += width;

    return .{ u, v };
}

test {
    _ = Atlas.init(undefined, 10);
}

const c = @import("vma.zig").c;
const vk = @import("vulkan");
const Atlas = @This();
const debug = std.debug;
const std = @import("std");
