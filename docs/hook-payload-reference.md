# Claude Code Hook Payload 参考手册

本文记录 Claude Code 各类 hook 事件发送的真实 JSON 字段结构，数据来自实际捕获实验（2026-04-05）。

---

## 公共字段（所有 hook 共有）

```json
{
  "session_id": "4799008e-bf47-4978-99b4-f666f877df88",
  "transcript_path": "/Users/xxx/.claude/projects/.../session_id.jsonl",
  "cwd": "/Users/xxx/Projects/my-project",
  "hook_event_name": "PreToolUse"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `session_id` | UUID | 会话唯一标识符 |
| `transcript_path` | String | 会话记录 jsonl 文件路径 |
| `cwd` | String | 会话工作目录 |
| `hook_event_name` | String | hook 类型名称（见下） |

---

## SessionStart

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "hook_event_name": "SessionStart",
  "source": "startup",
  "model": "claude-sonnet-4-6"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `source` | String | 启动来源，通常为 `"startup"` |
| `model` | String | 使用的模型 ID |

**注意：** `permission_mode` 字段在 SessionStart/SessionEnd 中**不存在**（为空）。

---

## SessionEnd

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "hook_event_name": "SessionEnd",
  "reason": "other"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `reason` | String | 会话结束原因，如 `"other"` |

---

## UserPromptSubmit

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "permission_mode": "default",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "Use the ask_user_question tool to ask me: what is your favorite color?"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `permission_mode` | String | 会话权限模式（见下方说明） |
| `prompt` | String | 用户提交的完整消息内容 |

**注意：** 在 `-p` 模式（`--print`）下，若通过 stdin 传入多行内容，`prompt` 会包含所有行（含换行符）。例如 `echo "4" | claude -p "..."` 时，`prompt` = `"...\n4\n"`。

---

## PreToolUse

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "echo hello",
    "description": "Print hello",
    "timeout": 120000
  },
  "tool_use_id": "toolu_01XF4fspAuN5iyX5mPbEgcP2"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `permission_mode` | String | 会话权限模式 |
| `tool_name` | String | 工具名称（如 `Bash`、`AskUserQuestion`、`Read` 等） |
| `tool_input` | Object | 工具参数（结构因 tool 而异，见下方各工具说明） |
| `tool_use_id` | String | 工具调用唯一 ID，可用于与 PostToolUse 对应 |

**注意：** PreToolUse 在工具执行前触发，此时**没有** `tool_response` 字段。

---

## PostToolUse

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "permission_mode": "default",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "echo hello",
    "description": "Print hello"
  },
  "tool_response": {
    "stdout": "hello\n",
    "stderr": "",
    "interrupted": false,
    "isImage": false,
    "noOutputExpected": false
  },
  "tool_use_id": "toolu_01XF4fspAuN5iyX5mPbEgcP2"
}
```

PostToolUse 包含 PreToolUse 的所有字段，新增：

| 字段 | 类型 | 说明 |
|------|------|------|
| `tool_response` | Object | 工具执行结果（结构因 tool 而异） |

Bash 工具的 `tool_response` 结构：

| 字段 | 类型 | 说明 |
|------|------|------|
| `stdout` | String | 标准输出 |
| `stderr` | String | 标准错误 |
| `interrupted` | Bool | 是否被中断 |
| `isImage` | Bool | 输出是否为图像 |
| `noOutputExpected` | Bool | 是否预期无输出（如 `wait` 命令） |
| `backgroundTaskId` | String? | 若为后台任务则有此字段 |

---

## Notification

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "hook_event_name": "Notification",
  "message": "Claude Code needs your attention",
  "notification_type": "permission_prompt"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | String | 通知文本 |
| `notification_type` | String | 通知类型（见下） |

**⚠️ 重要：Notification hook 的 `permission_mode` 字段为空（不含此字段）。**

已知 `notification_type` 取值：

| `notification_type` | `message` 示例 | 含义 |
|---------------------|--------------|------|
| `permission_prompt` | `"Claude Code needs your attention"` | AskUserQuestion 等待用户回答 |
| `permission_prompt` | `"Claude needs your permission to use Bash"` | 工具权限审批 |
| `elicitation_dialog` | — | 其他形式的用户交互请求 |
| `idle_prompt` | — | Agent 空闲等待 |
| （其他） | — | 一般状态通知 |

**两种 `permission_prompt` 的区分方式：**
- `message` 包含 `"needs your attention"` → AskUserQuestion 等待回答
- `message` 包含 `"permission to use"` → 工具权限审批

---

## Stop

```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "/...",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "The answer is 4."
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `stop_hook_active` | Bool | 是否有 stop hook 正在处理 |
| `last_assistant_message` | String | Claude 最后一条回复的文本内容 |

---

## 各工具的 tool_input 结构

### Bash

```json
{
  "command": "swift build -c debug",
  "description": "Build project",
  "timeout": 120000
}
```

### AskUserQuestion

```json
{
  "questions": [
    {
      "question": "What is your favorite color?",
      "header": "Fav Color",
      "options": [
        { "label": "Blue", "description": "A classic, calming choice" },
        { "label": "Red", "description": "Bold and energetic" }
      ],
      "multiSelect": false
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `questions[].question` | String | 问题文本 |
| `questions[].header` | String | 问题分组标题 |
| `questions[].options[]` | Array | 可选项列表（可为空） |
| `questions[].multiSelect` | Bool | 是否允许多选 |

### ToolSearch（内部工具）

```json
{
  "query": "select:AskUserQuestion",
  "max_results": 1
}
```

---

## permission_mode 字段说明

`permission_mode` 反映会话当前的权限模式，来自 `--permission-mode` CLI 参数或全局设置：

| 值 | 含义 |
|----|------|
| `"default"` | 遵循 allow/deny 列表，不在列表中的工具视设置决定 |
| `"acceptEdits"` | 文件编辑类工具自动批准，其他工具需要审批 |
| `"auto"` | 所有工具自动批准 |
| `"bypassPermissions"` | 完全绕过权限检查（危险） |
| `"plan"` | 只读计划模式，不执行任何工具 |
| `"dontAsk"` | 不询问，按规则直接允许或拒绝 |

**⚠️ `-p` 模式（`--print`）特殊行为：**
- 跳过所有交互式权限对话框
- `Notification` hook（包括 `permission_prompt`）在 `-p` 模式下**不触发**
- 权限依据设置规则自动批准或拒绝，不弹窗

---

## Hook 触发时序保证

由于 notify.sh 使用 `&` fire-and-forget 异步发送，**写入 JSONL 文件的顺序不保证与事件实际发生顺序一致**。以下规律在实验中观察到：

- PreToolUse 和 PostToolUse 属于同一 `tool_use_id` 的调用对
- Notification(permission_prompt) 与 PreToolUse 的顺序在文件中可能颠倒，实际业务顺序是 Notification 先触发
- Stop 通常在最后，但 PostToolUse 有时晚于 Stop 写入文件

---

## AskUserQuestion 的特殊行为

`AskUserQuestion` 工具与普通工具不同：

| 行为 | 普通工具（如 Bash） | AskUserQuestion |
|------|-----------------|----------------|
| PreToolUse | ✅ 触发 | ✅ 触发 |
| PostToolUse（`-p` 模式）| ✅ 触发 | ❌ **不触发** |
| PostToolUse（interactive 模式）| ✅ 触发 | 待确认 |
| Notification | 无 | ✅ 触发（`notification_type: "permission_prompt"`）|

在 `-p` 模式下，`AskUserQuestion` 的 `PostToolUse` 不触发的原因：工具调用后会话即结束，`Stop` 在 `PostToolUse` 之前写入，导致 `PostToolUse` 丢失或从未触发。
