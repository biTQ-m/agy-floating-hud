---
name: floating-hud
description: Control and configure the AGY Floating HUD desktop capsule & Dynamic Island overlay (show/hide, switch collapsed styles including Notch/Pill Dynamic Island and E01-E10 dual-state beacons, switch style modes and themes, adjust hover morph physics, opacity, pin expanded list, clear completed tasks, screen position preset, completion chime, or open the Floating HUD control panel in Antigravity Desktop).
---

# AGY Floating HUD Skill

Use this skill when the user asks to open, hide, move, switch themes/collapsed styles/Dynamic Island, adjust opacity/transparency, mute, unmute, pin, or preview the **AGY Floating HUD** (`agy-floating-hud`) desktop floating progress overlay on macOS.

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
  "maxSessionsShown": 5,
  "styleMode": "classic",
  "theme": "cosmos",
  "collapsedStyle": "e05",
  "hoverMorph": "m1"
}
```

Supported options:
- `collapsedStyle`: `"e05"` (灵动岛·刘海原生融黑, default), `"island"` (灵动岛·悬浮黑曜胶囊), `"e01"` .. `"e10"` (10 dual-state Active×Completed micro-beacons), `"capsule"` (经典双行宽胶囊).
- `hoverMorph`: `"m1"` (锚点液态撑开), `"m2"` (信标驻留·抽屉浮现), `"m3"` (90ms防误触·灵动展开), `"m4"` (光学景深聚焦).
- `styleMode`: `"classic"` (经典光学毛玻璃), `"aurora"` (S6 流体极光呼吸), `"frameless"` (S10 去外框悬浮堆叠).
- `theme`: `"smoked"` (3D 液态烟晶), `"cosmos"` (M2 深空星云), `"bamboo"` (M8 岚山竹影), `"sapphire"` (T2 午夜蓝宝石), `"pewter"` (M10 蚀刻雾银).
- `opacity`: Float in `0.20` .. `1.00` (default `0.94`).
- `positionPreset`: `"top_right"`, `"top_center"`, `"bottom_right"`, `"bottom_left"`, `"custom"`.

To clear all finished/completed tasks from the floating HUD, set `"clearedCompletedBefore"` in `settings.json` to the current Unix timestamp in seconds (e.g. `date +%s`). Any conversation that starts or finishes a new turn after that timestamp will automatically appear again.

## 3. Ensure Native Helper Is Running

If `AgyFloatingHud.app` is not currently running on macOS, start it cleanly in background mode without stealing focus:

```bash
open -g -a ~/.gemini/config/plugins/agy-floating-hud/macos/AgyFloatingHud.app
```
