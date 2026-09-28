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
# ANCORA_MODE_SAFE links against FLINT::FLINT (see ancora's CMakeLists.txt).
# Modern FLINT (3.x) bundles Arb's functionality directly; some
# distributions still package Arb separately (libarb-dev) as a FLINT
# dependency. Try apt first; if the headers/library aren't found afterward,
# build FLINT from source, mirroring how install_tool.sh previously
# source-built HiGHS when the apt package was missing or too old.
# ============================================================================

section "Installing FLINT / ARB"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libflint-dev \
    libgmp-dev \
    libmpfr-dev \
    libarb-dev \
    2>/dev/null || true

FLINT_HEADER=""

for candidate in \
    /usr/include/flint/flint.h \
    /usr/local/include/flint/flint.h
do
    if [ -f "${candidate}" ]; then
        FLINT_HEADER="${candidate}"
        break
    fi
done

if [ -z "${FLINT_HEADER}" ]; then

    echo "FLINT not found via apt. Building FLINT from source."

    FLINT_SRC="${TOOLKIT_DIR}/flint2"
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
        /usr/include/flint/flint.h \
        /usr/local/include/flint/flint.h
    do
        if [ -f "${candidate}" ]; then
            FLINT_HEADER="${candidate}"
            break
        fi
    done

    if [ -z "${FLINT_HEADER}" ]; then
        die "FLINT was built from source, but flint.h still could not be located."
    fi

else

    echo "FLINT found via apt."

fi

ldconfig

echo
echo "FLINT header:"
echo "    ${FLINT_HEADER}"


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
# to the conventional link line.
FLINT_LIBS=""
if have_command pkg-config && pkg-config --exists flint 2>/dev/null; then
    FLINT_LIBS="$(pkg-config --libs flint)"
else
    FLINT_LIBS="-lflint -lmpfr -lgmp"
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
