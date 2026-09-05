#!/usr/bin/env bash
# Zig build diagnostics: phase/rc notes always visible; heavy diagnostics gated on ZIG_DIAG=1.
# Never fails the build -- every external command is guarded with command -v.

[[ -n "${_ZIG_DIAG_SH_SOURCED:-}" ]] && return 0
_ZIG_DIAG_SH_SOURCED=1

source "${RECIPE_DIR}/building/_common.sh"

zig_diag_on() { [[ "${ZIG_DIAG:-0}" == "1" ]]; }

# Always prints -- phase boundaries and rc must never be invisible.
zig_diag_note() {
  echo "[zig-diag] $*" >&2
}

zig_diag_env() {
  local label="${1:-unknown}"
  zig_diag_on || return 0
  zig_diag_note "=== env: ${label} ==="
  command -v free &>/dev/null && free -m >&2
  command -v nproc &>/dev/null && zig_diag_note "nproc=$(nproc)"
  ulimit -a >&2 || true
  zig_diag_note "target_platform=${target_platform:-(unset)}"
  zig_diag_note "build_platform=${build_platform:-(unset)}"
  zig_diag_note "PREFIX=${PREFIX:-(unset)}"
  zig_diag_note "BUILD_PREFIX=${BUILD_PREFIX:-(unset)}"
  zig_diag_note "CONDA_BUILD_SYSROOT=${CONDA_BUILD_SYSROOT:-(unset)}"
  zig_diag_note "ZIG_TRIPLET=${ZIG_TRIPLET:-(unset)}"
  zig_diag_note "ZIG_QEMU_ARCH=${ZIG_QEMU_ARCH:-(unset)}"
  zig_diag_note "QEMU_EXECVE=${QEMU_EXECVE:-(unset)}"
  zig_diag_note "QEMU_EXECVE_NATIVE_PASSTHROUGH=${QEMU_EXECVE_NATIVE_PASSTHROUGH:-(unset)}"
  zig_diag_note "QEMU_LD_PREFIX=${QEMU_LD_PREFIX:-(unset)}"
  zig_diag_note "CPU_COUNT=${CPU_COUNT:-(unset)}"
  zig_diag_note "SKIP_LANGREF=${SKIP_LANGREF:-(unset)}"
  zig_diag_note "ZIG_DIAG=${ZIG_DIAG:-(unset)}"
  zig_diag_note "=== end env: ${label} ==="
  return 0
}

# Runs the command, always re-raising its exit code unchanged.
zig_diag_exec() {
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  zig_diag_note "BEGIN ${label}: $*"
  local _start=${SECONDS}
  local rc=0
  "$@" || rc=$?
  local _elapsed=$((SECONDS - _start))
  local _sig=""
  if [[ ${rc} -ge 128 ]]; then
    _sig=" signal=$(kill -l $((rc - 128)) 2>/dev/null || echo unknown)"
  fi
  zig_diag_note "END ${label}: rc=${rc} elapsed=${_elapsed}s${_sig}"
  return ${rc}
}
