#!/usr/bin/env bash
# run-tests.sh — Run swift test suite and capture output to test.log
# Usage: bash harness/debug/run-tests.sh [--filter <TestClass>]
# Run from project root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/tmp/logs"
TEST_LOG="$LOG_DIR/test.log"

mkdir -p "$LOG_DIR"
cd "$PROJECT_ROOT"

FILTER_ARG=""
if [[ "${1:-}" == "--filter" && -n "${2:-}" ]]; then
    FILTER_ARG="--filter $2"
fi

echo "Running swift test${FILTER_ARG:+ ($FILTER_ARG)}..."
echo "Output → $TEST_LOG"
echo ""

# Prepend timestamp header
echo "--- swift test run at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ---" >> "$TEST_LOG"

# Run tests; tee to terminal and log file
swift test $FILTER_ARG 2>&1 | tee -a "$TEST_LOG"

EXIT_CODE=${PIPESTATUS[0]}
echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "Tests passed. Output in $TEST_LOG"
else
    echo "Tests FAILED (exit $EXIT_CODE). See $TEST_LOG for details."
fi
exit $EXIT_CODE
