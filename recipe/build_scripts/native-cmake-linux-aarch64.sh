#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

SYSROOT_ARCH="aarch64"
ZIG_ARCH="aarch64"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_PREFIX_PATH=${PREFIX}" \
  "-DCMAKE_C_COMPILER=${CC}" \
  "-DCMAKE_CXX_COMPILER=${CXX}" \
  "-DZIG_SHARED_LLVM=OFF" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${ZIG_ARCH}-linux-gnu" \
  "-DZIG_TARGET_MCPU=baseline" \
  "-DZIG_SYSTEM_LIBCXX=stdc++" \
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cmake_build_install "${cmake_build_dir}"
