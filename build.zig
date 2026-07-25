const std = @import("std");

/// A target upstream ships a linkable SDK for, and the lazy dependency holding it.
const Sdk = struct {
    query: std.Target.Query,
    dep: []const u8,
};

const sdks = [_]Sdk{
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .dep = "slang_macos_aarch64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .dep = "slang_macos_x86_64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }, .dep = "slang_linux_x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, .dep = "slang_linux_aarch64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .dep = "slang_windows_x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu }, .dep = "slang_windows_aarch64" },
};

/// The MSVC-ABI spellings of the Windows targets. Same SDK either way — the DLL
/// and its import library are ABI-neutral, and this binding never crosses a CRT
/// boundary — but building for `-msvc` needs an MSVC installation for the CRT
/// and Windows SDK, which Zig cannot ship. So these are wired only when the host
/// is Windows, where that installation is the one thing likely to be present.
const windows_msvc_sdks = [_]Sdk{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc }, .dep = "slang_windows_x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .msvc }, .dep = "slang_windows_aarch64" },
};

/// Targets Slang supports but ships no *linkable* library for: the binding is
/// compiled for them — which runs its `comptime` ABI asserts — and linking is
/// left to whoever supplies a library.
///
/// Only wasm32-emscripten qualifies. Upstream's sole wasm artifact is Emscripten
/// static archives that `emcc` must link, and being 32-bit it is what exercises
/// the width-dependent half of the ABI: `SlangInt` as `isize`, and the 32-bit
/// branch of the descriptor-layout asserts.
///
/// Deliberately absent, because Slang does not support them: `wasm32-freestanding`
/// (slang.h has no platform branch for it and stops at `#error "unknown target
/// platform"`), and every 32-bit native target — upstream ships no x86 or 32-bit
/// ARM binaries at all, so there is nothing those builds could ever link against.
const compile_only_queries = [_]std.Target.Query{
    .{ .cpu_arch = .wasm32, .os_tag = .emscripten },
};

fn sdkDepName(t: std.Target) ![]const u8 {
    return switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => "slang_macos_aarch64",
            .x86_64 => "slang_macos_x86_64",
            else => error.UnsupportedTargetArch,
        },
        // The Linux archives are glibc builds. Linking one into a musl or
        // Android binary succeeds and then fails at load time, so reject it
        // here rather than ship something that only breaks on the target.
        .linux => if (!t.isGnuLibC()) error.UnsupportedTargetAbi else switch (t.cpu.arch) {
            .aarch64 => "slang_linux_aarch64",
            .x86_64 => "slang_linux_x86_64",
            else => error.UnsupportedTargetArch,
        },
        .windows => switch (t.cpu.arch) {
            .aarch64 => "slang_windows_aarch64",
            .x86_64 => "slang_windows_x86_64",
            else => error.UnsupportedTargetArch,
        },
        else => error.UnsupportedTargetOs,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;

    const all_targets = b.option(
        bool,
        "all-targets",
        "Also build the suite for every other target with an SDK: the six upstream ships, plus the two MSVC-ABI spellings on a Windows host. Fetches all six.",
    ) orelse false;

    const dep_name = try sdkDepName(t);

    const slang_mod = b.addModule("slang", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    slang_mod.linkSystemLibrary("slang", .{});

    const test_step = b.step("test", "Build and run the test suite");

    for (compile_only_queries) |query| {
        const co_target = b.resolveTargetQuery(query);
        const obj = b.addObject(.{
            .name = b.fmt("{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = co_target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&obj.step);
    }

    const dep = b.lazyDependency(dep_name, .{}) orelse {
        b.addNamedLazyPath("slang-runtime-dir", b.addWriteFiles().getDirectory());
        return;
    };
    const runtime_sub = if (t.os.tag == .windows) "bin" else "lib";
    const link_dir = dep.path("lib");
    const runtime_dir = dep.path(runtime_sub);

    slang_mod.addLibraryPath(link_dir);
    // Windows resolves DLLs by search path; an rpath there means nothing.
    if (t.os.tag != .windows) slang_mod.addRPath(runtime_dir);

    try addSuite(b, target, optimize, dep, slang_mod, test_step);

    // Every other SDK target, on request. Off by default because each
    // `lazyDependency` here makes the build runner fetch that SDK (~150 MB
    // unpacked apiece), which a plain `zig build test` has no use for.
    if (all_targets) {
        for (sdks) |sdk| try addSdkSuite(b, sdk, t, optimize, test_step);
        // `-msvc` needs the MSVC CRT, so only a Windows host can build these.
        if (b.graph.host.result.os.tag == .windows) {
            for (windows_msvc_sdks) |sdk| try addSdkSuite(b, sdk, t, optimize, test_step);
        }
    }

    // Shared libraries for a distributed binary: the rpath above points into the
    // package cache, which suits building and testing but not shipping. A
    // consumer installs them itself, from:
    //     zslang_dep.namedLazyPath("slang-runtime-dir")
    b.addNamedLazyPath("slang-runtime-dir", runtime_dir);
}

fn addSdkSuite(
    b: *std.Build,
    sdk: Sdk,
    built: std.Target,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) !void {
    const target = b.resolveTargetQuery(sdk.query);
    const t = target.result;
    if (t.os.tag == built.os.tag and t.cpu.arch == built.cpu.arch and t.abi == built.abi) return;
    const dep = b.lazyDependency(sdk.dep, .{}) orelse return;
    try addSuite(b, target, optimize, dep, null, test_step);
}

fn addSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
    existing_mod: ?*std.Build.Module,
    test_step: *std.Build.Step,
) !void {
    const t = target.result;
    const runtime_sub = if (t.os.tag == .windows) "bin" else "lib";
    const link_dir = dep.path("lib");
    const runtime_dir = dep.path(runtime_sub);

    // A fetched dependency always has a build root; without it there would
    // be no way to put the DLLs on a test's PATH, so fail loudly instead of
    // silently producing tests that cannot load them.
    const dll_dir = if (t.os.tag == .windows)
        b.pathJoin(&.{ dep.builder.build_root.path orelse return error.SdkPathUnavailable, runtime_sub })
    else
        null;

    const slang_mod = existing_mod orelse blk: {
        const m = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.linkSystemLibrary("slang", .{});
        m.addLibraryPath(link_dir);
        if (t.os.tag != .windows) m.addRPath(runtime_dir);
        break :blk m;
    };

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("slang", slang_mod);
    tests_mod.addLibraryPath(link_dir);
    if (t.os.tag != .windows) tests_mod.addRPath(runtime_dir);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = tests_mod }));
    run_tests.skip_foreign_checks = true;
    if (dll_dir) |dir| run_tests.addPathDir(dir);
    test_step.dependOn(&run_tests.step);
}
