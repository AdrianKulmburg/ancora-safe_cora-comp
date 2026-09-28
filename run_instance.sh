#!/bin/bash

# run_instance.sh — run the measured operation and report the verdict.
# SAFE MODE ONLY: this toolkit only ever runs ancora_benchmark_safe. There
# is no FAST-mode driver and no GPU driver at all - a device="gpu" request
# is reported as "unsupported" without even attempting to run anything,
# since ANCORA_MODE_SAFE has no GPU path (GPU is a FAST-only feature in
# ancora's own build).
#
# Arguments (the interface version, then the instance's instances.csv columns in file order):
# - $1: interface version string, e.g. "v1"
# - $2: benchmark,  the set representation, e.g. "zonotope" or "zonotope-batched"
# - $3: instance,   "<operation>-<n>d[-b<batch>]-<device>", e.g. "matMul-500d-b10-cpu"
# - $4: params,     JSON object with everything the tool needs, e.g. '{"set": "zonotope",
#                   "operation": "matMul", "dim": 500, "generators": 1000, "device": "cpu",
#                   "repetition": 100, "batch_size": 10}'
# A column added to the catalog later arrives as a further argument, in file order, and
# the results file to write is always the LAST argument.
#
# Everything this script does is timed. It runs the whole instance: generate the inputs,
# then perform the operation $REPETITION times, so that one measurement averages over
# repeats rather than timing a single noisy call.
#
# The harness owns timing: it measures the wall-clock time of this script and enforces
# the per-instance timeout (the "timeout" column in instances.csv, if the catalog sets
# one; otherwise the run is uncapped). Do not sleep to a deadline yourself.

set -e

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

BENCHMARK="$2"
INSTANCE="$3"
PARAMS="$4"
# The results file is always the last argument.
RESULTS_FILE="${@: -1}"

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Everything the tool needs is in the params JSON; the benchmark and instance names only
# repeat it in readable form. python3 is always present on the worker (the harness itself
# runs on it). batch_size is absent on the unbatched benchmarks, hence the default of 1.
read -r SET OPERATION DIM GENERATORS DEVICE BATCH_SIZE REPETITION POINTS TYPE <<EOF
$(printf '%s' "$PARAMS" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["set"], p["operation"], p["dim"], p.get("generators", 0), p["device"], p.get("batch_size", 1), p["repetition"], p.get("points", 0), p.get("type", ""))')
EOF

echo "Running $OPERATION on $SET in ${DIM}d, batch $BATCH_SIZE, x$REPETITION, on $DEVICE -> $RESULTS_FILE"

# SAFE mode has no GPU driver at all - report unsupported immediately
# rather than attempting to run anything (mirroring the FAST toolkit's
# "no GPU driver built" convention, but here it is unconditional: there is
# never a GPU driver in this toolkit).
if [ "$DEVICE" != "cpu" ]; then
    echo "SAFE mode has no '$DEVICE' driver (SAFE mode is CPU-only); reporting unsupported."
    printf 'result\nunsupported\n' > "$RESULTS_FILE"
    exit 0
fi

DRIVER="${TOOLKIT_DIR}/ancora_benchmark_safe"

if [ ! -x "$DRIVER" ]; then
    echo "SAFE benchmark driver not found or not executable at $DRIVER; reporting error."
    printf 'result\nerror\n' > "$RESULTS_FILE"
    exit 0
fi

# The measured region: run the benchmark driver. It generates the inputs the catalog
# defines and performs the operation $REPETITION times.
#   exit 0 -> finished
#   exit 3 -> unsupported (operation not implemented in ANCORA_MODE_SAFE,
#             e.g. zonotope contains/batched contains - no LP solver in
#             SAFE mode)
#   anything else -> error
set +e
"$DRIVER" \
        "$SET" "$OPERATION" "$DIM" "$GENERATORS" "$BATCH_SIZE" "$REPETITION" "$POINTS" "$TYPE"
DRIVER_EXIT=$?
set -e

case "$DRIVER_EXIT" in
    0) VERDICT="finished" ;;
    3) VERDICT="unsupported" ;;
    *) VERDICT="error" ;;
esac

# Write the results file: a header row plus one data row with a "result" column.
printf 'result\n%s\n' "$VERDICT" > "$RESULTS_FILE"
