#!/usr/bin/env bash
# harness/test-stale-detection.sh
#
# 测试 AppState.markStaleSessions() 的两阶段 stale 检测机制：
#
#   Phase 1 — TTY 已死：任何活跃 session 的 TTY 不存在 → 立即标 stale（无需等 30 分钟）
#   Phase 2 — 无 TTY 信息 + 超过 30 分钟无活动 → 标 stale
#
# 测试 case：
#   A. 死 TTY + 最近创建的 session  → Phase 1 检测，应在 <65s 内标 stale
#   B. 活 TTY + 最近创建的 session  → 应保持活跃（Phase 1 不触发，Phase 2 时间未到）
#   C. 无 TTY + 2 小时前创建的 session → Phase 2 检测，应在 <65s 内标 stale
#   D. 无 TTY + 最近创建的 session  → 应保持活跃（Phase 2 时间未到）
#
# 使用前提：
#   - 应用已在运行（make run）
#   - sqlite3 已安装
#
# 用法：
#   bash harness/test-stale-detection.sh

set -uo pipefail

# ── 配置 ──────────────────────────────────────────────────────────────────────
DB="$HOME/Library/Application Support/AgentPilot/db.sqlite"
POLL_INTERVAL=5      # 秒：每隔几秒查一次 DB
TIMEOUT=70           # 秒：最多等待多久
DEAD_TTY="/dev/ttys999"          # 不存在的 TTY，肯定是死的
# 获取当前终端 TTY：tty 在非交互式 shell 中会返回 "not a tty"，
# 所以先尝试从父进程获取，再验证路径以 /dev/ 开头
_raw_tty=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
if [[ "$_raw_tty" == "?"* ]] || [ -z "$_raw_tty" ]; then
    LIVE_TTY=""
else
    LIVE_TTY="/dev/${_raw_tty}"
fi

PASS=0
FAIL=0
SKIP=0

# ── 颜色 ──────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[TEST]${RESET} $*"; }
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ((FAIL++)); }
skip() { echo -e "${YELLOW}[SKIP]${RESET} $*"; ((SKIP++)); }
sep()  { echo "────────────────────────────────────────────────────────────"; }

# ── 前置检查 ──────────────────────────────────────────────────────────────────
sep
log "环境检查"

if [ ! -f "$DB" ]; then
    echo -e "${RED}[ERROR]${RESET} DB 不存在：$DB"
    echo "请先启动应用：make run"
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo -e "${RED}[ERROR]${RESET} 需要 sqlite3"
    exit 1
fi

# 检查应用是否在运行（通过 /health 端点）
PORT=$(defaults read com.agentpilot.AgentPilot serverPort 2>/dev/null || echo "9876")
if ! curl -sf "http://localhost:${PORT}/health" &>/dev/null; then
    echo -e "${RED}[ERROR]${RESET} 应用未运行或端口 ${PORT} 不可达"
    echo "请先启动应用：make run"
    exit 1
fi
log "应用正在运行（端口 ${PORT}）"
log "DB 路径：$DB"
[ -n "$LIVE_TTY" ] && log "当前终端 TTY：$LIVE_TTY" || log "无法获取当前 TTY，Case B 将跳过"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

# 格式化时间为 GRDB DatabaseDateComponents 格式（YYYY-MM-DD HH:MM:SS.SSS，UTC）
# GRDB 的 fetchStaleCandidates 将 cutoff 转为 UTC 再做文本比较，
# 所以手动插入的 started_at 也必须用 UTC，否则时区差会导致比较结果错误。
ts_now()      { date -u '+%Y-%m-%d %H:%M:%S.000'; }
ts_ago_2h()   { date -u -v-2H '+%Y-%m-%d %H:%M:%S.000'; }

# 插入测试 session（状态为 idle）
insert_session() {
    local id="$1" project="$2" tty_val="$3" started="$4"
    local tty_sql
    if [ "$tty_val" = "NULL" ]; then
        tty_sql="NULL"
    else
        tty_sql="'$tty_val'"
    fi
    sqlite3 "$DB" "
        INSERT OR REPLACE INTO sessions (id, project, tool, status, started_at, cwd, tty)
        VALUES ('$id', '$project', 'claude-code', 'idle', '$started', '/tmp', $tty_sql);
    "
}

# 查询 session 的 status
query_status() {
    sqlite3 "$DB" "SELECT status FROM sessions WHERE id='$1';"
}

# 等待 session 变成指定状态，超时则返回当前状态
wait_for_status() {
    local id="$1" expected="$2"
    local elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        local status
        status=$(query_status "$id")
        if [ "$status" = "$expected" ]; then
            echo "$status"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    query_status "$id"
    return 1
}

# 清理测试 session
cleanup() {
    local ids=("$@")
    for id in "${ids[@]}"; do
        sqlite3 "$DB" "DELETE FROM sessions WHERE id='$id';"
    done
}

# ── 生成唯一 session ID ────────────────────────────────────────────────────────
PREFIX="test-stale-$(date +%s)"
ID_A="${PREFIX}-case-a"
ID_B="${PREFIX}-case-b"
ID_C="${PREFIX}-case-c"
ID_D="${PREFIX}-case-d"

NOW=$(ts_now)
TWO_HOURS_AGO=$(ts_ago_2h)

sep
log "插入 4 个测试 session..."

# Case A: 死 TTY + 最近创建
insert_session "$ID_A" "test-case-a" "$DEAD_TTY" "$NOW"
log "Case A 已插入：id=${ID_A}, tty=${DEAD_TTY}, started=now"

# Case B: 活 TTY + 最近创建
if [ -n "$LIVE_TTY" ]; then
    insert_session "$ID_B" "test-case-b" "$LIVE_TTY" "$NOW"
    log "Case B 已插入：id=${ID_B}, tty=${LIVE_TTY}, started=now"
fi

# Case C: 无 TTY + 2 小时前创建
insert_session "$ID_C" "test-case-c" "NULL" "$TWO_HOURS_AGO"
log "Case C 已插入：id=${ID_C}, tty=NULL, started=2h ago"

# Case D: 无 TTY + 最近创建
insert_session "$ID_D" "test-case-d" "NULL" "$NOW"
log "Case D 已插入：id=${ID_D}, tty=NULL, started=now"

sep
log "等待 stale 检测触发（最多 ${TIMEOUT}s，每 ${POLL_INTERVAL}s 查询一次）..."
echo ""

# ── Case A ────────────────────────────────────────────────────────────────────
log "Case A: 死 TTY（${DEAD_TTY}）+ 最近创建 → 预期 stale"
final_a=$(wait_for_status "$ID_A" "stale" || true)
if [ "$final_a" = "stale" ]; then
    pass "Case A: 状态变为 stale ✓"
else
    fail "Case A: 状态仍为 '${final_a}'，预期 stale（Phase 1 未触发？）"
fi

# ── Case B ────────────────────────────────────────────────────────────────────
if [ -n "$LIVE_TTY" ]; then
    log "Case B: 活 TTY（${LIVE_TTY}）+ 最近创建 → 预期保持 idle"
    # 等到 Case A/C 都完成后再采样（确保至少经历过一次 timer tick）
    final_b=$(query_status "$ID_B")
    if [ "$final_b" = "idle" ] || [ "$final_b" = "busy" ] || [ "$final_b" = "waiting" ]; then
        pass "Case B: 状态保持 '${final_b}'，活 TTY 未被误判 ✓"
    else
        fail "Case B: 状态变为 '${final_b}'，活 TTY 被错误标 stale！"
    fi
else
    skip "Case B: 无法获取当前 TTY，跳过"
fi

# ── Case C ────────────────────────────────────────────────────────────────────
log "Case C: 无 TTY + 2 小时前创建 → 预期 stale"
final_c=$(wait_for_status "$ID_C" "stale" || true)
if [ "$final_c" = "stale" ]; then
    pass "Case C: 状态变为 stale ✓"
else
    fail "Case C: 状态仍为 '${final_c}'，预期 stale（Phase 2 未触发？检查 events/hook_logs 是否干扰）"
fi

# ── Case D ────────────────────────────────────────────────────────────────────
log "Case D: 无 TTY + 最近创建 → 预期保持 idle"
final_d=$(query_status "$ID_D")
if [ "$final_d" = "idle" ] || [ "$final_d" = "busy" ] || [ "$final_d" = "waiting" ]; then
    pass "Case D: 状态保持 '${final_d}'，最近 session 未被误判 ✓"
else
    fail "Case D: 状态变为 '${final_d}'，最近 session 被错误标 stale！"
fi

# ── 清理 ──────────────────────────────────────────────────────────────────────
sep
log "清理测试 session..."
cleanup "$ID_A" "$ID_B" "$ID_C" "$ID_D"
log "清理完成"

# ── 结果汇总 ──────────────────────────────────────────────────────────────────
sep
echo ""
echo -e "结果：${GREEN}${PASS} 通过${RESET}  ${RED}${FAIL} 失败${RESET}  ${YELLOW}${SKIP} 跳过${RESET}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}有测试失败。排查建议：${RESET}"
    echo "  1. 查看 app 日志：tail -f tmp/logs/app.log | grep -i stale"
    echo "  2. 手动查 DB：sqlite3 \"\$HOME/Library/Application Support/AgentPilot/db.sqlite\""
    echo "     SELECT id, project, status, tty, started_at FROM sessions WHERE id LIKE 'test-stale-%';"
    exit 1
fi

exit 0
