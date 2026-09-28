#!/bin/bash

# prepare_instance.sh — untimed setup before each instance.
# SAFE MODE ONLY: there is no GPU driver in this toolkit at all (SAFE mode
# has no GPU path), so there is nothing to warm up - no GPU context to
# initialize, no persistent JIT cache to prime. This script is effectively
# a no-op, kept only so run_instance.sh's harness contract (a
# prepare_instance.sh + run_instance.sh pair) is still satisfied.

set -e

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

echo "SAFE mode: nothing to warm up (no GPU support in this toolkit)."

exit 0
