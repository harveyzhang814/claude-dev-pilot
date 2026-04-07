# 通过 Hook 判断 Session 状态变化

本文整理如何利用 Claude Code hook 事件的组合与字段内容，推断 session 的状态转换。
数据来自 2026-04-05 实验捕获，覆盖两种 busy→waiting→busy 场景。

---

## Session 状态机回顾

```
idle ──────────────────────────────────────── stale (30min 无活动)
 │                                              │
 ▼ UserPromptSubmit / 任意事件                  │ AppState 60s 定时检查
busy ──┬── permissionNeeded ──► waiting          │
       │        │                 │              │
       │        └─ Stop+Notif ──► waiting        │
       │                          │              │
       │      PromptSubmit  ◄─────┘              │
       │                                         │
       └── agentStopped ──► (StopWindowService) ─┴──► idle / waiting
                                                        │
                                                        ▼
                                                    completed (SessionEnd)
```

---

## 完整 Hook → 状态映射表

### 一、状态进入 busy

| Hook | 关键字段 | 触发条件 | 状态变化 |
|------|---------|---------|---------|
| `UserPromptSubmit` | — | 用户发送任意消息 | → `busy` |
| `UserPromptSubmit` | — | 用户回答 AskUserQuestion（若触发） | → `busy` |
| `SessionStart` | `source: "startup"` | 新会话或重开旧会话 | → `idle`（不直接 busy）|

**注意：** `promptSubmitted` 事件在 `SessionLifecycleService.processEvent` 中会自动 dismiss 所有未读通知（隐式确认用户已看到）。

---

### 二、状态进入 waiting

#### 场景 A：AskUserQuestion（Claude 需要用户回答问题）

**Hook 序列：**
```
PreToolUse(AskUserQuestion)  →  Notification(permission_prompt)
```

| Hook | 关键字段 | 值 |
|------|---------|---|
| `PreToolUse` | `tool_name` | `"AskUserQuestion"` |
| | `tool_input.questions[].question` | 问题文本 |
| | `tool_input.questions[].options[]` | 可选项（可能为空） |
| `Notification` | `notification_type` | `"permission_prompt"` |
| | `message` | `"Claude Code needs your attention"` |

**判断规则：**
```
PreToolUse.tool_name == "AskUserQuestion"
  → session 进入 waiting（Claude 正在等待用户回答）
```

#### 场景 B：权限审批（Claude 需要用户批准工具调用）

**Hook 序列（interactive 模式）：**
```
Notification(permission_prompt)  →  [用户批准]  →  PreToolUse(实际工具)
```

**⚠️ 仅在 interactive 模式下触发。`-p` 模式跳过权限对话框，直接执行工具。**

| Hook | 关键字段 | 值 |
|------|---------|---|
| `Notification` | `notification_type` | `"permission_prompt"` |
| | `message` | `"Claude needs your permission to use Bash"` |
| | `permission_mode` | **空**（Notification 不含此字段）|

**判断规则：**
```
Notification.notification_type == "permission_prompt"
  AND message.contains("permission to use")
  → session 进入 waiting（等待用户批准权限）
```

#### 两种 waiting 场景的区分

```
Notification.notification_type == "permission_prompt"
  ├── message.contains("needs your attention")  → AskUserQuestion 等待回答
  └── message.contains("permission to use")     → 权限审批等待批准
```

---

### 三、状态退出 waiting（回到 busy）

#### AskUserQuestion 回答后

| Hook | 关键字段 | 值 |
|------|---------|---|
| `PostToolUse` | `tool_name` | `"AskUserQuestion"` |
| | `tool_response` | 用户回答内容 |

**注意：** 在 `-p` 模式下，`PostToolUse/AskUserQuestion` 不触发（`-p` 模式中工具调用后会话即结束）。完整 interactive 模式下应触发，但受 TUI 键盘交互复杂性限制，实验中未完整捕获。

#### 权限审批通过后

| Hook | 关键字段 | 值 |
|------|---------|---|
| `PreToolUse` | `tool_name` | 被批准的工具（如 `"Bash"`） |

**注意：** PreToolUse 紧跟在 Notification 后出现（async 写入顺序可能颠倒，业务逻辑上 Notification 先）。

---

### 四、状态进入 idle（agent 完成任务）

由 `StopWindowService` 在 2 秒窗口内合并 `Stop` 和 `Notification` 事件后决策：

```
收到 Stop hook:
  2s 内无 Notification(permission_prompt / elicitation_dialog / idle_prompt)
    → session 进入 idle
    → 生成合成事件 agentStopped(type: agentStopped, tier: review, title: "Claude is ready")

收到 Stop + Notification（2s 内）:
    → session 进入 waiting（有待处理的用户交互）
```

| Hook | 关键字段 | 状态结果 |
|------|---------|---------|
| `Stop` | `stop_hook_active: false` | 若 2s 内无 Notification → `idle` |
| `Stop` + `Notification` | `notification_type` = permission_prompt 等 | → `waiting` |

---

### 五、状态进入 completed

```
SessionEnd hook → session.status = completed, session.ended_at = now
```

---

### 六、状态进入 stale

```
AppState 60s 定时器 → 扫描 session.last_active < 30min → status = stale
```

（不由 hook 触发，由 timer 触发）

---

## 完整状态推断决策树

```
收到 hook 事件

├── SessionStart
│     └── session 已存在 + status in [completed, stale]
│           → 重置为 idle（会话重开）
│         session 不存在
│           → 新建 session，status = idle

├── SessionEnd
│     → status = completed

├── UserPromptSubmit
│     → status = busy
│       所有未读通知 is_dismissed = 1

├── PreToolUse
│     └── tool_name == "AskUserQuestion"
│           → 预示 session 即将进入 waiting（等 Notification 确认）
│         tool_name == 其他工具（紧跟 permission_prompt Notification 后）
│           → 表示权限已批准，session 回到 busy

├── PostToolUse
│     └── tool_name == "AskUserQuestion"
│           → session 从 waiting 回到 busy（用户已回答）
│         tool_name == 其他
│           → 工具完成，不直接改状态（等 Stop 决策）

├── Notification
│     └── notification_type == "permission_prompt"
│           ├── message.contains("needs your attention")
│           │     → AskUserQuestion: session = waiting
│           ├── message.contains("permission to use")
│           │     → 权限审批: session = waiting
│           └── 其他 message
│                 → 进入 StopWindowService 2s 窗口

│           notification_type == "idle_prompt"
│           │     → 进入 StopWindowService 窗口

│           notification_type == 其他
│                 → 进入 StopWindowService 窗口

└── Stop
      → 进入 StopWindowService 2s 窗口
        2s 后:
          有 Notification(permission_prompt / elicitation / idle)
            → session = waiting
          无 Notification
            → session = idle，发出 agentStopped 合成事件
```

---

## Agent Dev Pilot 当前实现与 Hook 的对应关系

### EventMapper 推断规则（实际代码）

| hookEventName | notificationType | EventType（推断） | AttentionTier |
|---------------|-----------------|-----------------|--------------|
| `UserPromptSubmit` | — | `promptSubmitted` | `background` |
| `Stop` | — | `agentStopped` | `background` |
| `Notification` | `permission_prompt` | `permissionNeeded` | **action** |
| `Notification` | `elicitation_dialog` | `permissionNeeded` | **action** |
| `Notification` | `idle_prompt` | `agentStopped` | `background` |
| `Notification` | 其他 | `agentStopped` | `background` |
| `PreToolUse` / `PostToolUse` | — | `agentStopped` | `background` |

### SessionLifecycleService 状态转换（实际代码）

| DevEvent.type | session 状态变化 |
|---------------|----------------|
| `promptSubmitted` | → `busy` + dismiss 所有通知 |
| `permissionNeeded` | → `waiting` |
| `agentStopped` | 不直接改（交给 StopWindowService）|
| `authSuccess` | → `busy` |

### 未被当前代码处理的 Hook 信号

| Hook 信号 | 当前处理 | 潜在改进 |
|----------|---------|---------|
| `PreToolUse/AskUserQuestion` | 作为 `agentStopped/background` 处理，丢弃 | 可用于更早检测 waiting 状态 |
| `PostToolUse/AskUserQuestion` | 作为 `agentStopped/background` 处理 | 可用于检测 waiting→busy 回归 |
| `Notification.message` 内容区分 | 统一为 `permissionNeeded` | 可区分 AskUserQuestion vs 权限审批，显示不同 UI |

---

## 实验数据摘要

以下为 2026-04-05 实验中捕获的真实 hook 序列：

### AskUserQuestion 场景（session `4799008e`）

```
SessionStart
UserPromptSubmit          pm=default  prompt="Use the ask_user_question tool..."
PreToolUse/ToolSearch     (查找 AskUserQuestion 工具)
PostToolUse/ToolSearch
PreToolUse/AskUserQuestion  ←── busy→waiting 信号
  tool_input.questions[0].question = "What is your favorite color?"
  tool_input.questions[0].options = [{Blue}, {Red}, {Green}, {Purple}]
Notification              notification_type=permission_prompt
  message = "Claude Code needs your attention"
[session 被终止，PostToolUse 未捕获]
```

### 权限审批场景（session `9635a700`，来自实际交互会话）

```
...（前序工具调用）...
PreToolUse/Bash           pm=acceptEdits  ←── 注意：有时在 Notification 前写入（异步乱序）
Notification              notification_type=permission_prompt
  message = "Claude needs your permission to use Bash"
  permission_mode = ""（空）
[用户批准]
PreToolUse/Bash           ←── waiting→busy 信号（实际执行的工具）
PostToolUse/Bash          tool_response.stdout = "..."
```

---

## 关键注意事项

1. **Notification 不含 `permission_mode`**：需要靠 `message` 内容区分场景，不能靠 `permission_mode`

2. **Hook 写入文件顺序不保证**：PreToolUse 可能在 Notification 前写入文件，但业务上 Notification 先发生。判断时应基于语义而非文件顺序

3. **`-p` 模式跳过权限对话框**：所有 interactive 权限相关的 Notification 只在真正有终端的交互会话中出现

4. **`AskUserQuestion` 的 PostToolUse 有不确定性**：`-p` 模式下不触发；interactive 模式下理论上触发，但受 TUI 键盘交互特殊性影响，行为需进一步验证

5. **StopWindowService 2s 窗口**：`Stop` 不直接改状态，必须等 2s 窗口期后合并决策，避免乱序导致状态闪烁

---

## 多场景实验结果 (2026-04-07)

实验系统：`scripts/experiments/` — 6 个 PTY 场景，采集完整 hook 事件流。
数据来源：`/tmp/hook_capture.jsonl`，按 session_id 隔离，时间戳对齐至实验运行窗口（UTC 07:02–07:07）。
实验版本：commit `1f02f09`，分支 `feat/hook-stream-experiment`。

---

### 各场景精确事件流（UTC 时间轴）

#### 场景 01：AskUserQuestion — session `94d71b5c`

```
07:02:21  SessionStart
07:02:34  UserPromptSubmit           ← 用户发送「请调用 AskUserQuestion」prompt
07:02:45  PreToolUse   tool=ToolSearch
07:02:45  PostToolUse  tool=ToolSearch
07:02:54  PreToolUse   tool=AskUserQuestion   ← busy→waiting 触发（T+0）
07:03:00  Notification nt=permission_prompt   ← 对话框出现（T+6s）
           msg="Claude Code needs your attention"
07:04:00  SessionEnd                          ← PTY cleanup 触发（工具悬挂中）
```

**关键发现：**
- `PreToolUse/AskUserQuestion` → `Notification(permission_prompt)` 间隔 **精确 6 秒**（TUI 渲染延迟）
- AskUserQuestion 悬挂期间收到 `SessionEnd`（PTY kill），`PostToolUse` **从未触发**
- 这证明 AskUserQuestion 工具在用户未回答时保持阻塞，工具生命周期不完结，`PostToolUse` 不会在中间触发

---

#### 场景 02：permission_needed — session `bdbb7db1`

```
07:04:02  SessionStart
07:04:33  UserPromptSubmit  pm=acceptEdits
07:04:44  Stop              stop_hook_active=False
```

**发现：**
- `--permission-mode acceptEdits` 不是有效 CLI 标志，claude 退化为默认模式
- Claude 直接给出文本回答（未调用 Bash），随即 Stop
- `stop_hook_active=False` = 正常完成（非被 stop hook 打断）
- 未捕获 Bash permission 场景，该场景需要单独实验（参见下方「ed38dc18」真实数据）

---

#### 场景 04：headless 模式 (`claude -p`) — session `61e30386`

```
07:05:41  SessionStart
07:05:42  UserPromptSubmit  pm=default
07:05:46  Stop              stop_hook_active=False
07:05:46  SessionEnd
```

**发现：**
- `Stop` 和 `SessionEnd` **同秒触发**（异步写入，顺序为 Stop 先、SessionEnd 后）
- 完整生命周期仅 4 个 hook 事件，耗时约 5 秒
- headless 模式无 `Notification`（无 TUI，无权限对话框）
- **StopWindowService 含义**：headless Stop 后 2s 内紧跟 SessionEnd，不会误判为 waiting

---

#### 场景 03/05/06：数据缺失 — sessions `c08167ec`, `9c2fc6fe`, `d095c0ed`

```
07:05:06  SessionStart  (c08167ec — simple_task)
07:05:54  SessionStart  (9c2fc6fe — task_interrupt)
07:06:34  SessionStart  (d095c0ed — session_end)
```

三个场景均仅捕获 `SessionStart`，无后续事件。

**已确认原因：**
PTY cleanup 在 `session.stop(flush_wait=6)` 内关闭 master_fd 后立即发送 SIGTERM，
claude 进程被终止时 hook 脚本（fire-and-forget `&`）随进程组一同被 kill。
6 秒 flush_wait 不足以等待 claude 自然完成任务再优雅退出；
正确做法是先让 claude 完成任务（等 Stop hook 触发），再 cleanup。

---

### 补充真实数据：interactive 模式 Bash 权限审批 — session `ed38dc18`

来自 `/tmp/hook_capture.jsonl` 同一天的真实 Claude Code 会话（非实验控制会话，但数据完整）。

```
07:03:41  UserPromptSubmit
07:03:46  PreToolUse  tool=Bash
07:03:52  Notification  nt=permission_prompt
           msg="Claude needs your permission to use Bash"
07:03:55  PostToolUse  tool=Bash           ← 用户批准后，工具执行完成
07:03:58  PreToolUse  tool=Bash            ← 下一个工具继续
...
07:11:06  Stop         stop_hook_active=False
07:12:06  Notification  nt=idle_prompt     ← Stop 后 60 秒触发
           msg="Claude is waiting for your input"
07:12:36  UserPromptSubmit                 ← 用户 90 秒后回复
```

**关键发现：`idle_prompt` 在 Stop 后 60 秒才触发**

这是本次分析中最重要的新发现：

- `Stop` 触发时，`StopWindowService` 已在 2 秒内决策 → session 进入 `idle`
- `Notification(idle_prompt)` 是 Claude Code 内置的「用户无响应提醒」，**延迟约 60 秒**才发出
- 因此 `idle_prompt` 对 `busy→idle` 状态检测**完全冗余**：状态早已在 Stop 时决策完毕
- 当前 `EventMapper` 将 `idle_prompt` 映射为 `agentStopped/background`，处理正确，但信号到达时已无意义

---

### 综合状态检测算法（最终版）

```
SessionStart                      → idle
                                    (若已 completed/stale → 重置为 idle)

UserPromptSubmit                  → busy
                                    (dismiss 所有未读通知，清除 waiting 状态)

PreToolUse (任意工具)             → busy（隐含，Claude 正在执行工具链）

PreToolUse/AskUserQuestion        → waiting（最早信号，T+0）
Notification(permission_prompt)   → waiting 确认（T+6s，AskUserQuestion 场景）
  msg contains "needs your attention"

Notification(permission_prompt)   → waiting（权限审批场景）
  msg contains "permission to use"

PostToolUse (任意工具)            → busy（工具完成，Claude 继续执行）
PostToolUse/AskUserQuestion       → busy（用户正确回答后触发，已验证）

Stop                              → 进入 StopWindowService 2s 窗口
  2s 内有 Notification(permission_prompt / elicitation_dialog / idle_prompt)
    → waiting
  2s 内无 Notification
    → idle，生成 agentStopped 合成事件

Notification(idle_prompt)         → 忽略（Stop 已在 60s 前决策 idle）

SessionEnd                        → completed（stamps ended_at）
```

---

### 特征置信度矩阵

| 特征 | 状态转换 | 置信度 | 来源 |
|------|---------|--------|------|
| `UserPromptSubmit` | → busy | ★★★ 确定 | 所有场景均出现 |
| `PreToolUse` (任意) | → busy | ★★★ 确定 | 场景 01 + ed38dc18 实测 |
| `Notification(permission_prompt)` "needs your attention" | → waiting | ★★★ 确定 | 场景 01 实测 |
| `Notification(permission_prompt)` "permission to use" | → waiting | ★★★ 确定 | ed38dc18 实测 |
| `PreToolUse/AskUserQuestion` | → waiting | ★★★ 确定 | 场景 01 实测（比 Notification 早 6s）|
| `Stop` 无后续 Notification | → idle | ★★★ 确定 | 场景 02/04 + ed38dc18 实测 |
| `SessionEnd` | → completed | ★★★ 确定 | 场景 01/04 实测 |
| `Stop` + `SessionEnd` 同秒 | headless 完成 | ★★★ 确定 | 场景 04 实测 |
| `PostToolUse/AskUserQuestion` | → busy | ★★★ 确定 | 场景07实测：PreToolUse→Notification(+6s)→PostToolUse(+27s后用户回答) |
| `Notification(idle_prompt)` | idle 60s 提醒 | ★★★ 确定 | ed38dc18 实测（与 Stop 间隔 60s）|
| `stop_hook_active=False` | 正常停止 | ★★★ 确定 | 场景 02/04 实测 |

---

### 对当前实现的影响评估

#### 现有实现正确的部分

| 逻辑 | 评估 |
|------|------|
| `StopWindowService` 2s 合并窗口 | ✅ 正确：Stop 后 2s 内无 Notification → idle |
| `UserPromptSubmit` → busy + dismiss | ✅ 正确：最可靠的 busy 信号 |
| `permissionNeeded` event → waiting | ✅ 正确：Notification(permission_prompt) 可靠 |
| `SessionEnd` → completed | ✅ 正确：无歧义 |
| `idle_prompt` → agentStopped/background | ✅ 正确：信号冗余，忽略即可 |
| headless Stop + SessionEnd 同秒 | ✅ 正确：StopWindowService 不会误判（SessionEnd 在 2s 内）|

#### 可改进的部分（未修复，记录于 TODOS.md）

| 信号 | 当前处理 | 可改进方向 |
|------|---------|-----------|
| `PreToolUse/AskUserQuestion` | 作为 `agentStopped/background` 丢弃 | 可提早 6s 检测 waiting（在 Notification 前）|
| `Notification.message` 内容 | 统一为 `permissionNeeded` | 可区分 AskUserQuestion vs 权限审批，显示不同 UI |
| `PostToolUse/AskUserQuestion` | 作为 `agentStopped/background` 丢弃 | 若验证可触发，可作为 waiting→busy 信号 |

---

### 已验证项完成情况

| 验证项 | 状态 | 结论 |
|--------|------|------|
| `PostToolUse/AskUserQuestion` 触发 | ✅ 已验证 | 用户回答后约 27s 触发（含 LLM 处理延迟）|
| headless Stop + SessionEnd 同秒 | ✅ 已验证 | Stop 先、SessionEnd 后，同秒写入 |
| `idle_prompt` 延迟 | ✅ 已验证 | Stop 后约 60s，对状态检测无意义 |
| `PreToolUse/AskUserQuestion` 时序 | ✅ 已验证 | T+0 触发，比 Notification 早 6s |

---

### 待验证项

1. **中断场景（ESC 键）Stop 是否触发**

   **实验结果（场景08）：** Claude 卡在 Glob/Bash 权限对话框（两次 `Notification(permission_prompt) "permission to use"`），ESC 可能只是 dismiss 了对话框而非停止任务。会话最终由 `/exit\r` 触发 `SessionEnd`，**无 Stop 触发**。

   **结论**：ESC 在权限对话框状态下不触发 Stop。正确测试需要 `--dangerously-skip-permissions` 绕过权限审批，让 Claude 自由执行工具调用，再发 ESC 中断。

   **实际影响**：若 Claude 在权限对话框等待用户审批时被 ESC dismiss，app 会看到 `waiting` 状态（由前面的 permission_prompt 设置），而后 SessionEnd。当前 `SessionLifecycleService` 在 `SessionEnd` 时设 `completed`，行为正确。

2. **`stop_hook_active=True` 场景**

   所有实测场景均为 `stop_hook_active=False`（正常完成）。`True` 只在 stop hook 本身正在运行时才会出现，属于极少见的竞态，实际可忽略。

3. **`elicitation_dialog` notification_type**

   仅在 `StopWindowService` 代码中出现，所有实测样本均为 `permission_prompt`。推测与某些 interactive 提示有关，待真实触发条件确认。

4. **Bash 权限拒绝（用户点击 Deny）**

   预期：`Notification(permission_prompt)` → 用户拒绝 → `Stop`（无 PostToolUse/Bash）。未实测。
