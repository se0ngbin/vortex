#!/bin/bash

# =============================================================================
# Vortex VM SimX Regression Test Script
# =============================================================================
# Creates a timestamped build directory, configures, builds, and runs all 28
# regression tests with VM enabled using SimX (software simulator).
#
# Usage: ./run_vm_simx_regression.sh [--skip-build]
#   --skip-build: Skip configure/build steps (use existing build)
#
# Output:
#   - Build directory: build_simx_YYYYMMDD_HHMMSS/
#   - Logs: build_simx_YYYYMMDD_HHMMSS/regression_logs/
#   - Summary: build_simx_YYYYMMDD_HHMMSS/regression_logs/summary.txt
# =============================================================================

set -e  # Exit on error during build phase

# Script directory (vortex root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Parse arguments
SKIP_BUILD=0
for arg in "$@"; do
    case $arg in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
    esac
done

# =============================================================================
# Configuration
# =============================================================================

# Add verilator to PATH (needed for building all runtime drivers during make)
export PATH=/opt/verilator/bin:$PATH

# Build configuration for VM (SimX doesn't need PERF_ENABLE for basic verification)
export CONFIGS="-DVM_ENABLE -DVM_ADDR_MODE=1"
DRIVER="simx"

# Failure detection patterns (regex for grep -E)
# Catches: explicit failures, Verilator errors, assertions, crashes, make errors
FAILURE_PATTERNS="FAILED|%Error:|Assertion failed|Aborted|core dumped|make: \*\*\*|Segmentation fault"

# 27 regression tests (sgemm_tcu handled separately)
TESTS=(
    basic
    bfs
    conv3
    cta
    demo
    diverge
    dogfood
    dotproduct
    dotproduct2
    dropout
    fence
    io_addr
    jacobi
    madmax
    mstress
    pathfinder
    printf
    priority
    raycast
    relu
    sgemm
    sgemm2
    sgemv
    softmax
    sort
    stencil3d
    vecadd
)

# =============================================================================
# Create Build Directory
# =============================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUILD_DIR="$SCRIPT_DIR/build_simx_$TIMESTAMP"
export VORTEX_RANDOMIZE_VA=0

echo "=============================================="
echo "  Vortex VM SimX Regression Test"
echo "=============================================="
echo "  Timestamp:    $TIMESTAMP"
echo "  Build Dir:    $BUILD_DIR"
echo "  CONFIGS:      $CONFIGS"
echo "  Driver:       $DRIVER"
echo "  Total Tests:  28 (27 regular + 1 sgemm_tcu)"
echo "=============================================="
echo ""

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# =============================================================================
# Configure and Build
# =============================================================================

if [ $SKIP_BUILD -eq 0 ]; then
    echo "[STEP 1/3] Configuring..."
    if ! ../configure --xlen=32 --tooldir=/opt; then
        echo ""
        echo "ERROR: Configuration failed!"
        echo "Please edit the tool paths in this script:"
        echo "  - Line 40: export PATH=<path-to-verilator>/bin:\$PATH"
        echo "  - Line 105: ../configure --xlen=32 --tooldir=<path-to-tools>"
        echo ""
        exit 1
    fi

    echo ""
    echo "[STEP 2/3] Building SimX with VM enabled..."
    if ! CONFIGS="$CONFIGS" make -s -j$(nproc); then
        echo ""
        echo "ERROR: Build failed!"
        echo "Please edit the tool paths in this script:"
        echo "  - Line 40: export PATH=<path-to-verilator>/bin:\$PATH"
        echo "  - Line 105: ../configure --xlen=32 --tooldir=<path-to-tools>"
        echo ""
        exit 1
    fi

    echo ""
    echo "Build completed successfully!"
    echo ""
else
    echo "[SKIP] Skipping configure and build (--skip-build)"
    echo ""
    # Find the most recent build directory, excluding the current one
    PREVIOUS_BUILD_DIR=$(ls -td "$SCRIPT_DIR"/build_* | grep -v "$BUILD_DIR" | head -n 1)
    if [ -z "$PREVIOUS_BUILD_DIR" ]; then
        echo "ERROR: No other existing build directory found!"
        exit 1
    fi
    echo "Using the most recent build directory (excluding current): $PREVIOUS_BUILD_DIR"
    echo "Copying necessary files from the previous build directory to the current directory..."
    cp -r "$PREVIOUS_BUILD_DIR"/ci "$PREVIOUS_BUILD_DIR"/hw "$PREVIOUS_BUILD_DIR"/kernel \
          "$PREVIOUS_BUILD_DIR"/runtime "$PREVIOUS_BUILD_DIR"/sim "$PREVIOUS_BUILD_DIR"/tests \
          "$PREVIOUS_BUILD_DIR"/config.mk "$PREVIOUS_BUILD_DIR"/Makefile ./
fi 

# =============================================================================
# Run Regression Tests
# =============================================================================

set +e  # Don't exit on test failure

echo "[STEP 3/3] Running 28 regression tests with SimX..."
echo ""

# Create log directory
LOG_DIR="$BUILD_DIR/regression_logs"
mkdir -p "$LOG_DIR"
SUMMARY_FILE="$LOG_DIR/summary.txt"

# Results tracking
PASSED=()
FAILED=()

# Run each test
for i in "${!TESTS[@]}"; do
    TEST="${TESTS[$i]}"
    TEST_NUM=$((i + 1))
    LOG_FILE="$LOG_DIR/${TEST}.log"

    printf "[%2d/28] Running %-15s ... " "$TEST_NUM" "$TEST"

    # Run the test and capture output
    CONFIGS="$CONFIGS" ./ci/blackbox.sh --driver=$DRIVER --app=$TEST > "$LOG_FILE" 2>&1
    EXIT_CODE=$?

    # Check for failure: non-zero exit code OR failure patterns in output
    # This catches crashes, assertions, and explicit failures
    if [ $EXIT_CODE -ne 0 ] || grep -qE "$FAILURE_PATTERNS" "$LOG_FILE"; then
        echo "FAILED (exit=$EXIT_CODE)"
        FAILED+=("$TEST")
    else
        echo "PASSED"
        PASSED+=("$TEST")
    fi
done

# =============================================================================
# Special Test: sgemm_tcu (requires TCU extension rebuild)
# =============================================================================

echo ""
echo "[SPECIAL] Running sgemm_tcu (requires TCU rebuild)..."
TEST="sgemm_tcu"
LOG_FILE="$LOG_DIR/${TEST}.log"

# Rebuild with TCU enabled
echo "  Rebuilding with TCU extension..."
TCU_CONFIGS="-DVM_ENABLE -DVM_ADDR_MODE=1 -DEXT_TCU_ENABLE"
CONFIGS="$TCU_CONFIGS" make -s -j$(nproc) >> "$LOG_FILE" 2>&1

# Build sgemm_tcu test binary
echo "  Building sgemm_tcu test binary..."
make -s -C tests/regression/sgemm_tcu clean >> "$LOG_FILE" 2>&1
CONFIGS="-DITYPE=int8 -DOTYPE=int32" make -s -C tests/regression/sgemm_tcu >> "$LOG_FILE" 2>&1

# Run sgemm_tcu
echo "  Running sgemm_tcu..."
CONFIGS="$TCU_CONFIGS" ./ci/blackbox.sh --driver=$DRIVER --app=sgemm_tcu >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

# Check result using same logic as main tests
printf "[28/28] Running %-15s ... " "$TEST"
if [ $EXIT_CODE -ne 0 ] || grep -qE "$FAILURE_PATTERNS" "$LOG_FILE"; then
    echo "FAILED (exit=$EXIT_CODE)"
    FAILED+=("$TEST")
else
    echo "PASSED"
    PASSED+=("$TEST")
fi

TOTAL=28

# =============================================================================
# Summary Report
# =============================================================================

echo ""
echo "=============================================="
echo "  SUMMARY"
echo "=============================================="
echo "  Total:   $TOTAL"
echo "  Passed:  ${#PASSED[@]}"
echo "  Failed:  ${#FAILED[@]}"
echo ""

# Write summary to file
{
    echo "=============================================="
    echo "  Vortex VM SimX Regression Test Summary"
    echo "=============================================="
    echo "  Date:      $(date)"
    echo "  Build Dir: $BUILD_DIR"
    echo "  CONFIGS:   $CONFIGS"
    echo "  Driver:    $DRIVER"
    echo ""
    echo "=============================================="
    echo "  RESULTS: ${#PASSED[@]}/${TOTAL} PASSED"
    echo "=============================================="
    echo ""
    echo "PASSED (${#PASSED[@]}):"
    for t in "${PASSED[@]}"; do
        echo "  [PASS] $t"
    done
    echo ""
    echo "FAILED (${#FAILED[@]}):"
    for t in "${FAILED[@]}"; do
        echo "  [FAIL] $t"
    done
} > "$SUMMARY_FILE"

# Print failed tests if any
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED[@]}"; do
        echo "  - $t (see $LOG_DIR/${t}.log)"
    done
    echo ""
fi

# Calculate pass rate
if command -v bc &> /dev/null; then
    PASS_RATE=$(echo "scale=1; ${#PASSED[@]} * 100 / $TOTAL" | bc)
    echo "Pass rate: $PASS_RATE% (${#PASSED[@]}/$TOTAL)"
else
    echo "Pass rate: ${#PASSED[@]}/$TOTAL"
fi

echo ""
echo "Detailed logs: $LOG_DIR/"
echo "Summary file:  $SUMMARY_FILE"
echo ""

# Exit with failure if any test failed
if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
