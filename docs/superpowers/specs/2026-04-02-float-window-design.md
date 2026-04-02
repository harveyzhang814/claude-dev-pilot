# Float Window Mode — Design Spec

**Date:** 2026-04-02
**Feature:** 灵动岛风格悬浮窗，作为 Menubar Popover 的替代展示模式

---

## 概述

在现有 Menubar Popover 之外新增一种展示模式：**Float Window**。用户可在 Settings 中手动切换。Float Window 是一个固定在屏幕顶部中央、menubar 底部的 `NSPanel`，行为类似 iPhone 灵动岛：有新通知时自动浮现，聚焦时展开完整内容。

---

## 模式切换

- **UserDefaults key:** `floatWindowMode`（Bool，默认 `false`）
- **切换入口:** `SettingsView` 中新增"展示模式"单选组：
  - `Menubar Popover`（默认）
  - `Float Window`
- `AppState` 通过 `onChange(of: floatWindowMode)` 监听，切换时即时创建或销毁 `FloatWindowController`
- Float Window 模式下，menubar 图标保留；点击图标触发 Expanded 状态

---

## 状态机

Float Window 有三个状态：

| 状态 | 显示条件 | 内容 |
|------|---------|------|
| **Hidden** | 无 active session，或有 session 但无未读 action/review 事件 | 窗口 `orderOut` |
| **Compact** | 有 active session **且** 有未读 `.action` / `.review` tier 事件 | `FloatWindowCompactView` |
| **Expanded** | 点击 menubar 图标，或鼠标移入/聚焦窗口 | 完整 `MenubarPopover` |

**转换规则：**
- Compact 自动出现：`PopoverViewModel` 中出现未读 action/review 事件时
- Compact → Hidden：所有 action/review 事件被 dismiss 后
- Compact → Expanded：点击 menubar 图标，或鼠标进入窗口
- Expanded → Compact：失去焦点（鼠标离开窗口）1 秒后，若仍有未读事件；或再次点击 menubar 图标
- Expanded → Hidden：失去焦点 1 秒后，且无未读事件；或再次点击 menubar 图标且无未读事件
- Hidden → Expanded：点击 menubar 图标（手动唤起）

---

## 窗口定位

- **水平位置：** 屏幕水平居中
- **垂直位置：** `y = visibleFrame.origin.y + visibleFrame.height`（即 menubar 底部，macOS 坐标系原点在左下角）
- **宽度：** 360pt（与现有 popover 一致）
- **高度：** 随状态动态变化（Compact 约 44–200pt 自适应内容；Expanded 最大 480pt）

---

## 窗口属性

```swift
// NSPanel 配置
styleMask: [.borderless, .nonactivatingPanel]
level: .floating
backgroundColor: .clear
isOpaque: false
hasShadow: true
collectionBehavior: [.canJoinAllSpaces, .stationary]  // 跨 Space 常驻
```

圆角（12pt）和背景 blur 由 SwiftUI 内容层实现：
- 背景使用 `NSVisualEffectView`（material: `.hudWindow`）
- SwiftUI 层叠加 `RoundedRectangle` clip

---

## 新增组件

### `FloatWindowController: NSObject`

位置：`Sources/App/FloatWindow/FloatWindowController.swift`

职责：
- 创建并持有 `NSPanel`
- 根据 `PopoverViewModel` 数据驱动三态切换
- 管理 expand/collapse 动画（`NSAnimationContext`，duration 0.2s，ease-in-out）
- 管理失焦 1 秒收起的 `Timer`
- 监听鼠标进入/离开事件（`NSTrackingArea`）

### `FloatWindowCompactView: View`

位置：`Sources/App/FloatWindow/FloatWindowCompactView.swift`

内容：
- 只显示未读 `.action` 和 `.review` tier 事件
- 复用 `EventCardView` 核心样式（左侧颜色条 + 文字），去掉 dismiss 按钮
- 最多显示 5 条，超出截断
- 点击任意 card → 触发 Expanded
- 背景：`NSVisualEffectView` + `RoundedRectangle(cornerRadius: 12)` clip

---

## 复用现有组件

- `MenubarPopover` — Expanded 状态直接复用，无需修改
- `PopoverViewModel` — 数据源，`FloatWindowController` 持有同一实例
- `EventCardView` — Compact view 复用核心样式

---

## AppState 变更

```swift
// 新增
var floatWindowMode: Bool {
    get { UserDefaults.standard.bool(forKey: "floatWindowMode") }
    set { UserDefaults.standard.set(newValue, forKey: "floatWindowMode") }
}
private var floatWindowController: FloatWindowController?

// start() 中
if floatWindowMode {
    floatWindowController = FloatWindowController(viewModel: popoverViewModel, onFocusSession: ...)
}
```

---

## SettingsView 变更

在现有 Settings 中新增一个 section：

```
展示模式
  ○ Menubar Popover
  ○ Float Window
```

切换后立即生效（不需要重启）。

---

## UserDefaults Keys（新增）

| Key | Default | Purpose |
|-----|---------|---------|
| `floatWindowMode` | `false` | Float Window 模式开关 |

---

## 不在本次范围内

- Float Window 内的事件 dismiss 交互（Compact 态仅展示，需展开后 dismiss）
- 自定义窗口位置/尺寸
- 动画细节的用户配置

---

## 文件清单

| 文件 | 操作 |
|------|------|
| `Sources/App/FloatWindow/FloatWindowController.swift` | 新建 |
| `Sources/App/FloatWindow/FloatWindowCompactView.swift` | 新建 |
| `Sources/App/AppState.swift` | 修改（新增 floatWindowMode + controller） |
| `Sources/App/Views/SettingsView.swift` | 修改（新增模式切换 UI） |
| `Sources/App/AgentDevPilotApp.swift` | 可能微调（menubar 图标点击行为） |
