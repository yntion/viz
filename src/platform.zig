const wl = client.wl;
const xdg = client.xdg;
const client = @import("wayland").client;

const c = @cImport(@cInclude("xcb/xcb.h"));

const Display = union(enum) {
    wayland: struct {
        display: *wl.Display,
        compositor: *wl.Compositor,
        wm_base: *xdg.WmBase,
    },
    xcb: struct {
        conn: *c.xcb_connection_t,
        screen: *c.xcb_screen_t,
    },
};

pub fn Platform(S: type) type {
    return struct {
        configure: Configure,
        state: *S,
        display: Display,

        const Self = @This();
        pub const Configure = struct {
            width: u32,
            height: u32,
        };

        pub fn init(state: *S) !Self {
            const display: Display = if (wl.Display.connect(null)) |display| blk: {
                errdefer display.disconnect();

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

                break :blk .{ .wayland = .{
                    .display = display,
                    .compositor = compositor,
                    .wm_base = wm_base,
                } };
            } else |_| blk: {
                var scr_i: c_int = undefined;
                const conn = c.xcb_connect(null, &scr_i).?;
                errdefer c.xcb_disconnect(conn);
                try cvt(c.xcb_connection_has_error(conn));

                var iter = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
                for (0..@intCast(scr_i)) |_| {
                    c.xcb_screen_next(&iter);
                }

                break :blk .{ .xcb = .{ .conn = conn, .screen = iter.data } };
            };

            return .{
                .configure = .{ .width = 0, .height = 0 },
                .state = state,
                .display = display,
            };
        }

        pub fn getWindow(self: *Self, width: u32, height: u32) !Window {
            switch (self.display) {
                .wayland => |wayland| {
                    const wl_surface = try wayland.compositor.createSurface();
                    errdefer wl_surface.destroy();

                    const xdg_surface = try wayland.wm_base.getXdgSurface(wl_surface);
                    const toplevel = try xdg_surface.getToplevel();
                    errdefer {
                        toplevel.destroy();
                        xdg_surface.destroy();
                    }

                    wl_surface.commit();
                    debug.print("kek\n", .{});

                    toplevel.setListener(*Configure, toplevelListener, &self.configure);
                    xdg_surface.setListener(*Self, xdgSurfaceListener, self);

                    return .{ .wayland = .{ .surface = wl_surface } };
                },
                .xcb => |xcb| {
                    const id = c.xcb_generate_id(xcb.conn);
                    const values: [2]u32 = .{xcb.screen.black_pixel, c.XCB_EVENT_MASK_EXPOSURE};
                    _ = c.xcb_create_window(
                        xcb.conn,
                        c.XCB_COPY_FROM_PARENT,
                        id,
                        xcb.screen.root,
                        0,
                        0,
                        @intCast(width),
                        @intCast(height),
                        50,
                        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
                        xcb.screen.root_visual,
                        c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
                        &values,
                    );
                    _ = c.xcb_map_window(xcb.conn, id);

                    return .{ .xcb = .{ .id = id } };
                },
            }
        }

        pub fn dispatch(self: Self) !void {
            switch (self.display) {
                .wayland => |wayland| {
                    if (wayland.display.dispatch() != .SUCCESS) return error.DispatchFailed;
                },
                .xcb => |xcb| {
                    debug.print("xcb dispatch\n", .{});
                    const event: *c.xcb_generic_event_t = c.xcb_wait_for_event(xcb.conn);
                    defer std.c.free(event);

                    switch (event.response_type & ~@as(c_int, 0x80)) {
                        c.XCB_EXPOSE => debug.print("expose\n", .{}),
                        else => unreachable,
                    }

                },
            }
        }

        fn toplevelListener(toplevel: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *Configure) void {
            _ = toplevel;
            debug.print("toplevel event: {}\n", .{event});

            switch (event) {
                .configure => |configure| {
                    state.width = @intCast(configure.width);
                    state.height = @intCast(configure.height);
                },
                else => {},
            }
        }

        fn xdgSurfaceListener(surface: *xdg.Surface, event: xdg.Surface.Event, platform: *Self) void {
            debug.print("xdg surface event: {}\n", .{event});

            switch (event) {
                .configure => |configure| {
                    surface.ackConfigure(configure.serial);
                    platform.state.handler(platform.configure);

                    //if (state.configure.width == 0 or state.configure.height == 0) {
                    //    state.flags.resize = true;
                    //} else {
                    //    if (state.configure.width != state.width or state.configure.height != state.height) {
                    //        state.width = state.configure.width;
                    //        state.height = state.configure.height;
                    //        state.flags.resize = true;
                    //    }
                    //}
                },
            }
        }
    };
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

const debug = std.debug;
const mem = std.mem;
const std = @import("std");

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

const Window = union(enum) {
    wayland: struct { surface: *wl.Surface },
    xcb: struct {
        id: c.xcb_window_t,
    },
};

const XcbError = error{ Conn, ConnClosedParse };

fn cvt(err: c_int) XcbError!void {
    return switch (err) {
        c.XCB_CONN_ERROR => XcbError.Conn,
        c.XCB_CONN_CLOSED_PARSE_ERR => XcbError.ConnClosedParse,
        0 => {},
        else => unreachable,
    };
}
