#!/bin/bash

# ============================================================================
# install_tool.sh
# ============================================================================
#
# CORA-COMP installation script for ancora - SAFE MODE ONLY.
#
# This build is exclusively ANCORA_MODE_SAFE (FLINT/ARB, arbitrary
# precision). There is NO FAST mode, and NO GPU support anywhere in this
# script: ANCORA_MODE_SAFE and ANCORA_USE_GPU are mutually exclusive in
# ancora's own CMakeLists.txt (GPU is a FAST-only feature), so a SAFE-only
# toolkit needs no CUDA, no HIP, no BLAS, no HiGHS, and no GPU detection at
# all.
#
# It builds:
#
#   libancora.a            (ANCORA_MODE_SAFE static library)
#   ancora_benchmark_safe   (the benchmark driver, always run on CPU)
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

section "Installing ancora tool (SAFE mode only)"

echo "Interface version : ${VERSION}"
echo "Toolkit directory : ${TOOLKIT_DIR}"
echo "Repository root   : ${REPO_ROOT}"
echo "Mode              : ANCORA_MODE_SAFE (FLINT/ARB, arbitrary precision)"
echo "GPU support       : none (SAFE mode has no GPU path)"


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
    ca-certificates \
    pkg-config


# ============================================================================
# 2. CMake
# ============================================================================
#
# ancora's top-level CMakeLists.txt unconditionally requires CMake 3.28+
# (cmake_minimum_required(VERSION 3.28) at the very top, regardless of
# whether GPU support is requested), so this still applies even though
# this toolkit never touches HIP/CUDA.
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
# 3. FLINT / ARB
# ============================================================================
#
# ANCORA_MODE_SAFE links against FLINT::FLINT (see ancora's CMakeLists.txt),
# and ancora's own headers do `#include <flint/arb.h>` - i.e. they assume
# FLINT 3.x's UNIFIED header layout, where Arb was absorbed into FLINT
# itself and every header (flint.h, arb.h, acb.h, ...) lives together under
# one prefix/include/flint/ directory.
#
# IMPORTANT: Ubuntu's apt packages (libflint-dev + libarb-dev) are the OLD
# FLINT 2.x + separate-Arb split. That split installs flint/flint.h (so a
# check for just that header wrongly looks "found"), but Arb's headers land
# at the TOP LEVEL (/usr/include/arb.h), not nested under flint/ - so
# `#include <flint/arb.h>` fails to compile even though "FLINT" is
# technically installed. There is no way to get the layout ancora expects
# from Ubuntu's apt packages; FLINT must be built from source here.
#
# So: check specifically for flint/arb.h (not just flint/flint.h), and if
# that split layout is all that apt provides, build FLINT 3.x from source
# unconditionally - this also produces flint/arb.h in the right place.
# ============================================================================

section "Installing FLINT / ARB"

# gmp/mpfr are FLINT's own build dependencies either way (apt's or a
# from-source FLINT both need them); libflint-dev/libarb-dev are installed
# too since they may pull in useful runtime bits, but are NOT trusted for
# the actual header layout check below.
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
    FLINT_VERSION="${FLINT_VERSION:-v3.1.3}"

    if [ ! -d "${FLINT_SRC}/.git" ]; then
        git clone \
            --branch "${FLINT_VERSION}" \
            --depth 1 \
            https://github.com/flintlib/flint.git \
            "${FLINT_SRC}"
    fi

    (
        cd "${FLINT_SRC}"
        ./bootstrap.sh 2>/dev/null || true
        ./configure
        make -j"$(nproc)"
        make install
    )

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

# Prefer pkg-config for FLINT's link flags when a .pc file is available
# (this is what a from-source FLINT install produces); otherwise fall back
# to the conventional link line. A from-source install defaults to
# /usr/local, whose pkgconfig directory isn't always on PKG_CONFIG_PATH by
# default, so add it explicitly here rather than relying on the ambient
# environment.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

FLINT_LIBS=""
if have_command pkg-config && pkg-config --exists flint 2>/dev/null; then
    FLINT_LIBS="$(pkg-config --libs flint)"
else
    FLINT_LIBS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lflint -lmpfr -lgmp"
fi

cc \
    -O2 \
    -std=c11 \
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

echo "Running startup smoke test..."

if ! "${TOOLKIT_DIR}/ancora_benchmark_safe" zonotope startup 1 1 1 1 0; then
    die "SAFE benchmark startup smoke test failed."
fi

echo "OK."


# ============================================================================
# 8. Done
# ============================================================================

section "Installation complete"

echo "SAFE benchmark:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_safe"
echo
echo "No FAST mode, no GPU support - this toolkit is SAFE-only."
