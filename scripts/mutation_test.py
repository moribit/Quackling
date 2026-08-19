#!/usr/bin/env python3
"""Mutation testing for Quackling's safety-critical guards.

A passing test suite only proves the tests *run*; it does not prove they would
notice if a bounds check disappeared. This script breaks each guard one at a
time and asserts that `zig build test` fails. A guard whose mutant SURVIVES has
no covering test, which is a real gap even though CI is green.

    python3 scripts/mutation_test.py            # run everything
    python3 scripts/mutation_test.py --list     # show the catalogue
    python3 scripts/mutation_test.py -k enum    # only mutants matching "enum"

Exit status is non-zero if any mutant survives, so this can gate CI.

Design notes:
  * Output is flushed per mutant - a long run must show progress, not buffer it.
  * Each source file is restored in a `finally`, and a SIGINT handler restores
    too, so an interrupted run never leaves the tree mutated.
  * A hang counts as CAUGHT: a guard whose removal makes the suite spin forever
    is unambiguously load-bearing (this is how the unbounded FETCH loop was
    found).
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Guards whose removal is not observable from a deterministic in-process test,
# with the reason. These are reported but do not fail the run.
#
# Keep this list *small* and justified: "hard to test" is not a reason, only
# "cannot be observed without relying on undefined behaviour or a race".
EXPECTED_SURVIVORS = {
    "pool/deinit-waits-for-leases":
        "Protects a caller that dereferences `lease.client` after `deinit`. "
        "The library's own release path never touches the client during "
        "shutdown, so removing the wait causes no in-library fault; the only "
        "way to observe it is a caller-side use-after-free (undefined "
        "behaviour) or a probe that races the releaser thread needed to "
        "unblock `deinit`. Verified by inspection: `releaseClient`/"
        "`discardClient` both return early on `closed` without using `c`.",
}

# (name, file, original, replacement)
#
# Each entry removes exactly one guard. The replacement must still compile -
# a mutant that fails to build tells us nothing about test coverage.
MUTANTS = [
    # -- serialization/reader.zig: the untrusted-byte primitives -------------
    ("reader/varint-overflow", "src/serialization/reader.zig",
     "            if (shift >= 64) return Error.VarIntOverflow;\n            // Bits that would be shifted",
     "            if (false) return Error.VarIntOverflow;\n            // Bits that would be shifted"),
    ("reader/varint-capacity", "src/serialization/reader.zig",
     "            if (capacity < 64 and payload >= (@as(u64, 1) << @intCast(capacity))) {\n                return Error.VarIntOverflow;\n            }",
     "            if (capacity < 64 and payload >= (@as(u64, 1) << @intCast(capacity))) {\n                // mutant: detected but not reported\n            }"),
    ("reader/byte-length-cap", "src/serialization/reader.zig",
     "        if (len > self.limits.max_byte_length) return Error.LengthLimitExceeded;",
     "        if (false) return Error.LengthLimitExceeded;"),
    ("reader/length-vs-remaining", "src/serialization/reader.zig",
     "        const n: usize = @intCast(len);\n        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;\n        return n;\n    }\n\n    /// A list element count.",
     "        const n: usize = @intCast(len);\n        return n;\n    }\n\n    /// A list element count."),
    ("reader/list-count-cap", "src/serialization/reader.zig",
     "        if (len > self.limits.max_list_length) return Error.LengthLimitExceeded;",
     "        if (false) return Error.LengthLimitExceeded;"),
    ("reader/list-vs-remaining", "src/serialization/reader.zig",
     "        // Every element costs at least one byte, so a count exceeding the bytes\n        // left is guaranteed-truncated input. Reject before allocating for it.\n        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;",
     "        // Every element costs at least one byte, so a count exceeding the bytes\n        // left is guaranteed-truncated input. Reject before allocating for it.\n        if (false) return Error.UnexpectedEndOfBuffer;"),
    ("reader/take-bounds", "src/serialization/reader.zig",
     "        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;\n        const out = self.buf[self.pos..][0..n];",
     "        if (n > self.buf.len) return Error.UnexpectedEndOfBuffer;\n        const out = self.buf[self.pos..][0..n];"),
    ("reader/depth-limit", "src/serialization/reader.zig",
     "        if (self.depth >= self.limits.max_depth) return Error.LengthLimitExceeded;",
     "        if (false) return Error.LengthLimitExceeded;"),

    # -- serialization/decoder.zig: structural validation --------------------
    ("decoder/payload-length", "src/serialization/decoder.zig",
     "            if (declared != expected) return Error.MalformedVector;",
     "            if (declared != expected) {} // mutant: mismatch detected but allowed"),
    ("decoder/validity-assignment", "src/serialization/decoder.zig",
     "                result.validity = ValidityMask.init(bytes, count);",
     "                _ = bytes;"),
    ("decoder/dictionary-bounds", "src/serialization/decoder.zig",
     "        if (v >= dict_count) return Error.MalformedVector;",
     "        if (false) return Error.MalformedVector;"),
    ("decoder/selection-length", "src/serialization/decoder.zig",
     "    if (sel.len < count * 4) return Error.MalformedVector;",
     "    if (false) return Error.MalformedVector;"),
    ("decoder/column-count-match", "src/serialization/decoder.zig",
     "                if (n != types_filled) return Error.MalformedVector;",
     "                if (false) return Error.MalformedVector;"),
    ("decoder/row-count-cap", "src/serialization/decoder.zig",
     "                if (rc > data_chunk_mod.standard_vector_size) return Error.RowCountTooLarge;",
     "                if (false) return Error.RowCountTooLarge;"),
    ("decoder/varchar-count-match", "src/serialization/decoder.zig",
     "            const n = try r.readListLength();\n            if (n != count) return Error.MalformedVector;\n            const slices = try allocator.alloc([]const u8, n);",
     "            const n = try r.readListLength();\n            if (false) return Error.MalformedVector;\n            const slices = try allocator.alloc([]const u8, n);"),
    ("decoder/enum-count-agreement", "src/serialization/decoder.zig",
     "        if (declared != n) return Error.MalformedVector;",
     "        if (declared != n) {} // mutant: disagreement detected but allowed"),
    ("decoder/fsst-rejection", "src/serialization/decoder.zig",
     "                    .fsst => return Error.UnsupportedVectorType,",
     "                    .fsst => {},"),
    ("decoder/unknown-field", "src/serialization/decoder.zig",
     "            else => return Error.UnexpectedField,\n        }\n    }\n\n    return DataChunk{",
     "            else => {},\n        }\n    }\n\n    return DataChunk{"),

    # -- types: value interpretation -----------------------------------------
    ("validity/null-semantics", "src/types/validity.zig",
     "        return (b[byte_idx] >> bit) & 1 == 1;",
     "        return (b[byte_idx] >> bit) & 1 == 0;"),
    ("validity/mask-bounds", "src/types/validity.zig",
     "        if (byte_idx >= b.len) return false;",
     "        if (false) return false;"),
    ("vector/enum-index-bounds", "src/types/vector.zig",
     "                if (idx >= self.type.enum_values.len) return Error.MalformedVector;",
     "                if (false) return Error.MalformedVector;"),
    ("vector/row-bounds", "src/types/vector.zig",
     "    pub fn getValue(self: *const Vector, i: usize) Error!Value {\n        if (i >= self.count) return Error.MalformedVector;",
     "    pub fn getValue(self: *const Vector, i: usize) Error!Value {\n        if (false) return Error.MalformedVector;"),
    ("vector/readfixed-bounds", "src/types/vector.zig",
     "        if (off + @sizeOf(T) > bytes.len) return null;",
     "        if (false) return null;"),
    ("vector/asslice-alignment", "src/types/vector.zig",
     "        if (@intFromPtr(bytes.ptr) % @alignOf(T) != 0) return null;",
     "        if (false) return null;"),
    ("vector/asslice-length", "src/types/vector.zig",
     "        return width == @sizeOf(T) and bytes.len >= self.count * @sizeOf(T);",
     "        return width == @sizeOf(T) and bytes.len >= 0 * @sizeOf(T);"),

    # -- params.zig: the SQL-injection boundary --------------------------------
    ("params/quote-escaping", "src/params.zig",
     "        if (c == '\\'') try w.writeByte('\\'');",
     "        if (false) try w.writeByte('\\'');"),
    ("params/skip-string-literals", "src/params.zig",
     "            '\\'' => i = try copyQuoted(allocator, &out, sql, i, '\\''),",
     "            '\\'' => { try out.append(allocator, c); i += 1; },"),
    ("params/skip-line-comments", "src/params.zig",
     "                if (i + 1 < sql.len and sql[i + 1] == '-') {",
     "                if (false) {"),
    ("params/skip-block-comments", "src/params.zig",
     "                if (i + 1 < sql.len and sql[i + 1] == '*') {",
     "                if (false) {"),
    ("params/count-match", "src/params.zig",
     "    if (next != params.len) return Error.ParameterCountMismatch;",
     "    if (false) return Error.ParameterCountMismatch;"),
    ("params/count-overrun", "src/params.zig",
     "                if (next >= params.len) return Error.ParameterCountMismatch;",
     "                if (false and next >= params.len) return Error.ParameterCountMismatch;"),
    ("params/utf8-validation", "src/params.zig",
     "    if (!std.unicode.utf8ValidateSlice(s)) return Error.InvalidUtf8;",
     "    if (false) return Error.InvalidUtf8;"),
    ("params/nul-rejection", "src/params.zig",
     "    if (std.mem.indexOfScalar(u8, s, 0) != null) return Error.UnsupportedParameter;",
     "    if (false) return Error.UnsupportedParameter;"),

    # -- client.zig / result.zig: session and streaming -------------------------
    ("client/auth-classification", "src/client.zig",
     '    return std.ascii.indexOfIgnoreCase(m, "authenticat") != null or',
     '    return false and std.ascii.indexOfIgnoreCase(m, "authenticat") != null or'),
    ("client/protocol-version-min", "src/client.zig",
     "        if (body.quack_version < compat.min_supported_version or",
     "        if (false and body.quack_version < compat.min_supported_version or"),
    ("client/protocol-version-max", "src/client.zig",
     "            body.quack_version > compat.max_supported_version)",
     "            false and body.quack_version > compat.max_supported_version)"),
    ("client/http-status", "src/client.zig",
     "        if (response.status < 200 or response.status >= 300) {",
     "        if (false) {"),
    ("client/response-size-cap", "src/client.zig",
     "        if (response.body.len > self.options.max_response_bytes) {",
     "        if (false) {"),
    ("client/missing-session-id", "src/client.zig",
     "        if (header.connection_id.len == 0) return errors.ProtocolError.UnexpectedMessageType;",
     "        if (false) return errors.ProtocolError.UnexpectedMessageType;"),
    ("result/fetch-ceiling", "src/result.zig",
     "        if (self.fetches >= self.max_fetches) {",
     "        if (false) {"),
    ("result/empty-batch-terminates", "src/result.zig",
     "        if (got.body.chunks.len == 0) {",
     "        if (false) {"),
    ("result/cancel-check", "src/result.zig",
     "            if (self.cancel) |c| if (c.isCancelled()) return errors.TransportError.Cancelled;",
     "            if (self.cancel) |c| if (false and c.isCancelled()) return errors.TransportError.Cancelled;"),

    # -- pool.zig: concurrency ---------------------------------------------------
    ("pool/mutual-exclusion", "src/pool.zig",
     "        self.mutex.lockUncancelable(self.io);\n        defer self.mutex.unlock(self.io);\n\n        if (self.closed) return Error.PoolClosed;",
     "        if (self.closed) return Error.PoolClosed;"),
    ("pool/capacity-limit", "src/pool.zig",
     "            if (self.owned.items.len < self.options.max_connections) {",
     "            if (true) {"),
    ("pool/deinit-waits-for-leases", "src/pool.zig",
     "        while (self.leased > 0) {\n            self.available.waitUncancelable(self.io, &self.mutex);\n        }",
     "        while (false) {\n            self.available.waitUncancelable(self.io, &self.mutex);\n        }"),
    ("pool/double-release-guard", "src/pool.zig",
     "    pub fn release(self: *Lease) void {\n        if (self.released) return;",
     "    pub fn release(self: *Lease) void {\n        if (false) return;"),

    # -- uri.zig: endpoint validation ----------------------------------------------
    ("uri/embedded-credentials", "src/uri.zig",
     "    if (std.mem.indexOfScalar(u8, rest, '@') != null) return Error.InvalidUrl;",
     "    if (false) return Error.InvalidUrl;"),
    ("uri/control-characters", "src/uri.zig",
     "        if (c <= 0x20 or c == 0x7F) return Error.InvalidUrl;",
     "        if (c <= 0x20 or c == 0x7F) {} // mutant: detected but allowed"),
    ("uri/zero-port", "src/uri.zig",
     "    if (p == 0) return Error.InvalidPort;",
     "    if (false) return Error.InvalidPort;"),

    # -- protocol/message.zig: framing ------------------------------------------------
    ("message/header-unknown-field", "src/protocol/message.zig",
     "                else => return Error.UnexpectedField,\n            }\n        }\n        return h;",
     "                else => {},\n            }\n        }\n        return h;"),
    ("message/connection-id-default-skip", "src/protocol/message.zig",
     "        try w.writePropertyStringWithDefault(hdr_connection_id, self.connection_id);",
     "        try w.writePropertyString(hdr_connection_id, self.connection_id);"),
]

# Per-mutant timeout, derived from the measured baseline (see `main`). A mutant
# that removes a loop bound makes the suite spin forever, and waiting out a
# fixed generous timeout dominates the whole run once the suite itself is fast:
# with an ~8s suite, a 240s ceiling costs 30x a normal mutant. A small multiple
# of the baseline is enough to distinguish "slow" from "never finishes", while
# staying well clear of ordinary variance.
TIMEOUT_FLOOR_S = 45.0
TIMEOUT_MULTIPLIER = 6.0
_timeout_s: float = 240.0
# The suite currently running, so an interrupt can kill its whole tree too.
_active: subprocess.Popen | None = None


def run_suite() -> tuple[str, str]:
    """Run the test suite. Returns (verdict, detail).

    The suite is launched in its own process group so that a timeout can kill
    the *whole tree*. `zig build` spawns the compiled test binaries as
    grandchildren; killing only the direct child leaves those spinning at 100%
    CPU forever, and a mutant that removes a loop bound produces exactly that.
    """
    global _active
    proc = subprocess.Popen(
        ["zig", "build", "test"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,  # its own process group, so we can signal it all
    )
    _active = proc
    try:
        stdout, stderr = proc.communicate(timeout=_timeout_s)
    except subprocess.TimeoutExpired:
        _kill_tree(proc)
        _active = None
        # A guard whose removal makes the suite spin is unambiguously needed.
        return "CAUGHT", "hang"
    finally:
        if _active is proc:
            _active = None

    if proc.returncode != 0:
        out = stdout + stderr
        if "error:" in out and "failed:" not in out and "pass" not in out:
            # Did not compile: the mutant is malformed, not the tests' fault.
            first = next((l.strip() for l in out.splitlines() if "error:" in l), "")
            return "INVALID", first[:90]
        failing = [l.strip() for l in out.splitlines() if "failed:" in l]
        detail = failing[0].split("failed:")[0].strip() if failing else ""
        if detail.startswith("error: '"):
            detail = detail[len("error: '"):].rstrip("'")
        return "CAUGHT", detail[:70]
    return "SURVIVED", ""


def _descendants(root_pid: int) -> list[int]:
    """Every transitive child of `root_pid`, deepest first.

    `killpg` is not enough here: Zig's build runner starts each compiled test
    binary in its *own* session, so those grandchildren are not in the group we
    created and a group signal never reaches them. Verified by comparing pgids -
    the test binary reports a different pgid from the `zig build` parent. They
    must therefore be located through the process tree instead.
    """
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,ppid="], capture_output=True, text=True, timeout=10
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return []

    children: dict[int, list[int]] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)

    found: list[int] = []
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        for child in children.get(pid, ()):
            found.append(child)
            stack.append(child)
    # Deepest first, so a parent cannot respawn a child we already killed.
    found.reverse()
    return found


def _orphaned_test_binaries() -> list[int]:
    """Test binaries from *this* project's cache that no longer have a live
    build runner above them.

    Matched narrowly on the project's own `.zig-cache` path so a concurrent,
    unrelated Zig build on the same machine is never touched.
    """
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return []

    alive = set()
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        alive.add(pid)
        rows.append((pid, ppid, parts[2]))

    marker = ".zig-cache/o/"
    out_pids = []
    for pid, ppid, cmd in rows:
        if marker not in cmd or "test --cache-dir" not in cmd:
            continue
        # Only ours, and only if its build runner is gone.
        if ppid not in alive or ppid == 1:
            out_pids.append(pid)
    return out_pids


def _kill_tree(proc: subprocess.Popen) -> None:
    """Kill a process and every descendant, then reap it.

    A mutant that removes a loop bound leaves a test binary spinning at 100%
    CPU. Killing only the direct child orphans it, where it runs until the
    machine is rebooted - so the whole tree has to go.

    The tree is re-scanned between passes rather than snapshotted once: the Zig
    build runner keeps spawning test binaries while it is alive, so a single
    snapshot misses any child created after it was taken.
    """
    # Order matters: enumerate the tree *first*, then kill leaves before the
    # root. Killing the root first reparents its children away, and they can no
    # longer be found by walking down from it.
    for attempt in range(4):
        victims = _descendants(proc.pid)  # deepest first
        sig = signal.SIGKILL if attempt else signal.SIGTERM
        for pid in victims:
            try:
                os.kill(pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.kill(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            continue
        if not _descendants(proc.pid) and not _orphaned_test_binaries():
            break

    # Final sweep for anything reparented mid-kill.
    for pid in _orphaned_test_binaries():
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    for stream in (proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", metavar="SUBSTR", help="only run mutants whose name contains SUBSTR")
    ap.add_argument("--list", action="store_true", help="list mutants and exit")
    args = ap.parse_args()

    selected = [m for m in MUTANTS if not args.k or args.k in m[0]]
    if args.list:
        for name, path, _, _ in selected:
            print(f"  {name:38} {path}")
        print(f"\n  {len(selected)} mutants")
        return 0
    if not selected:
        print(f"no mutants match {args.k!r}", file=sys.stderr)
        return 2

    # A baseline failure would make every result meaningless. Time it too, so
    # the per-mutant timeout tracks how fast the suite actually is.
    print("baseline: ", end="", flush=True)
    global _timeout_s
    t0 = time.time()
    verdict, detail = run_suite()
    baseline_s = time.time() - t0
    if verdict != "SURVIVED":
        print(f"FAIL - the suite must be green before mutating ({verdict} {detail})")
        return 2
    _timeout_s = max(TIMEOUT_FLOOR_S, baseline_s * TIMEOUT_MULTIPLIER)
    print(f"green in {baseline_s:.1f}s (per-mutant timeout {_timeout_s:.0f}s)\n")

    in_flight: dict[Path, Path] = {}

    def restore_all(*_):
        # Kill any suite still running before touching the sources, so a
        # half-mutated tree is never left behind a live compiler.
        if _active is not None:
            _kill_tree(_active)
        for target, backup in list(in_flight.items()):
            if backup.exists():
                shutil.move(backup, target)
        in_flight.clear()

    signal.signal(signal.SIGINT, lambda *a: (restore_all(), sys.exit(130)))
    signal.signal(signal.SIGTERM, lambda *a: (restore_all(), sys.exit(143)))

    caught, survived, invalid, expected = [], [], [], []
    width = max(len(m[0]) for m in selected)
    started = time.time()

    for i, (name, rel, old, new) in enumerate(selected, 1):
        path = ROOT / rel
        src = path.read_text()
        print(f"[{i:2}/{len(selected)}] {name:<{width}} ", end="", flush=True)

        if old not in src:
            print("INVALID (pattern not found - code moved?)", flush=True)
            invalid.append(name)
            continue

        backup = path.with_suffix(path.suffix + ".mutbak")
        shutil.copy(path, backup)
        in_flight[path] = backup
        try:
            path.write_text(src.replace(old, new, 1))
            verdict, detail = run_suite()
        finally:
            shutil.move(backup, path)
            in_flight.pop(path, None)

        if verdict == "CAUGHT":
            print(f"caught     {detail}", flush=True)
            caught.append(name)
        elif verdict == "INVALID":
            print(f"INVALID    {detail}", flush=True)
            invalid.append(name)
        elif name in EXPECTED_SURVIVORS:
            print("survived   (expected - see EXPECTED_SURVIVORS)", flush=True)
            expected.append(name)
        else:
            print("SURVIVED  <-- no test covers this guard", flush=True)
            survived.append(name)

    total = len(caught) + len(survived)
    elapsed = time.time() - started
    print(f"\n{'=' * 72}")
    print(f"caught {len(caught)}/{total}"
          f"{f' ({100 * len(caught) // total}%)' if total else ''}"
          f"   expected-survivors {len(expected)}"
          f"   invalid {len(invalid)}   in {elapsed:.0f}s")
    if expected:
        print("\nEXPECTED SURVIVORS (documented as not deterministically testable):")
        for n in expected:
            print(f"  - {n}")
            print(f"      {EXPECTED_SURVIVORS[n]}")
    if survived:
        print("\nSURVIVING MUTANTS (guards with no covering test):")
        for n in survived:
            print(f"  - {n}")
    if invalid:
        print("\nINVALID (pattern not found or would not compile - update the catalogue):")
        for n in invalid:
            print(f"  - {n}")
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
