//! Internal utilities shared by `verifyAbi` and the test suite: the
//! session → module → entry points → composite → link sequence.

const std = @import("std");
const slang = @import("root.zig");

pub const CompileOptions = struct {
    /// Slang source, NUL-terminated.
    source: [:0]const u8,
    module_name: [:0]const u8 = "module",
    path: [:0]const u8 = "module.slang",
    /// Target format to emit (e.g. `.metal`, `.spirv`).
    format: slang.CompileTarget,
    matrix_layout: slang.MatrixLayoutMode = .row_major,
    /// Search paths for `import`/`#include`. Each entry NUL-terminated.
    search_paths: []const [*:0]const u8 = &.{},
    /// Preprocessor macros `#define`d for every module in the session.
    preprocessor_macros: []const slang.PreprocessorMacroDesc = &.{},
};

/// A linked program: session plus linked component, so target code and
/// reflection come from the *same* link.
pub const Program = struct {
    session: slang.Session,
    linked: slang.Component,

    pub fn deinit(self: Program) void {
        self.linked.deinit();
        self.session.deinit();
    }

    /// Target code for the program (target index 0). An owned `Blob`.
    pub fn getTargetCode(self: Program, diag: *slang.Diagnostics) slang.Error!slang.Blob {
        return self.linked.getTargetCode(0, diag);
    }

    /// Reflection for the program (target index 0). Borrowed — valid until this
    /// `Program` is `deinit`ed.
    pub fn getLayout(self: Program, diag: *slang.Diagnostics) slang.Error!slang.ProgramLayout {
        return self.linked.getLayout(0, diag);
    }
};

/// Compile a single `.slang` source string for `opts.format`, auto-discovering
/// and linking all of its `[shader(...)]` entry points, and return the linked
/// `Program` (from which both target code and reflection are available).
///
/// `gpa` is used only for a transient list of entry-point components. On any
/// failure, `diag` holds the compiler diagnostics (if any). Caller owns the
/// returned `Program`.
pub fn compileAndLinkProgram(
    gpa: std.mem.Allocator,
    global: slang.GlobalSession,
    opts: CompileOptions,
    diag: *slang.Diagnostics,
) (slang.Error || std.mem.Allocator.Error)!Program {
    const targets = [_]slang.TargetDesc{slang.target(opts.format)};
    const session = try global.createSession(.{
        .targets = &targets,
        .search_paths = opts.search_paths,
        .matrix_layout = opts.matrix_layout,
        .preprocessor_macros = opts.preprocessor_macros,
    });
    errdefer session.deinit();

    var module = try session.loadModuleFromSource(opts.module_name, opts.path, opts.source, diag);
    defer module.deinit();

    // Compose the module with every entry point it defines. The module, entry
    // points, and composite are only needed to produce the linked component;
    // once linked, they can be released (the session keeps the code alive).
    var components: std.ArrayList(*slang.IComponentType) = .empty;
    defer components.deinit(gpa);
    var owned_eps: std.ArrayList(slang.Component) = .empty;
    defer {
        for (owned_eps.items) |ep| ep.deinit();
        owned_eps.deinit(gpa);
    }

    try components.append(gpa, module.raw.asComponent());
    const n = module.definedEntryPointCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ep = try module.definedEntryPoint(i);
        try owned_eps.append(gpa, ep);
        try components.append(gpa, ep.raw);
    }

    const composed = try session.createComposite(components.items, diag);
    defer composed.deinit();

    const linked = try composed.link(diag);
    return .{ .session = session, .linked = linked };
}

/// `compileAndLinkProgram` plus `getTargetCode`, for callers that want only the
/// code. The returned `Blob` deliberately outlives the session: a Slang blob
/// carries its own reference and its own buffer, so releasing the session that
/// produced it does not invalidate the bytes.
pub fn compileAndLinkProgramToTargetCode(
    gpa: std.mem.Allocator,
    global: slang.GlobalSession,
    opts: CompileOptions,
    diag: *slang.Diagnostics,
) (slang.Error || std.mem.Allocator.Error)!slang.Blob {
    const p = try compileAndLinkProgram(gpa, global, opts, diag);
    defer p.deinit();
    return p.getTargetCode(diag);
}
