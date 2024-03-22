// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Keith Chambers

const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_protocols: [2][]const u8 = .{
        "stable/xdg-shell/xdg-shell.xml",
        "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
    };

    const interface_list: [5][]const u8 = .{
        "xdg_wm_base 2",
        "wl_compositor 4",
        "wl_seat 5",
        "wl_shm 1",
        "zxdg_decoration_manager_v1 1",
    };

    const wayland_dep = b.dependency("zig_wayland", .{
        .generate_interfaces = @as([]const []const u8, &interface_list),
        .system_protocols = @as([]const []const u8, &system_protocols),
    });
    const wayland_module = wayland_dep.module("zig_wayland");

    const exe = b.addExecutable(.{
        .name = "wayland_client",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("wayland", wayland_module);

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-cursor");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run wayland_client");
    run_step.dependOn(&run_cmd.step);
}
