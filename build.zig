const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------
    // Core library.
    //
    // The protocol/serialization/type layers are pure computation over byte
    // slices: no sockets, no libc, no OS calls. Transport is injected by the
    // caller, which is what lets the same module compile for native, WASI and
    // freestanding wasm32 (todo.md §6).
    // ---------------------------------------------------------------------
    const quackling = b.addModule("quackling", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------------
    // CLI - a *consumer* of the library, never a special case inside it.
    // ---------------------------------------------------------------------
    // The CLI needs a native HTTP transport, so it is only built for targets
    // that have sockets. wasm consumers use the browser bridge instead.
    const target_is_wasm = target.result.cpu.arch.isWasm();

    // The version comes from build.zig.zon so `--version` cannot drift from the
    // package metadata. `-Dversion=` lets a release build stamp in a git
    // describe string instead.
    const cli_opts = b.addOptions();
    cli_opts.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Version string reported by --version") orelse
            @import("build.zig.zon").version,
    );

    if (!target_is_wasm) {
        const cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quackling", .module = quackling }},
        });
        cli_mod.addOptions("build_options", cli_opts);
        const cli = b.addExecutable(.{ .name = "quackling", .root_module = cli_mod });
        b.installArtifact(cli);

        const run_cli = b.addRunArtifact(cli);
        run_cli.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cli.addArgs(args);
        b.step("run", "Run the Quack CLI").dependOn(&run_cli.step);
    }

    // A library-only build check: proves the protocol core compiles for a
    // target even when the CLI cannot.
    const lib_check = b.addLibrary(.{
        .name = "quackling",
        .root_module = quackling,
        .linkage = .static,
    });
    b.step("check", "Build the core library only (works on every target)")
        .dependOn(&lib_check.step);

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------
    const test_step = b.step("test", "Run unit and golden tests");

    const lib_tests = b.addTest(.{ .root_module = quackling });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // Golden tests replay real server payloads captured from `quack_serve()`.
    const golden = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quackling", .module = quackling }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(golden).step);

    // The CLI's own tests (argument parsing, CSV/JSON escaping, width
    // calculation). Without this step they would compile but never run.
    if (!target_is_wasm) {
        const cli_test_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quackling", .module = quackling }},
        });
        cli_test_mod.addOptions("build_options", cli_opts);
        const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
        test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    }

    // Decoder guard tests: malformed messages that real servers never send,
    // covering bounds checks the golden fixtures cannot reach.
    const decoder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/decoder_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quackling", .module = quackling }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(decoder_tests).step);

    // Client/Result tests over a mock transport - no server required, so the
    // session and streaming logic is covered even in CI without DuckDB.
    const client_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/client_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quackling", .module = quackling }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(client_tests).step);

    // The fuzz suite drives ~25k decodes of mutated input. In Debug that costs
    // ~14s - roughly 80% of the whole test run - because of allocator
    // bookkeeping and the absence of inlining, not because the work is large.
    // Build it with ReleaseSafe: every safety check the suite actually relies
    // on (bounds, overflow, unreachable) is still active, and it runs ~100x
    // faster. `-Dfuzz-optimize` overrides for a Debug-level investigation.
    const fuzz_opt = b.option(
        std.builtin.OptimizeMode,
        "fuzz-optimize",
        "Optimization mode for the fuzz suite (default: ReleaseSafe)",
    ) orelse if (optimize == .Debug) .ReleaseSafe else optimize;
    const fuzz_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = fuzz_opt,
    });
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_test.zig"),
            .target = target,
            .optimize = fuzz_opt,
            .imports = &.{.{ .name = "quackling", .module = fuzz_lib }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // ---------------------------------------------------------------------
    // Integration tests - require a live `quack_serve()` server. Kept off the
    // default `test` step so CI without a server stays green (todo.md §26).
    // ---------------------------------------------------------------------
    const it_opts = b.addOptions();
    it_opts.addOption(
        []const u8,
        "quack_endpoint",
        b.option([]const u8, "quack-endpoint", "Quack server endpoint for integration tests") orelse "",
    );
    it_opts.addOption(
        []const u8,
        "quack_token",
        b.option([]const u8, "quack-token", "Auth token for integration tests") orelse "",
    );

    const itest_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "quackling", .module = quackling }},
    });
    itest_mod.addOptions("build_options", it_opts);
    const itest = b.addTest(.{ .root_module = itest_mod });
    const run_itest = b.addRunArtifact(itest);
    run_itest.has_side_effects = true;
    b.step("test-integration", "Run integration tests against a live Quack server")
        .dependOn(&run_itest.step);

    // ---------------------------------------------------------------------
    // Examples
    // ---------------------------------------------------------------------
    const examples_step = b.step("examples", "Build all examples");
    for ([_][]const u8{ "query", "streaming", "typed_result", "pooled" }) |name| {
        const ex = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "quackling", .module = quackling }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(ex, .{}).step);
    }

    // ---------------------------------------------------------------------
    // Benchmarks (todo.md §25 - measure before optimizing)
    // ---------------------------------------------------------------------
    // Benchmarking a Debug build measures the wrong thing, and the library
    // itself must be optimised too - not just the harness around it.
    const bench_opt: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseFast else optimize;
    const bench_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_opt,
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = bench_opt,
        .imports = &.{.{ .name = "quackling", .module = bench_lib }},
    });
    // Fixtures live outside bench/, so expose them as an import root.
    bench_mod.addAnonymousImport("fixtures", .{
        .root_source_file = b.path("tests/fixtures/fixtures.zig"),
    });
    const bench = b.addExecutable(.{ .name = "quack-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run decode/encode benchmarks").dependOn(&run_bench.step);

    // ---------------------------------------------------------------------
    // Release: cross-compile the CLI for every supported platform, named the way
    // `scripts/install.sh` expects. `zig build release -Dversion=v1.2.3`
    // produces zig-out/release/quackling-<version>-<triple>[.exe].
    // ---------------------------------------------------------------------
    const release_step = b.step("release", "Cross-compile release binaries for every platform");
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };
    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const rel_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = resolved,
            // Release binaries keep safety checks: a client that silently
            // misreads a hostile response is worse than one that aborts.
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "quackling", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            }) }},
        });
        rel_mod.addOptions("build_options", cli_opts);
        const exe = b.addExecutable(.{ .name = "quackling", .root_module = rel_mod });
        const suffix = if (query.os_tag == .windows) ".exe" else "";
        const dest = b.fmt("release/quackling-{s}{s}", .{ triple, suffix });
        const install = b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, dest);
        release_step.dependOn(&install.step);
    }

    // Checksums, so `scripts/install.sh` can verify what it downloaded. Emitted
    // by the release step itself rather than by hand, because a SHA256SUMS that
    // does not match the binaries is worse than none at all.
    const sums = b.addSystemCommand(&.{ "sh", "scripts/checksums.sh" });
    sums.has_side_effects = true;
    for (release_step.dependencies.items) |dep| sums.step.dependOn(dep);
    release_step.dependOn(&sums.step);

    // ---------------------------------------------------------------------
    // WASM build check: proves the protocol core is free of native-only deps.
    // ---------------------------------------------------------------------
    const wasm_step = b.step("wasm", "Build the wasm32-freestanding browser module");
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "quackling",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm/exports.zig"),
            .target = wasm_target,
            .optimize = if (optimize == .Debug) .ReleaseSmall else optimize,
            .imports = &.{.{ .name = "quackling", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasm_target,
                .optimize = if (optimize == .Debug) .ReleaseSmall else optimize,
            }) }},
        }),
    });
    // Freestanding wasm has no entry point; it is a reactor-style module.
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&wasm_install.step);

    // Also drop the module next to the JS binding, so `web/` is a
    // ready-to-publish package and web tooling needs no manual copy step.
    const wasm_to_web = b.addInstallFile(wasm.getEmittedBin(), "../web/quackling.wasm");
    wasm_to_web.step.dependOn(&wasm.step);
    wasm_step.dependOn(&wasm_to_web.step);

    // Exercise the JS-facing FFI boundary with hostile arguments. Requires
    // node; skipped gracefully by CI when it is unavailable.
    const wasm_test = b.addSystemCommand(&.{ "node", "tests/wasm/boundary_test.mjs" });
    wasm_test.step.dependOn(&wasm_install.step);
    wasm_test.has_side_effects = true;
    const wasm_test_step = b.step("test-wasm", "Run the WASM FFI boundary test (requires node)");
    wasm_test_step.dependOn(&wasm_test.step);

    // The JS binding's own tests: request serialization, FETCH streaming and the
    // one-result-at-a-time constraint - properties the WASM module cannot
    // enforce by itself. Needs a live server; skips when none is reachable.
    const web_test = b.addSystemCommand(&.{
        "node", "--test", "web/test/binding.test.mjs", "web/test/worker.test.mjs",
    });
    web_test.step.dependOn(&wasm_to_web.step);
    web_test.has_side_effects = true;
    b.step("test-web", "Run the JS binding + Web Worker tests (needs node + a server)")
        .dependOn(&web_test.step);
}
