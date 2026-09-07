#!/usr/bin/env python3
"""Regression test: dl_iterate_phdr must not trap on an ELF without PT_PHDR.

zig's std.posix.dl_iterate_phdr derives dl_phdr_info.addr by scanning the
program headers for PT_PHDR. Upstream falls off that loop into `unreachable`,
so a binary with no PT_PHDR segment panics with "reached unreachable code"
(ppc64le static links are the case we hit). Our patch
patches/ppc64le/0004-dl-iterate-phdr-no-pt-phdr-posix.zig.patch replaces the
`else unreachable` with `else 0`.

langref used to exercise this incidentally, via doctests that panic and walk
the stack. ppc64le now skips langref (recipe.yaml skip_langref), so this test
is the only thing covering the path.

The test is only meaningful if the probe binary genuinely lacks PT_PHDR: a
binary that HAS one takes the `break` and passes with or without the patch.
That premise is asserted, and a violation is reported as INCONCLUSIVE rather
than PASS.

An optional zig_lib_dir argument points --zig-lib-dir at a different stdlib,
which is how the positive control is run: against an UNPATCHED lib dir this
test must FAIL with "reached unreachable code". If it passes there, the probe
is not reaching the patched code and a green result here proves nothing.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

from _test_utils import _run, check_emulation_env

PROBE_SRC = """\
const std = @import("std");

fn callback(info: *std.posix.dl_phdr_info, size: usize, counter: *usize) error{}!void {
    _ = size;
    counter.* += 1;
    // .addr is the field the PT_PHDR scan computes; touch it so the
    // computation cannot be optimised out.
    std.mem.doNotOptimizeAway(info.addr);
}

pub fn main() !void {
    var counter: usize = 0;
    try std.posix.dl_iterate_phdr(&counter, error{}, callback);
    std.debug.print("dl_iterate_phdr ok, entries={d}\\n", .{counter});
}
"""

PANIC_RE = re.compile(r"reached unreachable code|panic:", re.IGNORECASE)


def _build(triplet: str, src: str, binary: str, zig_target: str,
           zig_lib_dir: str = "") -> subprocess.CompletedProcess:
    # qemu-user does not PATH-search argv[0]; resolve it ourselves.
    zig = shutil.which(f"{triplet}-zig") or f"{triplet}-zig"
    cmd = [zig, "build-exe"]
    if zig_lib_dir:
        cmd += ["--zig-lib-dir", zig_lib_dir]
    # -static keeps the link non-PIE ET_EXEC, which is what drops PT_PHDR.
    cmd += ["-target", zig_target, "-static", "-femit-bin=" + binary, src]
    # _run's 30s default is too low: zig build-exe under qemu has measured >149s.
    return _run(cmd, timeout=600, target=triplet)


def _has_pt_phdr(binary: str) -> bool:
    readelf = subprocess.run(
        ["readelf", "-l", binary],
        check=True, capture_output=True, text=True,
    )
    # Segment-type column; PT_PHDR renders as a bare "PHDR" token.
    return bool(re.search(r"^\s*PHDR\b", readelf.stdout, re.MULTILINE))


def main(triplet: str, zig_target: str = "", zig_lib_dir: str = "") -> int:
    if not check_emulation_env(triplet):
        return 1
    if not zig_target:
        zig_target = triplet.replace("-conda", "") + ".2.17"

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "probe.zig")
        binary = os.path.join(tmpdir, "probe")
        with open(src, "w") as f:
            f.write(PROBE_SRC)

        build = _build(triplet, src, binary, zig_target, zig_lib_dir)
        if build.returncode != 0:
            # Distinct from a runtime panic: a compile failure here usually
            # means the std.posix.dl_iterate_phdr signature drifted, not that
            # the PT_PHDR bug is back.
            print("FAIL: could not build the dl_iterate_phdr probe "
                  "(API drift, not a PT_PHDR result?)", file=sys.stderr)
            print(build.stdout, file=sys.stderr)
            print(build.stderr, file=sys.stderr)
            return 1

        if _has_pt_phdr(binary):
            print("INCONCLUSIVE: probe binary HAS a PT_PHDR segment, so it "
                  "cannot exercise the patched path; adjust the link flags",
                  file=sys.stderr)
            subprocess.run(["readelf", "-l", binary], check=False)
            return 1

        result = _run([binary], timeout=600, target=triplet)
        combined = (result.stdout or "") + (result.stderr or "")

        if result.returncode == 0 and not PANIC_RE.search(combined):
            print("PASS dl_iterate_phdr survives an ELF without PT_PHDR")
            return 0

        print(f"FAIL: probe exited {result.returncode} on a binary without "
              "PT_PHDR", file=sys.stderr)
        print("--- stdout ---", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print("--- stderr ---", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        print("--- readelf -l (probe) ---", file=sys.stderr)
        subprocess.run(["readelf", "-l", binary], check=False)
        return 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3, 4):
        sys.exit(f"usage: {sys.argv[0]} <conda_triplet> [zig_target] [zig_lib_dir]")
    sys.exit(main(
        sys.argv[1],
        sys.argv[2] if len(sys.argv) > 2 else "",
        sys.argv[3] if len(sys.argv) > 3 else "",
    ))