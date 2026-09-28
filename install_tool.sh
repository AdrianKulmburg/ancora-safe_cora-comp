#!/bin/bash

# ============================================================================
# install_tool.sh (SAFE mode)
# ============================================================================
#
# CORA-COMP installation script for ancora, ANCORA_MODE_SAFE only.
#
# This toolkit is SAFE-only: there is no FAST-mode build here and no GPU
# support anywhere (GPU is a FAST-only feature in ancora's own
# CMakeLists.txt, mutually exclusive with ANCORA_MODE_SAFE). It builds:
#
#   libancora.a
#   ancora_benchmark_safe
#
# Requires CMake 3.28+ (ancora's own CMakeLists.txt sets this as its
# cmake_minimum_required unconditionally, even though SAFE mode itself
# doesn't need HIP's native language support).
#
# ============================================================================

set -euo pipefail


# ============================================================================
# Configuration
# ============================================================================

VERSION="${1:-v1}"

ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"


# ============================================================================
# Paths
# ============================================================================

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLKIT_DIR}/.." && pwd)"


# ============================================================================
# Helpers
# ============================================================================

die()
{
    echo
    echo "============================================================" >&2
    echo "ERROR" >&2
    echo "============================================================" >&2
    echo "$*" >&2
    echo "============================================================" >&2
    exit 1
}


have_command()
{
    command -v "$1" >/dev/null 2>&1
}


section()
{
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


# ============================================================================
# Banner
# ============================================================================

section "Installing ancora tool (SAFE mode)"

echo "Interface version : ${VERSION}"
echo "Toolkit directory : ${TOOLKIT_DIR}"
echo "Repository root   : ${REPO_ROOT}"
echo "Mode              : ANCORA_MODE_SAFE (FLINT/ARB, no GPU)"


# ============================================================================
# 1. Base build tools
# ============================================================================

section "Installing base build tools"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake \
    gcc \
    g++ \
    git \
    python3 \
    python3-pip \
    wget \
    curl \
    build-essential \
    libgomp1 \
    ca-certificates \
    gpg \
    pkg-config


# ============================================================================
# 2. CMake
# ============================================================================
#
# ancora's top-level CMakeLists.txt unconditionally requires CMake 3.28+
# (it needs that for the FAST+GPU flavor's native HIP language support),
# even though the SAFE flavor built here doesn't touch HIP at all. Install
# from the Python wheel so this doesn't depend on the distro's CMake.
# ============================================================================

section "Checking CMake"

CMAKE_MIN_VERSION="3.28.0"

python3 -m pip install --upgrade --disable-pip-version-check "cmake>=3.28,<4"

if [ -x /usr/local/bin/cmake ]; then
    export PATH="/usr/local/bin:${PATH}"
fi

if ! have_command cmake; then
    die "CMake was not found after installation."
fi

echo
echo "CMake:"
echo "    $(command -v cmake)"
cmake --version

CMAKE_VERSION="$(
    cmake --version |
    head -1 |
    sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
)"

if [ -z "${CMAKE_VERSION}" ]; then
    die "Could not determine the installed CMake version."
fi

if [ "$(printf '%s\n' "${CMAKE_VERSION}" "${CMAKE_MIN_VERSION}" | sort -V | head -1)" != "${CMAKE_MIN_VERSION}" ]; then
    die "CMake ${CMAKE_MIN_VERSION} or newer is required; found ${CMAKE_VERSION}."
fi


# ============================================================================
# 3. FLINT / Arb
# ============================================================================
#
# ancora's SAFE-mode headers assume FLINT 3.x's unified layout, where Arb
# is absorbed into FLINT itself and every header (flint.h, arb.h, acb.h,
# ...) lives together under <prefix>/include/flint/. Debian/Ubuntu's apt
# packages (libflint-dev + libarb-dev) are the OLDER FLINT 2.x + separate
# Arb split, where arb.h lands at the top level (/usr/include/arb.h), NOT
# under flint/ -- so #include <flint/arb.h> fails even with those apt
# packages installed. Detection therefore checks specifically for
# flint/arb.h, not just flint/flint.h (which the old split also provides).
#
# FLINT_VERSION is pinned to v3.6.0 rather than an earlier 3.x point
# release: 3.1.3 was tried first and turned out to have an incomplete/
# still-transitional flint_rand_* API (declarations for the new
# flint_rand_init/flint_rand_clear/flint_rand_set_seed names existed
# without matching symbols to link against in some builds), which a more
# settled later release avoids having to track by trial and error.
#
# FLINT 3.x builds via CMake (its own CMakeLists.txt), not autotools --
# there is no ./configure script in the release tree.
# ============================================================================

section "Installing FLINT / ARB"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libgmp-dev \
    libmpfr-dev \
    2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libflint-dev \
    libarb-dev \
    2>/dev/null || true

FLINT_ARB_HEADER=""

for candidate in \
    /usr/include/flint/arb.h \
    /usr/local/include/flint/arb.h
do
    if [ -f "${candidate}" ]; then
        FLINT_ARB_HEADER="${candidate}"
        break
    fi
done

if [ -z "${FLINT_ARB_HEADER}" ]; then

    echo "flint/arb.h not found (apt's FLINT, if any, is the old FLINT 2.x + separate Arb split)."
    echo "Building FLINT 3.x from source, which bundles Arb under flint/."

    FLINT_SRC="${TOOLKIT_DIR}/flint"
    FLINT_VERSION="${FLINT_VERSION:-v3.6.0}"

    if [ ! -d "${FLINT_SRC}/.git" ]; then
        git clone --branch "${FLINT_VERSION}" --depth 1 \
            https://github.com/flintlib/flint.git "${FLINT_SRC}"
    fi

    FLINT_CMAKE_BUILD_DIR="${FLINT_SRC}/build"

    cmake -S "${FLINT_SRC}" -B "${FLINT_CMAKE_BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
    cmake --build "${FLINT_CMAKE_BUILD_DIR}" -j"$(nproc)"
    cmake --install "${FLINT_CMAKE_BUILD_DIR}"

    ldconfig

    for candidate in \
        /usr/include/flint/arb.h \
        /usr/local/include/flint/arb.h
    do
        if [ -f "${candidate}" ]; then
            FLINT_ARB_HEADER="${candidate}"
            break
        fi
    done

    if [ -z "${FLINT_ARB_HEADER}" ]; then
        die "FLINT 3.x was built from source, but flint/arb.h still could not be located."
    fi

else

    echo "flint/arb.h found (a unified FLINT 3.x layout is already present)."

fi

echo
echo "FLINT/Arb header:"
echo "    ${FLINT_ARB_HEADER}"

ldconfig


# ============================================================================
# 4. Locate ancora source
# ============================================================================

section "Locating ancora source"

ANCORA_SOURCE_DIR="${ANCORA_SOURCE_DIR:-}"

if [ -n "${ANCORA_SOURCE_DIR}" ]; then

    echo "Using ANCORA_SOURCE_DIR:"
    echo "    ${ANCORA_SOURCE_DIR}"

elif [ -f "${REPO_ROOT}/ancora/CMakeLists.txt" ]; then

    ANCORA_SOURCE_DIR="${REPO_ROOT}/ancora"

    echo "Using sibling ancora repository:"
    echo "    ${ANCORA_SOURCE_DIR}"

else

    ANCORA_SOURCE_DIR="${TOOLKIT_DIR}/ancora"

    echo "ancora source not found locally."
    echo "Cloning:"
    echo "    ${ANCORA_REPO_URL}"

    if [ ! -d "${ANCORA_SOURCE_DIR}/.git" ]; then

        git clone \
            --depth 1 \
            "${ANCORA_REPO_URL}" \
            "${ANCORA_SOURCE_DIR}"

    fi

fi

if [ ! -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ]; then
    die "ancora source not found at ${ANCORA_SOURCE_DIR}"
fi

echo
echo "Using ancora source:"
echo "    ${ANCORA_SOURCE_DIR}"


# ============================================================================
# 5. Build ancora SAFE library
# ============================================================================

section "Building ancora SAFE library"

SAFE_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_safe"

cmake \
    -S "${ANCORA_SOURCE_DIR}" \
    -B "${SAFE_BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANCORA_MODE_SAFE=ON \
    -DANCORA_USE_GPU=OFF \
    -DANCORA_BUILD_TESTS=OFF

cmake \
    --build "${SAFE_BUILD_DIR}" \
    --target ancora \
    -j"$(nproc)"

if [ ! -f "${SAFE_BUILD_DIR}/libancora.a" ]; then
    die "SAFE ancora library was not produced."
fi

echo
echo "SAFE library:"
echo "    ${SAFE_BUILD_DIR}/libancora.a"


# ============================================================================
# 6. Build SAFE benchmark
# ============================================================================

section "Building SAFE benchmark"

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

FLINT_LIBS=""
if have_command pkg-config && pkg-config --exists flint 2>/dev/null; then
    FLINT_LIBS="$(pkg-config --libs flint)"
else
    FLINT_LIBS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lflint -lmpfr -lgmp"
fi

cc \
    -O2 -std=c11 \
    -I"${ANCORA_SOURCE_DIR}/include" \
    -DANCORA_MODE=ANCORA_MODE_SAFE \
    "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
    -o "${TOOLKIT_DIR}/ancora_benchmark_safe" \
    "${SAFE_BUILD_DIR}/libancora.a" \
    ${FLINT_LIBS} \
    -lm

if [ ! -x "${TOOLKIT_DIR}/ancora_benchmark_safe" ]; then
    die "SAFE benchmark was not produced."
fi

echo
echo "SAFE benchmark:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_safe"


# ============================================================================
# 7. Final verification
# ============================================================================

section "Final verification"

"${TOOLKIT_DIR}/ancora_benchmark_safe" zonotope startup 1 1 1 1 0

echo
echo "SAFE benchmark smoke test passed."


# ============================================================================
# 8. Done
# ============================================================================

section "Installation complete"

echo "SAFE:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_safe"
echo
echo "FLINT/Arb header:"
echo "    ${FLINT_ARB_HEADER}"
