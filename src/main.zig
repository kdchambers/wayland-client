// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

var screen_dimensions = geometry.Dimensions2D(u32){
    .width = 1920 / 2,
    .height = 1080 / 2,
};

const compositor_poll_fps: usize = 60;

var frame_buffer_index: usize = 0;
var frame_index: usize = 0;
var initialized: bool = false;

const graphics = struct {
    const Rgba = extern struct {
        pub fn init(r: u8, g: u8, b: u8, a: u8) @This() {
            return .{
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            };
        }

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const Argb = extern struct {
        pub fn init(r: u8, g: u8, b: u8, a: u8) @This() {
            return .{
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            };
        }

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        b: u8,
        g: u8,
        r: u8,
        a: u8,
    };
};

const window_decorations = struct {
    const height_pixels = 30;
    const color = graphics.Argb.init(200, 200, 200, 255);
    const exit_button = struct {
        const size_pixels = 24;
        const color_hovered = graphics.RGBA(f32).fromInt(u8, 180, 180, 180, 255);
    };
};

const bytes_per_pixel: u64 = 4;
const buffer_count: u64 = 2;

var is_shutdown_requested: bool = false;
var is_render_requested: bool = false;
var framebuffer_resized: bool = true;
var wayland_client: WaylandClient = undefined;
var is_drawn: bool = false;

var mouse_coordinates = geometry.Coordinates2D(f64){ .x = 0.0, .y = 0.0 };
var is_mouse_in_screen = false;
var draw_window_decorations_requested: bool = true;
var frame_count: u64 = 0;

const geometry = struct {
    pub fn Coordinates2D(comptime BaseType: type) type {
        return packed struct {
            x: BaseType,
            y: BaseType,
        };
    }

    pub fn Dimensions2D(comptime BaseType: type) type {
        return packed struct {
            height: BaseType,
            width: BaseType,
        };
    }

    pub fn Extent2D(comptime BaseType: type) type {
        return packed struct {
            x: BaseType,
            y: BaseType,
            height: BaseType,
            width: BaseType,

            inline fn isWithinBounds(self: @This(), comptime T: type, point: T) bool {
                const end_x = self.x + self.width;
                const end_y = self.y + self.height;
                return (point.x >= self.x and point.y >= self.y and point.x <= end_x and point.y <= end_y);
            }
        };
    }
};

pub fn main() !void {
    try setup();
    try appLoop();
    waylandDeinit();
    std.log.info("Terminated cleanly", .{});
}

fn appLoop() !void {
    const target_ms_per_frame: u32 = 1000 / compositor_poll_fps;
    const target_ns_per_frame = target_ms_per_frame * std.time.ns_per_ms;

    const app_start_ns: i128 = std.time.nanoTimestamp();

    var poll_count: usize = 0;

    while (!is_shutdown_requested) {
        const frame_start_ns = std.time.nanoTimestamp();

        while (!wayland_client.display.prepareRead()) {
            _ = wayland_client.display.dispatchPending();
        }
        _ = wayland_client.display.flush();

        _ = wayland_client.display.readEvents();
        _ = wayland_client.display.dispatchPending();

        const frame_end_ns = std.time.nanoTimestamp();
        const frame_duration_ns: u64 = @intCast(frame_end_ns - frame_start_ns);

        if (frame_duration_ns < target_ns_per_frame) {
            const remaining_ns: u64 = target_ns_per_frame - @as(u64, @intCast(frame_duration_ns));
            std.time.sleep(remaining_ns);
        }

        poll_count += 1;
    }

    const app_end_ns: i128 = std.time.nanoTimestamp();
    const app_duration_ns: u64 = @intCast(app_end_ns - app_start_ns);

    std.log.info("Poll count: {d}", .{poll_count});
    std.log.info("App duration: {d}ms", .{app_duration_ns / std.time.ns_per_ms});
}

fn draw() !void {
    const pixels_per_frame = screen_dimensions.width * screen_dimensions.height;
    {
        const pixels_ptr: [*]graphics.Argb = @ptrCast(wayland_client.shared_memory_map.ptr);
        const pixels: []graphics.Argb = pixels_ptr[0..pixels_per_frame];
        for (pixels) |*pixel| {
            pixel.a = 255;
            pixel.r = 255;
            pixel.g = 0;
            pixel.b = 255;
        }
    }
    {
        const pixels_ptr: [*]graphics.Argb = @ptrCast(wayland_client.shared_memory_map.ptr);
        const pixels: []graphics.Argb = pixels_ptr[pixels_per_frame .. pixels_per_frame + pixels_per_frame];
        for (pixels) |*pixel| {
            pixel.a = 255;
            pixel.r = 255;
            pixel.g = 0;
            pixel.b = 255;
        }
    }
}

const FrameBuffer = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: []graphics.Argb,
};

fn frameBufferFromIndex(index: usize) FrameBuffer {
    const pixels_per_frame: usize = 1920 * 1080;
    const pixel_offset = if (index == 0) 0 else pixels_per_frame;
    const pixels_ptr: [*]graphics.Argb = @ptrCast(wayland_client.shared_memory_map.ptr);
    const pixels: []graphics.Argb = pixels_ptr[pixel_offset .. pixel_offset + pixels_per_frame];
    return .{
        .width = screen_dimensions.width,
        .height = screen_dimensions.height,
        .pixels = pixels,
        .stride = 1920,
    };
}

fn drawGradient(framebuffer: FrameBuffer) void {
    const color_from = graphics.Argb{ .r = 255, .g = 10, .b = 10, .a = 255 };
    const color_to = graphics.Argb{ .r = 20, .g = 255, .b = 10, .a = 255 };
    const duration_frames: usize = 60 * 10;
    const current_frame: f64 = @floatFromInt(frame_index % duration_frames);
    const progress: f64 = current_frame / @as(f64, @floatFromInt(duration_frames));
    const color_current = graphics.Argb{
        .a = 255,
        .r = @intCast(lerp(color_from.r, color_to.r, progress)),
        .g = @intCast(lerp(color_from.g, color_to.g, progress)),
        .b = @intCast(lerp(color_from.b, color_to.b, progress)),
    };
    drawRect(framebuffer, 0, 0, framebuffer.width, framebuffer.height, color_current);
}

fn drawRect(frame_buffer: FrameBuffer, pos_x: usize, pos_y: usize, width: usize, height: usize, color: graphics.Argb) void {
    const y_min: usize = pos_y;
    const y_max: usize = pos_y + height;
    const x_min: usize = pos_x;
    const x_max: usize = pos_x + width;
    for (y_min..y_max) |y| {
        for (x_min..x_max) |x| {
            frame_buffer.pixels[(y * frame_buffer.stride) + x] = color;
        }
    }
}

fn appDraw() void {
    const framebuffer = frameBufferFromIndex(frame_buffer_index);
    var titlebar_height: usize = 0;
    if (draw_window_decorations_requested) {
        titlebar_height = window_decorations.height_pixels;
        drawRect(framebuffer, 0, 0, screen_dimensions.width, titlebar_height, window_decorations.color);
    }
    const app_body_framebuffer = FrameBuffer{
        .width = screen_dimensions.width,
        .height = @intCast(screen_dimensions.height - titlebar_height),
        .stride = framebuffer.stride,
        .pixels = framebuffer.pixels[framebuffer.stride * titlebar_height ..],
    };
    drawGradient(app_body_framebuffer);
}

fn drawAnimation() void {
    const height_px: usize = 10;
    const width_px: usize = 20;
    const current_x: usize = frame_index % (screen_dimensions.width - width_px);
    const visible_width: usize = @min(screen_dimensions.width - current_x, width_px);
    const frame_buffer = frameBufferFromIndex(frame_buffer_index);
    const pixels = frame_buffer.pixels;

    for (0..height_px) |y| {
        for (0..screen_dimensions.width) |x| {
            const pixel_index: usize = (y * screen_dimensions.width) + x;
            pixels[pixel_index].a = 255;
            pixels[pixel_index].r = 255;
            pixels[pixel_index].g = 0;
            pixels[pixel_index].b = 255;
        }
    }

    for (0..height_px) |y| {
        for (current_x..current_x + visible_width) |x| {
            const pixel_index: usize = (y * screen_dimensions.width) + x;
            pixels[pixel_index].a = 255;
            pixels[pixel_index].r = 25;
            pixels[pixel_index].g = 5;
            pixels[pixel_index].b = 255;
        }
    }
}

fn updateScreen() void {
    std.log.info("frame index: {d}", .{frame_index});
    const pixels_per_frame = screen_dimensions.width * screen_dimensions.height;
    const pixels_ptr: [*]graphics.Argb = @ptrCast(wayland_client.shared_memory_map.ptr);
    const pixel_offset = if (frame_buffer_index == 0) 0 else pixels_per_frame;
    const pixels: []graphics.Argb = pixels_ptr[pixel_offset .. pixel_offset + pixels_per_frame];
    const pixel_value: usize = frame_index % 255;
    for (pixels) |*pixel| {
        pixel.a = 255;
        pixel.r = @intCast(pixel_value);
        pixel.g = @intCast(pixel_value);
        pixel.b = @intCast(pixel_value);
    }
}

fn setup() !void {
    try waylandSetup();
}

const WaylandClient = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    xdg_wm_base: *xdg.WmBase,
    surface: *wl.Surface,
    seat: *wl.Seat,
    pointer: *wl.Pointer,
    frame_callback: *wl.Callback,
    xdg_toplevel: *xdg.Toplevel,
    xdg_surface: *xdg.Surface,
    cursor_theme: *wl.CursorTheme,
    cursor: *wl.Cursor,
    cursor_surface: *wl.Surface,
    xcursor: [:0]const u8,
    shared_memory: *wl.Shm,
    memory_pool: *wl.ShmPool,
    frame_buffers: [2]*wl.Buffer,
    shared_memory_map: []align(4096) u8,
};

const XCursor = struct {
    const hidden = "hidden";
    const left_ptr = "left_ptr";
    const text = "text";
    const xterm = "xterm";
    const hand2 = "hand2";
    const top_left_corner = "top_left_corner";
    const top_right_corner = "top_right_corner";
    const bottom_left_corner = "bottom_left_corner";
    const bottom_right_corner = "bottom_right_corner";
    const left_side = "left_side";
    const right_side = "right_side";
    const top_side = "top_side";
    const bottom_side = "bottom_side";
};

/// Wayland uses linux' input-event-codes for keys and buttons. When a mouse button is
/// clicked one of these will be sent with the event.
/// https://wayland-book.com/seat/pointer.html
/// https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
const MouseButton = enum(c_int) { left = 0x110, right = 0x111, middle = 0x112, _ };

fn xdgWmBaseListener(xdg_wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *WaylandClient) void {
    switch (event) {
        .ping => |ping| {
            xdg_wm_base.pong(ping.serial);
        },
    }
}

fn setupFramebuffers() !void {
    const max_width: usize = 1920;
    const max_height: usize = 1080;

    const bytes_per_frame: u64 = max_width * max_height * bytes_per_pixel;
    const required_memory = bytes_per_frame * buffer_count;

    const shm_name = "/reel_wl_shm2";

    const fd = blk: {
        const oflags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
        break :blk std.c.shm_open(
            shm_name,
            @bitCast(oflags),
            0o644,
        );
    };

    if (fd < 0) {
        return error.OpenSharedMemoryFailed;
    }
    _ = std.c.shm_unlink(shm_name);

    const alignment_padding_bytes: usize = required_memory % std.mem.page_size;
    const allocation_size_bytes: usize = required_memory + (std.mem.page_size - alignment_padding_bytes);
    std.debug.assert(allocation_size_bytes % std.mem.page_size == 0);
    std.debug.assert(allocation_size_bytes <= std.math.maxInt(i32));

    std.log.info("Allocating {} for frames", .{std.fmt.fmtIntSizeDec(allocation_size_bytes)});

    try std.os.ftruncate(fd, allocation_size_bytes);

    wayland_client.shared_memory_map = try std.os.mmap(null, allocation_size_bytes, linux.PROT.READ | linux.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    wayland_client.memory_pool = try wl.Shm.createPool(wayland_client.shared_memory, fd, @intCast(allocation_size_bytes));

    wayland_client.frame_buffers[0] = try wayland_client.memory_pool.createBuffer(
        0,
        @intCast(screen_dimensions.width),
        @intCast(screen_dimensions.height),
        @intCast(bytes_per_pixel * max_width),
        .xrgb8888,
    );

    wayland_client.frame_buffers[1] = try wayland_client.memory_pool.createBuffer(
        bytes_per_frame,
        @intCast(screen_dimensions.width),
        @intCast(screen_dimensions.height),
        @intCast(bytes_per_pixel * max_width),
        .xrgb8888,
    );

    wayland_client.frame_buffers[0].setListener(*const void, bufferListener, &{});
    wayland_client.frame_buffers[1].setListener(*const void, bufferListener, &{});

    try draw();

    initialized = true;
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            std.log.info("Configure event", .{});
            xdg_surface.ackConfigure(configure.serial);
            if (!is_drawn) {
                is_drawn = true;
                setupFramebuffers() catch |err| {
                    std.log.err("Failed to draw initial screen. Error: {}", .{err});
                    return;
                };
                surface.attach(wayland_client.frame_buffers[frame_buffer_index], 0, 0);
                surface.commit();
                frame_buffer_index = (frame_buffer_index + 1) % 2;
            }
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, close_requested: *bool) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.width != screen_dimensions.width) {
                framebuffer_resized = true;
                screen_dimensions.width = @intCast(configure.width);
            }
            if (configure.height > 0 and configure.height != screen_dimensions.height) {
                framebuffer_resized = true;
                screen_dimensions.height = @intCast(configure.height);
            }

            if (initialized and framebuffer_resized) {
                std.log.info("Resizing framebuffer to {d} x {d}", .{ screen_dimensions.width, screen_dimensions.height });
                framebuffer_resized = false;
                resizeWlBuffer(0) catch unreachable;
                resizeWlBuffer(1) catch unreachable;
            }
        },
        .close => close_requested.* = true,
    }
}

fn resizeWlBuffer(buffer_index: usize) !void {
    const max_width: usize = 1920;
    const max_height: usize = 1080;
    const bytes_per_frame: i32 = @intCast(max_width * max_height * bytes_per_pixel);
    const offset: i32 = if (buffer_index == 0) 0 else bytes_per_frame;

    const required_pixels: usize = screen_dimensions.width * screen_dimensions.height;
    const max_pixels: usize = max_width * max_height;
    std.debug.assert(required_pixels <= max_pixels);

    wayland_client.frame_buffers[buffer_index].destroy();
    wayland_client.frame_buffers[buffer_index] = try wayland_client.memory_pool.createBuffer(
        offset,
        @intCast(screen_dimensions.width),
        @intCast(screen_dimensions.height),
        @intCast(bytes_per_pixel * 1920),
        .xrgb8888,
    );
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, client: *WaylandClient) void {
    switch (event) {
        .done => {
            // std.log.info("Frame callback", .{});
            is_render_requested = true;
            callback.destroy();
            client.frame_callback = client.surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                return;
            };
            client.frame_callback.setListener(*WaylandClient, frameListener, client);

            appDraw();

            client.surface.attach(client.frame_buffers[frame_buffer_index], 0, 0);
            client.surface.damageBuffer(0, 0, @intCast(screen_dimensions.width), @intCast(screen_dimensions.height));
            client.surface.commit();

            frame_buffer_index = (frame_buffer_index + 1) % 2;
            frame_index += 1;
        },
    }
}

fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, client: *WaylandClient) void {
    _ = client;
    _ = shm;
    switch (event) {
        .format => |format| {
            std.log.info("Shm format: {}", .{format});
        },
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, client: *WaylandClient) void {
    switch (event) {
        .global => |global| {
            std.log.info("Wayland: {s}", .{global.interface});
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.getInterface().name) == .eq) {
                client.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.getInterface().name) == .eq) {
                client.xdg_wm_base = registry.bind(global.name, xdg.WmBase, 3) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.getInterface().name) == .eq) {
                client.seat = registry.bind(global.name, wl.Seat, 5) catch return;
                client.pointer = client.seat.getPointer() catch return;
                client.pointer.setListener(*WaylandClient, pointerListener, &wayland_client);
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.getInterface().name) == .eq) {
                client.shared_memory = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.getInterface().name) == .eq) {
                //
                // TODO: Negociate with compositor how the window decorations will be drawn
                //
                draw_window_decorations_requested = false;
            }
        },
        .global_remove => |remove| {
            std.log.info("Wayland global removed: {d}", .{remove.name});
        },
    }
}

fn bufferListener(buffer: *wl.Buffer, event: wl.Buffer.Event, _: *const void) void {
    _ = buffer;
    switch (event) {
        .release => {}, // std.log.info("Buffer released", .{}),
    }
}

fn waylandSetup() !void {
    wayland_client.display = try wl.Display.connect(null);
    wayland_client.registry = try wayland_client.display.getRegistry();

    wayland_client.registry.setListener(*WaylandClient, registryListener, &wayland_client);

    if (wayland_client.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    wayland_client.xdg_wm_base.setListener(*WaylandClient, xdgWmBaseListener, &wayland_client);

    wayland_client.surface = try wayland_client.compositor.createSurface();

    wayland_client.xdg_surface = try wayland_client.xdg_wm_base.getXdgSurface(wayland_client.surface);
    wayland_client.xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, wayland_client.surface);

    wayland_client.xdg_toplevel = try wayland_client.xdg_surface.getToplevel();
    wayland_client.xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    wayland_client.xdg_toplevel.setTitle("wayclient");
    wayland_client.xdg_toplevel.setAppId("kdchambers.wayclient");

    wayland_client.shared_memory.setListener(*WaylandClient, shmListener, &wayland_client);
    wayland_client.surface.commit();

    // if (wayland_client.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    wayland_client.frame_callback = try wayland_client.surface.frame();
    wayland_client.frame_callback.setListener(*WaylandClient, frameListener, &wayland_client);

    //
    // Load cursor theme
    //

    // wayland_client.cursor_surface = try wayland_client.compositor.createSurface();

    // const cursor_size = 24;
    // wayland_client.cursor_theme = try wl.CursorTheme.load(null, cursor_size, wayland_client.shared_memory);
    // wayland_client.cursor = wayland_client.cursor_theme.getCursor(XCursor.left_ptr).?;
    // wayland_client.xcursor = XCursor.left_ptr;
}

fn waylandDeinit() void {
    wayland_client.xdg_toplevel.destroy();
    wayland_client.xdg_surface.destroy();
    wayland_client.surface.destroy();

    // wayland_client.cursor_surface.destroy();
    // wayland_client.cursor_theme.destroy();

    wayland_client.shared_memory.destroy();

    wayland_client.pointer.release();
    wayland_client.seat.release();

    wayland_client.xdg_wm_base.destroy();
    wayland_client.compositor.destroy();
    wayland_client.registry.destroy();
    _ = wayland_client.display.flush();
    wayland_client.display.disconnect();
}

fn lerp(from: i64, to: i64, value: f64) i64 {
    std.debug.assert(value <= 1.0);
    std.debug.assert(value >= 0.0);
    const diff: f64 = @floatFromInt(to - from);
    const inc: i64 = @intFromFloat(diff * value);
    return from + inc;
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, client: *WaylandClient) void {
    // _ = client;
    switch (event) {
        .enter => |enter| {
            is_mouse_in_screen = true;
            mouse_coordinates.x = enter.surface_x.toDouble();
            mouse_coordinates.y = enter.surface_y.toDouble();

            //
            // When mouse enters application surface, update the cursor image
            //
            // const image = client.cursor.images[0];
            // const image_buffer = image.getBuffer() catch return;
            // client.cursor_surface.attach(image_buffer, 0, 0);
            // client.pointer.setCursor(enter.serial, client.cursor_surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
            // client.cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            // client.cursor_surface.commit();
        },
        .leave => |leave| {
            _ = leave;
            is_mouse_in_screen = false;
        },
        .motion => |motion| {
            mouse_coordinates.x = motion.surface_x.toDouble();
            mouse_coordinates.y = motion.surface_y.toDouble();
        },
        .button => |button| {
            if (!is_mouse_in_screen) {
                return;
            }
            const mouse_button: MouseButton = @enumFromInt(button.button);
            {
                const mouse_x: u16 = @intFromFloat(mouse_coordinates.x);
                const mouse_y: u16 = @intFromFloat(mouse_coordinates.y);
                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{ mouse_x, mouse_y, screen_dimensions.width, screen_dimensions.height });
                if (mouse_x < 3 and mouse_y < 3) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_left);
                }

                const edge_threshold = 3;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .top_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x > max_width and mouse_y > max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x < edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .left);
                    return;
                }

                if (mouse_x > max_width) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .right);
                    return;
                }

                if (mouse_y <= edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .top);
                    return;
                }

                if (mouse_y == max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom);
                    return;
                }
            }

            if (draw_window_decorations_requested and mouse_button == .left) {
                if (@as(u32, @intFromFloat(mouse_coordinates.y)) <= window_decorations.height_pixels) {
                    client.xdg_toplevel.move(client.seat, button.serial);
                }
            }

            // if (@as(u16, @intFromFloat(mouse_coordinates.y)) > screen_dimensions.height or @as(u16, @intFromFloat(mouse_coordinates.x)) > screen_dimensions.width) {
            //     return;
            // }

            // if (draw_window_decorations_requested and mouse_button == .left) {
            //     // Start interactive window move if mouse coordinates are in window decorations bounds
            //     if (@as(u32, @intFromFloat(mouse_coordinates.y)) <= window_decorations.height_pixels) {
            //         client.xdg_toplevel.move(client.seat, button.serial);
            //     }
            //     const end_x = exit_button_extent.x + exit_button_extent.width;
            //     const end_y = exit_button_extent.y + exit_button_extent.height;
            //     const mouse_x: u16 = @intFromFloat(mouse_coordinates.x);
            //     const mouse_y: u16 = screen_dimensions.height - @as(u16, @intFromFloat(mouse_coordinates.y));
            //     const is_within_bounds = (mouse_x >= exit_button_extent.x and mouse_y >= exit_button_extent.y and mouse_x <= end_x and mouse_y <= end_y);
            //     if (is_within_bounds) {
            //         std.log.info("Close button clicked. Shutdown requested.", .{});
            //         is_shutdown_requested = true;
            //     }
            // }
        },
        .axis => |axis| {
            std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() });
        },
        .frame => |frame| {
            _ = frame;
        },
        .axis_source => |axis_source| {
            std.log.info("Mouse: axis_source {}", .{axis_source.axis_source});
        },
        .axis_stop => |axis_stop| {
            _ = axis_stop;
            std.log.info("Mouse: axis_stop", .{});
        },
        .axis_discrete => |axis_discrete| {
            _ = axis_discrete;
            std.log.info("Mouse: axis_discrete", .{});
        },
    }
}
