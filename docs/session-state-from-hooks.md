# 通过 Hook 判断 Session 状态变化

本文整理如何利用 Claude Code hook 事件的组合与字段内容，推断 session 的状态转换。
实现入口：`SessionStateReducer`（纯函数）+ `HookStreamCoordinator`（actor，执行副作用）。

> 架构版本：`HookStreamCoordinator` pipeline（2026-04-07 hook-stream-experiment 合并后）。

---

## Session 状态机

```
            SessionStart / 任意 hook（missed-SessionStart fallback）
               │
               ▼
             idle ◄──────────────── stopWindowExpired（Rule 10）
               │                           ▲
               │ UserPromptSubmit (Rule 3)  │
               │ PreToolUse non-AQU (Rule 11)  Stop → 2s（Rule 9）
               ▼                           │
             busy ──────────────────────────┘
               │
               │ PreToolUse/AskUserQuestion (Rule 4)
               │ Notification(permissionPrompt) when busy (Rule 6)
               ▼
            waiting
               │
               │ PostToolUse when waiting (Rule 8)
               │ UserPromptSubmit (Rule 3，from any state)
               ▼
             busy
               │
               │ SessionEnd (Rule 2)
               ▼
           completed

任意状态 ──── 60min 无活动（AppState timer）────► stale
```

---

## SessionStateReducer：完整 11 条规则

`SessionStateReducer.reduce(state, event) → (nextState, [Action])`

纯函数，不做 I/O，由 `HookStreamCoordinator.execute(actions)` 负责实际写 DB。

| 规则 | 触发条件 | 状态变化 | 产生的 Actions |
|------|---------|---------|----------------|
| **1** | `SessionStart` | → `idle`（已 completed/stale 也重置） | `upsertSession(idle)` [+ cancelStopWindow] |
| **2** | `SessionEnd` | → `completed` | `cancelStopWindow`, `updateSessionStatus(completed)` |
| **3** | `UserPromptSubmit`（任意状态） | → `busy` | `updateSessionStatus(busy)`, `dismissPriorEvents`, `insertDevEvent(promptSubmitted/background)` |
| **4** | `PreToolUse("AskUserQuestion")`（任意状态） | → `waiting` | `updateSessionStatus(waiting)`, `insertDevEvent(permissionNeeded/action)` |
| **5** | `Notification(permissionPrompt)` 且 stopWindowActive | → 无变化（no-op） | — |
| **6** | `Notification(permissionPrompt)` 且 status == `.busy` | → `waiting` | `updateSessionStatus(waiting)`, `insertDevEvent(permissionNeeded/action)` |
| **7** | `Notification(permissionPrompt)` — 其他所有状态 | → 无变化（no-op） | — |
| **8** | `PostToolUse(任意工具)` 且 status == `.waiting` | → `busy` | `updateSessionStatus(busy)` |
| **9** | `Stop`（任意状态） | 状态不变，启动 2s 窗口 | `startStopWindow` |
| **10** | `stopWindowExpired`（虚拟事件，由 HookStreamCoordinator 注入） | → `idle` | `updateSessionStatus(idle)`, `insertDevEvent(agentStopped/review)` |
| **11** | `PreToolUse(非 AskUserQuestion)` 且 status in {`.idle`, `.waiting`} | → `busy` | `updateSessionStatus(busy)` |
| **12–13** | 其他所有情况 | → 无变化（no-op） | — |

---

## 规则详解

### Rule 5：stop window 中收到 Notification → no-op

**为什么**：`notify.sh` 使用 `&` 异步投递，`Notification(permissionPrompt)` 的实际到达顺序不保证。
常见乱序：`PostToolUse → Stop → [Notification 迟到]`。

`Stop` 只在 agent loop 退出后触发，而 agent loop 在权限对话框真正打开时**不会退出**。
因此 stop window 期间收到的 permission notification 必然是已处理过的旧通知（stale delivery），
取消 stop window 会导致 session 卡在 `.waiting` 且无后续事件清除它。

修复前（旧 Rule 5）的 bug 场景：
```
PreToolUse(Bash) → PostToolUse(Bash) → Stop → [Notification 迟到]
                                               ↑
                                        旧 Rule 5 取消 stop window + 设 waiting
                                        → 卡死在 waiting，无法自动恢复
```

### Rule 6：仅从 `.busy` 状态接受 Notification

`.idle` / `.completed` / `.stale` 状态下收到的 notification 一律 no-op，
防止迟到通知将已完成的 session 错误地拉回 `.waiting`。

### Rules 3 + 4：两条进入 waiting 的路径

- **Rule 3**（UserPromptSubmit）：从任意状态（包括 waiting）回到 busy，同时 dismiss 所有未读事件
- **Rule 4**（PreToolUse/AskUserQuestion）：Claude 准备询问用户，比对应的 Notification 早约 6 秒触发

### Rule 9 + 10：Stop 的两阶段处理

`Stop` 本身不直接改状态（Rule 9），仅启动 2 秒协调窗口。
2 秒内若无其他 action 取消，`HookStreamCoordinator.injectExpired` 注入虚拟 `.stopWindowExpired`，
Rule 10 将 session 置为 `idle` 并写入 `agentStopped` 事件（`.review` tier，触发"Claude is ready"通知）。

2 秒窗口的目的：容忍 `PostToolUse` 晚于 `Stop` 到达的乱序情况（尽管 PostToolUse 通常不会改变 stop 的结果，但 cancelStopWindow 由其他路径处理）。

---

## missed-SessionStart fallback

若应用在 Claude Code 运行期间启动（SessionStart 已丢失），后续任意 hook 仍可触发 session 创建：

```
HookStreamCoordinator.process(payload):
  current = states[sid] ?? .initial      // .initial.cwd = nil
  if current.cwd == nil && payload.cwd != ""
    current.cwd = payload.cwd            // 从 payload 补充 cwd
  (next, actions) = reduce(current, event)
  // actions 中的 updateSessionStatus 若 session 不存在 → INSERT 最小 session
  //   使用 states[sid]?.cwd（即已补充的 payload.cwd）作为 project 来源
```

结果：session 以真实项目名（而非 "unknown"）创建，用户可识别。

**已知限制**：若 Claude Code 完全处于 idle（无任何新 hook），session 直到下一次用户提交 prompt 才会出现。

---

## Hook → 状态映射速查表

### 进入 busy

| Hook | 触发条件 | 规则 |
|------|---------|------|
| `UserPromptSubmit` | 任意状态 | Rule 3 |
| `PreToolUse(非 AskUserQuestion)` | status == idle 或 waiting | Rule 11 |
| `PostToolUse(任意工具)` | status == waiting | Rule 8 |

### 进入 waiting

| Hook | 触发条件 | 规则 |
|------|---------|------|
| `PreToolUse("AskUserQuestion")` | 任意状态 | Rule 4 |
| `Notification(permissionPrompt)` | status == busy 且 stopWindowActive == false | Rule 6 |

### 进入 idle

| 触发 | 规则 |
|------|------|
| stopWindowExpired（Stop 后 2s 无取消） | Rule 10 |

### 进入 waiting（停止场景） — 注意：已废弃行为

旧 Rule 5（Stop + 迟到 Notification → waiting）已修复为 no-op，此路径不再存在。
若 Claude 真正需要用户输入，Notification 会在 Stop 之前到达，由 Rule 6 处理。

### 进入 completed / stale

| 触发 | 规则 |
|------|------|
| `SessionEnd` | Rule 2 |
| AppState 60s timer（30min 无活动） | timer，非 hook |

---

## 完整决策树

```
收到 hook 事件
│
├── SessionStart
│     → idle（completed/stale 重置；session 不存在则 INSERT）
│
├── SessionEnd
│     → completed
│
├── UserPromptSubmit
│     → busy + dismiss 所有未读通知
│
├── PreToolUse
│     ├── toolName == "AskUserQuestion"
│     │     → waiting + permissionNeeded 事件
│     └── toolName == 其他
│           status in {idle, waiting} → busy
│           status == busy           → no-op
│
├── PostToolUse
│     status == waiting → busy
│     status != waiting → no-op
│
├── Notification
│     kind == .permissionPrompt:
│       stopWindowActive == true         → no-op（Rule 5，迟到通知）
│       status == .busy                  → waiting + permissionNeeded 事件（Rule 6）
│       status == .idle/.waiting/其他    → no-op（Rule 7）
│     kind == .idlePrompt / .other       → no-op
│
└── Stop
      → 启动 2s stop window
      2s 后无取消 → idle + agentStopped 事件（"Claude is ready"，tier: review）
```

---

## 实验数据（2026-04-05 / 2026-04-07）

### AskUserQuestion 场景（session `94d71b5c`）

```
07:02:21  SessionStart
07:02:34  UserPromptSubmit
07:02:45  PreToolUse   tool=ToolSearch
07:02:45  PostToolUse  tool=ToolSearch
07:02:54  PreToolUse   tool=AskUserQuestion   ← Rule 4 触发 waiting（T+0）
07:03:00  Notification nt=permission_prompt   ← Rule 7 no-op（已 waiting）
           msg="Claude Code needs your attention"  [约 T+6s，TUI 渲染延迟]
07:04:00  SessionEnd   (PTY cleanup，AskUserQuestion 悬挂中)
```

**发现**：PreToolUse/AskUserQuestion 比对应 Notification 早 6 秒，是更早的 waiting 信号。
用户未回答时 PostToolUse/AskUserQuestion 不触发（工具阻塞中）。

### Bash 权限审批场景（session `ed38dc18`）

```
07:03:41  UserPromptSubmit
07:03:46  PreToolUse  tool=Bash           ← Rule 11: idle → busy（此时还没权限弹窗）
07:03:52  Notification nt=permission_prompt ← Rule 6: busy → waiting
           msg="Claude needs your permission to use Bash"
07:03:55  PostToolUse tool=Bash           ← Rule 8: waiting → busy（用户已批准）
07:03:58  PreToolUse  tool=Bash           ← Rule 11 no-op（已 busy）
...
07:11:06  Stop                            ← Rule 9: stop window 开始
07:11:08  stop window 到期               ← Rule 10: busy → idle，agentStopped 事件
07:12:06  Notification nt=idle_prompt    ← Rule 7 no-op（Stop 后 60s 才到，idle 早已设置）
```

**发现**：`idle_prompt` 在 Stop 后约 60 秒才到，完全冗余，Rule 7 正确忽略之。

### headless 模式（`claude -p`，session `61e30386`）

```
07:05:41  SessionStart
07:05:42  UserPromptSubmit
07:05:46  Stop + SessionEnd（同秒异步写入）
```

**发现**：headless 模式无 Notification；Stop 后 2s 内 SessionEnd 到达（Rule 2 取消 stop window）。

---

## 特征置信度矩阵

| 信号 | 状态转换 | 置信度 | 来源 |
|------|---------|--------|------|
| `UserPromptSubmit` | → busy | ★★★ | 所有场景均出现 |
| `PreToolUse(非 AQU)` when idle/waiting | → busy | ★★★ | ed38dc18 实测 |
| `PreToolUse("AskUserQuestion")` | → waiting | ★★★ | 场景 01 实测，比 Notification 早 6s |
| `Notification(permissionPrompt)` when busy | → waiting | ★★★ | ed38dc18 实测 |
| `PostToolUse("AskUserQuestion")` when waiting | → busy | ★★★ | 场景 07 实测（用户回答后约 27s）|
| `PostToolUse(Bash)` when waiting | → busy | ★★★ | ed38dc18 实测 |
| `Stop`（无后续 Notification） | → idle（2s 后） | ★★★ | 多场景实测 |
| `SessionEnd` | → completed | ★★★ | 场景 01/04 实测 |
| `Notification(permissionPrompt)` during stop window | → no-op | ★★★ | Rule 5 fix，基于时序分析 |
| `Notification(idle_prompt)` | → no-op | ★★★ | ed38dc18 实测（Stop 后 60s）|

---

## 未验证项

1. **`elicitation_dialog` notification_type** — 理论上触发 Rule 6 同路径（`.permissionPrompt` kind），未实测。
2. **ESC 中断时 Stop 是否触发** — 实验显示 ESC 在权限对话框状态下不触发 Stop；正常执行中的 ESC 未测。
3. **Bash 权限拒绝（用户 Deny）** — 预期：Notification → 用户拒绝 → Stop（无 PostToolUse），未实测。
4. **`stop_hook_active=True`** — 所有实测均为 False（正常完成），True 属于极罕见竞态。
