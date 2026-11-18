# [zslang](https://github.com/zig-gamedev/zslang)

Zig package for [Slang shader compiler](https://github.com/shader-slang/slang) (2026.14) with
an idiomatic Zig binding for the SDK.

**Work-in-progress** - incrementally updated.

## Slang SDK Coverage

### Compilation
`IGlobalSession`, `ISession`, `IModule`, `IComponentType` and `IBlob` are COM-style C++
behind one C entry point, `slang_createGlobalSession`. Their vtables are mirrored in Zig and
called directly, so a consumer needs no C or C++ toolchain — at the cost of transcribing
slot order by hand, which is what the checks below are for.

Every handle owns one COM reference and takes exactly one `deinit`; reflection handles are
borrowed views and take none. The directly-returned `IModule*` is borrowed by the session,
so it is `addRef`ed on the way out to keep that uniform.

**Version fragility** - *vtable order matters*, and a release could change it without
changing any struct size. Hence the pinned SDK version, `comptime` asserts pinning every
called slot to its index and every descriptor's field offsets — both tables checked against
a C++ `sizeof`/`offsetof` probe compiled from `slang.h`, for 64-bit and 32-bit alike — and
`verifyAbi`, which compiles and reflects a known shader at runtime to confirm the values
read back as hand-computed.

**Bound** - `slang_createGlobalSession` and `createSession` (1/30 `IGlobalSession`); loading a
module from source, its defined entry points and its transitive dependency list (4/13
`IModule`); `createComposite`, `link` and `getTargetCode` (3/14 `IComponentType`);
`TargetDesc`'s profile, float-mode and line-directive fields.

**TODO** - Core-module load/save, downstream-compiler config, capability and profile queries;
loading from file, IR blob, precompiled or builtin modules; `findEntryPointByName`,
`findAndCheckEntryPoint`, `getName`, `getFilePath`, `getUniqueIdentity` and `IEntryPoint`
itself; `linkWithOptions`, `renameEntryPoint`, `getEntryPointCode`,
`getEntryPointHostCallable`; all 158 `CompilerOptionName` entries and preprocessor macros;
module serialization; specialization, generics and `ITypeConformance`; compile metadata
(`IMetadata` and the bindless, cooperative-type, coverage and synthetic-resource variants).

### Reflection
A flat set of `extern "C"` `spReflection*` functions, which the C++ reflection classes only
wrap inline.

**Bound** - A linked program's entry points and global parameters (4/29 program); each entry
point's name, stage and parameters (4/12 entry points); types and their layouts — kind,
scalar type, element type and count, row/column and field counts, resource shape, access and
result type, sizes, strides, byte offsets, binding index and space (9/50 type layouts, 11/21
types, 4/9 variable layouts, 1/11 variables). Enough to walk global parameters, their
bindings and constant-buffer field layouts.

**TODO** - Finding a type, function or variable by name, type parameters, hashed strings and
JSON dump; compute thread-group and wave size, result var layout, name overrides; binding and
descriptor ranges, alignment, matrix layout mode, field lookup by name; semantic
name/index, image format, pending data layout; modifiers, user attributes and defaults; and
functions, generics, declarations, user attributes and type parameters.

### Not planned (yet?)
The SDK is more than its compiler library, and the rest is not planned here: the host-side
interfaces you *implement* rather than call - filesystems, writers, the shared-library
loader and the profiler. `slang-gfx` is a deprecated graphics abstraction over
D3D12/Vulkan/Metal/WGPU shipped as its own library. Host-callable entry points and executing
the byte-code interpreter to run compiled shader code on the CPU is also out.


## Tests

```
zig build test
```

Builds and runs the suite against the real libslang for your host. The first build fetches
the SDK for your target: 20-55 MB down, ~150 MB unpacked, cached globally by Zig.

```
zig build test -Dall-targets
```

Additionally builds the suite for every target upstream ships an SDK for — macOS, Linux and
Windows on x86_64 and arm64 — plus, on a Windows host, the two MSVC-ABI spellings of the
Windows targets, which need an MSVC installation Zig cannot ship. Those the host can execute
are run (on an arm64 Mac that is both macOS targets, the x86_64 one under Rosetta); the rest
are built and linked, then skipped. It is behind a flag because it fetches all six SDKs.

The suite links against the real libslang and covers the dynamic half: a shader compiles to
a usable blob; reflection reports field offsets, sizes, strides and binding indices,
hand-computed and cross-checked against the `[[buffer/texture/sampler(n)]]` attributes Slang
emitted; parameter categories are pinned for both a Metal and a SPIR-V layout, since they
differ; session options reach the compiler — a preprocessor macro selects a `#ifdef` branch,
a search path resolves an `import` from disk; a broken module yields diagnostics rather than
a crash; a module reports its transitive dependencies; sessions tear down without the
borrowed-handle use-after-free. What can be settled without running anything — descriptor
layouts, vtable slot indices — is asserted at `comptime` instead.

## Shipping a binary

Install the shared libraries from the named lazy path:

```zig
const zslang = b.dependency("zslang", .{ .target = target, .optimize = .ReleaseFast });

exe.root_module.addImport("slang", zslang.module("slang"));

b.installDirectory(.{
    .source_dir = zslang.namedLazyPath("slang-runtime-dir"),
    // Windows finds DLLs next to the .exe; elsewhere an rpath does the work.
    .install_dir = if (target.result.os.tag == .windows) .bin else .lib,
    .install_subdir = "",
});
```

`slang-runtime-dir` is the SDK's `bin/` on Windows and `lib/` elsewhere — the shared
libraries, not the import libraries. Off Windows the binary also needs its own
`@loader_path`/`$ORIGIN`-relative rpath.

That directory is ~150 MB, mostly `slang-llvm`. The minimum is:

- **macOS/Linux:** one file. `libslang.dylib` is a symlink to
  `libslang-compiler.<version>.dylib`, and the versioned name is what your binary records
  as its `@rpath` dependency. MSL and SPIR-V both work with only it present.
- **Windows:** two. `slang.dll` is a 158 KB stub forwarding 458 exports to
  `slang-compiler.dll`.

The rest (`slang-llvm`, `slang-glslang`, `gfx`, `slang-rt`, the standard-module directory)
serves paths this binding does not reach.

On Windows a *host tool* that links this — a shader compiler run during your build — needs
the DLLs on `PATH`.
