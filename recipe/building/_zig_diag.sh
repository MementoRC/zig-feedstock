#!/usr/bin/env bash
# Zig build diagnostics, gated entirely on DEBUG_ZIG_BUILD (reuses the existing
# recipe.yaml-plumbed toggle -- no new variable, no recipe.yaml changes needed).
# Default (DEBUG_ZIG_BUILD unset or "0") is completely silent: nothing in this
# file prints. zig_diag_exec still always runs its command and re-raises its
# exit code regardless of the gate -- only its instrumentation output is gated.
# Never fails the build -- every external command is guarded (command -v /
# || true) so this file is safe under set -euo pipefail.

[[ -n "${_ZIG_DIAG_SH_SOURCED:-}" ]] && return 0
_ZIG_DIAG_SH_SOURCED=1

source "${RECIPE_DIR}/building/_common.sh"

zig_diag_on() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

# Gated -- silent unless DEBUG_ZIG_BUILD=1.
zig_diag_note() {
  zig_diag_on || return 0
  echo "[zig-diag] $*" >&2
}

zig_diag_env() {
  local label="${1:-unknown}"
  zig_diag_on || return 0
  zig_diag_note "=== env: ${label} ==="
  command -v free &>/dev/null && free -m >&2 || true
  command -v nproc &>/dev/null && zig_diag_note "nproc=$(nproc)" || true
  ulimit -a >&2 || true
  zig_diag_note "target_platform=${target_platform:-<unset>}"
  zig_diag_note "build_platform=${build_platform:-<unset>}"
  zig_diag_note "PREFIX=${PREFIX:-<unset>}"
  zig_diag_note "BUILD_PREFIX=${BUILD_PREFIX:-<unset>}"
  zig_diag_note "CONDA_BUILD_SYSROOT=${CONDA_BUILD_SYSROOT:-<unset>}"
  zig_diag_note "ZIG_TRIPLET=${ZIG_TRIPLET:-<unset>}"
  zig_diag_note "ZIG_QEMU_ARCH=${ZIG_QEMU_ARCH:-<unset>}"
  zig_diag_note "QEMU_EXECVE=${QEMU_EXECVE:-<unset>}"
  zig_diag_note "QEMU_EXECVE_NATIVE_PASSTHROUGH=${QEMU_EXECVE_NATIVE_PASSTHROUGH:-<unset>}"
  zig_diag_note "QEMU_LD_PREFIX=${QEMU_LD_PREFIX:-<unset>}"
  zig_diag_note "CPU_COUNT=${CPU_COUNT:-<unset>}"
  zig_diag_note "SKIP_LANGREF=${SKIP_LANGREF:-<unset>}"
  zig_diag_note "DEBUG_ZIG_BUILD=${DEBUG_ZIG_BUILD:-<unset>}"
  zig_diag_note "=== end env: ${label} ==="
  return 0
}

# Always runs the command and re-raises its exit code unchanged, regardless
# of the gate; only the BEGIN/END instrumentation output is gated.
zig_diag_exec() {
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local _on=0
  if zig_diag_on; then
    _on=1
    zig_diag_note "BEGIN ${label}: $*"
  fi
  local _start=${SECONDS}
  local rc=0
  "$@" || rc=$?
  if [[ ${_on} -eq 1 ]]; then
    local _elapsed=$((SECONDS - _start))
    local _sig=""
    if [[ ${rc} -ge 128 ]]; then
      _sig=" signal=$(kill -l $((rc - 128)) 2>/dev/null || echo unknown)"
    fi
    zig_diag_note "END ${label}: rc=${rc} elapsed=${_elapsed}s${_sig}"
  fi
  return ${rc}
}
