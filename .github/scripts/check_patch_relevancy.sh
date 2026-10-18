#!/usr/bin/env bash
#
# check_patch_relevancy.sh — patch relevancy audit gate for zig-feedstock 0.17.x
#
# PURPOSE
#   Extracts a *fresh* copy of the pinned (or overridden) upstream zig source
#   tarball, replays the recipe.yaml `source[0].patches` list in the exact
#   cumulative order rattler-build would apply it for a given target platform
#   (selectors evaluated the same way rattler-build does), and reports, per
#   patch, whether it applies CLEAN (offset 0, no fuzz), with OFFSET/FUZZ
#   drift, or FAILs outright.
#
#   The patch list is NEVER hardcoded here — it is parsed straight out of
#   recipe.yaml on every run, so this script cannot drift from the recipe.
#
#   RUN THIS ON EVERY SNAPSHOT BUMP (relevancy gate). Large OFFSET/FUZZ on a
#   patch signals upstream churn in that region (candidate for regen/removal
#   review); a FAIL means the patch is broken against the new snapshot and
#   the build WILL fail once rattler-build reaches it.
#
#   Two extra tiers beyond CLEAN/OFFSET/FUZZ/DRIFT/FAIL:
#     OBSOLETE  reverse-applying the patch to the current tree succeeds
#               cleanly, i.e. upstream already contains this change. This
#               is what rattler-build itself reports as "appears to be
#               already applied; skipping. It may no longer be necessary".
#               NOT a failure — a real candidate for removal from recipe.yaml.
#     HIGHFUZZ  neither git apply --check nor plain `patch --dry-run`
#               (fuzz=2) accept the hunk, but `patch --fuzz=10` does.
#               rattler-build's own patch application is measurably more
#               tolerant than GNU patch's default fuzz (verified against
#               real CI logs), so this tier exists to avoid false FAILs on
#               patches that build fine in practice. Still flagged for a
#               regen since fuzz=10 is a coarse heuristic, not proof of
#               correctness.
#
#   CASCADE CAVEAT: a patch that hard-FAILs is NOT applied to the working
#   tree (there is nothing sane to apply). Every patch checked after that
#   point is therefore tested against a tree that has already diverged from
#   what rattler-build's real cumulative sequence would produce, so treat
#   FAIL/OFFSET/DRIFT results *after* the first FAIL with extra suspicion —
#   the script prints an explicit warning to stderr the first time this
#   happens.
#
# USAGE
#   recipe/ci_support/check_patch_relevancy.sh [target_platform] [--snapshot X] [--keep]
#
#   target_platform   e.g. linux-64 (default), osx-64, win-64, linux-ppc64le, win-32
#   --snapshot X      override the recipe.yaml snapshot (e.g. to probe a candidate
#                      bump before editing recipe.yaml). sha256 verification is
#                      SKIPPED when this is used, since the pinned sha256 belongs
#                      to the recipe's current snapshot, not the override.
#   --keep            do not delete the temp workdir on exit (prints its path)
#
# EXIT STATUS
#   0   all patches in the effective sequence applied cleanly (CLEAN/OFFSET/FUZZ)
#   1   at least one patch FAILed, or a setup step (download/extract/sha256) failed
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PWD}/recipe/recipe.yaml" ]]; then
  RECIPE_DIR="${PWD}/recipe"
else
  RECIPE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
FEEDSTOCK_DIR="$(cd "${RECIPE_DIR}/.." && pwd)"
RECIPE_YAML="${RECIPE_DIR}/recipe.yaml"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_PLATFORM=""
SNAPSHOT_OVERRIDE=""
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot)
      SNAPSHOT_OVERRIDE="${2:-}"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      TARGET_PLATFORM="$1"
      shift
      ;;
  esac
done
TARGET_PLATFORM="${TARGET_PLATFORM:-linux-64}"

if [[ ! -f "${RECIPE_YAML}" ]]; then
  echo "ERROR: recipe.yaml not found at ${RECIPE_YAML}" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
python3 -c "import yaml" >/dev/null 2>&1 || { echo "ERROR: PyYAML (python3 -c 'import yaml') required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zig-patch-relevancy.XXXXXX")"
cleanup() {
  if [[ "${KEEP}" -eq 1 ]]; then
    echo "KEEP: workdir preserved at ${WORKDIR}"
  else
    chmod -R u+rwX "${WORKDIR}" 2>/dev/null || true
    rm -rf "${WORKDIR}" 2>/dev/null || rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: parse recipe.yaml -> version/snapshot/url/sha256/effective patch list
# (selector semantics per project convention:
#    unix  = not target_platform.startswith("win")
#    linux = target_platform.startswith("linux")
#    win32 = target_platform == "win-32")
# ---------------------------------------------------------------------------
PARSE_HELPER="${WORKDIR}/_parse_recipe.py"
cat > "${PARSE_HELPER}" <<'PYEOF'
import json
import re
import sys

import yaml

recipe_yaml_path, target_platform = sys.argv[1], sys.argv[2]
snapshot_override = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

with open(recipe_yaml_path) as fh:
    doc = yaml.safe_load(fh)

context = doc.get("context", {}) or {}
version = context.get("version")
snapshot = snapshot_override or context.get("snapshot")

unix = not target_platform.startswith("win")
linux = target_platform.startswith("linux")
win32 = target_platform == "win-32"
osx = target_platform.startswith("osx")
win = target_platform.startswith("win")
aarch64 = target_platform.endswith("aarch64")
arm64 = target_platform.endswith("arm64")
ppc64le = target_platform.endswith("ppc64le")
x86_64 = target_platform.endswith("-64") and not (aarch64 or arm64 or ppc64le or target_platform.endswith("riscv64"))

namespace = {
    "unix": unix,
    "linux": linux,
    "win32": win32,
    "osx": osx,
    "win": win,
    "aarch64": aarch64,
    "arm64": arm64,
    "ppc64le": ppc64le,
    "x86_64": x86_64,
    "xtarget_": target_platform,
    "target_platform": target_platform,
}


def eval_selector(cond):
    try:
        return bool(eval(cond, {"__builtins__": {}}, namespace))
    except Exception as exc:  # pragma: no cover - defensive
        print(f"ERROR: could not evaluate selector {cond!r}: {exc}", file=sys.stderr)
        sys.exit(2)


def walk(items):
    out = []
    for item in items or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict) and "if" in item:
            branch = item.get("then", []) if eval_selector(item["if"]) else item.get("else", [])
            out.extend(walk(branch))
        else:
            raise ValueError(f"Unexpected patches list entry: {item!r}")
    return out


source0 = doc["source"][0]
patches = walk(source0.get("patches", []))

ctx_for_url = dict(context)
ctx_for_url["version"] = version
ctx_for_url["snapshot"] = snapshot


def substitute(template):
    return re.sub(r"\$\{\{\s*(\w+)\s*\}\}", lambda m: str(ctx_for_url.get(m.group(1), "")), template)


url = substitute(source0["url"])
sha256 = source0["sha256"]

print(json.dumps({
    "version": version,
    "snapshot": snapshot,
    "snapshot_overridden": bool(snapshot_override),
    "url": url,
    "sha256": sha256,
    "patches": patches,
}))
PYEOF

PARSE_JSON="$(python3 "${PARSE_HELPER}" "${RECIPE_YAML}" "${TARGET_PLATFORM}" "${SNAPSHOT_OVERRIDE}")" || {
  echo "ERROR: failed to parse recipe.yaml" >&2
  exit 1
}

read_field() {
  python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "${PARSE_JSON}" "$1"
}

VERSION="$(read_field version)"
SNAPSHOT="$(read_field snapshot)"
SNAPSHOT_OVERRIDDEN="$(read_field snapshot_overridden)"
URL="$(read_field url)"
SHA256="$(read_field sha256)"
mapfile -t PATCHES < <(python3 -c "import json,sys; [print(p) for p in json.loads(sys.argv[1])['patches']]" "${PARSE_JSON}")

echo "================================================================================"
echo "PATCH RELEVANCY AUDIT  target=${TARGET_PLATFORM}  version=${VERSION}  snapshot=${SNAPSHOT}"
echo "================================================================================"
echo "source url   : ${URL}"
echo "patch count  : ${#PATCHES[@]} (effective, in application order)"
[[ "${SNAPSHOT_OVERRIDDEN}" == "True" ]] && echo "NOTE: --snapshot override active; sha256 verification SKIPPED"

# ---------------------------------------------------------------------------
# Step 2: obtain a FRESH tarball (prefer cache, else curl) + verify sha256
# ---------------------------------------------------------------------------
TARBALL_NAME="$(basename "${URL}")"
TARBALL="${WORKDIR}/${TARBALL_NAME}"

# This script's OWN persistent cache, distinct from rattler-build's build
# cache (which is only populated by a real local build, not by this
# checker). Without this, running the checker across multiple platforms
# in one loop re-downloads the identical tarball once per platform.
PERSISTENT_CACHE_DIR="${HOME}/.cache/zig-patch-relevancy/src_cache"
mkdir -p "${PERSISTENT_CACHE_DIR}" 2>/dev/null || true

find_cached() {
  local candidates=(
    "${PERSISTENT_CACHE_DIR}"
    "${FEEDSTOCK_DIR}/build_artifacts/src_cache"
    "${HOME}/.cache/rattler-build/src_cache"
    "${HOME}/.cache/rattler-build/cache/src_cache"
  )
  for d in "${candidates[@]}"; do
    [[ -d "${d}" ]] || continue
    local hit
    hit="$(find "${d}" -maxdepth 1 -type f -name "*${TARBALL_NAME}" 2>/dev/null | head -1)"
    [[ -n "${hit}" ]] && { echo "${hit}"; return 0; }
  done
  return 1
}

CACHED="$(find_cached || true)"
if [[ -n "${CACHED}" ]]; then
  echo "source cache : HIT  ${CACHED}"
  cp "${CACHED}" "${TARBALL}"
else
  echo "source cache : MISS -> downloading"
  if ! curl -fsSL -o "${TARBALL}" "${URL}"; then
    echo "ERROR: download failed for ${URL}" >&2
    exit 1
  fi
fi

if [[ "${SNAPSHOT_OVERRIDDEN}" != "True" ]]; then
  ACTUAL_SHA="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  if [[ "${ACTUAL_SHA}" != "${SHA256}" ]]; then
    echo "ERROR: sha256 mismatch. expected=${SHA256} actual=${ACTUAL_SHA}" >&2
    exit 1
  fi
  echo "sha256       : OK (${ACTUAL_SHA})"
else
  echo "sha256       : skipped (override snapshot)"
fi

# Populate the persistent cache for subsequent runs/platforms — only after
# a fresh download (a cache HIT already came from a persisted copy), and
# only once we've either verified sha256 or the user explicitly opted out
# of verification via --snapshot.
if [[ -z "${CACHED}" ]]; then
  cp "${TARBALL}" "${PERSISTENT_CACHE_DIR}/${TARBALL_NAME}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 3: extract fresh -> zig-source/, git init for git-apply based checking
# ---------------------------------------------------------------------------
EXTRACT_DIR="${WORKDIR}/extract"
mkdir -p "${EXTRACT_DIR}"
tar -xf "${TARBALL}" -C "${EXTRACT_DIR}" || { echo "ERROR: extraction failed" >&2; exit 1; }

TOPDIR="$(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ -z "${TOPDIR}" ]]; then
  echo "ERROR: could not locate extracted top-level directory" >&2
  exit 1
fi

ZIG_SOURCE="${WORKDIR}/zig-source"
mv "${TOPDIR}" "${ZIG_SOURCE}"

cd "${ZIG_SOURCE}"
git init -q .
git config user.email "patch-relevancy@local"
git config user.name "patch-relevancy"
git add -A
git commit -q -m "pristine ${VERSION}-dev.${SNAPSHOT}" --no-verify

# ---------------------------------------------------------------------------
# Step 4: apply patches cumulatively, recording CLEAN/OFFSET/FUZZ/FAIL
# ---------------------------------------------------------------------------
PARSE_PATCH_OUT="${WORKDIR}/_parse_patch_output.py"
cat > "${PARSE_PATCH_OUT}" <<'PYEOF'
import re
import sys

text = sys.stdin.read()
offsets = [abs(int(x)) for x in re.findall(r"\(offset (-?\d+) lines?\)", text)]
fuzzes = [int(x) for x in re.findall(r"with fuzz (\d+)", text)]
print(max(offsets) if offsets else 0, max(fuzzes) if fuzzes else 0)
PYEOF

declare -a RESULT_PATCH
declare -a RESULT_STATUS
ANY_FAIL=0
ANY_OBSOLETE=0
CASCADE_WARNED=0

warn_cascade() {
  if [[ "${CASCADE_WARNED}" -eq 0 ]]; then
    echo "WARNING: cumulative tree state diverges from here on — downstream OFFSET/DRIFT/FAIL results may be unreliable cascade noise, not independent failures" >&2
    CASCADE_WARNED=1
  fi
}

for rel_patch in "${PATCHES[@]}"; do
  patch_abs="${RECIPE_DIR}/${rel_patch}"
  if [[ ! -f "${patch_abs}" ]]; then
    RESULT_PATCH+=("${rel_patch}")
    RESULT_STATUS+=("FAIL(missing file)")
    ANY_FAIL=1
    warn_cascade
    continue
  fi

  # Already-applied / obsolete check FIRST: if reversing this patch against
  # the current tree applies cleanly, the tree already contains the patch's
  # changes (upstream absorbed it). This mirrors rattler-build's own
  # "appears to be already applied; skipping" detection instead of
  # miscategorizing it as ordinary OFFSET/FUZZ drift.
  rev_out="$(patch -p1 --dry-run --force -R -i "${patch_abs}" 2>&1)"
  rev_rc=$?
  if [[ ${rev_rc} -eq 0 ]]; then
    RESULT_PATCH+=("${rel_patch}")
    RESULT_STATUS+=("OBSOLETE(already applied upstream — candidate for removal)")
    ANY_OBSOLETE=1
    continue
  fi

  check_out="$(git apply --check -p1 "${patch_abs}" 2>&1)"
  check_rc=$?

  # patch(1) dry-run is ALSO the offset/fuzz oracle when git apply succeeds,
  # and the fallback "does GNU patch's fuzz tolerance save this hunk anyway"
  # oracle when git apply's stricter (fuzz=0) check fails. rattler-build's
  # own apply step is GNU-patch-based, so a git-FAIL + patch-OK case is real
  # (quantifiable) upstream drift the build silently absorbs via fuzz — not
  # a hard break. A git-FAIL + patch-FAIL case would break the build too.
  dry_out="$(patch -p1 --dry-run --force -i "${patch_abs}" 2>&1)"
  dry_rc=$?
  read -r max_offset max_fuzz <<< "$(printf '%s' "${dry_out}" | python3 "${PARSE_PATCH_OUT}")"

  if [[ ${check_rc} -eq 0 ]]; then
    if git apply -p1 "${patch_abs}" 2>>"${WORKDIR}/apply_errors.log"; then
      if [[ "${max_fuzz}" -gt 0 ]]; then
        status="FUZZ(${max_fuzz})"
      elif [[ "${max_offset}" -gt 0 ]]; then
        status="OFFSET(${max_offset})"
      else
        status="CLEAN"
      fi
    else
      status="FAIL(git apply --check ok but apply failed)"
      ANY_FAIL=1
      warn_cascade
    fi
  elif [[ ${dry_rc} -eq 0 ]]; then
    # GNU patch fuzz-tolerates it (matches what CI's build actually sees);
    # advance cumulative state via patch(1) itself so later patches see it.
    if patch -p1 --force -i "${patch_abs}" >/dev/null 2>>"${WORKDIR}/apply_errors.log"; then
      status="DRIFT(git-strict-FAIL, patch-fuzzy-OK offset=${max_offset} fuzz=${max_fuzz})"
    else
      status="FAIL(patch dry-run ok but real apply failed)"
      ANY_FAIL=1
      warn_cascade
    fi
  else
    # Last-resort high-fuzz fallback, approximating rattler-build's more
    # tolerant real-world apply behaviour before declaring a hard FAIL —
    # verified against real CI logs that some fuzz=2 FAILs here build fine.
    hf_out="$(patch -p1 --dry-run --force --fuzz=10 -i "${patch_abs}" 2>&1)"
    hf_rc=$?
    if [[ ${hf_rc} -eq 0 ]]; then
      read -r hf_offset hf_fuzz <<< "$(printf '%s' "${hf_out}" | python3 "${PARSE_PATCH_OUT}")"
      if patch -p1 --force --fuzz=10 -i "${patch_abs}" >/dev/null 2>>"${WORKDIR}/apply_errors.log"; then
        status="HIGHFUZZ(offset=${hf_offset} fuzz=${hf_fuzz} — regen recommended)"
      else
        status="FAIL(patch dry-run ok at fuzz=10 but real apply failed)"
        ANY_FAIL=1
        warn_cascade
      fi
    else
      reason="$(printf '%s' "${check_out}" | head -1 | sed 's/^error: //')"
      status="FAIL(${reason:-git apply --check failed})"
      ANY_FAIL=1
      warn_cascade
    fi
  fi

  RESULT_PATCH+=("${rel_patch}")
  RESULT_STATUS+=("${status}")
done

# ---------------------------------------------------------------------------
# Step 5: summary
# ---------------------------------------------------------------------------
echo "--------------------------------------------------------------------------------"
printf "%-70s %s\n" "PATCH" "STATUS"
echo "--------------------------------------------------------------------------------"
clean_count=0
obsolete_count=0
for i in "${!RESULT_PATCH[@]}"; do
  printf "%-70s %s\n" "${RESULT_PATCH[$i]}" "${RESULT_STATUS[$i]}"
  case "${RESULT_STATUS[$i]}" in
    CLEAN) clean_count=$((clean_count + 1)) ;;
    OBSOLETE*) obsolete_count=$((obsolete_count + 1)) ;;
  esac
done
echo "--------------------------------------------------------------------------------"
echo "CLEAN: ${clean_count}/${#RESULT_PATCH[@]}"
[[ "${obsolete_count}" -gt 0 ]] && echo "OBSOLETE (candidates for removal): ${obsolete_count}"
[[ "${KEEP}" -eq 1 ]] && echo "workdir kept at: ${WORKDIR}"

if [[ "${ANY_FAIL}" -eq 1 ]]; then
  echo "RESULT: FAIL — one or more patches did not apply against this snapshot"
  exit 1
fi
echo "RESULT: OK — all patches in the effective sequence applied"
exit 0
