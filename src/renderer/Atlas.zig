width: u16,
height: u16,
staging_buffer: void,

pub fn init(power: u4) Atlas {
    const side: u16 = 1 << power;
    const size = side << power;
    _ = size;

    return .{
        .width = side,
        .height = side,
    };
}

pub fn insert(self: *Atlas, bitmap: []const u8) void {}

const Atlas = @This();
