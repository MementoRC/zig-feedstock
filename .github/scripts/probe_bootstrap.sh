#!/usr/bin/env bash
#
# probe_bootstrap.sh -- can the PINNED bootstrap zig_impl build the NEW snapshot?
#
# Run from a bumped feedstock checkout (the `upstream` dir). Installs the
# zig_impl_linux-64 build selected by recipe.yaml's zig_impl_pin, applies the
# linux-64 patch list to the new snapshot source (via check_patch_relevancy.sh
# KEEP_TREE), then runs `zig build --print-configuration` there. That compiles
# build.zig and its imports against the bootstrap's std, the step that dies in
# about a minute on every native lane when the snapshot needs newer std APIs.
# (`zig build --help` does NOT compile build.zig in zig 0.18.)
#
#   PASS     exit 0 and a non-empty .zon configuration: keep bootstrap_via_upstream: false
#   FAIL     zig compile error in .zig source: flips bootstrap_via_upstream to true
#   UNKNOWN  infrastructure problem (install, download, timeout, ...): no edit
#   SKIP     bootstrap_via_upstream is already true
#
# Env: PROBE_SUMMARY  markdown summary path (default $RUNNER_TEMP/bootstrap-probe.md)
# Last stdout line is always "VERDICT: <verdict>". Exit status is always 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_YAML="${PWD}/recipe/recipe.yaml"
SUMMARY="${PROBE_SUMMARY:-${RUNNER_TEMP:-/tmp}/bootstrap-probe.md}"
TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

WORK="$(mktemp -d "${TMP_ROOT}/zig-bootstrap-probe.XXXXXX")"
trap 'chmod -R u+rwX "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

PIN=""
ERRORS=""
NOTE=""

finish() {
  local verdict="$1"
  {
    echo "Verdict: **${verdict}**"
    [[ -n "${PIN}" ]] && echo "- pin probed: \`zig_impl_linux-64${PIN}\`"
    [[ -n "${NOTE}" ]] && echo "- ${NOTE}"
    if [[ "${verdict}" == "FAIL" ]]; then
      echo "- the previous pinned build cannot compile the new snapshot's build.zig; \`bootstrap_via_upstream\` set to \`true\` in this PR"
      echo
      echo '```'
      printf '%s\n' "${ERRORS}"
      echo '```'
    fi
  } > "${SUMMARY}"
  echo "VERDICT: ${verdict}"
  exit 0
}

ctx() {
  sed -n -E "s/^  $1:[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?[[:space:]]*\$/\1/p" "${RECIPE_YAML}" | head -1
}

[[ -f "${RECIPE_YAML}" ]] || { NOTE="recipe/recipe.yaml not found in ${PWD}"; finish UNKNOWN; }

if [[ "$(ctx bootstrap_via_upstream)" == "true" ]]; then
  NOTE="bootstrap_via_upstream is already true; nothing to probe"
  finish SKIP
fi

BOOT_VERSION="$(ctx bootstrap_version)"
SNAP_REF="$(ctx snapshot_ref)"
BUILD_REF="$(ctx build_ref)"
if [[ -z "${BOOT_VERSION}" || -z "${SNAP_REF}" || -z "${BUILD_REF}" ]]; then
  NOTE="could not read bootstrap_version/snapshot_ref/build_ref from recipe.yaml"
  finish UNKNOWN
fi
PIN="[version=\"${BOOT_VERSION}.*\", build=\"*_${SNAP_REF}_*\", build_number=\">=${BUILD_REF}\"]"
echo "probing zig_impl_linux-64${PIN}"

# --- micromamba + pinned bootstrap ---
MM="$(command -v micromamba || true)"
if [[ -z "${MM}" ]]; then
  if ! curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C "${WORK}" bin/micromamba; then
    NOTE="could not download micromamba"
    finish UNKNOWN
  fi
  MM="${WORK}/bin/micromamba"
fi

export MAMBA_ROOT_PREFIX="${WORK}/mamba"
BOOT_PFX="${WORK}/bootstrap"
if ! "${MM}" create -y -q -p "${BOOT_PFX}" \
    -c conda-forge/label/zig_dev -c conda-forge --override-channels \
    "zig_impl_linux-64${PIN}" > "${WORK}/install.log" 2>&1; then
  tail -n 5 "${WORK}/install.log"
  NOTE="could not install the pinned bootstrap (unpublished or unsolvable pin?)"
  finish UNKNOWN
fi

# build.sh renames bin/zig to bin/<conda_triplet>-zig; lib/zig sits beside it
ZIG_BIN="$(ls "${BOOT_PFX}"/bin/*-zig 2>/dev/null | head -1)"
[[ -x "${ZIG_BIN}" && -d "${BOOT_PFX}/lib/zig" ]] || {
  NOTE="no *-zig binary or lib/zig in the installed bootstrap"
  finish UNKNOWN
}
echo "bootstrap zig: ${ZIG_BIN} ($("${ZIG_BIN}" version 2>&1 | head -1))"

# --- new snapshot source with linux-64 patches applied ---
TREE="${WORK}/zig-source"
mkdir -p "${TREE}"
KEEP_TREE="${TREE}" bash "${SCRIPT_DIR}/check_patch_relevancy.sh" linux-64 > "${WORK}/relevancy.log" 2>&1
relevancy_rc=$?
if [[ ! -f "${TREE}/build.zig" ]]; then
  tail -n 5 "${WORK}/relevancy.log"
  NOTE="could not obtain the patched snapshot source"
  finish UNKNOWN
fi
[[ ${relevancy_rc} -ne 0 ]] && NOTE="some linux-64 patches failed to apply; build.zig may differ from the real build"

# --- JIT-compile build.zig against the bootstrap std ---
mkdir -p "${WORK}/cache-global" "${WORK}/cache-local"
CMDLINE="cd ${TREE} && ZIG_LIB_DIR=${BOOT_PFX}/lib/zig ZIG_GLOBAL_CACHE_DIR=${WORK}/cache-global ZIG_LOCAL_CACHE_DIR=${WORK}/cache-local timeout 900 ${ZIG_BIN} build --print-configuration"
rc=0
(
  cd "${TREE}" || exit 1
  ZIG_LIB_DIR="${BOOT_PFX}/lib/zig" \
  ZIG_GLOBAL_CACHE_DIR="${WORK}/cache-global" \
  ZIG_LOCAL_CACHE_DIR="${WORK}/cache-local" \
    timeout 900 "${ZIG_BIN}" build --print-configuration
) > "${WORK}/probe.zon" 2> "${WORK}/probe.log" || rc=$?
echo "ran: ${CMDLINE} (exit ${rc})"
tail -n 20 "${WORK}/probe.log"
[[ -n "${NOTE}" ]] && NOTE="${NOTE}"$'\n'"- "
NOTE="${NOTE}command: \`${CMDLINE}\`"

if [[ ${rc} -eq 0 && -s "${WORK}/probe.zon" ]]; then
  finish PASS
elif [[ ${rc} -ne 124 ]] && cat "${WORK}/probe.zon" "${WORK}/probe.log" | grep -Eq '\.zig:[0-9]+:[0-9]+: error:'; then
  ERRORS="$(cat "${WORK}/probe.zon" "${WORK}/probe.log" | grep -E 'error:' | head -5)"
  sed -i 's/^  bootstrap_via_upstream: false$/  bootstrap_via_upstream: true/' "${RECIPE_YAML}"
  if [[ "$(ctx bootstrap_via_upstream)" != "true" ]]; then
    NOTE="${NOTE}"$'\n'"- FLAG EDIT FAILED: bootstrap_via_upstream is still not true"
  fi
  finish FAIL
fi
if [[ ${rc} -eq 0 ]]; then
  REASON="exit 0 but empty configuration"
else
  REASON="exit ${rc} without a .zig compile error (124 = timeout)"
fi
NOTE="${NOTE}"$'\n'"- ${REASON}"
finish UNKNOWN
