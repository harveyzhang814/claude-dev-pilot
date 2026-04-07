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
数据来源：`/tmp/hook_capture.jsonl` + 各场景 `data/raw/*.jsonl`，通过 session_id 时间关联。

---

### 场景 01：AskUserQuestion（关键未知项）

**session**: `94d71b5c`
**完整 hook 序列：**

```
SessionStart
UserPromptSubmit              (用户发送「请调用 AskUserQuestion」prompt)
PreToolUse  tool=ToolSearch   (Claude 确认工具可用)
PostToolUse tool=ToolSearch
PreToolUse  tool=AskUserQuestion   ← Claude 调用工具
Notification nt=permission_prompt  ← 对话框出现（6s 后）
SessionEnd                         ← 会话被终止（工具悬挂状态）
```

**关键结论：**

- `PostToolUse/AskUserQuestion` **从未触发**。
  原因：AskUserQuestion 工具处于「等待用户输入」挂起状态，工具生命周期未完成。
  当 session 被 kill 时，触发的是 `SessionEnd` 而非 `PostToolUse`。
  
- 正确完成路径推断：用户在 TUI 中用方向键选择选项 + Enter 后，
  `PostToolUse/AskUserQuestion` **应当**触发（tool 完成），随后 Claude 继续执行。
  本次实验未能验证此路径（因为发送了文本 "Blue\r" 而非方向键）。

- **`waiting → busy` 转换信号**（推断）：`PostToolUse/AskUserQuestion`。
  若无法可靠捕获，备用方案：`UserPromptSubmit`（用户重新输入）。

- **`idle/busy → waiting` 信号**：`PreToolUse/AskUserQuestion` 或 `Notification(permission_prompt)`。

---

### 场景 02：permission_needed (acceptEdits 模式)

**session**: `bdbb7db1`
**hook 序列：**

```
SessionStart
UserPromptSubmit  pm=acceptEdits
Stop              stop_hook_active=False
```

**发现：**
- `--permission-mode acceptEdits` 可能不是有效 CLI 标志，Claude 未执行 Bash 工具调用。
- `stop_hook_active=False`：正常停止（非中断）。
- **待验证**：正确的 permission 拒绝/批准场景的 hook 序列。

---

### 场景 04：headless 模式 (`claude -p`)

**session**: `61e30386`
**hook 序列：**

```
SessionStart
UserPromptSubmit  pm=default
Stop              stop_hook_active=False   ← 同秒
SessionEnd                                 ← 同秒
```

**发现：**
- headless 模式下，`Stop` 和 `SessionEnd` **同秒触发**，顺序为 Stop 先于 SessionEnd。
- `stop_hook_active=False`：正常完成。
- headless 模式无需工具调用时，完整生命周期仅有 4 个 hook 事件。

---

### 场景 03/05/06：数据缺失

场景 03 (simple_task)、05 (interrupt)、06 (session_end) 仅捕获到 `SessionStart`，
未见 `Stop`/`SessionEnd`/`Notification` 事件。

**可能原因：**
- `_cleanup()` 关闭 PTY master_fd 后，claude 进程被 SIGTERM/SIGKILL 终止太快，
  hook 脚本（fire-and-forget `&`）在系统级别被一同杀死。
- 需要在 `stop()` 调用后增加更长的 flush_wait，或避免 SIGKILL 路径。

---

### 综合状态检测算法（基于实验数据）

```
SessionStart                   → idle
UserPromptSubmit               → busy  (同时 dismiss 所有旧事件)
PreToolUse                     → busy  (任意工具)
PreToolUse/AskUserQuestion     → waiting
Notification(permission_prompt)→ waiting  (与 PreToolUse/AQU 共同确认)
PostToolUse/AskUserQuestion    → busy   (unconfirmed — 需再次实验验证)
Stop [recent permission_prompt]→ waiting
Stop [无 permission_prompt]    → idle   (经 StopWindowService 2s 确认)
Notification(idle_prompt)      → idle
SessionEnd                     → completed
```

**最高置信度特征（已验证）：**
1. `UserPromptSubmit` → **busy**（最可靠，无歧义）
2. `PreToolUse` (任意工具) → **busy**
3. `Notification(idle_prompt)` → **idle**
4. `Notification(permission_prompt)` → **waiting**
5. `SessionEnd` → **completed**

**待验证：**
- `PostToolUse/AskUserQuestion` 在用户正确回答后是否触发
- `Stop` + `Notification(idle_prompt)` 的共现顺序（哪个先）
- 中断场景（ESC）的 hook 序列
