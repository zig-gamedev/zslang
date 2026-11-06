//! zslang — an idiomatic Zig binding for the Slang shader compiler.

const std = @import("std");
const builtin = @import("builtin");

/// The Slang SDK version this binding is built and tested against. `verifyAbi`
/// checks the linked libslang reports this exact build tag.
pub const version = "2026.14";

extern fn spGetBuildTagString() ?[*:0]const u8;

/// The build-tag string of the linked libslang (e.g. "2026.14").
pub fn buildTag() [:0]const u8 {
    return span(spGetBuildTagString());
}

pub const Error = error{
    GlobalSessionFailed,
    SessionFailed,
    LoadModuleFailed,
    EntryPointFailed,
    CompositionFailed,
    LinkFailed,
    CodeGenFailed,
    ReflectionFailed,
};

// =============================================================================
// Utilities
// =============================================================================

/// Name for a slot this binding does not call: `_` and its index. Written out
/// by hand rather than with `std.fmt`, which costs comptime branches and pulls
/// enough of std into analysis to break the wasm32-emscripten build.
fn skipName(comptime index: usize) []const u8 {
    return if (index < 10)
        &[_]u8{ '_', '0' + index }
    else
        &[_]u8{ '_', '0' + index / 10, '0' + index % 10 };
}

/// Build a vtable from parts, in slang.h's declaration order.
///
/// A part is either an extern struct — whose fields are the slots this binding
/// calls, declared by name — or an integer, meaning that many consecutive slots
/// it never calls. Only the index matters for the ones it skips, so they are a
/// count rather than lines of placeholder fields.
///
/// COM interfaces derive by single inheritance, so a derived vtable *is* its
/// parent's slots followed by its own; passing the parent's slots as a part
/// keeps that a reference rather than a re-transcription. The `assertSlot`
/// checks below still pin every called method to its index.
fn Concat(comptime parts: anytype) type {
    comptime var names: []const []const u8 = &.{};
    comptime var types: []const type = &.{};
    inline for (parts) |part| {
        if (@TypeOf(part) == comptime_int) {
            // A run of slots this binding does not call.
            inline for (0..part) |_| {
                names = names ++ [_][]const u8{skipName(names.len)};
                types = types ++ [_]type{*const anyopaque};
            }
        } else {
            const part_info = @typeInfo(part).@"struct";
            inline for (part_info.field_names, part_info.field_types) |field_name, FieldType| {
                // Skipped slots from a nested part are renamed to their absolute
                // index, so two parts can never contribute the same name.
                const nm = if (field_name[0] == '_')
                    skipName(names.len)
                else
                    field_name;
                names = names ++ [_][]const u8{nm};
                types = types ++ [_]type{FieldType};
            }
        }
    }
    const n = names.len;
    const names_arr: [n][]const u8 = names[0..n].*;
    const types_arr: [n]type = types[0..n].*;
    const attrs: [n]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.@"extern", null, &names_arr, &types_arr, &attrs);
}

/// Assert `name` is dispatched from vtable slot `index`.
fn assertSlot(comptime V: type, comptime name: []const u8, comptime index: usize) void {
    std.debug.assert(@offsetOf(V, name) == index * @sizeOf(usize));
}

/// Assert a vtable holds exactly `slots` entries. Because the size is checked
/// against `slots` pointers, this also catches a slot declared as anything that
/// is not pointer-sized, which would corrupt every index after it.
fn assertTableLen(comptime V: type, comptime slots: usize) void {
    std.debug.assert(@sizeOf(V) == slots * @sizeOf(usize));
}

inline fn span(p: ?[*:0]const u8) [:0]const u8 {
    return if (p) |pp| std.mem.span(pp) else "";
}

// =============================================================================
// slang.h
// =============================================================================
// The COM interface ABI and the descriptor structs. With the reflection section
// below, this is the only part of the binding that knows about vtable layout,
// calling conventions or struct field offsets.
//
// How this works, and why no C/C++ shim is needed:
//
//  * Slang exposes exactly one C entry point for bootstrapping —
//    `slang_createGlobalSession` (declared `SLANG_EXTERN_C`). Everything else
//    (`ISession`, `IModule`, `IComponentType`, `IBlob`, …) is a COM-style
//    C++ interface: an object whose first word is a pointer to a vtable of
//    virtual methods.
//
//  * Off Windows, Slang's `SLANG_MCALL` macro expands to nothing, so its
//    interface methods use the platform C++ member ABI. Under the Itanium C++
//    ABI (macOS/Linux, incl. arm64) that means: `this` is passed as an ordinary
//    leading pointer argument and the call is otherwise the C calling
//    convention. So a virtual method is reachable from Zig as a
//    `*const fn (self, args...) callconv(mcall) Ret` read out of the vtable.
//    On Windows `SLANG_MCALL` is `__stdcall`, which differs from C only on
//    32-bit x86 — see `mcall` above.
//
//  * The vtable a live object points at is the *full* one built by libslang.
//    We only ever mirror the leading slots we call, in declaration order
//    (base-interface methods first, then derived). Reading slot k is correct
//    as long as every slot 0..=k is in the right order; we never index past
//    what we declare. Slots we don't call are counted, not named, so the ones
//    we do call land at the right index — see `Concat`.

const mcall: std.builtin.CallingConvention = if (builtin.target.os.tag == .windows) .winapi else .c;

pub const Result = i32;

pub const Int = isize;

pub const Int32 = i32;

pub const API_VERSION: Int = 0; // SLANG_API_VERSION

pub inline fn failed(r: Result) bool {
    return r < 0; // SLANG_FAILED
}

pub const UUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const CompileTarget = enum(c_int) {
    // 1. Not code-generation targets.
    unknown = 0,
    none = 1,

    // 2. Emitted by Slang's own backends, with no external tool.
    glsl = 2,
    hlsl = 5,
    spirv = 6,
    spirv_asm = 7,
    c_source = 12,
    cpp_source = 13,
    cuda_source = 17,
    cpp_pytorch_binding = 23,
    metal = 24,
    wgsl = 28,
    cpp_header = 32,
    cuda_header = 33,

    // 3. Slang emits source, then hands it to a downstream compiler that must be
    // installed and findable. Absent one, codegen fails with "failed to load
    // downstream compiler" — and this binding cannot yet point Slang at it
    // (`setDownstreamCompilerPath` and friends are unbound). Tools, per the
    // diagnostics: fxc (dxbc), dxc (dxil), nvrtc (ptx), Apple's metal
    // (metal_lib), tint (wgsl_spirv), a host C++ compiler (host_executable,
    // host_shared_library).
    dxbc = 8,
    dxbc_asm = 9,
    dxil = 10,
    dxil_asm = 11,
    host_executable = 14,
    ptx = 18,
    cuda_object_code = 19,
    metal_lib = 25,
    metal_lib_asm = 26,
    host_shared_library = 27,
    wgsl_spirv_asm = 29,
    wgsl_spirv = 30,

    // 4. Host/CPU code, routed through the SDK's bundled slang-llvm. These emit,
    // but *running* the result needs the host-callable and byte-code APIs, which
    // this binding does not bind.
    shader_shared_library = 15,
    shader_host_callable = 16,
    object_code = 20,
    host_cpp_source = 21,
    host_host_callable = 22,
    host_vm = 31,
    host_object_code = 34,
    host_llvm_ir = 35,
    shader_llvm_ir = 36,

    _,
};

pub const default_target_flags: u32 = 1 << 10;

pub const MatrixLayoutMode = enum(c_uint) {
    unknown = 0,
    row_major = 1,
    column_major = 2,
    _,
};

pub const Stage = enum(u32) {
    none = 0,
    vertex = 1,
    hull = 2,
    domain = 3,
    geometry = 4,
    fragment = 5,
    compute = 6,
    ray_generation = 7,
    intersection = 8,
    any_hit = 9,
    closest_hit = 10,
    miss = 11,
    callable = 12,
    mesh = 13,
    amplification = 14,
    _,
};

/// `ISlangUnknown`'s three slots, typed for whichever interface inherits them.
fn IUnknownSlots(comptime Self: type) type {
    return extern struct {
        query_interface: *const fn (*Self, *const UUID, *?*anyopaque) callconv(mcall) Result,
        add_ref: *const fn (*Self) callconv(mcall) u32,
        release: *const fn (*Self) callconv(mcall) u32,
    };
}

pub const IUnknown = extern struct {
    vtable: *const VTable,
    pub const VTable = IUnknownSlots(IUnknown);
    pub inline fn release(self: *IUnknown) u32 {
        return self.vtable.release(self);
    }
};

pub const IBlob = extern struct {
    vtable: *const VTable,
    pub const VTable = Concat(.{ IUnknownSlots(IBlob), extern struct {
        get_buffer_pointer: *const fn (*IBlob) callconv(mcall) ?[*]const u8,
        get_buffer_size: *const fn (*IBlob) callconv(mcall) usize,
    } });
    pub inline fn getBufferPointer(self: *IBlob) ?[*]const u8 {
        return self.vtable.get_buffer_pointer(self);
    }
    pub inline fn getBufferSize(self: *IBlob) usize {
        return self.vtable.get_buffer_size(self);
    }
    pub inline fn release(self: *IBlob) u32 {
        return self.vtable.release(self);
    }
    /// The blob's bytes as a slice. Valid until the blob is released.
    pub inline fn slice(self: *IBlob) []const u8 {
        const n = self.getBufferSize();
        const p = self.getBufferPointer() orelse return &.{};
        return p[0..n];
    }
};

/// An owned Slang blob (compiled code, disassembly, …).
pub const Blob = struct {
    raw: *IBlob,

    /// The blob's bytes. Valid until `deinit`.
    pub fn bytes(self: Blob) []const u8 {
        return self.raw.slice();
    }

    pub fn deinit(self: Blob) void {
        _ = self.raw.release();
    }
};

/// Holds a diagnostics blob produced by a failed (or warning-producing)
/// compile step. `text()` is empty when there are none. Call `deinit`.
pub const Diagnostics = struct {
    blob: ?*IBlob = null,

    /// The diagnostic text (Slang emits UTF-8). Valid until `deinit`.
    pub fn text(self: Diagnostics) []const u8 {
        return if (self.blob) |b| b.slice() else "";
    }

    pub fn deinit(self: *Diagnostics) void {
        if (self.blob) |b| _ = b.release();
        self.blob = null;
    }

    /// Adopt an out-blob written by libslang, releasing any previous one. A null
    /// out-blob means the call produced no diagnostics, and leaves the last set
    /// intact.
    fn set(self: *Diagnostics, blob: ?*IBlob) void {
        if (blob == null) return;
        if (self.blob) |old| _ = old.release();
        self.blob = blob;
    }
};

pub const TypeKind = enum(c_uint) {
    none = 0,
    structure = 1, // SLANG_TYPE_KIND_STRUCT
    array = 2,
    matrix = 3,
    vector = 4,
    scalar = 5,
    constant_buffer = 6,
    resource = 7,
    sampler_state = 8,
    texture_buffer = 9,
    shader_storage_buffer = 10,
    parameter_block = 11,
    generic_type_parameter = 12,
    interface = 13,
    output_stream = 14,
    mesh_output = 15,
    specialized = 16,
    feedback = 17,
    pointer = 18,
    dynamic_resource = 19,
    @"enum" = 20,
    _,
};

pub const ScalarType = enum(c_uint) {
    none = 0,
    void = 1,
    bool = 2,
    int32 = 3,
    uint32 = 4,
    int64 = 5,
    uint64 = 6,
    float16 = 7,
    float32 = 8,
    float64 = 9,
    int8 = 10,
    uint8 = 11,
    int16 = 12,
    uint16 = 13,
    intptr = 14,
    uintptr = 15,
    _,
};

/// `SlangResourceShape`: a base shape in the low four bits plus flag bits, laid
/// out to match the C value bit for bit.
pub const ResourceShape = packed struct(c_uint) {
    base: Base,
    feedback: bool = false,
    shadow: bool = false,
    array: bool = false,
    multisample: bool = false,
    /// A combined texture-sampler, e.g. `Sampler2D` rather than `Texture2D`.
    combined: bool = false,
    _: u23 = 0,

    pub const Base = enum(u4) {
        none = 0,
        texture_1d = 1,
        texture_2d = 2,
        texture_3d = 3,
        texture_cube = 4,
        texture_buffer = 5,
        structured_buffer = 6,
        byte_address_buffer = 7,
        unknown = 8,
        acceleration_structure = 9,
        texture_subpass = 10,
        _,
    };
};

pub const ResourceAccess = enum(c_uint) {
    none = 0,
    read = 1,
    read_write = 2,
    raster_ordered = 3,
    append = 4,
    consume = 5,
    write = 6,
    feedback = 7,
    _,
};

pub const ParameterCategory = enum(c_uint) {
    none = 0,
    mixed = 1,
    constant_buffer = 2,
    shader_resource = 3,
    unordered_access = 4,
    varying_input = 5,
    varying_output = 6,
    sampler_state = 7,
    uniform = 8,
    descriptor_table_slot = 9,
    specialization_constant = 10,
    push_constant_buffer = 11,
    register_space = 12,
    generic = 13,
    ray_payload = 14,
    hit_attributes = 15,
    callable_payload = 16,
    shader_record = 17,
    _,

    // Metal-specific aliases (same underlying category values as above).
    pub const metal_buffer: ParameterCategory = .constant_buffer;
    pub const metal_texture: ParameterCategory = .shader_resource;
    pub const metal_sampler: ParameterCategory = .sampler_state;
};

pub const IGlobalSession = extern struct {
    vtable: *const VTable,
    pub const VTable = Concat(.{ IUnknownSlots(IGlobalSession), extern struct {
        create_session: *const fn (*IGlobalSession, *const SessionDesc, *?*ISession) callconv(mcall) Result,
    } });
    pub inline fn createSession(self: *IGlobalSession, desc: *const SessionDesc, out: *?*ISession) Result {
        return self.vtable.create_session(self, desc, out);
    }
    pub inline fn release(self: *IGlobalSession) u32 {
        return self.vtable.release(self);
    }
};

/// The process-wide Slang session factory. Create one, keep it for the lifetime
/// of your compiler usage, and make `Session`s from it.
pub const GlobalSession = struct {
    raw: *IGlobalSession,

    pub fn create() Error!GlobalSession {
        var out: ?*IGlobalSession = null;
        const r = slang_createGlobalSession(API_VERSION, &out);
        if (failed(r) or out == null) return Error.GlobalSessionFailed;
        return .{ .raw = out.? };
    }

    pub fn deinit(self: GlobalSession) void {
        _ = self.raw.release();
    }

    /// Open a compilation session for the given targets / search paths.
    ///
    /// The slices in `opts` need only stay alive for the duration of this call
    /// (Slang copies what it needs), so a stack-built `TargetDesc` array works.
    pub fn createSession(self: GlobalSession, opts: SessionOptions) Error!Session {
        var desc: SessionDesc = .{
            .default_matrix_layout_mode = opts.matrix_layout,
        };
        if (opts.targets.len != 0) {
            desc.targets = opts.targets.ptr;
            desc.target_count = @intCast(opts.targets.len);
        }
        if (opts.search_paths.len != 0) {
            desc.search_paths = opts.search_paths.ptr;
            desc.search_path_count = @intCast(opts.search_paths.len);
        }
        if (opts.preprocessor_macros.len != 0) {
            desc.preprocessor_macros = opts.preprocessor_macros.ptr;
            desc.preprocessor_macro_count = @intCast(opts.preprocessor_macros.len);
        }
        var out: ?*ISession = null;
        if (failed(self.raw.createSession(&desc, &out)) or out == null) return Error.SessionFailed;
        return .{ .raw = out.? };
    }
};

/// `slang::TargetDesc`. Defaults reproduce a C++ `TargetDesc{}`.
pub const TargetDesc = extern struct {
    structure_size: usize = @sizeOf(TargetDesc),
    format: CompileTarget = .unknown,
    profile: u32 = 0, // SLANG_PROFILE_UNKNOWN
    flags: u32 = default_target_flags,
    floating_point_mode: u32 = 0, // SLANG_FLOATING_POINT_MODE_DEFAULT
    line_directive_mode: u32 = 0, // SLANG_LINE_DIRECTIVE_MODE_DEFAULT
    force_glsl_scalar_buffer_layout: bool = false,
    compiler_option_entries: ?*const anyopaque = null,
    compiler_option_entry_count: u32 = 0,
};

/// Convenience: a `TargetDesc` for `format` with Slang's own defaults.
pub fn target(format: CompileTarget) TargetDesc {
    return .{ .format = format };
}

pub const PreprocessorMacroDesc = extern struct {
    name: ?[*:0]const u8 = null,
    value: ?[*:0]const u8 = null,
};

/// `slang::SessionDesc`. Defaults reproduce a C++ `SessionDesc{}` — note the
/// matrix-layout default is row-major (1), matching Slang, not zero.
pub const SessionDesc = extern struct {
    structure_size: usize = @sizeOf(SessionDesc),
    targets: ?[*]const TargetDesc = null,
    target_count: Int = 0,
    flags: u32 = 0, // kSessionFlags_None
    default_matrix_layout_mode: MatrixLayoutMode = .row_major,
    search_paths: ?[*]const [*:0]const u8 = null,
    search_path_count: Int = 0,
    preprocessor_macros: ?[*]const PreprocessorMacroDesc = null,
    preprocessor_macro_count: Int = 0,
    file_system: ?*anyopaque = null,
    enable_effect_annotations: bool = false,
    allow_glsl_syntax: bool = false,
    compiler_option_entries: ?*const anyopaque = null,
    compiler_option_entry_count: u32 = 0,
    skip_spirv_validation: bool = false,
};

pub const SessionOptions = struct {
    /// Code-generation targets (build with `slang.target(.metal)` etc.).
    targets: []const TargetDesc,
    /// Directories searched to resolve `import`/`#include`. Each entry is a
    /// NUL-terminated path.
    search_paths: []const [*:0]const u8 = &.{},
    /// Default matrix layout for the session. Slang's own default is row-major;
    /// Metal codegen conventionally wants column-major.
    matrix_layout: MatrixLayoutMode = .row_major,
    /// Preprocessor macros `#define`d for every module compiled in this session.
    preprocessor_macros: []const PreprocessorMacroDesc = &.{},
};

pub const ISession = extern struct {
    vtable: *const VTable,
    /// Skipped: getGlobalSession, loadModule, loadModuleFromSource; then
    /// specializeType through isBinaryModuleUpToDate.
    pub const VTable = Concat(.{ IUnknownSlots(ISession), 3, extern struct {
        create_composite_component_type: *const fn (
            *ISession,
            [*]const *IComponentType,
            Int,
            *?*IComponentType,
            *?*IBlob,
        ) callconv(mcall) Result,
    }, 13, extern struct {
        load_module_from_source_string: *const fn (
            *ISession,
            moduleName: ?[*:0]const u8,
            path: ?[*:0]const u8,
            string: [*:0]const u8,
            outDiagnostics: *?*IBlob,
        ) callconv(mcall) ?*IModule,
    } });

    pub inline fn loadModuleFromSourceString(
        self: *ISession,
        module_name: ?[*:0]const u8,
        path: ?[*:0]const u8,
        string: [*:0]const u8,
        out_diagnostics: *?*IBlob,
    ) ?*IModule {
        return self.vtable.load_module_from_source_string(self, module_name, path, string, out_diagnostics);
    }

    pub inline fn createCompositeComponentType(
        self: *ISession,
        components: []const *IComponentType,
        out: *?*IComponentType,
        out_diagnostics: *?*IBlob,
    ) Result {
        return self.vtable.create_composite_component_type(
            self,
            components.ptr,
            @intCast(components.len),
            out,
            out_diagnostics,
        );
    }

    pub inline fn release(self: *ISession) u32 {
        return self.vtable.release(self);
    }
};

/// A compilation session: a scope for loading modules and composing programs
/// against a fixed set of targets and search paths.
pub const Session = struct {
    raw: *ISession,

    pub fn deinit(self: Session) void {
        _ = self.raw.release();
    }

    /// Load and type-check a module from Slang source. `source` must be
    /// NUL-terminated. On failure `diag` carries the compiler messages.
    ///
    /// Ownership subtlety: `loadModuleFromSourceString` *returns* an `IModule*`
    /// directly (not through a `writeRef`-style out-parameter), which by Slang's
    /// COM convention is a **borrowed** reference — the module is owned by the
    /// session, and a caller keeping a handle must `addRef` it (exactly what
    /// `Slang::ComPtr<IModule>(rawPtr)` does). We `addRef` here so the returned
    /// `Module` owns one balanced reference that its `deinit` releases, keeping
    /// the uniform owned-handle model.
    pub fn loadModuleFromSource(
        self: Session,
        module_name: [:0]const u8,
        path: [:0]const u8,
        source: [:0]const u8,
        diag: *Diagnostics,
    ) Error!Module {
        var d: ?*IBlob = null;
        const m = self.raw.loadModuleFromSourceString(module_name.ptr, path.ptr, source.ptr, &d);
        diag.set(d);
        const raw = m orelse return Error.LoadModuleFailed;
        _ = raw.addRef(); // take our own reference on the session-owned module
        return .{ .raw = raw };
    }

    /// Combine components (a module plus its entry points, typically) into one
    /// composite. Result is owned; call `deinit`.
    pub fn createComposite(self: Session, components: []const *IComponentType, diag: *Diagnostics) Error!Component {
        var out: ?*IComponentType = null;
        var d: ?*IBlob = null;
        const r = self.raw.createCompositeComponentType(components, &out, &d);
        diag.set(d);
        if (failed(r) or out == null) return Error.CompositionFailed;
        return .{ .raw = out.?, .owned = true };
    }
};

/// `IComponentType`'s own 14 slots, typed for itself or for `IModule`, which
/// inherits them. Skipped: getSession; getSpecializationParamCount through
/// specialize; getEntryPointHostCallable through linkWithOptions; the two
/// metadata getters.
fn IComponentTypeSlots(comptime Self: type) type {
    return Concat(.{
        1,
        extern struct {
            get_layout: *const fn (*Self, Int, *?*IBlob) callconv(mcall) ?*SlangReflection,
        },
        5,
        extern struct {
            link: *const fn (*Self, *?*IComponentType, *?*IBlob) callconv(mcall) Result,
        },
        3,
        extern struct {
            get_target_code: *const fn (*Self, Int, *?*IBlob, *?*IBlob) callconv(mcall) Result,
        },
        2,
    });
}

pub const IComponentType = extern struct {
    vtable: *const VTable,
    pub const VTable = Concat(.{ IUnknownSlots(IComponentType), IComponentTypeSlots(IComponentType) });

    pub inline fn link(self: *IComponentType, out: *?*IComponentType, out_diagnostics: *?*IBlob) Result {
        return self.vtable.link(self, out, out_diagnostics);
    }
    pub inline fn getTargetCode(self: *IComponentType, target_index: Int, out_code: *?*IBlob, out_diagnostics: *?*IBlob) Result {
        return self.vtable.get_target_code(self, target_index, out_code, out_diagnostics);
    }
    /// The reflection root for this component; see `Component.getLayout`.
    pub inline fn getLayout(self: *IComponentType, target_index: Int, out_diagnostics: *?*IBlob) ?*SlangReflection {
        return self.vtable.get_layout(self, target_index, out_diagnostics);
    }
    pub inline fn release(self: *IComponentType) u32 {
        return self.vtable.release(self);
    }
};

/// A composable/linkable unit: a module, an entry point, a composite, or a
/// linked program. `owned` distinguishes handles this binding must release from
/// borrowed views (e.g. `Module.asComponent`).
pub const Component = struct {
    raw: *IComponentType,
    owned: bool = true,

    pub fn deinit(self: Component) void {
        if (self.owned) _ = self.raw.release();
    }

    /// Link this component against its dependencies, yielding a program from
    /// which target code can be generated. Result is owned; call `deinit`.
    pub fn link(self: Component, diag: *Diagnostics) Error!Component {
        var out: ?*IComponentType = null;
        var d: ?*IBlob = null;
        const r = self.raw.link(&out, &d);
        diag.set(d);
        if (failed(r) or out == null) return Error.LinkFailed;
        return .{ .raw = out.?, .owned = true };
    }

    /// Emit the compiled code for `target_index` (the target's position in the
    /// session's target list). Result is an owned `Blob`.
    pub fn getTargetCode(self: Component, target_index: usize, diag: *Diagnostics) Error!Blob {
        var out: ?*IBlob = null;
        var d: ?*IBlob = null;
        const r = self.raw.getTargetCode(@intCast(target_index), &out, &d);
        diag.set(d);
        if (failed(r) or out == null) return Error.CodeGenFailed;
        return .{ .raw = out.? };
    }

    /// Reflect this (typically linked) component for `target_index`, yielding a
    /// `ProgramLayout`. The reflection data is owned by this component and stays
    /// valid until it is `deinit`ed.
    pub fn getLayout(self: Component, target_index: usize, diag: *Diagnostics) Error!ProgramLayout {
        var d: ?*IBlob = null;
        const p = self.raw.getLayout(@intCast(target_index), &d);
        diag.set(d);
        return .{ .raw = p orelse return Error.ReflectionFailed };
    }
};

pub const IModule = extern struct {
    vtable: *const VTable,
    /// Skipped: findEntryPointByName; then serialize, writeToFile, getName,
    /// getFilePath, getUniqueIdentity, findAndCheckEntryPoint.
    pub const VTable = Concat(.{ IUnknownSlots(IModule), IComponentTypeSlots(IModule), 1, extern struct {
        get_defined_entry_point_count: *const fn (*IModule) callconv(mcall) Int32,
        get_defined_entry_point: *const fn (*IModule, Int32, *?*IComponentType) callconv(mcall) Result,
    }, 6, extern struct {
        get_dependency_file_count: *const fn (*IModule) callconv(mcall) Int32,
        get_dependency_file_path: *const fn (*IModule, Int32) callconv(mcall) ?[*:0]const u8,
    } });

    pub inline fn getDefinedEntryPointCount(self: *IModule) Int32 {
        return self.vtable.get_defined_entry_point_count(self);
    }
    /// Number of files this module depends on — its own source plus everything
    /// transitively pulled in by `import` and `#include`.
    pub inline fn getDependencyFileCount(self: *IModule) Int32 {
        return self.vtable.get_dependency_file_count(self);
    }
    /// Path of the `index`-th dependency. Owned by the module; valid while it is.
    /// Not bounds-checked by libslang — an out-of-range `index` segfaults.
    pub inline fn getDependencyFilePath(self: *IModule, index: Int32) ?[*:0]const u8 {
        return self.vtable.get_dependency_file_path(self, index);
    }
    /// Returns the entry point as an `*IComponentType` (its usable super-type;
    /// `IEntryPoint` derives from `IComponentType` with an identical pointer).
    pub inline fn getDefinedEntryPoint(self: *IModule, index: Int32, out: *?*IComponentType) Result {
        return self.vtable.get_defined_entry_point(self, index, out);
    }
    pub inline fn addRef(self: *IModule) u32 {
        return self.vtable.add_ref(self);
    }
    pub inline fn release(self: *IModule) u32 {
        return self.vtable.release(self);
    }
    /// A module *is* a component type (single inheritance, same pointer).
    pub inline fn asComponent(self: *IModule) *IComponentType {
        return @ptrCast(self);
    }
};

/// A loaded, checked Slang module. Also usable as a `Component` (it is one).
pub const Module = struct {
    raw: *IModule,

    pub fn deinit(self: Module) void {
        _ = self.raw.release();
    }

    /// This module as a linkable component (same underlying object, borrowed —
    /// do not `deinit` the result separately).
    pub fn asComponent(self: Module) Component {
        return .{ .raw = self.raw.asComponent(), .owned = false };
    }

    /// Number of entry points defined in this module (functions marked with a
    /// `[shader("...")]` attribute).
    pub fn definedEntryPointCount(self: Module) u32 {
        const n = self.raw.getDefinedEntryPointCount();
        return if (n < 0) 0 else @intCast(n);
    }

    /// The `index`-th defined entry point, as an owned component. Call `deinit`.
    pub fn definedEntryPoint(self: Module, index: u32) Error!Component {
        var out: ?*IComponentType = null;
        if (failed(self.raw.getDefinedEntryPoint(@intCast(index), &out)) or out == null) {
            return Error.EntryPointFailed;
        }
        return .{ .raw = out.?, .owned = true };
    }

    /// Number of files this module depends on: its own source plus everything
    /// transitively reached through `import` and `#include`. This is what a
    /// rebuild or hot-reload watcher needs to know to invalidate the module.
    pub fn dependencyFileCount(self: Module) u32 {
        const n = self.raw.getDependencyFileCount();
        return if (n < 0) 0 else @intCast(n);
    }

    /// Path of the `index`-th dependency, as Slang recorded it — a filesystem
    /// path for a file-backed dependency, or the `path` argument given to
    /// `loadModuleFromSource` for one compiled from a string. Borrowed: the
    /// module owns the string, so copy it to outlive the module.
    ///
    /// `index` must be `< dependencyFileCount()`. libslang indexes its list
    /// without a bounds check and segfaults on an out-of-range index, so this
    /// asserts instead of letting that through.
    pub fn dependencyFilePath(self: Module, index: u32) [:0]const u8 {
        std.debug.assert(index < self.dependencyFileCount());
        const p = self.raw.getDependencyFilePath(@intCast(index)) orelse return "";
        return std.mem.span(p);
    }
};

pub extern fn slang_createGlobalSession(
    apiVersion: Int,
    outGlobalSession: *?*IGlobalSession,
) callconv(.c) Result;

// ---- Layout self-checks ----------------------------------------------------
// Both tables were confirmed against a C++ `sizeof`/`offsetof` probe compiled
// from slang.h: the 64-bit one for x86_64, the 32-bit one for x86 (SysV), x86
// (Windows), ARM EABI and wasm32, which agree with each other.
comptime {
    switch (@sizeOf(usize)) {
        8 => {
            std.debug.assert(@sizeOf(TargetDesc) == 48);
            std.debug.assert(@offsetOf(TargetDesc, "format") == 8);
            std.debug.assert(@offsetOf(TargetDesc, "profile") == 12);
            std.debug.assert(@offsetOf(TargetDesc, "flags") == 16);
            std.debug.assert(@offsetOf(TargetDesc, "force_glsl_scalar_buffer_layout") == 28);
            std.debug.assert(@offsetOf(TargetDesc, "compiler_option_entries") == 32);

            std.debug.assert(@sizeOf(SessionDesc) == 96);
            std.debug.assert(@offsetOf(SessionDesc, "targets") == 8);
            std.debug.assert(@offsetOf(SessionDesc, "target_count") == 16);
            std.debug.assert(@offsetOf(SessionDesc, "flags") == 24);
            std.debug.assert(@offsetOf(SessionDesc, "default_matrix_layout_mode") == 28);
            std.debug.assert(@offsetOf(SessionDesc, "search_paths") == 32);
            std.debug.assert(@offsetOf(SessionDesc, "search_path_count") == 40);
            std.debug.assert(@offsetOf(SessionDesc, "file_system") == 64);
            std.debug.assert(@offsetOf(SessionDesc, "enable_effect_annotations") == 72);
            std.debug.assert(@offsetOf(SessionDesc, "allow_glsl_syntax") == 73);
            std.debug.assert(@offsetOf(SessionDesc, "compiler_option_entries") == 80);
            std.debug.assert(@offsetOf(SessionDesc, "compiler_option_entry_count") == 88);
            std.debug.assert(@offsetOf(SessionDesc, "skip_spirv_validation") == 92);

            std.debug.assert(@sizeOf(PreprocessorMacroDesc) == 16);
        },
        4 => {
            std.debug.assert(@sizeOf(TargetDesc) == 36);
            std.debug.assert(@offsetOf(TargetDesc, "format") == 4);
            std.debug.assert(@offsetOf(TargetDesc, "profile") == 8);
            std.debug.assert(@offsetOf(TargetDesc, "flags") == 12);
            std.debug.assert(@offsetOf(TargetDesc, "force_glsl_scalar_buffer_layout") == 24);
            std.debug.assert(@offsetOf(TargetDesc, "compiler_option_entries") == 28);

            std.debug.assert(@sizeOf(SessionDesc) == 56);
            std.debug.assert(@offsetOf(SessionDesc, "targets") == 4);
            std.debug.assert(@offsetOf(SessionDesc, "target_count") == 8);
            std.debug.assert(@offsetOf(SessionDesc, "flags") == 12);
            std.debug.assert(@offsetOf(SessionDesc, "default_matrix_layout_mode") == 16);
            std.debug.assert(@offsetOf(SessionDesc, "search_paths") == 20);
            std.debug.assert(@offsetOf(SessionDesc, "search_path_count") == 24);
            std.debug.assert(@offsetOf(SessionDesc, "file_system") == 36);
            std.debug.assert(@offsetOf(SessionDesc, "enable_effect_annotations") == 40);
            std.debug.assert(@offsetOf(SessionDesc, "allow_glsl_syntax") == 41);
            std.debug.assert(@offsetOf(SessionDesc, "compiler_option_entries") == 44);
            std.debug.assert(@offsetOf(SessionDesc, "compiler_option_entry_count") == 48);
            std.debug.assert(@offsetOf(SessionDesc, "skip_spirv_validation") == 52);

            std.debug.assert(@sizeOf(PreprocessorMacroDesc) == 8);
        },
        else => @compileError("libslang has no ABI for this pointer width"),
    }

    // Width-independent: SlangUUID is four fixed-width fields.
    std.debug.assert(@sizeOf(UUID) == 16);
}

// ---- Vtable slot self-checks -----------------------------------------------
// Every method is dispatched by *index*, so a miscounted gap or a slot added,
// dropped or reordered above shifts each later entry and silently calls the
// wrong method — the one transcription mistake the struct-layout asserts cannot
// see. These pin each called slot to the index its method occupies in slang.h's
// declaration order, and pin each table's length so a missing slot cannot go
// unnoticed. They are what makes the gap counts in `Concat` safe.
comptime {
    assertTableLen(IUnknown.VTable, 3);
    assertTableLen(IBlob.VTable, 5);
    assertTableLen(IGlobalSession.VTable, 4);
    assertTableLen(ISession.VTable, 21);
    assertTableLen(IComponentType.VTable, 17);
    assertTableLen(IModule.VTable, 28);

    // IUnknown, inherited by every interface above.
    assertSlot(IUnknown.VTable, "release", 2);

    assertSlot(IBlob.VTable, "get_buffer_pointer", 3);
    assertSlot(IBlob.VTable, "get_buffer_size", 4);

    assertSlot(IGlobalSession.VTable, "create_session", 3);

    assertSlot(ISession.VTable, "create_composite_component_type", 6);
    assertSlot(ISession.VTable, "load_module_from_source_string", 20);

    assertSlot(IComponentType.VTable, "get_layout", 4);
    assertSlot(IComponentType.VTable, "link", 10);
    assertSlot(IComponentType.VTable, "get_target_code", 14);

    // IModule's own methods follow IComponentType's 14, hence the high indices.
    assertSlot(IModule.VTable, "get_defined_entry_point_count", 18);
    assertSlot(IModule.VTable, "get_defined_entry_point", 19);
    assertSlot(IModule.VTable, "get_dependency_file_count", 26);
    assertSlot(IModule.VTable, "get_dependency_file_path", 27);
}

// =============================================================================
// slang-deprecated.h
// =============================================================================
// Unlike the compile path above (COM interfaces bound through vtables),
// Slang's *reflection* API is exposed as a flat set of plain C
// functions — `spReflection*`, `spReflectionType*`, `spReflectionTypeLayout*`,
// `spReflectionVariableLayout*`, `spReflectionEntryPoint*` — declared inside an
// `extern "C"` block in Slang's `slang-deprecated.h` (which `slang.h` includes)
// and exported from libslang with C names. The C++ reflection classes
// (`ProgramLayout`, `TypeLayoutReflection`, …) are only inline
// `reinterpret_cast` wrappers over these functions.
//
// Binding the C functions directly has a decisive advantage for correctness:
// every function here takes/returns only C-ABI-friendly scalars, enums,
// `size_t`, `const char*`, or opaque handle pointers. **None returns a struct
// by value**, so the Itanium sret hazard that complicates by-value C++ returns
// simply does not arise on this surface. There is likewise no vtable ordering
// to get wrong — the linker resolves each function by name, so a Slang release
// that reorders methods cannot silently misdispatch these calls (a removed or
// renamed symbol would fail to link, loudly). See `verifyAbi` for the runtime
// guard that additionally proves the *values* are being read correctly.
//
// Handles here are borrowed views into the `ProgramLayout` returned by
// `Component.getLayout`; they live as long as that linked component and are not
// separately released. The wrappers are thin, and a null handle from the C API
// reads back as an empty string or a zero count rather than crashing.

const SlangReflection = opaque {};

const SlangReflectionEntryPoint = opaque {};

const SlangReflectionVariable = opaque {};

const SlangReflectionVariableLayout = opaque {};

const SlangReflectionType = opaque {};

const SlangReflectionTypeLayout = opaque {};

extern fn spReflectionType_GetColumnCount(t: *SlangReflectionType) c_uint;

extern fn spReflectionType_GetElementCount(t: *SlangReflectionType) usize;

extern fn spReflectionType_GetElementType(t: *SlangReflectionType) ?*SlangReflectionType;

extern fn spReflectionType_GetFieldCount(t: *SlangReflectionType) c_uint;

extern fn spReflectionType_GetKind(t: *SlangReflectionType) TypeKind;

extern fn spReflectionType_GetName(t: *SlangReflectionType) ?[*:0]const u8;

extern fn spReflectionType_GetResourceAccess(t: *SlangReflectionType) ResourceAccess;

extern fn spReflectionType_GetResourceResultType(t: *SlangReflectionType) ?*SlangReflectionType;

extern fn spReflectionType_GetResourceShape(t: *SlangReflectionType) ResourceShape;

extern fn spReflectionType_GetRowCount(t: *SlangReflectionType) c_uint;

extern fn spReflectionType_GetScalarType(t: *SlangReflectionType) ScalarType;

extern fn spReflectionTypeLayout_GetElementStride(tl: *SlangReflectionTypeLayout, category: ParameterCategory) usize;

extern fn spReflectionTypeLayout_GetElementTypeLayout(tl: *SlangReflectionTypeLayout) ?*SlangReflectionTypeLayout;

extern fn spReflectionTypeLayout_GetFieldByIndex(tl: *SlangReflectionTypeLayout, index: c_uint) ?*SlangReflectionVariableLayout;

extern fn spReflectionTypeLayout_GetFieldCount(tl: *SlangReflectionTypeLayout) u32;

extern fn spReflectionTypeLayout_GetParameterCategory(tl: *SlangReflectionTypeLayout) ParameterCategory;

extern fn spReflectionTypeLayout_GetSize(tl: *SlangReflectionTypeLayout, category: ParameterCategory) usize;

extern fn spReflectionTypeLayout_GetStride(tl: *SlangReflectionTypeLayout, category: ParameterCategory) usize;

extern fn spReflectionTypeLayout_GetType(tl: *SlangReflectionTypeLayout) ?*SlangReflectionType;

extern fn spReflectionTypeLayout_getKind(tl: *SlangReflectionTypeLayout) TypeKind;

/// The *type* behind a layout — Slang's `TypeReflection`. A `TypeLayout` answers
/// where things sit; this answers what the type is.
pub const Type = struct {
    raw: *SlangReflectionType,

    pub fn kind(self: Type) TypeKind {
        return spReflectionType_GetKind(self.raw);
    }
    /// Number of fields, for a struct type.
    pub fn fieldCount(self: Type) u32 {
        return spReflectionType_GetFieldCount(self.raw);
    }
    /// Element type of an array, vector or matrix. Not the same as
    /// `TypeLayout.elementTypeLayout`, which descends one level of *layout*: for
    /// a `float4x4` this reports the scalar, while the element type layout is
    /// the row vector.
    pub fn elementType(self: Type) ?Type {
        return .{ .raw = spReflectionType_GetElementType(self.raw) orelse return null };
    }
    /// Shape of a resource type (texture dimension, buffer kind, flags such as
    /// `combined`). `.none` for non-resource types.
    pub fn resourceShape(self: Type) ResourceShape {
        return spReflectionType_GetResourceShape(self.raw);
    }
    /// Read/write access of a resource type, e.g. `.read` for `Texture2D` and
    /// `.read_write` for `RWTexture2D`.
    pub fn resourceAccess(self: Type) ResourceAccess {
        return spReflectionType_GetResourceAccess(self.raw);
    }
    /// The type a resource yields when read, e.g. `float4` for `Texture2D<float4>`.
    pub fn resourceResultType(self: Type) ?Type {
        return .{ .raw = spReflectionType_GetResourceResultType(self.raw) orelse return null };
    }
};

/// The layout of a type: its kind, byte size, fields (for structs), and element
/// type (for constant buffers, arrays, vectors, matrices).
pub const TypeLayout = struct {
    raw: *SlangReflectionTypeLayout,

    pub fn kind(self: TypeLayout) TypeKind {
        return spReflectionTypeLayout_getKind(self.raw);
    }
    /// Name of the underlying type (e.g. the struct name of a constant buffer's
    /// element). Empty for anonymous types.
    pub fn name(self: TypeLayout) [:0]const u8 {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return "";
        return span(spReflectionType_GetName(t));
    }
    /// Byte size in `category` (use `.uniform` for host-shared struct data).
    pub fn size(self: TypeLayout, cat: ParameterCategory) usize {
        return spReflectionTypeLayout_GetSize(self.raw, cat);
    }
    pub fn stride(self: TypeLayout, cat: ParameterCategory) usize {
        return spReflectionTypeLayout_GetStride(self.raw, cat);
    }
    /// Stride between array elements in `category`.
    pub fn elementStride(self: TypeLayout, cat: ParameterCategory) usize {
        return spReflectionTypeLayout_GetElementStride(self.raw, cat);
    }
    /// The element type layout — of a constant buffer's contents, or an array's
    /// element.
    pub fn elementTypeLayout(self: TypeLayout) ?TypeLayout {
        return .{ .raw = spReflectionTypeLayout_GetElementTypeLayout(self.raw) orelse return null };
    }
    pub fn fieldCount(self: TypeLayout) u32 {
        return spReflectionTypeLayout_GetFieldCount(self.raw);
    }
    pub fn fieldByIndex(self: TypeLayout, index: u32) ?VariableLayout {
        return .{ .raw = spReflectionTypeLayout_GetFieldByIndex(self.raw, index) orelse return null };
    }
    /// The underlying type, for the questions a layout cannot answer.
    pub fn reflectedType(self: TypeLayout) ?Type {
        return .{ .raw = spReflectionTypeLayout_GetType(self.raw) orelse return null };
    }
    /// Scalar element type (for scalar/vector/matrix types).
    pub fn scalarType(self: TypeLayout) ScalarType {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return .none;
        return spReflectionType_GetScalarType(t);
    }
    /// Resource shape (for resource types); see `Type.resourceShape`.
    pub fn resourceShape(self: TypeLayout) ResourceShape {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return .{ .base = .none };
        return spReflectionType_GetResourceShape(t);
    }
    /// Resource access (for resource types); see `Type.resourceAccess`.
    pub fn resourceAccess(self: TypeLayout) ResourceAccess {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return .none;
        return spReflectionType_GetResourceAccess(t);
    }
    /// Number of elements for a vector or (single-dimension) array type; 0 for
    /// non-aggregate types.
    pub fn elementCount(self: TypeLayout) usize {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return 0;
        return spReflectionType_GetElementCount(t);
    }
    /// Row/column counts (for matrix and vector types).
    pub fn rowCount(self: TypeLayout) u32 {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return 0;
        return spReflectionType_GetRowCount(t);
    }
    pub fn columnCount(self: TypeLayout) u32 {
        const t = spReflectionTypeLayout_GetType(self.raw) orelse return 0;
        return spReflectionType_GetColumnCount(t);
    }
};

extern fn spReflectionVariable_GetName(v: *SlangReflectionVariable) ?[*:0]const u8;

extern fn spReflectionVariableLayout_GetOffset(v: *SlangReflectionVariableLayout, category: ParameterCategory) usize;

extern fn spReflectionVariableLayout_GetTypeLayout(v: *SlangReflectionVariableLayout) ?*SlangReflectionTypeLayout;

extern fn spReflectionVariableLayout_GetVariable(v: *SlangReflectionVariableLayout) ?*SlangReflectionVariable;

extern fn spReflectionVariableLayout_getStage(v: *SlangReflectionVariableLayout) Stage;
// `SlangReflectionParameter*` is `SlangReflectionVariableLayout*` at the ABI.

extern fn spReflection_GetParameterByIndex(reflection: *SlangReflection, index: c_uint) ?*SlangReflectionVariableLayout;

extern fn spReflection_GetParameterCount(reflection: *SlangReflection) c_uint;

// These two take/return `SlangUInt`, which slang.h sizes to the pointer width.
extern fn spReflection_getEntryPointByIndex(reflection: *SlangReflection, index: usize) ?*SlangReflectionEntryPoint;

extern fn spReflection_getEntryPointCount(reflection: *SlangReflection) usize;

/// The reflection root for a linked program, from `Component.getLayout`.
pub const ProgramLayout = struct {
    raw: *SlangReflection,

    pub fn entryPointCount(self: ProgramLayout) u32 {
        return @intCast(spReflection_getEntryPointCount(self.raw));
    }
    pub fn entryPointByIndex(self: ProgramLayout, index: u32) ?EntryPoint {
        return .{ .raw = spReflection_getEntryPointByIndex(self.raw, index) orelse return null };
    }
    /// Number of global-scope shader parameters — where a shader declares its
    /// `ConstantBuffer`/`Texture2D`/`SamplerState` resources.
    pub fn parameterCount(self: ProgramLayout) u32 {
        return spReflection_GetParameterCount(self.raw);
    }
    pub fn parameterByIndex(self: ProgramLayout, index: u32) ?VariableLayout {
        return .{ .raw = spReflection_GetParameterByIndex(self.raw, index) orelse return null };
    }
};

extern fn spReflectionParameter_GetBindingIndex(p: *SlangReflectionVariableLayout) c_uint;

extern fn spReflectionParameter_GetBindingSpace(p: *SlangReflectionVariableLayout) c_uint;

/// A shader parameter (or struct field) *with layout*: its name, resource
/// category, binding index, byte offset, and type layout.
pub const VariableLayout = struct {
    raw: *SlangReflectionVariableLayout,

    pub fn name(self: VariableLayout) [:0]const u8 {
        const v = spReflectionVariableLayout_GetVariable(self.raw) orelse return "";
        return span(spReflectionVariable_GetName(v));
    }
    /// The parameter category of this variable's leaf resource (buffer,
    /// texture, sampler, uniform, varying, …).
    pub fn category(self: VariableLayout) ParameterCategory {
        const tl = spReflectionVariableLayout_GetTypeLayout(self.raw) orelse return .none;
        return spReflectionTypeLayout_GetParameterCategory(tl);
    }
    /// The resource binding index (Metal `[[buffer(n)]]`/`[[texture(n)]]`/
    /// `[[sampler(n)]]` slot).
    pub fn bindingIndex(self: VariableLayout) u32 {
        return spReflectionParameter_GetBindingIndex(self.raw);
    }
    pub fn bindingSpace(self: VariableLayout) u32 {
        return spReflectionParameter_GetBindingSpace(self.raw);
    }
    /// Byte offset of this variable within its parent, measured in `category`
    /// (use `.uniform` for a field inside a constant buffer).
    pub fn offset(self: VariableLayout, cat: ParameterCategory) usize {
        return spReflectionVariableLayout_GetOffset(self.raw, cat);
    }
    /// This variable's type layout. Present for any real parameter or field;
    /// optional so a null from the C API reads back as absence, like every other
    /// accessor here, rather than aborting the process.
    pub fn typeLayout(self: VariableLayout) ?TypeLayout {
        return .{ .raw = spReflectionVariableLayout_GetTypeLayout(self.raw) orelse return null };
    }
    pub fn stage(self: VariableLayout) Stage {
        return spReflectionVariableLayout_getStage(self.raw);
    }
};

extern fn spReflectionEntryPoint_getName(ep: *SlangReflectionEntryPoint) ?[*:0]const u8;

extern fn spReflectionEntryPoint_getParameterByIndex(ep: *SlangReflectionEntryPoint, index: c_uint) ?*SlangReflectionVariableLayout;

extern fn spReflectionEntryPoint_getParameterCount(ep: *SlangReflectionEntryPoint) c_uint;

extern fn spReflectionEntryPoint_getStage(ep: *SlangReflectionEntryPoint) Stage;

pub const EntryPoint = struct {
    raw: *SlangReflectionEntryPoint,

    pub fn name(self: EntryPoint) [:0]const u8 {
        return span(spReflectionEntryPoint_getName(self.raw));
    }
    pub fn stage(self: EntryPoint) Stage {
        return spReflectionEntryPoint_getStage(self.raw);
    }
    pub fn parameterCount(self: EntryPoint) u32 {
        return spReflectionEntryPoint_getParameterCount(self.raw);
    }
    pub fn parameterByIndex(self: EntryPoint, index: u32) ?VariableLayout {
        return .{ .raw = spReflectionEntryPoint_getParameterByIndex(self.raw, index) orelse return null };
    }
};

// =============================================================================
// Self-check
// =============================================================================

/// Internal scaffolding: the session → module → entry points → composite → link
/// sequence, shared by `verifyAbi` and the test suite. Not part of the binding's
/// API — this mirrors Slang, which has no such one-call helper — but two
/// internal consumers need the same sequence and a second copy would drift.
pub const util = @import("util.zig");

pub const VerifyError = (Error || std.mem.Allocator.Error) || error{ VersionMismatch, AbiCheckFailed };

/// Runtime self-check against a libslang whose ABI has drifted from what this
/// binding assumes — the guard for the version-fragility the mirrored vtables
/// cannot detect at comptime. It (1) asserts the linked libslang reports the
/// pinned build tag, then (2) compiles a known shader, reflects it, and checks
/// that concrete offsets and parameter categories read back exactly as
/// hand-computed. If a future Slang reordered a vtable or changed a layout, one
/// of these would fail loudly instead of returning garbage. Cheap enough to call
/// once at startup.
pub fn verifyAbi(gpa: std.mem.Allocator) VerifyError!void {
    if (!std.mem.eql(u8, buildTag(), version)) return error.VersionMismatch;

    const src =
        \\struct M {
        \\    float4x4 transform;
        \\    float4   base_color;
        \\    float2   tiling;
        \\    float    roughness;
        \\    uint     flags;
        \\};
        \\ConstantBuffer<M> mat;
        \\Texture2D<float4> tex;
        \\SamplerState samp;
        \\[shader("fragment")]
        \\float4 fsMain(float2 uv : TEXCOORD0) : SV_Target {
        \\    float4 c = mat.base_color * tex.Sample(samp, uv * mat.tiling);
        \\    c.a *= mat.roughness;
        \\    c += mat.transform[0];
        \\    return (mat.flags != 0u) ? c * 0.5 : c;
        \\}
    ;
    var diag: Diagnostics = .{};
    defer diag.deinit();
    const global = try GlobalSession.create();
    defer global.deinit();
    const program = util.compileAndLinkProgram(gpa, global, .{
        .source = src,
        .format = .metal,
        .matrix_layout = .column_major,
    }, &diag) catch return error.AbiCheckFailed;
    defer program.deinit();

    const layout = program.getLayout(&diag) catch return error.AbiCheckFailed;
    if (layout.entryPointCount() != 1) return error.AbiCheckFailed;
    const ep = layout.entryPointByIndex(0) orelse return error.AbiCheckFailed;
    if (ep.stage() != .fragment) return error.AbiCheckFailed;

    var saw_buffer = false;
    var saw_texture = false;
    var saw_sampler = false;
    var p: u32 = 0;
    while (p < layout.parameterCount()) : (p += 1) {
        const param = layout.parameterByIndex(p) orelse continue;
        // Categories as a Metal target reports them (`metal_buffer` and friends
        // are Slang's aliases for exactly these three).
        switch (param.category()) {
            .constant_buffer => {
                saw_buffer = true;
                // The constant buffer's element struct: transform (float4x4) at
                // offset 0, base_color (float4) at offset 64. A float4x4 is
                // unambiguously 64 bytes in Metal uniform layout, so a wrong
                // dispatch/ABI would not reproduce this.
                const cb = param.typeLayout() orelse return error.AbiCheckFailed;
                const elem = cb.elementTypeLayout() orelse return error.AbiCheckFailed;
                if (elem.fieldCount() < 2) return error.AbiCheckFailed;
                const f0 = elem.fieldByIndex(0) orelse return error.AbiCheckFailed;
                const f1 = elem.fieldByIndex(1) orelse return error.AbiCheckFailed;
                if (f0.offset(.uniform) != 0) return error.AbiCheckFailed;
                if (f1.offset(.uniform) != 64) return error.AbiCheckFailed;
            },
            .shader_resource => saw_texture = true,
            .sampler_state => saw_sampler = true,
            else => {},
        }
    }
    if (!(saw_buffer and saw_texture and saw_sampler)) return error.AbiCheckFailed;
}
