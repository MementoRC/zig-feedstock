#!/usr/bin/env python3
"""Verify <triplet>-zig-cc wrapper: -Wl,-eSYM to -Wl,/ENTRY:SYM translation on Windows."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def _fail(zig_cc_exe: str, argv: list[str], result: subprocess.CompletedProcess[str], label: str) -> None:
    """Emit the full argv, untruncated stderr, and a -v re-run's link line, then exit."""
    print(f"FAIL: [{zig_cc_exe}] {label} (rc={result.returncode})", flush=True)
    print(f"ARGV: {' '.join(argv)}", flush=True)
    print(f"STDERR:\n{result.stderr}", flush=True)
    verbose = subprocess.run([*argv, "-v"], capture_output=True, text=True, check=False)
    print(f"VERBOSE RERUN rc={verbose.returncode}", flush=True)
    print(f"VERBOSE STDOUT:\n{verbose.stdout[:20000]}", flush=True)
    print(f"VERBOSE STDERR:\n{verbose.stderr[:20000]}", flush=True)
    sys.exit(f"FAIL: [{zig_cc_exe}] {label}")


def main() -> None:
    # Select the wrapper for THIS lane's target: honour CONDA_ZIG_HOST/ZIG_CC
    # instead of a fixed-order PATH probe (that always picked x86_64 first).
    candidates = [
        "x86_64-w64-mingw32-zig-cc",
        "i686-w64-mingw32-zig-cc",
        "aarch64-w64-mingw32-zig-cc",
    ]
    zig_cc_exe = None
    selected_via = None

    zig_cc_env = os.environ.get("ZIG_CC")
    if zig_cc_env:
        found = shutil.which(zig_cc_env) or (zig_cc_env if Path(zig_cc_env).is_file() else None)
        if found:
            zig_cc_exe = found
            selected_via = "ZIG_CC"

    if zig_cc_exe is None:
        conda_zig_host = os.environ.get("CONDA_ZIG_HOST")
        if conda_zig_host:
            found = shutil.which(f"{conda_zig_host}-cc")
            if found:
                zig_cc_exe = found
                selected_via = "CONDA_ZIG_HOST"

    if zig_cc_exe is None:
        for candidate in candidates:
            found = shutil.which(candidate)
            if found:
                zig_cc_exe = found
                selected_via = "candidate list fallback"
                break

    if zig_cc_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-cc wrapper found on PATH")

    on_path = [c for c in candidates if shutil.which(c)]
    print(f"INFO: using wrapper: {zig_cc_exe} (selected via {selected_via})")
    print(f"INFO: wrappers on PATH: {', '.join(on_path)}")

    # Minimal Windows C source with custom entry point
    c_source = """#include <windows.h>
void MyEntry(void) { ExitProcess(0); }
"""

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)

        # Test 1: -Wl,-eSYM (CONCAT form)
        c_file_1 = tmpdir_path / "test1.c"
        exe_file_1 = tmpdir_path / "test1_concat.exe"
        c_file_1.write_text(c_source)

        argv_1 = [zig_cc_exe, "-Wl,-eMyEntry", "-Wl,--subsystem,console", str(c_file_1), "-o", str(exe_file_1)]
        result = subprocess.run(argv_1, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            _fail(zig_cc_exe, argv_1, result, "-Wl,-eMyEntry test1.c failed")

        if not exe_file_1.is_file():
            sys.exit(f"FAIL: [{zig_cc_exe}] did not create {exe_file_1}")

        size_1 = exe_file_1.stat().st_size
        if size_1 == 0:
            sys.exit(f"FAIL: [{zig_cc_exe}] output {exe_file_1} is empty (0 bytes)")

        # Test 2: -Wl,-e,SYM (COMMA form)
        c_file_2 = tmpdir_path / "test2.c"
        exe_file_2 = tmpdir_path / "test2_comma.exe"
        c_file_2.write_text(c_source)

        argv_2 = [zig_cc_exe, "-Wl,-e,MyEntry", "-Wl,--subsystem,console", str(c_file_2), "-o", str(exe_file_2)]
        result = subprocess.run(argv_2, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            _fail(zig_cc_exe, argv_2, result, "-Wl,-e,MyEntry test2.c failed")

        if not exe_file_2.is_file():
            sys.exit(f"FAIL: [{zig_cc_exe}] did not create {exe_file_2}")

        size_2 = exe_file_2.stat().st_size
        if size_2 == 0:
            sys.exit(f"FAIL: [{zig_cc_exe}] output {exe_file_2} is empty (0 bytes)")

    print(f"PASS: [{zig_cc_exe}] -Wl,-eSYM and -Wl,-e,SYM translated to -Wl,--entry,SYM; output sizes: {size_1} {size_2}")


if __name__ == "__main__":
    main()
