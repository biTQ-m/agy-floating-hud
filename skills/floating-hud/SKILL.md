---
name: floating-hud
description: Control and configure the AGY Floating HUD desktop capsule overlay (show/hide, pin expanded list, clear completed tasks, screen position preset, completion chime, or open the Floating HUD control panel in Antigravity Desktop).
---

# AGY Floating HUD Skill

Use this skill when the user asks to open, hide, move, mute, unmute, pin, or preview the **AGY Floating HUD** (`agy-floating-hud`) desktop floating progress capsule on macOS.

## 1. Open the Sidecar Control Panel Pill

When the plugin is enabled and the user wants to visually adjust settings in the right-hand auxiliary pane, surface this clickable pill link:

```markdown
[Floating HUD](sidecar://agy-floating-hud/floating_hud/?v=3)
```

## 2. Live Configuration File (`settings.json`)

The native macOS helper (`AgyFloatingHud.app`) watches `~/.gemini/antigravity/plugin_data/agy-floating-hud/settings.json` via `DispatchSource` and applies updates instantaneously (<5ms) without restarting:

```json
{
  "visible": true,
  "pinnedExpanded": false,
  "soundEnabled": true,
  "autoDimIdle": true,
  "opacity": 0.94,
  "positionPreset": "top_right",
  "maxSessionsShown": 5
}
```

Supported `positionPreset` values:
- `"top_right"` — 右上角（默认推荐）
- `"top_center"` — 顶部居中（灵动岛下方）
- `"bottom_right"` — 右下角
- `"bottom_left"` — 左下角
- `"custom"` — 用户手动鼠标拖拽后的自定义坐标（`customTopCenterX`, `customTopY`）

To clear all finished/completed tasks from the floating HUD, set `"clearedCompletedBefore"` in `settings.json` to the current Unix timestamp in seconds (e.g. `date +%s`). Any conversation that starts or finishes a new turn after that timestamp will automatically appear again.

## 3. Ensure Native Helper Is Running

If `AgyFloatingHud.app` is not currently running on macOS, start it cleanly in background mode without stealing focus:

```bash
open -g -a ~/.gemini/config/plugins/agy-floating-hud/macos/AgyFloatingHud.app
```
