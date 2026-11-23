# AGY Floating HUD — Antigravity 2.0 桌面灵动胶囊进度悬浮窗

专为 **Antigravity 2.0 Desktop (macOS)** 打造的全屏置顶会话实时进度与完成提醒插件。即使你切到浏览器、终端、Xcode 或全屏视频，也能通过屏幕角落的**原生灵动胶囊 (`NSPanel`)** 一眼掌握所有后台 Agent 会话的实时动态。

## 核心特性

- **灵动胶囊双态交互（Dynamic Capsule HUD）**：
  - **默认紧凑模式**：仅占约 `326 × 42 pt`，展示状态呼吸灯、当前项目名、实时工具动作、`task.md` 清单百分比与本轮耗时；不抢焦点（`nonactivatingPanel`），支持全桌面空间与全屏应用置顶（`canJoinAllSpaces` + `fullScreenAuxiliary`）。
  - **悬停自动展开 / 图钉固定**：鼠标移入自动向下展开多会话进度卡片列表；支持任意位置拖拽记忆与四角/灵动岛预设位切换。
- **双引擎毫秒级进度感知**：
  - **SQLite WAL 实时只读引擎 (`conversations/<id>.db`)**：直接以 `SQLITE_OPEN_READONLY` + `PRAGMA query_only = ON` 读取 Antigravity 实时会话库与子代理树（自动聚合父子会话进度，避免 `transcript.jsonl` 跨轮次延迟落盘导致状态滞后）。
  - **Lifecycle Hooks + `task.md` 清单百分比**：实时捕获 `Stop` 终止原因，并自动解析会话下 `task.md` 复选框完成进度条（如 `3/4 · 75%`）。
- **点击卡片直达对应会话**：
  - 结合 `nonactivatingPanel` 首次点击穿透 (`acceptsFirstMouse`) 与官方 `sidecar_sdk` (`window.sidecar.ui.toggleConversation`) 预热长轮询桥接，点击任意会话卡片即可在 `<5ms` 内激活 Antigravity 并精准切换到对应会话标签页。
- **完成与待确认提醒**：
  - 会话从运行态转为**已完成 (`✓`)**、**待你确认 (`⏳`)** 或 **异常 (`⚠`)** 时，胶囊边框高亮闪烁 4.8 秒并播放柔和系统提示音（`Glass` / `Tink` / `Basso`，可随时一键静音）。
  - 点击任意会话卡片即可一键唤起并切回 **Antigravity** 主窗口。
- **顶部菜单栏 + 右侧辅助面板双控**：
  - 支持浮窗右下角 **「清理已完成 (N)」** 一键清空历史完成项（不会把更早的历史旧会话顶上来；后续有新对话轮次时自动重新出现），每张完成卡片右上角也支持单条 `×` 移除。
  - macOS 顶部状态栏常驻快捷菜单（显示活跃会话数、快速隐藏/显示、位置预设、清理已完成任务）。
  - Antigravity 右侧辅助栏内置 **`Floating HUD`** 可视化控制中心。

## 快速安装与启动

```bash
git clone https://github.com/biTQ-m/agy-floating-hud.git
cd agy-floating-hud
chmod +x ./install.sh
./install.sh
```

常用参数：
- `./install.sh --rebuild`：强制重新编译 `macos/AgyFloatingHud.app`
- `./install.sh --copy`：使用复制模式而非软链接安装到 `~/.gemini/config/plugins/agy-floating-hud`
- `./install.sh --uninstall`：退出悬浮窗进程并移除插件链接

## 运行单元测试

```bash
python3 -m unittest discover -s tests
```
