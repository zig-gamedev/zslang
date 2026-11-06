const std = @import("std");
const testing = std.testing;

const slang = @import("slang");

test "verifyAbi passes against the linked libslang" {
    try slang.verifyAbi(std.testing.allocator);
}

test "compile a trivial Slang module to MSL" {
    const two_entry_points =
        \\[shader("vertex")]
        \\float4 vsMain(uint id : SV_VertexID) : SV_Position {
        \\    return float4(float(id), 0, 0, 1);
        \\}
        \\
        \\[shader("fragment")]
        \\float4 fsMain() : SV_Target {
        \\    return float4(1, 0, 0, 1);
        \\}
    ;

    const gpa = std.testing.allocator;

    const global = try slang.GlobalSession.create();
    defer global.deinit();

    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const blob = slang.util.compileAndLinkProgramToTargetCode(gpa, global, .{
        .source = two_entry_points,
        .module_name = "smoke",
        .path = "smoke.slang",
        .format = .metal,
        // Metal codegen conventionally wants column-major.
        .matrix_layout = .column_major,
    }, &diag) catch |err| {
        std.debug.print("compile failed: {s}\ndiagnostics: {s}\n", .{ @errorName(err), diag.text() });
        return err;
    };
    defer blob.deinit();

    const msl = blob.bytes();
    // A non-empty blob means the `IBlob` pointer/length slots read back the
    // buffer Slang actually produced, and both entry-point names surviving to
    // the output means discovery and composition included each of them. Those
    // names come from the source above, so they track this binding rather than
    // Slang's codegen style — nothing here asserts how Slang spells its
    // preamble or its stage attributes, which is Slang's business to change.
    try std.testing.expect(msl.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl, "vsMain") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "fsMain") != null);
}

test "a broken module surfaces diagnostics, not a crash" {
    const gpa = std.testing.allocator;

    const global = try slang.GlobalSession.create();
    defer global.deinit();

    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const bad = "[shader(\"vertex\")] float4 vsMain() : SV_Position { return nope; }";
    const result = slang.util.compileAndLinkProgramToTargetCode(gpa, global, .{
        .source = bad,
        .format = .metal,
    }, &diag);
    try std.testing.expectError(slang.Error.LoadModuleFailed, result);
    try std.testing.expect(diag.text().len > 0);
}

fn mslHasAttr(msl: []const u8, comptime kind: []const u8, index: u32) !bool {
    var buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "[[" ++ kind ++ "({d})]]", .{index});
    return std.mem.indexOf(u8, msl, needle) != null;
}

test "reflect a uniform buffer + texture + sampler and verify layout/bindings" {
    const source =
        \\struct Material {
        \\    float4x4 transform;   // 0
        \\    float4   base_color;  // 64
        \\    float2   tiling;      // 80
        \\    float    roughness;   // 88
        \\    uint     flags;       // 92
        \\};                        // size 96
        \\
        \\ConstantBuffer<Material> material;
        \\Texture2D<float4>        albedo_tex;
        \\SamplerState             tex_sampler;
        \\
        \\[shader("fragment")]
        \\float4 fsMain(float2 uv : TEXCOORD0) : SV_Target {
        \\    float4 c = material.base_color;
        \\    c *= albedo_tex.Sample(tex_sampler, uv * material.tiling);
        \\    c.a *= material.roughness;
        \\    c += material.transform[0];
        \\    if (material.flags != 0u) c.rgb *= 0.5;
        \\    return c;
        \\}
    ;

    // Hand-computed Metal uniform-layout offsets/sizes for `Material`.
    const expected_fields = [_]struct { name: []const u8, offset: usize, size: usize }{
        .{ .name = "transform", .offset = 0, .size = 64 },
        .{ .name = "base_color", .offset = 64, .size = 16 },
        .{ .name = "tiling", .offset = 80, .size = 8 },
        .{ .name = "roughness", .offset = 88, .size = 4 },
        .{ .name = "flags", .offset = 92, .size = 4 },
    };

    const gpa = std.testing.allocator;

    const global = try slang.GlobalSession.create();
    defer global.deinit();

    // Guard: the linked libslang is the version this binding pins.
    try std.testing.expectEqualStrings(slang.version, slang.buildTag());

    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const program = slang.util.compileAndLinkProgram(gpa, global, .{
        .source = source,
        .module_name = "material",
        .path = "material.slang",
        .format = .metal,
        .matrix_layout = .column_major,
    }, &diag) catch |err| {
        std.debug.print("compile failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
        return err;
    };
    defer program.deinit();

    const code = try program.getTargetCode(&diag);
    defer code.deinit();
    const msl = code.bytes();
    const layout = try program.getLayout(&diag);

    // ---- entry point ----
    try std.testing.expectEqual(@as(u32, 1), layout.entryPointCount());
    const ep = layout.entryPointByIndex(0).?;
    try std.testing.expectEqualStrings("fsMain", ep.name());
    try std.testing.expectEqual(slang.Stage.fragment, ep.stage());

    // ---- global shader parameters ----
    var buffer_param: ?slang.VariableLayout = null;
    var texture_param: ?slang.VariableLayout = null;
    var sampler_param: ?slang.VariableLayout = null;

    var i: u32 = 0;
    while (i < layout.parameterCount()) : (i += 1) {
        const p = layout.parameterByIndex(i).?;
        // A Metal target spells these `metal_buffer`/`metal_texture`/
        // `metal_sampler`; they are aliases for the same three category values.
        switch (p.category()) {
            .constant_buffer => buffer_param = p,
            .shader_resource => texture_param = p,
            .sampler_state => sampler_param = p,
            else => {},
        }
    }

    const bufp = buffer_param orelse return error.NoBufferParam;
    const texp = texture_param orelse return error.NoTextureParam;
    const smpp = sampler_param orelse return error.NoSamplerParam;

    // ---- binding indices must match the attributes Slang emitted in the MSL ----
    try std.testing.expect(try mslHasAttr(msl, "buffer", bufp.bindingIndex()));
    try std.testing.expect(try mslHasAttr(msl, "texture", texp.bindingIndex()));
    try std.testing.expect(try mslHasAttr(msl, "sampler", smpp.bindingIndex()));

    // ---- categories ----
    try std.testing.expectEqual(slang.ParameterCategory.constant_buffer, bufp.category());
    try std.testing.expectEqual(slang.ParameterCategory.shader_resource, texp.category());
    try std.testing.expectEqual(slang.ParameterCategory.sampler_state, smpp.category());

    // ---- constant-buffer struct layout ----
    const cb_type = bufp.typeLayout().?;
    try std.testing.expectEqual(slang.TypeKind.constant_buffer, cb_type.kind());
    const elem = cb_type.elementTypeLayout().?;
    try std.testing.expectEqualStrings("Material", elem.name());
    try std.testing.expectEqual(@as(u32, expected_fields.len), elem.fieldCount());
    try std.testing.expectEqual(@as(usize, 96), elem.size(.uniform));

    var f: u32 = 0;
    while (f < elem.fieldCount()) : (f += 1) {
        const field = elem.fieldByIndex(f).?;
        const ft = field.typeLayout().?;
        try std.testing.expectEqualStrings(expected_fields[f].name, field.name());
        try std.testing.expectEqual(expected_fields[f].offset, field.offset(.uniform));
        try std.testing.expectEqual(expected_fields[f].size, ft.size(.uniform));
    }

    // ---- scalar-kind classification (what a uniform-struct emitter keys on) ----
    // roughness is float32, flags is uint32.
    const roughness = elem.fieldByIndex(3).?.typeLayout().?;
    const flags = elem.fieldByIndex(4).?.typeLayout().?;
    try std.testing.expectEqual(slang.TypeKind.scalar, roughness.kind());
    try std.testing.expectEqual(slang.ScalarType.float32, roughness.scalarType());
    try std.testing.expectEqual(slang.ScalarType.uint32, flags.scalarType());

    // transform is a matrix, base_color a vector.
    const transform = elem.fieldByIndex(0).?.typeLayout().?;
    const base_color = elem.fieldByIndex(1).?.typeLayout().?;
    const tiling = elem.fieldByIndex(2).?.typeLayout().?;
    try std.testing.expectEqual(slang.TypeKind.matrix, transform.kind());
    try std.testing.expectEqual(slang.TypeKind.vector, base_color.kind());

    // ---- shape accessors ----
    // A float4x4 is 4x4; a vector reports one row and its length in columns,
    // which `elementCount` repeats. `stride` is the field's own extent.
    try std.testing.expectEqual(@as(u32, 4), transform.rowCount());
    try std.testing.expectEqual(@as(u32, 4), transform.columnCount());
    try std.testing.expectEqual(@as(usize, 64), transform.stride(.uniform));
    try std.testing.expectEqual(@as(u32, 1), base_color.rowCount());
    try std.testing.expectEqual(@as(u32, 4), base_color.columnCount());
    try std.testing.expectEqual(@as(usize, 4), base_color.elementCount());
    try std.testing.expectEqual(@as(u32, 2), tiling.columnCount());
    try std.testing.expectEqual(@as(usize, 2), tiling.elementCount());
    try std.testing.expectEqual(@as(usize, 8), tiling.stride(.uniform));

    // ---- the type behind the layout ----
    // `reflectedType` reaches what a layout cannot answer. For the constant
    // buffer the two agree; for a matrix they differ by one level: the element
    // *layout* is the row vector, the element *type* is the scalar.
    try std.testing.expectEqual(slang.TypeKind.constant_buffer, cb_type.reflectedType().?.kind());
    const elem_type = elem.reflectedType().?;
    try std.testing.expectEqual(slang.TypeKind.structure, elem_type.kind());
    try std.testing.expectEqual(@as(u32, expected_fields.len), elem_type.fieldCount());

    try std.testing.expectEqual(slang.TypeKind.vector, transform.elementTypeLayout().?.kind());
    try std.testing.expectEqual(slang.TypeKind.scalar, transform.reflectedType().?.elementType().?.kind());
    try std.testing.expectEqual(slang.TypeKind.scalar, base_color.reflectedType().?.elementType().?.kind());
    // A scalar bottoms out: it has no element type.
    try std.testing.expectEqual(@as(?slang.Type, null), roughness.reflectedType().?.elementType());

    // Every parameter here is in the default space.
    try std.testing.expectEqual(@as(u32, 0), bufp.bindingSpace());
    try std.testing.expectEqual(@as(u32, 0), texp.bindingSpace());
    try std.testing.expectEqual(@as(u32, 0), smpp.bindingSpace());
}

// `elementStride` only says anything for an array, so it needs its own fixture:
// three float4s, 16 bytes apart, 48 in total.
test "an array field reports its element count and stride" {
    const gpa = std.testing.allocator;
    const global = try slang.GlobalSession.create();
    defer global.deinit();
    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const program = try slang.util.compileAndLinkProgram(gpa, global, .{
        .source =
        \\struct P { float4 items[3]; };
        \\ConstantBuffer<P> p;
        \\[shader("fragment")]
        \\float4 fsMain() : SV_Target { return p.items[1]; }
        ,
        .format = .metal,
        .matrix_layout = .column_major,
    }, &diag);
    defer program.deinit();

    const layout = try program.getLayout(&diag);
    const cb = layout.parameterByIndex(0).?.typeLayout().?;
    const items = cb.elementTypeLayout().?.fieldByIndex(0).?.typeLayout().?;

    try std.testing.expectEqual(slang.TypeKind.array, items.kind());
    try std.testing.expectEqual(@as(usize, 3), items.elementCount());
    try std.testing.expectEqual(@as(usize, 16), items.elementStride(.uniform));
    try std.testing.expectEqual(@as(usize, 48), items.stride(.uniform));
}

// ---- Parameter categories are target-dependent -----------------------------
// The category `category()` reports is Slang's answer *for the target the layout
// was produced for*, not a property of the declaration. A Metal build sorts the
// resources below into buffer/texture/sampler categories, while a SPIR-V build
// reports `descriptor_table_slot` for all of them — uniform buffer, storage
// buffers, textures and sampler alike. Anything mapping categories onto an API's
// binding tables has to know which target it is reading, so this pins the
// behaviour both ways.

fn categoryOf(layout: slang.ProgramLayout, want: []const u8) !slang.ParameterCategory {
    var i: u32 = 0;
    while (i < layout.parameterCount()) : (i += 1) {
        const p = layout.parameterByIndex(i).?;
        if (std.mem.eql(u8, p.name(), want)) return p.category();
    }
    return error.ParamNotFound;
}

fn typeLayoutOf(layout: slang.ProgramLayout, want: []const u8) !slang.TypeLayout {
    var i: u32 = 0;
    while (i < layout.parameterCount()) : (i += 1) {
        const p = layout.parameterByIndex(i).?;
        if (std.mem.eql(u8, p.name(), want)) return p.typeLayout().?;
    }
    return error.ParamNotFound;
}

test "parameter categories differ between a Metal and a SPIR-V layout" {
    const resource_zoo =
        \\struct P { float4 c; };
        \\ConstantBuffer<P>         cb;
        \\StructuredBuffer<float>   ro_sb;
        \\RWStructuredBuffer<float> rw_sb;
        \\Texture2D<float4>         tex;
        \\RWTexture2D<float4>       rw_tex;
        \\SamplerState              samp;
        \\SamplerCube               env;
        \\
        \\[shader("compute")]
        \\[numthreads(1,1,1)]
        \\void csMain(uint3 tid : SV_DispatchThreadID) {
        \\    rw_sb[0] = ro_sb[0] + cb.c.x + tex.SampleLevel(samp, float2(0,0), 0).x + env.SampleLevel(float3(0,0,1), 0).x;
        \\    rw_tex[tid.xy] = float4(1, 0, 0, 1);
        \\}
    ;

    const gpa = std.testing.allocator;

    const global = try slang.GlobalSession.create();
    defer global.deinit();
    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    {
        const program = slang.util.compileAndLinkProgram(gpa, global, .{
            .source = resource_zoo,
            .module_name = "zoo_metal",
            .path = "zoo.slang",
            .format = .metal,
            .matrix_layout = .column_major,
        }, &diag) catch |err| {
            std.debug.print("metal compile failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
            return err;
        };
        defer program.deinit();
        const layout = try program.getLayout(&diag);

        const buffer = slang.ParameterCategory.metal_buffer; // == .constant_buffer
        const texture = slang.ParameterCategory.metal_texture; // == .shader_resource
        const sampler = slang.ParameterCategory.metal_sampler; // == .sampler_state

        try std.testing.expectEqual(buffer, try categoryOf(layout, "cb"));
        // Structured buffers land in Metal's *buffer* category, read-only and
        // read-write alike — a UAV category is never reported here.
        try std.testing.expectEqual(buffer, try categoryOf(layout, "ro_sb"));
        try std.testing.expectEqual(buffer, try categoryOf(layout, "rw_sb"));
        try std.testing.expectEqual(texture, try categoryOf(layout, "tex"));
        try std.testing.expectEqual(texture, try categoryOf(layout, "rw_tex"));
        try std.testing.expectEqual(sampler, try categoryOf(layout, "samp"));
    }

    {
        const program = slang.util.compileAndLinkProgram(gpa, global, .{
            .source = resource_zoo,
            .module_name = "zoo_spirv",
            .path = "zoo.slang",
            .format = .spirv,
        }, &diag) catch |err| {
            std.debug.print("spirv compile failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
            return err;
        };
        defer program.deinit();
        const layout = try program.getLayout(&diag);

        var i: u32 = 0;
        while (i < layout.parameterCount()) : (i += 1) {
            const p = layout.parameterByIndex(i).?;
            // One category for every resource; the binding index still
            // distinguishes them.
            try std.testing.expectEqual(slang.ParameterCategory.descriptor_table_slot, p.category());
        }
        try std.testing.expect(layout.parameterCount() > 0);

        // Shape and access are properties of the declaration, not the target:
        // they tell `Texture2D` from `RWTexture2D`, and a `SamplerCube` (a
        // combined texture-sampler) from a plain texture.
        const tex = try typeLayoutOf(layout, "tex");
        try std.testing.expectEqual(slang.ResourceShape{ .base = .texture_2d }, tex.resourceShape());
        try std.testing.expectEqual(slang.ResourceAccess.read, tex.resourceAccess());
        try std.testing.expectEqual(slang.TypeKind.vector, tex.reflectedType().?.resourceResultType().?.kind());

        const rw_tex = try typeLayoutOf(layout, "rw_tex");
        try std.testing.expectEqual(slang.ResourceShape{ .base = .texture_2d }, rw_tex.resourceShape());
        try std.testing.expectEqual(slang.ResourceAccess.read_write, rw_tex.resourceAccess());

        const env = try typeLayoutOf(layout, "env");
        try std.testing.expectEqual(slang.ResourceShape{ .base = .texture_cube, .combined = true }, env.resourceShape());
        try std.testing.expectEqual(slang.ResourceAccess.read, env.resourceAccess());

        const ro_sb = try typeLayoutOf(layout, "ro_sb");
        try std.testing.expectEqual(slang.ResourceShape{ .base = .structured_buffer }, ro_sb.resourceShape());
        try std.testing.expectEqual(slang.ResourceAccess.read, ro_sb.resourceAccess());
        try std.testing.expectEqual(slang.ResourceAccess.read_write, (try typeLayoutOf(layout, "rw_sb")).resourceAccess());

        // Non-resource types report no shape.
        try std.testing.expectEqual(slang.ResourceShape{ .base = .none }, (try typeLayoutOf(layout, "cb")).elementTypeLayout().?.resourceShape());
    }
}

// ---- Regression test for the teardown use-after-free -----------------------
//
// A module that `import`s another lands *multiple* source files in the
// session's `SourceManager`. If a handle returned as a *borrowed* reference
// (notably the `IModule*` from `loadModuleFromSourceString`) is over-released,
// the module drops below the session's own reference and its source is freed
// early; the session's later teardown (`~Linkage` → `~SourceManager`) then
// touches freed memory. Whether that read faults depends on heap reuse, so it
// is a probabilistic (~heap-layout) crash — invisible to a single import-free
// compile, and hidden under a debugger.
//
// The bug is triggered by the *load + session teardown* alone (no code
// generation needed), so the stress loop below stays cheap while directly
// exercising the path. The first test additionally does a full compile +
// reflection once, to confirm an importing module actually builds.
//
// What this does and does not prove: a fault during teardown fails the run, so
// an over-release is caught. Nothing here measures COM refcounts or process
// memory, so an over-*retain* — a handle never released — would pass unnoticed;
// only Zig-side allocations are checked, by the testing allocator in the tests
// that take one.

/// Open a session and load the three modules (main imports common + util) so the
/// SourceManager holds multiple sources. The caller tears everything down.
fn loadImporting(global: slang.GlobalSession, diag: *slang.Diagnostics) !struct { session: slang.Session, common: slang.Module, util: slang.Module, main: slang.Module } {
    const common_src =
        \\module common;
        \\public static const float PI = 3.14159265;
        \\public float3 tint(float3 c) { return c * 0.5 + 0.1; }
        \\public float3 desaturate(float3 c, float t) {
        \\    float g = dot(c, float3(0.299, 0.587, 0.114));
        \\    return lerp(c, float3(g, g, g), t);
        \\}
    ;

    const util_src =
        \\module util;
        \\import common;
        \\public float2 warp(float2 uv, float k) { return uv + k * float2(sin(uv.y * PI), cos(uv.x * PI)); }
    ;

    const main_src =
        \\import common;
        \\import util;
        \\
        \\struct Params { float4x4 mvp; float4 color; float amount; };
        \\ConstantBuffer<Params> params;
        \\Texture2D<float4>      tex;
        \\SamplerState           samp;
        \\
        \\[shader("fragment")]
        \\float4 fsMain(float2 uv : TEXCOORD0) : SV_Target {
        \\    float2 w = warp(uv, params.amount);
        \\    float3 base = tint(tex.Sample(samp, w).rgb) * params.color.rgb;
        \\    return float4(desaturate(base, params.amount) + params.mvp[0].xyz * 0.0, 1.0);
        \\}
    ;

    const targets = [_]slang.TargetDesc{slang.target(.metal)};
    const session = try global.createSession(.{ .targets = &targets, .matrix_layout = .column_major });
    errdefer session.deinit();
    // Imported modules are resolved from the session's already-loaded modules by
    // name, so pre-load them. Each handle owns a reference from here on, so a
    // later load failing has to release the earlier ones — the testing allocator
    // cannot see an unbalanced COM refcount, and leaving one behind in the file
    // that exists to police refcount balance would be its own trap.
    const common = try session.loadModuleFromSource("common", "common.slang", common_src, diag);
    errdefer common.deinit();
    const util = try session.loadModuleFromSource("util", "util.slang", util_src, diag);
    errdefer util.deinit();
    const main = try session.loadModuleFromSource("mainm", "mainm.slang", main_src, diag);
    return .{ .session = session, .common = common, .util = util, .main = main };
}

test "an importing module compiles and reflects, and tears down" {
    const gpa = std.testing.allocator;
    const global = try slang.GlobalSession.create();
    defer global.deinit();

    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const s = loadImporting(global, &diag) catch |err| {
        std.debug.print("load failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
        return err;
    };
    defer s.session.deinit();
    defer s.common.deinit();
    defer s.util.deinit();
    defer s.main.deinit();

    var comps: std.ArrayList(*slang.IComponentType) = .empty;
    defer comps.deinit(gpa);
    var eps: std.ArrayList(slang.Component) = .empty;
    defer {
        for (eps.items) |e| e.deinit();
        eps.deinit(gpa);
    }
    try comps.append(gpa, s.main.raw.asComponent());
    var i: u32 = 0;
    while (i < s.main.definedEntryPointCount()) : (i += 1) {
        const e = try s.main.definedEntryPoint(i);
        try eps.append(gpa, e);
        try comps.append(gpa, e.raw);
    }

    const composed = try s.session.createComposite(comps.items, &diag);
    defer composed.deinit();
    const linked = try composed.link(&diag);
    defer linked.deinit();
    const code = try linked.getTargetCode(0, &diag);
    defer code.deinit();
    const layout = try linked.getLayout(0, &diag);

    try std.testing.expect(code.bytes().len > 0);
    try std.testing.expectEqual(@as(u32, 1), layout.entryPointCount());
}

/// Whether `m` lists `want` among its dependencies.
fn dependsOn(m: slang.Module, want: []const u8) bool {
    var i: u32 = 0;
    while (i < m.dependencyFileCount()) : (i += 1) {
        if (std.mem.eql(u8, m.dependencyFilePath(i), want)) return true;
    }
    return false;
}

// What a hot-reload watcher keys on: the dependency list is *transitive* and
// includes the module's own path, so watching every entry of every loaded module
// catches an edit to an imported file as well as to the importer.
test "a module reports its own source and its transitive imports as dependencies" {
    const global = try slang.GlobalSession.create();
    defer global.deinit();

    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    const s = loadImporting(global, &diag) catch |err| {
        std.debug.print("load failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
        return err;
    };
    defer s.session.deinit();
    defer s.common.deinit();
    defer s.util.deinit();
    defer s.main.deinit();

    // `common` imports nothing: itself only.
    try std.testing.expectEqual(@as(u32, 1), s.common.dependencyFileCount());
    try std.testing.expectEqualStrings("common.slang", s.common.dependencyFilePath(0));

    // `util` imports common.
    try std.testing.expectEqual(@as(u32, 2), s.util.dependencyFileCount());
    try std.testing.expect(dependsOn(s.util, "util.slang"));
    try std.testing.expect(dependsOn(s.util, "common.slang"));

    // `mainm` imports common and util — and gets common transitively via util
    // too, but it is listed once.
    try std.testing.expectEqual(@as(u32, 3), s.main.dependencyFileCount());
    try std.testing.expect(dependsOn(s.main, "mainm.slang"));
    try std.testing.expect(dependsOn(s.main, "common.slang"));
    try std.testing.expect(dependsOn(s.main, "util.slang"));

    // For a string-loaded module the recorded path is the `path` argument, not a
    // real file — a watcher has to supply paths it can actually stat.
    try std.testing.expect(!dependsOn(s.main, "does-not-exist.slang"));
}

test "repeated session teardown with imported modules does not crash or leak" {
    // Detection is probabilistic — it depends on the freed source memory being
    // reused before teardown reads it — so this count is the sensitivity. A short
    // loop keeps the path exercised on every run; raise it temporarily to hunt a
    // suspected regression.
    const stress_iterations = 8;

    const global = try slang.GlobalSession.create();
    defer global.deinit();

    var n: u32 = 0;
    while (n < stress_iterations) : (n += 1) {
        var diag: slang.Diagnostics = .{};
        defer diag.deinit();
        const s = loadImporting(global, &diag) catch |err| {
            std.debug.print("iteration {d} failed: {s}\ndiag: {s}\n", .{ n, @errorName(err), diag.text() });
            return err;
        };
        // Tear the whole session (and its multi-source SourceManager) down.
        s.main.deinit();
        s.util.deinit();
        s.common.deinit();
        s.session.deinit();
    }
}

// ---- SessionOptions fields that only the session descriptor sees -----------

test "preprocessor macros reach the compiler" {
    const src =
        \\[shader("fragment")]
        \\float4 fsMain() : SV_Target {
        \\#ifdef USE_RED
        \\    return float4(1, 0, 0, 1);
        \\#else
        \\    return float4(0, 1, 0, 1);
        \\#endif
        \\}
    ;

    const gpa = std.testing.allocator;
    const global = try slang.GlobalSession.create();
    defer global.deinit();
    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    // Default: the macro is undefined, so the `#else` arm survives.
    const plain = try slang.util.compileAndLinkProgramToTargetCode(gpa, global, .{
        .source = src,
        .format = .metal,
    }, &diag);
    defer plain.deinit();
    try std.testing.expect(std.mem.indexOf(u8, plain.bytes(), "0.0f, 1.0f, 0.0f") != null);

    // With it defined, the other arm does.
    const macros = [_]slang.PreprocessorMacroDesc{.{ .name = "USE_RED", .value = "1" }};
    const red = try slang.util.compileAndLinkProgramToTargetCode(gpa, global, .{
        .source = src,
        .format = .metal,
        .preprocessor_macros = &macros,
    }, &diag);
    defer red.deinit();
    try std.testing.expect(std.mem.indexOf(u8, red.bytes(), "1.0f, 0.0f, 0.0f") != null);
}

test "a search path resolves an import from disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "ondisk.slang",
        .data =
        \\module ondisk;
        \\public float3 fromDisk() { return float3(0.25, 0.5, 0.75); }
        ,
    });

    // Slang needs a real directory path to search; take it from the file just
    // written, minus the file name.
    const file_path = try tmp.dir.realPathFileAlloc(io, "ondisk.slang", gpa);
    defer gpa.free(file_path);
    const dir_path = std.fs.path.dirname(file_path).?;
    const dir_z = try gpa.dupeSentinel(u8, dir_path, 0);
    defer gpa.free(dir_z);

    const global = try slang.GlobalSession.create();
    defer global.deinit();
    var diag: slang.Diagnostics = .{};
    defer diag.deinit();

    // `import ondisk;` is resolvable only via the search path — the module is
    // never loaded into the session by hand.
    const paths = [_][*:0]const u8{dir_z.ptr};
    const blob = slang.util.compileAndLinkProgramToTargetCode(gpa, global, .{
        .source =
        \\import ondisk;
        \\[shader("fragment")]
        \\float4 fsMain() : SV_Target { return float4(fromDisk(), 1); }
        ,
        .format = .metal,
        .search_paths = &paths,
    }, &diag) catch |err| {
        std.debug.print("search-path compile failed: {s}\ndiag: {s}\n", .{ @errorName(err), diag.text() });
        return err;
    };
    defer blob.deinit();
    try std.testing.expect(std.mem.indexOf(u8, blob.bytes(), "0.25") != null);
}
