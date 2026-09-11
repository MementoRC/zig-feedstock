# Native bootstrap zig, built from our patched source (no 0003 GCC redirect).
# Only invoked when ZIG_BOOTSTRAP_NATIVE_REBUILD=1 (operator switch, off by
# default). See recipe.yaml's bootstrap_native_rebuild and build.sh's gate.

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_zig_diag.sh"

# build_native_bootstrap_zig <source_dir> <build_zig>
# Builds a NATIVE (build-platform) zig using <build_zig>, from <source_dir>.
# Installs to a work-area dir (never PREFIX). Sets NATIVE_BOOTSTRAP_ZIG on
# success; exits non-zero if the binary is not produced.
function build_native_bootstrap_zig() {
  local source_dir=$1
  local build_zig=$2
  local install_dir="${SRC_DIR}/zig-native-bootstrap"

  echo "=== STAGE A: native bootstrap zig (build_platform=${build_platform}, no 0003 redirect) ==="
  echo "[native-bootstrap] source=${source_dir} build_zig=${build_zig} install=${install_dir}"

  mkdir -p "${install_dir}"

  # No -Dtarget: standardTargetOptions() defaults to the native build platform.
  # -Dstatic-llvm=true skips the CMake/config.h integration (not built yet at
  # this point in the script) and links LLVM/clang/lld static libs directly
  # via --search-prefix.
  local native_args=(
    --prefix "${install_dir}"
    --search-prefix "${BUILD_PREFIX}"
    --maxrss 7800000000
    -Dcpu=baseline
    -Denable-llvm
    -Doptimize=ReleaseSafe
    -Dstatic-llvm=true
    -Dstrip=true
    -Duse-zig-libcxx=false
    -Dno-langref
    -Dversion-string="${PKG_VERSION}"
  )

  local rc=0
  (
    cd "${source_dir}" &&
    ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-native-bootstrap-global-cache" \
    ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-native-bootstrap-local-cache" \
    "${build_zig}" build "${native_args[@]}"
  ) || rc=$?

  if [[ ${rc} -ne 0 ]]; then
    echo "ERROR: native bootstrap zig build failed (rc=${rc})" >&2
    exit 1
  fi

  NATIVE_BOOTSTRAP_ZIG="${install_dir}/bin/zig"
  if [[ ! -x "${NATIVE_BOOTSTRAP_ZIG}" ]]; then
    echo "ERROR: native bootstrap zig binary not produced at ${NATIVE_BOOTSTRAP_ZIG}" >&2
    exit 1
  fi

  echo "=== STAGE A complete: native bootstrap zig at ${NATIVE_BOOTSTRAP_ZIG} ==="
  export NATIVE_BOOTSTRAP_ZIG
}
