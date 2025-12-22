#!/bin/bash

# =============================================================================
# Vortex VM Regression Test Script with Randomized VA Allocation
# =============================================================================
# Creates a timestamped build directory, configures, builds, and runs all 28
# regression tests with VM enabled and RANDOMIZED virtual address mappings.
#
# Usage: ./run_vm_regression_random.sh [OPTIONS]
#   --skip-build:      Skip configure/build steps (use existing build)
#   --seed=<value>:    Set RNG seed for reproducibility (default: auto-generated)
#
# Examples:
#   ./run_vm_regression_random.sh                    # Random VA with auto-seed
#   ./run_vm_regression_random.sh --seed=0xBEEFCAFE  # Reproducible random
#
# Output:
#   - Build directory: build_YYYYMMDD_HHMMSS/
#   - Logs: build_YYYYMMDD_HHMMSS/regression_logs/
#   - Summary: build_YYYYMMDD_HHMMSS/regression_logs/summary.txt
# =============================================================================

set -e  # Exit on error during build phase

# Script directory (vortex root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Parse arguments
SKIP_BUILD=0
VA_SEED=""
for arg in "$@"; do
    case $arg in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --seed=*)
            VA_SEED="${arg#*=}"
            shift
            ;;
    esac
done

# =============================================================================
# Configuration
# =============================================================================

# Add verilator to PATH
export PATH=/opt/verilator/bin:$PATH

# Build configuration for VM
export CONFIGS="-DVM_ENABLE -DVM_ADDR_MODE=1 -DPERF_ENABLE"
DRIVER="rtlsim"
PERF_FLAG="--perf=2"

# Failure detection patterns (regex for grep -E)
# Catches: explicit failures, Verilator errors, assertions, crashes, make errors
FAILURE_PATTERNS="FAILED|%Error:|Assertion failed|Aborted|core dumped|make: \*\*\*|Segmentation fault"

# 28 regression tests
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
BUILD_DIR="$SCRIPT_DIR/build_$TIMESTAMP"

# Always enable randomized VA allocation
export VORTEX_RANDOMIZE_VA=1

# Set up RNG seed
if [ -n "$VA_SEED" ]; then
    export VORTEX_VA_SEED="$VA_SEED"
    SEED_INFO="$VA_SEED"
else
    # Generate random seed if not specified
    export VORTEX_VA_SEED="0x$(date +%s%N | md5sum | head -c 8)"
    SEED_INFO="$VORTEX_VA_SEED (auto-generated)"
fi

echo "=============================================="
echo "  Vortex VM Regression Test"
echo "=============================================="
echo "  Timestamp:    $TIMESTAMP"
echo "  Build Dir:    $BUILD_DIR"
echo "  CONFIGS:      $CONFIGS"
echo "  Driver:       $DRIVER"
echo "  VA Mapping:   RANDOMIZED"
echo "  RNG Seed:     $SEED_INFO"
echo "  Total Tests:  ${#TESTS[@]}"
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
        echo "  - Line 50: export PATH=<path-to-verilator>/bin:\$PATH"
        echo "  - Line 130: ../configure --xlen=32 --tooldir=<path-to-tools>"
        echo ""
        exit 1
    fi

    echo ""
    echo "[STEP 2/3] Building with VM enabled (this may take a while)..."
    if ! CONFIGS="$CONFIGS" make -s -j$(nproc); then
        echo ""
        echo "ERROR: Build failed!"
        echo "Please edit the tool paths in this script:"
        echo "  - Line 50: export PATH=<path-to-verilator>/bin:\$PATH"
        echo "  - Line 130: ../configure --xlen=32 --tooldir=<path-to-tools>"
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

echo "[STEP 3/3] Running ${#TESTS[@]} regression tests..."
echo ""

# Create log directory
LOG_DIR="$BUILD_DIR/regression_logs"
mkdir -p "$LOG_DIR"
SUMMARY_FILE="$LOG_DIR/summary.txt"

# Results tracking
PASSED=()
FAILED=()
TOTAL=${#TESTS[@]}



# Run each test
for i in "${!TESTS[@]}"; do
    TEST="${TESTS[$i]}"
    TEST_NUM=$((i + 1))
    LOG_FILE="$LOG_DIR/${TEST}.log"

    printf "[%2d/%d] Running %-15s ... " "$TEST_NUM" "$TOTAL" "$TEST"

    # Run the test and capture output
    CONFIGS="$CONFIGS" ./ci/blackbox.sh --driver=$DRIVER --app=$TEST $PERF_FLAG > "$LOG_FILE" 2>&1
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

# Rebuild RTL with TCU enabled
echo "  Rebuilding RTL with TCU extension..."
TCU_CONFIGS="-DVM_ENABLE -DVM_ADDR_MODE=1 -DPERF_ENABLE -DEXT_TCU_ENABLE"
CONFIGS="$TCU_CONFIGS" make -s -j$(nproc) >> "$LOG_FILE" 2>&1

# Build sgemm_tcu test binary
echo "  Building sgemm_tcu test binary..."
make -s -C tests/regression/sgemm_tcu clean >> "$LOG_FILE" 2>&1
CONFIGS="-DITYPE=int8 -DOTYPE=int32" make -s -C tests/regression/sgemm_tcu >> "$LOG_FILE" 2>&1

# Run sgemm_tcu
echo "  Running sgemm_tcu..."
CONFIGS="$TCU_CONFIGS" ./ci/blackbox.sh --driver=$DRIVER --app=sgemm_tcu $PERF_FLAG >> "$LOG_FILE" 2>&1
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

TOTAL=28  # Total is still 28 (27 regular + 1 sgemm_tcu)

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
    echo "  Vortex VM Regression Test Summary"
    echo "=============================================="
    echo "  Date:      $(date)"
    echo "  Build Dir: $BUILD_DIR"
    echo "  CONFIGS:   $CONFIGS"
    echo "  Driver:    $DRIVER"
    echo "  VA Mode:   RANDOMIZED"
    echo "  RNG Seed:  $VORTEX_VA_SEED"
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

# Disable randomized VA allocation for future runs
unset VORTEX_RANDOMIZE_VA
unset VORTEX_VA_SEED

# Exit with failure if any test failed
if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
