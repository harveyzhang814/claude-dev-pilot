# Menubar Popover — Session-Grouped UI

**Goal:** 将 menubar popover 改写为以 session 为主维度展示，事件归属于各自的 session 下，替代原有的"Needs Attention / Recent Activity"双区块结构。

---

## 背景

当前 popover 结构：
- 顶部：绿点 + "N active sessions" 横幅（仅有数量）
- Needs Attention 区块（action 事件）
- Recent Activity 区块（action + review 事件）
- Footer

问题：用户无法从 popover 直接感知哪个 session 产生了哪条事件，需要跳转到 Session Panel 才能关联。

---

## 设计决策

### 1. 布局结构

有活跃 session 时，popover 内容区改为：每个活跃 session 占一个分组，session 之间用细分割线隔开。

```
┌─────────────────────────────────┐
│ ● my-saas          [needs input]│  ← session header
│ ▌ Permission needed: write to…  │  ← event (red bar)
├─────────────────────────────────┤  ← session divider
│ ● agent-dev-pilot     [running] │
│ ▌ Task completed: add lifecycle │  ← event (green bar)
│ ▌ Task started: impl installer  │  ← event (gray bar)
├─────────────────────────────────┤
│ ● dotfiles            [running] │
│   Working...                    │  ← no events yet
├─────────────────────────────────┤
│ Session Panel          Quit     │  ← footer
└─────────────────────────────────┘
```

### 2. Session 排序

活跃 session 按 `startedAt` 降序（最新启动的在前）。`waiting` 状态不做额外置顶，依靠红色颜色 bar 自然突出。原"Needs Attention"独立区块移除。

### 3. Session Header 行

```
[状态点 7px] [project name 粗体] [状态标签]
```

- 状态点颜色：running = `#FF9F0A`（amber），waiting = `#FF453A`（红）
- 状态标签：running → `"running"`（amber），waiting → `"needs input"`（红）
- 无时间信息（保持紧凑）

### 4. Session 内事件列表

- 取该 session 最近 **5 条** undismissed 事件（`attentionTier != background`），按 `timestamp` 降序
- 复用现有 `EventCardView`，`sessionLabel` 传 `nil`（session 已是标题，不需重复）
- 事件颜色 bar：action → 红，review(completed) → 绿，review(started) → 灰（`#48484A`）

### 5. 无事件的 Session

Session header 正常显示，下方渲染一行 italic 灰色文字：`"Working..."`（`#48484A`，11pt italic）

### 6. 无活跃 Session 时的空状态

```
        ⌨️  (terminal SF Symbol, 32pt, opacity 0.25)
   No active sessions
   Start Claude Code in any project
         to see it here.
```

使用 `terminal` SF Symbol（`Image(systemName: "terminal")`），显示于垂直居中区域。Footer 保留。

### 7. Footer

不变：`Session Panel`（accentColor）| `Quit`（secondary）

---

## 数据层变更

### PopoverViewModel 新增

```swift
// 活跃 session 列表（running + waiting，按 startedAt 降序）
public var activeSessions: [DevSession] = []

// 按 session 分组的事件（key = sessionId，最多 5 条，attentionTier != background）
public var eventsBySession: [String: [DevEvent]] = [:]
```

新增两个 `ValueObservation`：
1. `activeSessions`：观察 `DevSession` where status in (running, waiting)，按 `startedAt` desc
2. `eventsBySession`：观察 `DevEvent` where sessionId in activeSessions，按 session 分组，每组最多 5 条

现有 `actionEvents`、`recentEvents`、`activeSessionCount`、`sessionStartTimes` **保留不动**（MenubarPopover 不再使用，但 SessionPanelView 可能复用）。

---

## 视图层变更

### 新增：`SessionGroupView.swift`

单个 session 分组组件，负责渲染：
- Session header 行
- 事件列表（复用 `EventCardView`）或 "Working..." 占位

```swift
struct SessionGroupView: View {
    let session: DevSession
    let events: [DevEvent]
    var onOpenTerminal: ((String) -> Void)?
    var onDismiss: (String) -> Void
}
```

### 修改：`MenubarPopover.swift`

- 移除旧的 `activeSessionCount` 横幅、Needs Attention 区块、Recent Activity 区块
- 替换为：
  - 有 session：`ForEach(viewModel.activeSessions)` → `SessionGroupView` + 分割线
  - 无 session：空状态 view
- `frame(width:)` 保持 360（与现有一致）

---

## 不在范围内

- 事件 dismiss 滑动手势：保留（`EventCardView` 本身已支持）
- Session Panel 窗口：不变
- 通知系统：不变
- 已完成/stale session 的历史事件：不在 popover 展示（去 Session Panel 看）

---

## 成功标准

1. popover 打开时，每个活跃 session 以独立分组显示
2. 有权限事件的 session 靠红色颜色 bar 突出，无需独立"Needs Attention"区块
3. 刚启动无事件的 session 显示"Working..."占位
4. 无活跃 session 时显示空状态（terminal 图标 + 文字）
5. 全部现有测试（69 条）通过，新增 SessionGroupView 快照或逻辑测试
