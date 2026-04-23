#!/usr/bin/env bash
# verify-logs.sh — Verify per-layer log capture for AgentPilot
# Usage: bash harness/debug/verify-logs.sh
# Run from project root.

set -euo pipefail

LOG_DIR="$(cd "$(dirname "$0")/../.." && pwd)/tmp/logs"
APP_LOG="$LOG_DIR/app.log"
HTTP_LOG="$LOG_DIR/http.log"
TEST_LOG="$LOG_DIR/test.log"

OK=0
FAIL=0
SKIP=0
RESULTS=()

# ── helpers ──────────────────────────────────────────────────────────────────

check_iso8601() {
    local file="$1"
    # macOS log stream emits 2 header lines before data lines.
    # Data lines look like: 2024-01-15 14:30:01.234567  AgentPilot[PID:TID] ...
    # Also accept strict ISO 8601: 2024-01-15T14:30:01
    # Skip header lines (start with "Filtering" or "Timestamp") before checking.
    if grep -m5 -vE '^(Filtering|Timestamp)' "$file" 2>/dev/null \
            | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        return 0
    fi
    return 1
}

record_ok()   { RESULTS+=("  [OK]   $1"); OK=$((OK+1)); }
record_fail() { RESULTS+=("  [FAIL] $1"); FAIL=$((FAIL+1)); }
record_skip() { RESULTS+=("  [SKIP] $1 (任务驱动型，无活跃任务)"); SKIP=$((SKIP+1)); }

# ── 1. app.log ────────────────────────────────────────────────────────────────
# 常驻来源：需要 log stream 后台进程 + app 进程同时运行

echo ""
echo "=== AgentPilot log verification ==="
echo "LOG_DIR: $LOG_DIR"
echo ""

# Check log stream capture process is running
if pgrep -f "log stream.*AgentPilot" > /dev/null 2>&1; then
    STREAM_RUNNING=true
else
    STREAM_RUNNING=false
fi

if [[ ! -f "$APP_LOG" ]]; then
    record_fail "app.log — 文件不存在 (log stream 未启动？运行: bash harness/debug/start-log-capture.sh)"
elif [[ "$STREAM_RUNNING" != "true" ]]; then
    # File exists but stream not running — could be stale
    record_fail "app.log — log stream 进程未运行，文件可能是旧的 (运行: bash harness/debug/start-log-capture.sh)"
else
    # Trigger a health check to produce fresh output, then check for recent writes
    TOKEN_FILE="$HOME/.agentpilot/token"
    if [[ -f "$TOKEN_FILE" ]]; then
        PORT="${AGENTPILOT_PORT:-9876}"
        curl -s "http://127.0.0.1:${PORT}/health" -o /dev/null 2>/dev/null || true
        sleep 2
    fi

    # Check that file was modified in the last 60 seconds
    if [[ "$(find "$APP_LOG" -mmin -1 2>/dev/null)" ]]; then
        if check_iso8601 "$APP_LOG"; then
            record_ok "app.log — 有新内容，时间戳格式正确"
        else
            record_fail "app.log — 有新内容，但时间戳格式不符合预期 (head -5 $APP_LOG)"
        fi
    else
        if [[ -s "$APP_LOG" ]]; then
            record_fail "app.log — 文件存在但超过 60 秒未更新 (app 是否在运行？curl 结果：$(curl -s http://127.0.0.1:9876/health -o /dev/null -w '%{http_code}' 2>/dev/null || echo 'unreachable'))"
        else
            record_fail "app.log — 文件为空 (app 是否在运行？)"
        fi
    fi
fi

# ── 2. http.log ───────────────────────────────────────────────────────────────
# 任务驱动型：由 verify 脚本本身触发 curl 产生

TOKEN_FILE="$HOME/.agentpilot/token"
PORT="${AGENTPILOT_PORT:-9876}"

if ! curl -s --max-time 2 "http://127.0.0.1:${PORT}/health" -o /dev/null 2>/dev/null; then
    record_skip "http.log — 服务端口 ${PORT} 不可达，app 未运行"
else
    # Trigger a few requests and log them
    {
        echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") GET /health"
        RESP=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "ERR")
        echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") GET /health → ${RESP}"

        if [[ -f "$TOKEN_FILE" ]]; then
            TOKEN=$(cat "$TOKEN_FILE")
            echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") POST /event (no-auth test)"
            RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                -H "Content-Type: application/json" \
                -d '{"hook_event_name":"SessionStart","session_id":"verify-test-1","cwd":"/tmp"}' \
                "http://127.0.0.1:${PORT}/event" 2>/dev/null || echo "ERR")
            echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") POST /event (no auth) → ${RESP} (expect 401)"

            echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") POST /event (valid token)"
            RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${TOKEN}" \
                -d '{"hook_event_name":"SessionStart","session_id":"verify-test-2","cwd":"/tmp"}' \
                "http://127.0.0.1:${PORT}/event" 2>/dev/null || echo "ERR")
            echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") POST /event (valid token) → ${RESP} (expect 200)"
        else
            echo "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z") WARN token not found at $TOKEN_FILE, skipping auth tests"
        fi
    } >> "$HTTP_LOG"

    if [[ -s "$HTTP_LOG" ]]; then
        if check_iso8601 "$HTTP_LOG"; then
            record_ok "http.log — 有内容，时间戳格式正确"
        else
            record_fail "http.log — 有内容但时间戳格式不正确"
        fi
    else
        record_fail "http.log — 文件为空"
    fi
fi

# ── 3. test.log ───────────────────────────────────────────────────────────────
# 任务驱动型：仅在 swift test 运行时产生

THRESHOLD=$((60 * 60)) # 1 hour — test runs can be slow
if [[ ! -f "$TEST_LOG" ]]; then
    record_skip "test.log — 文件不存在 (运行: bash harness/debug/run-tests.sh 生成)"
else
    AGE=$(( $(date +%s) - $(stat -f %m "$TEST_LOG" 2>/dev/null || echo 0) ))
    if [[ $AGE -gt $THRESHOLD ]]; then
        record_skip "test.log — 文件存在但超过 1 小时未更新 (上次运行: $(date -r "$TEST_LOG" 2>/dev/null || echo 'unknown'))"
    elif [[ ! -s "$TEST_LOG" ]]; then
        record_fail "test.log — 文件为空"
    else
        if grep -q "Test Suite" "$TEST_LOG" 2>/dev/null; then
            record_ok "test.log — 包含 swift test 输出"
        else
            record_fail "test.log — 文件有内容但未找到 'Test Suite' 标志 (格式异常？)"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
for r in "${RESULTS[@]}"; do
    echo "$r"
done
echo ""
echo "  OK: $OK  FAIL: $FAIL  SKIP: $SKIP"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $FAIL 个来源未通过。请修复后重跑。"
    exit 1
else
    echo "All required sources OK (SKIP sources are task-driven, normal)."
    exit 0
fi
