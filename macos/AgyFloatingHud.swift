import AppKit
import Cocoa
import Foundation
import SQLite3
import SwiftUI

// MARK: - Data Models

enum SessionPhase: String, Codable, Equatable {
    case thinking
    case runningTool = "running_tool"
    case waiting
    case streaming
    case completed
    case error
    case canceled
    case idle

    var isActive: Bool {
        switch self {
        case .thinking, .runningTool, .waiting, .streaming:
            return true
        case .completed, .error, .canceled, .idle:
            return false
        }
    }

    var badgeText: String {
        switch self {
        case .thinking: return "思考中"
        case .runningTool: return "执行中"
        case .waiting: return "待确认"
        case .streaming: return "输出中"
        case .completed: return "已完成"
        case .error: return "异常"
        case .canceled: return "已停止"
        case .idle: return "待命"
        }
    }

    var accentColor: Color {
        switch self {
        case .thinking:
            return Color(red: 0.38, green: 0.76, blue: 1.0)    // Apple System Sky
        case .runningTool:
            return Color(red: 0.50, green: 0.64, blue: 1.0)    // Crisp Periwinkle Blue
        case .waiting:
            return Color(red: 1.00, green: 0.80, blue: 0.30)   // Apple System Amber
        case .streaming:
            return Color(red: 0.34, green: 0.86, blue: 0.78)   // Apple System Mint
        case .completed:
            return Color(red: 0.32, green: 0.84, blue: 0.54)   // Apple System Green
        case .error:
            return Color(red: 1.00, green: 0.42, blue: 0.45)   // Apple System Coral Red
        case .canceled:
            return Color(white: 0.66)                          // Clear Silver
        case .idle:
            return Color(white: 0.62)                          // Neutral Silver
        }
    }

    var symbolName: String {
        switch self {
        case .thinking: return "sparkles"
        case .runningTool: return "bolt.horizontal.circle.fill"
        case .waiting: return "questionmark.bubble.fill"
        case .streaming: return "text.bubble.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .canceled: return "stop.circle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    var progressGradientColors: [Color] {
        switch self {
        case .thinking:
            return [
                Color(red: 0.30, green: 0.66, blue: 0.98),
                Color(red: 0.52, green: 0.84, blue: 1.00),
            ]
        case .runningTool:
            return [
                Color(red: 0.42, green: 0.56, blue: 0.98),
                Color(red: 0.62, green: 0.74, blue: 1.00),
            ]
        case .waiting:
            return [
                Color(red: 0.94, green: 0.68, blue: 0.20),
                Color(red: 1.00, green: 0.84, blue: 0.40),
            ]
        case .streaming:
            return [
                Color(red: 0.26, green: 0.78, blue: 0.72),
                Color(red: 0.46, green: 0.92, blue: 0.82),
            ]
        case .completed:
            return [
                Color(red: 0.28, green: 0.78, blue: 0.52),
                Color(red: 0.42, green: 0.88, blue: 0.60),
            ]
        case .error:
            return [
                Color(red: 0.94, green: 0.36, blue: 0.40),
                Color(red: 1.00, green: 0.52, blue: 0.54),
            ]
        case .canceled, .idle:
            return [
                Color(white: 0.56),
                Color(white: 0.72),
            ]
        }
    }

    var progressGlowColor: Color {
        accentColor
    }
}

struct TaskChecklistStats: Equatable, Codable {
    var done: Int
    var inProgress: Int
    var total: Int
    var percent: Int
    var currentItem: String
}

struct SessionSnapshot: Identifiable, Equatable {
    var id: String                  // root conversationId
    var shortId: String
    var projectId: String
    var conversationTitle: String   // Sidebar conversation title from conversation_summaries.db
    var workspaceName: String
    var modelShortName: String
    var promptTitle: String
    var phase: SessionPhase
    var detailText: String
    var stepCount: Int
    var turnToolCount: Int
    var turnToolMix: String
    var taskStats: TaskChecklistStats?
    var turnStartedAt: Date
    var updatedAt: Date
    var completedAt: Date?

    /// 1 = 思考, 2 = 执行/待确认, 3 = 回复, 4 = 完成
    var lifecycleStage: Int {
        switch phase {
        case .thinking:
            return turnToolCount > 0 ? 2 : 1
        case .runningTool, .waiting:
            return 2
        case .streaming:
            return 3
        case .completed, .error, .canceled, .idle:
            return 4
        }
    }

    /// Smooth, monotonic progress fraction (0.0 ... 1.0) combining `task.md` checklist milestones
    /// or asymptotic real-time turn progression (`thinking` -> `tool loop` -> `streaming`).
    func estimatedProgress(at now: Date) -> Double {
        if let ts = taskStats, ts.total > 0 {
            let activeCredit = (phase.isActive && ts.done < ts.total)
                ? max(0.42, min(0.85, Double(max(1, ts.inProgress)) * 0.5))
                : 0.0
            return min(1.0, max(0.08, (Double(ts.done) + activeCredit) / Double(ts.total)))
        }
        guard phase.isActive else {
            return phase == .completed ? 1.0 : 0.0
        }
        let elapsed = max(0.0, now.timeIntervalSince(turnStartedAt))
        if phase == .streaming {
            return min(0.95, 0.88 + 0.07 * (1.0 - exp(-elapsed / 12.0)))
        }
        if turnToolCount <= 0 {
            return 0.14 + 0.20 * (1.0 - exp(-elapsed / 7.5))
        }
        let stepCurve = 1.0 - exp(-Double(turnToolCount) / 14.0)
        return min(0.85, 0.26 + 0.59 * stepCurve)
    }

    var primaryTitle: String {
        if !conversationTitle.isEmpty {
            return conversationTitle
        }
        if !promptTitle.isEmpty {
            return String(promptTitle.prefix(24))
        }
        if !workspaceName.isEmpty {
            return workspaceName
        }
        return "会话 \(shortId)"
    }

    var displayTitle: String {
        primaryTitle
    }

    /// Top-right badge: live ticking elapsed timer while active; relative "刚刚 / Xm 前" once finished.
    func primaryTimeBadge(now: Date) -> String {
        if phase.isActive {
            let secs = max(0, Int(now.timeIntervalSince(turnStartedAt)))
            return Self.formatElapsed(secs)
        }
        let ref = completedAt ?? updatedAt
        let ago = max(0, Int(now.timeIntervalSince(ref)))
        if ago < 15 { return "刚刚" }
        if ago < 60 { return "\(ago)s 前" }
        let mins = ago / 60
        if mins < 60 { return "\(mins)m 前" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h 前" }
        return "\(hrs / 24)d 前"
    }

    /// Turn elapsed duration for secondary metadata on finished turns.
    var finishedTurnDurationText: String? {
        guard !phase.isActive, let comp = completedAt, comp >= turnStartedAt else { return nil }
        let secs = Int(comp.timeIntervalSince(turnStartedAt))
        guard secs > 0 && secs < 86_400 else { return nil }
        return "用时 \(Self.formatElapsed(secs))"
    }

    static func formatElapsed(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let rem = secs % 60
        if mins < 60 { return String(format: "%d:%02d", mins, rem) }
        let hrs = mins / 60
        return String(format: "%dh%02dm", hrs, mins % 60)
    }
}

enum HudStyleMode: String, CaseIterable, Equatable {
    case classic    // 目前的光学毛玻璃浮窗
    case aurora     // S6 · 流体极光呼吸底 (Living Mesh Aurora)
    case frameless  // S10 · 去外框独立悬浮胶囊堆叠 (Frameless Levitating Stack)

    var displayName: String {
        switch self {
        case .classic: return "经典光学毛玻璃"
        case .aurora: return "S6 流体极光呼吸"
        case .frameless: return "S10 去外框悬浮堆叠"
        }
    }

    var shortLabel: String {
        switch self {
        case .classic: return "经典"
        case .aurora: return "极光"
        case .frameless: return "无框"
        }
    }

    var symbolName: String {
        switch self {
        case .classic: return "square.on.square"
        case .aurora: return "sparkles"
        case .frameless: return "rectangle.stack"
        }
    }

    var nextStyle: HudStyleMode {
        switch self {
        case .classic: return .aurora
        case .aurora: return .frameless
        case .frameless: return .classic
        }
    }
}

enum HudCollapsedStyle: String, CaseIterable, Equatable {
    case e05      // 灵动岛 · 刘海原生融黑 (MacBook Hardware Notch Dynamic Island)
    case island   // 灵动岛 · 悬浮黑曜胶囊 (iPhone Dynamic Island Floating Pill)
    case e01      // E01 · 磁吸双子微舱 (Twin Telemetry Pods)
    case e02      // E02 · 双环复杂功能方表 (Dual-Ring Watch Tile)
    case e03      // E03 · 双腔沙漏结晶塔 (Hourglass Crystal Totem)
    case e04      // E04 · 动静双轨星系球 (Dual-Orbit Galaxy Orb)
    case e06      // E06 · 多槽服务器微刀片 (Micro Blade Rack)
    case e07      // E07 · 双键客制化宏键盘 (2-Key Macro Pad)
    case e08      // E08 · 内扫外锚双区声呐 (Bezel-Arc Sonar Scope)
    case e09      // E09 · S10 无框悬浮星珠簇 (Frameless Bead Cluster)
    case e10      // E10 · 双色天平能量尺 (Segmented Ledger Bar)
    case capsule  // 经典双行宽胶囊 (Classic Wide Capsule)

    var displayName: String {
        switch self {
        case .e05: return "灵动岛 · 刘海原生融黑"
        case .island: return "灵动岛 · 悬浮黑曜胶囊"
        case .e01: return "E01 磁吸双子微舱"
        case .e02: return "E02 双环复杂方表"
        case .e03: return "E03 双腔沙漏晶塔"
        case .e04: return "E04 动静双轨星系"
        case .e06: return "E06 多槽微刀片架"
        case .e07: return "E07 双键客制键盘"
        case .e08: return "E08 内扫外锚声呐"
        case .e09: return "E09 无框悬浮珠簇"
        case .e10: return "E10 双色天平光尺"
        case .capsule: return "经典双行宽胶囊"
        }
    }

    var shortLabel: String {
        switch self {
        case .e05: return "刘海灵动岛"
        case .island: return "悬浮灵动岛"
        case .e01: return "E01 双子"
        case .e02: return "E02 方表"
        case .e03: return "E03 沙漏"
        case .e04: return "E04 星系"
        case .e06: return "E06 刀片"
        case .e07: return "E07 双键"
        case .e08: return "E08 声呐"
        case .e09: return "E09 珠簇"
        case .e10: return "E10 光尺"
        case .capsule: return "宽胶囊"
        }
    }

    var symbolName: String {
        switch self {
        case .e05: return "menubar.dock.rectangle"
        case .island: return "capsule.portrait.bottomhalf.filled"
        case .e01: return "capsule.lefthalf.filled"
        case .e02: return "applewatch.watchface"
        case .e03: return "hourglass"
        case .e04: return "atom"
        case .e06: return "chart.bar.xaxis"
        case .e07: return "keyboard"
        case .e08: return "dot.radiowaves.left.and.right"
        case .e09: return "circles.hexagongrid"
        case .e10: return "slider.horizontal.below.rectangle"
        case .capsule: return "rectangle.roundedtop"
        }
    }

    var nextStyle: HudCollapsedStyle {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .e05 }
        return all[(idx + 1) % all.count]
    }
}

enum HudHoverMorph: String, CaseIterable, Equatable {
    case m1  // M1 · 右上锚点液态撑开 (Corner-Locked Liquid Morph)
    case m2  // M2 · 信标驻留·抽屉浮现 (Beacon Stay + Detached Drawer)
    case m3  // M3 · 90ms防误触·灵动展开 (90ms Intent Guard + Crisp Unfold)
    case m4  // M4 · 光学景深聚焦切换 (Optical Depth Blur Focus)

    var displayName: String {
        switch self {
        case .m1: return "M1 锚点液态撑开"
        case .m2: return "M2 信标驻留·抽屉浮现"
        case .m3: return "M3 90ms防误触·灵动展开"
        case .m4: return "M4 光学景深聚焦"
        }
    }

    var shortLabel: String {
        switch self {
        case .m1: return "M1 液态"
        case .m2: return "M2 驻留"
        case .m3: return "M3 防误触"
        case .m4: return "M4 景深"
        }
    }

    var expandAnimation: Animation {
        switch self {
        case .m1: return .spring(response: 0.44, dampingFraction: 0.85, blendDuration: 0.14)
        case .m2: return .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0.12)
        case .m3: return .spring(response: 0.42, dampingFraction: 0.85, blendDuration: 0.12)
        case .m4: return .spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.10)
        }
    }

    var collapseAnimation: Animation {
        switch self {
        case .m1, .m2, .m3: return .spring(response: 0.36, dampingFraction: 0.89, blendDuration: 0.12)
        case .m4: return .spring(response: 0.33, dampingFraction: 0.91, blendDuration: 0.08)
        }
    }
}

enum HudCanvasMetrics {
    static let width: CGFloat = 500
    static let height: CGFloat = 600
    static let hPad: CGFloat = 24
    static let vPad: CGFloat = 18
}

enum HudTheme: String, CaseIterable, Equatable {
    case smoked    // 3D · 液态烟晶 (VisionOS Luminous Dark)
    case cosmos    // M2 · 深空星云 (Deep Cosmos Indigo Glass)
    case bamboo    // M8 · 岚山竹影 (Kyoto Bamboo Charcoal-Green Glass)
    case sapphire  // T2 · 午夜蓝宝石 (Midnight Sapphire Frosted Glass)
    case pewter    // M10 · 蚀刻雾银 (Etched Pewter Low-Glare Silver Mist)

    var displayName: String {
        switch self {
        case .smoked: return "3D 液态烟晶"
        case .cosmos: return "M2 深空星云"
        case .bamboo: return "M8 岚山竹影"
        case .sapphire: return "T2 午夜蓝宝石"
        case .pewter: return "M10 蚀刻雾银"
        }
    }

    var shortLabel: String {
        switch self {
        case .smoked: return "烟晶"
        case .cosmos: return "星云"
        case .bamboo: return "竹影"
        case .sapphire: return "蓝宝"
        case .pewter: return "雾银"
        }
    }

    var nextTheme: HudTheme {
        switch self {
        case .smoked: return .cosmos
        case .cosmos: return .bamboo
        case .bamboo: return .sapphire
        case .sapphire: return .pewter
        case .pewter: return .smoked
        }
    }

    var isLight: Bool {
        self == .pewter
    }

    var usesBorderlessDividers: Bool {
        false
    }

    var swatchColor: Color {
        switch self {
        case .smoked: return Color(red: 0.38, green: 0.65, blue: 0.98)   // #60A5FA
        case .cosmos: return Color(red: 0.51, green: 0.67, blue: 1.00)   // #82AAFF
        case .bamboo: return Color(red: 0.55, green: 0.90, blue: 0.53)   // #8CE587
        case .sapphire: return Color(red: 0.33, green: 0.78, blue: 1.00) // #54C8FF
        case .pewter: return Color(red: 0.06, green: 0.46, blue: 0.43)   // #0F766E
        }
    }

    var glassGradientColors: [Color] {
        switch self {
        case .smoked:
            return [
                Color(red: 0.26, green: 0.28, blue: 0.33),
                Color(red: 0.17, green: 0.19, blue: 0.23),
            ]
        case .cosmos:
            return [
                Color(red: 0.12, green: 0.14, blue: 0.26),
                Color(red: 0.08, green: 0.10, blue: 0.19),
            ]
        case .bamboo:
            return [
                Color(red: 0.14, green: 0.18, blue: 0.15),
                Color(red: 0.09, green: 0.13, blue: 0.11),
            ]
        case .sapphire:
            return [
                Color(red: 0.15, green: 0.22, blue: 0.36),
                Color(red: 0.10, green: 0.15, blue: 0.27),
            ]
        case .pewter:
            return [
                Color(red: 0.88, green: 0.89, blue: 0.92),
                Color(red: 0.81, green: 0.83, blue: 0.87),
            ]
        }
    }

    var outerBorderColors: [Color] {
        switch self {
        case .smoked:
            return [Color.white.opacity(0.38), Color.white.opacity(0.16)]
        case .cosmos:
            return [Color(red: 0.78, green: 0.82, blue: 1.00).opacity(0.38), Color(red: 0.78, green: 0.82, blue: 1.00).opacity(0.15)]
        case .bamboo:
            return [Color(red: 0.73, green: 0.97, blue: 0.82).opacity(0.34), Color(red: 0.73, green: 0.97, blue: 0.82).opacity(0.14)]
        case .sapphire:
            return [Color(red: 0.65, green: 0.85, blue: 1.00).opacity(0.42), Color(red: 0.65, green: 0.85, blue: 1.00).opacity(0.18)]
        case .pewter:
            return [Color.white.opacity(0.88), Color.white.opacity(0.52)]
        }
    }

    var primaryText: Color {
        switch self {
        case .pewter: return Color(red: 0.07, green: 0.09, blue: 0.15)
        default: return .white
        }
    }

    var secondaryText: Color {
        switch self {
        case .smoked: return Color(red: 0.86, green: 0.89, blue: 0.94)
        case .cosmos: return Color(red: 0.88, green: 0.91, blue: 1.00)
        case .bamboo: return Color(red: 0.86, green: 0.99, blue: 0.91)
        case .sapphire: return Color(red: 0.85, green: 0.93, blue: 1.00)
        case .pewter: return Color(red: 0.22, green: 0.25, blue: 0.32)
        }
    }

    var tertiaryText: Color {
        switch self {
        case .smoked: return Color(red: 0.78, green: 0.83, blue: 0.90).opacity(0.88)
        case .cosmos: return Color(red: 0.65, green: 0.71, blue: 0.99)
        case .bamboo: return Color(red: 0.64, green: 0.81, blue: 0.66)
        case .sapphire: return Color(red: 0.65, green: 0.83, blue: 0.97)
        case .pewter: return Color(red: 0.32, green: 0.37, blue: 0.44)
        }
    }

    var dividerColor: Color {
        isLight ? Color(red: 0.07, green: 0.09, blue: 0.15).opacity(0.10) : Color.white.opacity(0.13)
    }

    var controlBg: Color {
        isLight ? Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.08) : Color.white.opacity(0.11)
    }

    var controlActiveBg: Color {
        isLight ? Color(red: 0.06, green: 0.46, blue: 0.43).opacity(0.16) : Color.white.opacity(0.22)
    }

    var activeCardFill: Color {
        switch self {
        case .smoked: return Color.white.opacity(0.12)
        case .cosmos: return Color(red: 0.78, green: 0.82, blue: 1.00).opacity(0.10)
        case .bamboo: return Color.white.opacity(0.09)
        case .sapphire: return Color(red: 0.58, green: 0.77, blue: 0.99).opacity(0.13)
        case .pewter: return Color.white.opacity(0.58)
        }
    }

    var activeCardHoverFill: Color {
        isLight ? Color.white.opacity(0.76) : Color.white.opacity(0.16)
    }

    var activeCardBorder: Color {
        switch self {
        case .smoked: return Color.white.opacity(0.20)
        case .cosmos: return Color(red: 0.78, green: 0.82, blue: 1.00).opacity(0.20)
        case .bamboo: return Color(red: 0.73, green: 0.97, blue: 0.82).opacity(0.18)
        case .sapphire: return Color(red: 0.73, green: 0.90, blue: 0.99).opacity(0.24)
        case .pewter: return Color.white.opacity(0.82)
        }
    }

    var doneCardFill: Color {
        isLight ? Color.white.opacity(0.36) : Color.white.opacity(0.06)
    }

    var doneCardHoverFill: Color {
        isLight ? Color.white.opacity(0.54) : Color.white.opacity(0.10)
    }

    var waitingCardFill: Color {
        isLight
            ? Color(red: 1.00, green: 0.96, blue: 0.86).opacity(0.88)
            : Color(red: 0.98, green: 0.75, blue: 0.14).opacity(0.18)
    }

    var waitingCardBorder: Color {
        isLight
            ? Color(red: 0.92, green: 0.65, blue: 0.15).opacity(0.65)
            : Color(red: 0.99, green: 0.83, blue: 0.30).opacity(0.46)
    }

    var waitingTitleAccent: Color {
        isLight
            ? Color(red: 0.68, green: 0.32, blue: 0.04)
            : Color(red: 0.99, green: 0.90, blue: 0.54)
    }

    var waitingDetailColor: Color {
        isLight
            ? Color(red: 0.52, green: 0.25, blue: 0.06)
            : Color(red: 0.99, green: 0.95, blue: 0.78)
    }

    var ringTrackColor: Color {
        switch self {
        case .smoked: return Color.white.opacity(0.20)
        case .cosmos: return Color(red: 0.88, green: 0.91, blue: 1.00).opacity(0.20)
        case .bamboo: return Color(red: 0.86, green: 0.99, blue: 0.91).opacity(0.20)
        case .sapphire: return Color(red: 0.73, green: 0.90, blue: 0.99).opacity(0.22)
        case .pewter: return Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.15)
        }
    }

    var doneCheckBg: Color {
        switch self {
        case .smoked, .cosmos: return Color(red: 0.32, green: 0.88, blue: 0.66).opacity(0.24)
        case .bamboo: return Color(red: 0.55, green: 0.90, blue: 0.53).opacity(0.24)
        case .sapphire: return Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.24)
        case .pewter: return Color(red: 0.06, green: 0.46, blue: 0.43).opacity(0.16)
        }
    }

    var doneCheckFg: Color {
        switch self {
        case .smoked, .cosmos: return Color(red: 0.43, green: 0.91, blue: 0.72)
        case .bamboo: return Color(red: 0.53, green: 0.94, blue: 0.67)
        case .sapphire: return Color(red: 0.49, green: 0.83, blue: 0.99)
        case .pewter: return Color(red: 0.06, green: 0.46, blue: 0.43)
        }
    }

    func ringColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .thinking, .runningTool:
            return swatchColor
        case .streaming:
            switch self {
            case .smoked, .cosmos: return Color(red: 0.37, green: 0.92, blue: 0.83)
            case .bamboo: return Color(red: 0.65, green: 0.95, blue: 0.64)
            case .sapphire: return Color(red: 0.49, green: 0.91, blue: 0.99)
            case .pewter: return Color(red: 0.05, green: 0.58, blue: 0.53)
            }
        case .waiting:
            return isLight
                ? Color(red: 0.85, green: 0.47, blue: 0.02)
                : Color(red: 0.99, green: 0.83, blue: 0.30)
        case .completed:
            return doneCheckFg
        case .error:
            return isLight
                ? Color(red: 0.86, green: 0.15, blue: 0.15)
                : Color(red: 0.98, green: 0.44, blue: 0.52)
        case .canceled, .idle:
            return tertiaryText
        }
    }
}

struct HudSettings: Codable, Equatable {
    static let minOpacity: Double = 0.20
    static let maxOpacity: Double = 1.00

    var visible: Bool = true
    var pinnedExpanded: Bool = false
    var soundEnabled: Bool = true
    var autoDimIdle: Bool = true
    var opacity: Double = 0.94
    var positionPreset: String = "top_right"
    var customTopCenterX: Double? = nil
    var customTopY: Double? = nil
    var customBottomY: Double? = nil
    var customVerticalMode: String? = nil
    var customAnchorMode: String? = nil
    var customAnchorX: Double? = nil
    var maxSessionsShown: Int = 5
    var styleMode: String? = nil
    var theme: String? = nil
    var collapsedStyle: String? = nil
    var hoverMorph: String? = nil
    var hoverDelay: Double? = nil
    var clearedCompletedBefore: Double? = nil
    var dismissedSessions: [String: Double]? = nil

    var resolvedStyleMode: HudStyleMode {
        HudStyleMode(rawValue: styleMode ?? "") ?? .classic
    }

    var resolvedTheme: HudTheme {
        if theme == "pine" {
            return .bamboo
        }
        return HudTheme(rawValue: theme ?? "") ?? .cosmos
    }

    var resolvedCollapsedStyle: HudCollapsedStyle {
        HudCollapsedStyle(rawValue: collapsedStyle ?? "") ?? .e05
    }

    var resolvedHoverMorph: HudHoverMorph {
        HudHoverMorph(rawValue: hoverMorph ?? "") ?? .m1
    }

    var resolvedHoverDelay: Double {
        if let raw = hoverDelay {
            return min(1.20, max(0.05, raw))
        }
        return resolvedHoverMorph == .m3 ? 0.28 : 0.18
    }

    var clampedOpacity: Double {
        min(Self.maxOpacity, max(Self.minOpacity, opacity))
    }
}

enum FlashBanner: Equatable {
    case completed(String)
    case waiting(String)
    case error(String)

    var message: String {
        switch self {
        case .completed(let name): return "✓ \(name) 已完成本轮任务"
        case .waiting(let name): return "⏳ \(name) 正在等待你的确认"
        case .error(let name): return "⚠ \(name) 执行遇到异常"
        }
    }

    var color: Color {
        switch self {
        case .completed: return Color(red: 0.32, green: 0.84, blue: 0.54)
        case .waiting: return Color(red: 1.00, green: 0.80, blue: 0.30)
        case .error: return Color(red: 1.00, green: 0.42, blue: 0.45)
        }
    }
}

// MARK: - Lightweight Protobuf Wire Reader (Read-Only)

private enum ProtoValue {
    case varint(UInt64)
    case bytes(Data)
}

private enum ProtoWire {
    static func readVarint(_ data: Data, from offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let count = data.count
        for _ in 0..<10 {
            guard offset < count else { return nil }
            let b = data[offset]
            offset += 1
            if shift == 63 && b > 1 { return nil }
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    static func decode(_ data: Data) -> [Int: [ProtoValue]] {
        var out: [Int: [ProtoValue]] = [:]
        var pos = 0
        let n = data.count
        while pos < n {
            guard let key = readVarint(data, from: &pos) else { break }
            let fieldNum = Int(key >> 3)
            let wireType = Int(key & 0x07)
            if fieldNum <= 0 { break }
            switch wireType {
            case 0:
                guard let v = readVarint(data, from: &pos) else { return out }
                out[fieldNum, default: []].append(.varint(v))
            case 2:
                guard let lenU = readVarint(data, from: &pos) else { return out }
                let len = Int(lenU)
                guard len >= 0 && pos + len <= n else { return out }
                let sub = data.subdata(in: pos..<(pos + len))
                pos += len
                out[fieldNum, default: []].append(.bytes(sub))
            case 1:
                guard pos + 8 <= n else { return out }
                pos += 8
            case 5:
                guard pos + 4 <= n else { return out }
                pos += 4
            default:
                return out
            }
        }
        return out
    }

    static func lastBytes(_ map: [Int: [ProtoValue]], _ field: Int) -> Data? {
        guard let arr = map[field] else { return nil }
        for item in arr.reversed() {
            if case .bytes(let d) = item { return d }
        }
        return nil
    }

    static func allBytes(_ map: [Int: [ProtoValue]], _ field: Int) -> [Data] {
        guard let arr = map[field] else { return [] }
        return arr.compactMap {
            if case .bytes(let d) = $0 { return d }
            return nil
        }
    }

    static func lastString(_ map: [Int: [ProtoValue]], _ field: Int) -> String {
        guard let d = lastBytes(map, field), !d.isEmpty else { return "" }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lastInt(_ map: [Int: [ProtoValue]], _ field: Int) -> Int? {
        guard let arr = map[field] else { return nil }
        for item in arr.reversed() {
            if case .varint(let v) = item { return Int(truncatingIfNeeded: v) }
        }
        return nil
    }

    static func parseTimestamp(_ raw: Data?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let f = decode(raw)
        guard let secs = lastInt(f, 1), secs > 1_600_000_000 && secs < 2_500_000_000 else {
            return nil
        }
        let nanos = max(0, min(999_999_999, lastInt(f, 2) ?? 0))
        return Date(timeIntervalSince1970: Double(secs) + Double(nanos) / 1_000_000_000.0)
    }
}

// MARK: - Cached SQLite Facts

private struct DBCachedRecord {
    var convId: String
    var effectiveMtime: TimeInterval
    var parentConversationId: String
    var rootConversationId: String
    var projectId: String
    var workspaceName: String
    var subagentRole: String
    var modelName: String
    var hasUserStep: Bool
    var lastUserPrompt: String
    var lastUserAt: Date?
    var totalSteps: Int
    var turnToolCount: Int
    var turnToolMix: String

    // Immediate running state if status IN (1, 2, 8, 9)
    var immediateActivePhase: SessionPhase?
    var immediateActiveDetail: String

    // Tail step facts when no step has status IN (1, 2, 8, 9)
    var tailStepType: Int
    var tailStatus: Int
    var tailHasToolCalls: Bool
    var tailFirstToolSummary: String
    var tailCreatedAt: Date?
    var tailCompletedAt: Date?
}

private struct SummaryDBEntry {
    var convId: String
    var title: String
    var status: String
    var notFullyIdle: Bool
    var parentConversationId: String
    var workspaceName: String
    var projectId: String
}

struct NotchScreenMetrics: Equatable {
    var hasHardwareNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var notchCenterX: CGFloat
    var menuBarHeight: CGFloat
    var screenFrame: NSRect
    var visibleFrame: NSRect

    static func current(for preferredScreen: NSScreen? = nil) -> NotchScreenMetrics {
        let notchScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        let screen = preferredScreen ?? notchScreen ?? NSScreen.main ?? NSScreen.screens.first
        let full = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 876)
        let safeTop = screen?.safeAreaInsets.top ?? 0

        if safeTop > 0,
           let leftAux = screen?.auxiliaryTopLeftArea,
           let rightAux = screen?.auxiliaryTopRightArea,
           rightAux.minX > leftAux.maxX {
            let nw = rightAux.minX - leftAux.maxX
            let rawCx = (leftAux.maxX + rightAux.minX) / 2.0
            // Snap within 2pt to exact physical display midpoint (eliminates odd-pixel 771/772 split drift)
            let cx = abs(rawCx - full.midX) <= 2.0 ? full.midX : rawCx
            let mh = max(safeTop, full.maxY - vis.maxY)
            return NotchScreenMetrics(
                hasHardwareNotch: true,
                notchWidth: nw,
                notchHeight: safeTop,
                notchCenterX: cx,
                menuBarHeight: mh,
                screenFrame: full,
                visibleFrame: vis
            )
        }

        return NotchScreenMetrics(
            hasHardwareNotch: safeTop > 0,
            notchWidth: safeTop > 0 ? 186 : 0,
            notchHeight: safeTop > 0 ? safeTop : 0,
            notchCenterX: full.midX,
            menuBarHeight: max(24, full.maxY - vis.maxY),
            screenFrame: full,
            visibleFrame: vis
        )
    }
}

private struct CachedTaskMeta {
    var mtime: Date
    var stats: TaskChecklistStats?
}

// MARK: - View Model & Real-Time SQLite Engine

@MainActor
final class HudViewModel: ObservableObject {
    @Published var sessions: [SessionSnapshot] = []
    @Published var settings: HudSettings = HudSettings()
    @Published var isHovered: Bool = false
    @Published var isHoverArming: Bool = false
    @Published var isCanvasExpanded: Bool = false
    @Published var isContentRevealed: Bool = false
    @Published var isOpacityBarOpen: Bool = false
    @Published var flashBanner: FlashBanner? = nil
    @Published var jumpingSessionId: String? = nil
    @Published var now: Date = Date()
    @Published var pulseTick: Bool = false

    var onLayoutChange: (() -> Void)?
    var onLayoutChangeNow: (() -> Void)?
    var onAlphaChange: (() -> Void)?
    var onStatusChange: (() -> Void)?

    /// Non-published live hit rect inside the fixed 452x560 SwiftUI canvas (avoids @Published view invalidation).
    var activeCanvasRect: CGRect = CGRect(x: 70, y: 0, width: 312, height: 36)

    func recordActiveCanvasRect(_ rect: CGRect) {
        guard rect.width > 8, rect.height > 8, rect.width.isFinite, rect.height.isFinite else { return }
        activeCanvasRect = rect
    }

    let appDataDir: URL
    let summariesDBURL: URL
    let conversationsDir: URL
    let brainDir: URL
    let pluginDataDir: URL
    let settingsURL: URL
    let hudStateURL: URL
    let helperStatusURL: URL
    let navRequestURL: URL
    let siblingStatusURL: URL

    private var summariesCacheMtime: TimeInterval = 0
    private var summariesCache: [String: SummaryDBEntry] = [:]
    private var summariesOrderedIds: [String] = []
    private var dbCache: [String: DBCachedRecord] = [:]
    private var taskCache: [String: CachedTaskMeta] = [:]
    private var previousPhases: [String: SessionPhase] = [:]
    private var hasSeededInitialPhases = false
    private var lastSettingsMtime: Date? = nil
    private var lastChimeAt: Date = .distantPast
    private var flashClearWorkItem: DispatchWorkItem? = nil
    private var hoverEnterWorkItem: DispatchWorkItem? = nil
    private var hoverExitWorkItem: DispatchWorkItem? = nil
    private var contentRevealWorkItem: DispatchWorkItem? = nil
    private var collapseCanvasWorkItem: DispatchWorkItem? = nil
    private var pendingOpacitySaveWorkItem: DispatchWorkItem? = nil
    private var watchSources: [DispatchSourceFileSystemObject] = []

    private let isoFormatterWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let envDir = ProcessInfo.processInfo.environment["AGY_DESKTOP_DATA_DIR"], !envDir.isEmpty {
            base = URL(fileURLWithPath: envDir)
        } else {
            base = home.appendingPathComponent(".gemini/antigravity")
        }
        self.appDataDir = base
        self.summariesDBURL = base.appendingPathComponent("conversation_summaries.db")
        self.conversationsDir = base.appendingPathComponent("conversations")
        self.brainDir = base.appendingPathComponent("brain")
        self.pluginDataDir = base.appendingPathComponent("plugin_data/agy-floating-hud")
        self.settingsURL = pluginDataDir.appendingPathComponent("settings.json")
        self.hudStateURL = pluginDataDir.appendingPathComponent("hud_state.json")
        self.helperStatusURL = pluginDataDir.appendingPathComponent("helper_status.json")
        self.navRequestURL = pluginDataDir.appendingPathComponent("nav_request.json")
        self.siblingStatusURL = base.appendingPathComponent("plugin_data/agy-desktop-status/active_session.json")

        try? FileManager.default.createDirectory(at: pluginDataDir, withIntermediateDirectories: true)
        loadSettingsIfNeeded(force: true)
        refreshAll()
        startWatchers()
    }

    var isExpanded: Bool {
        settings.pinnedExpanded || isHovered
    }

    var effectiveCanvasExpanded: Bool {
        settings.pinnedExpanded || isCanvasExpanded || isHovered
    }

    var isBottomAnchored: Bool {
        let cs = settings.resolvedCollapsedStyle
        if cs == .e05 { return false }
        if settings.positionPreset == "custom" {
            return settings.customVerticalMode == "bottom"
        }
        return settings.positionPreset == "bottom_right" || settings.positionPreset == "bottom_left"
    }

    var resolvedHorizontalZone: String {
        let cs = settings.resolvedCollapsedStyle
        if cs == .e05 {
            return "center"
        }
        if cs == .island && (settings.positionPreset == "top_right" || settings.positionPreset == "top_center") {
            return "center"
        }
        switch settings.positionPreset {
        case "top_center":
            return "center"
        case "bottom_left":
            return "left"
        case "bottom_right", "top_right":
            return "right"
        case "custom":
            return settings.customAnchorMode ?? "right"
        default:
            return "right"
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch resolvedHorizontalZone {
        case "left": return .leading
        case "center": return .center
        default: return .trailing
        }
    }

    var anchorAlignment: Alignment {
        switch (isBottomAnchored, resolvedHorizontalZone) {
        case (false, "left"): return .topLeading
        case (false, "center"): return .top
        case (false, _): return .topTrailing
        case (true, "left"): return .bottomLeading
        case (true, "center"): return .bottom
        case (true, _): return .bottomTrailing
        }
    }

    var anchorUnitPoint: UnitPoint {
        switch (isBottomAnchored, resolvedHorizontalZone) {
        case (false, "left"): return .topLeading
        case (false, "center"): return .top
        case (false, _): return .topTrailing
        case (true, "left"): return .bottomLeading
        case (true, "center"): return .bottom
        case (true, _): return .bottomTrailing
        }
    }

    var primarySession: SessionSnapshot? {
        sessions.first
    }

    var activeCount: Int {
        sessions.filter { $0.phase.isActive }.count
    }

    var waitingCount: Int {
        sessions.filter { $0.phase == .waiting }.count
    }

    var clearableCount: Int {
        sessions.filter { !$0.phase.isActive }.count
    }

    func clearCompletedSessions() {
        let cutoff = Date().timeIntervalSince1970
        let maxSnapUpdated = sessions
            .filter { !$0.phase.isActive }
            .map { $0.updatedAt.timeIntervalSince1970 }
            .max() ?? cutoff
        let effectiveCutoff = max(cutoff, maxSnapUpdated)
        updateSettings {
            $0.clearedCompletedBefore = effectiveCutoff
            $0.dismissedSessions = nil
        }
        refreshAll()
    }

    func dismissSession(_ session: SessionSnapshot) {
        let cutoff = max(Date().timeIntervalSince1970, session.updatedAt.timeIntervalSince1970)
        updateSettings {
            var map = $0.dismissedSessions ?? [:]
            map[session.id] = cutoff
            if map.count > 60 {
                let sorted = map.sorted { $0.value > $1.value }.prefix(40)
                map = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
            }
            $0.dismissedSessions = map
        }
        refreshAll()
    }

    var isAllIdleForLong: Bool {
        guard settings.autoDimIdle, flashBanner == nil, !isExpanded else { return false }
        guard let primary = primarySession else { return true }
        if primary.phase.isActive { return false }
        return now.timeIntervalSince(primary.updatedAt) > 180
    }

    func cancelPendingHoverDwellForDrag() {
        if let pendingEnter = hoverEnterWorkItem {
            pendingEnter.cancel()
            hoverEnterWorkItem = nil
        }
        if let pendingExit = hoverExitWorkItem {
            pendingExit.cancel()
            hoverExitWorkItem = nil
        }
        if !isHovered && isHoverArming {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                isHoverArming = false
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        if hovering {
            if let pendingExit = hoverExitWorkItem {
                pendingExit.cancel()
                hoverExitWorkItem = nil
            }
            collapseCanvasWorkItem?.cancel()

            if settings.pinnedExpanded || isHovered {
                if isHoverArming {
                    isHoverArming = false
                }
                if !isHovered {
                    isHovered = true
                }
                if !isCanvasExpanded {
                    isCanvasExpanded = true
                }
                if !isContentRevealed {
                    isContentRevealed = true
                }
                return
            }

            // Already counting down dwell — let the in-flight peeking spring & timer continue!
            if hoverEnterWorkItem != nil {
                return
            }

            // Stage 1 (0ms): Immediate viscous liquid pull (starts moving smoothly at 120Hz right away)
            let dwell = settings.resolvedHoverDelay
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0.10)) {
                isHoverArming = true
            }

            // Stage 2 (velocity handoff at dwell): Continue seamlessly from in-flight spring into full open!
            let enterItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.hoverEnterWorkItem = nil
                if !self.isCanvasExpanded {
                    self.isCanvasExpanded = true
                }
                self.onAlphaChange?()
                withAnimation(self.settings.resolvedHoverMorph.expandAnimation) {
                    self.isHoverArming = false
                    self.isHovered = true
                    self.isContentRevealed = true
                }
            }
            hoverEnterWorkItem = enterItem
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: enterItem)
        } else {
            if let pendingEnter = hoverEnterWorkItem {
                pendingEnter.cancel()
                hoverEnterWorkItem = nil
            }
            contentRevealWorkItem?.cancel()

            // Cursor brushed past before dwell finished -> glide smoothly back to rest!
            if !isHovered {
                if isHoverArming {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84, blendDuration: 0.08)) {
                        isHoverArming = false
                    }
                }
                return
            }

            // Already counting down exit grace -> don't reset timer repeatedly
            if hoverExitWorkItem != nil {
                return
            }

            let exitItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.hoverExitWorkItem = nil
                if self.settings.pinnedExpanded {
                    if self.isHovered {
                        self.isHovered = false
                    }
                    if !self.isContentRevealed {
                        self.isContentRevealed = true
                    }
                    return
                }
                if self.isHovered {
                    let morph = self.settings.resolvedHoverMorph
                    withAnimation(morph.collapseAnimation) {
                        self.isContentRevealed = false
                        self.isHovered = false
                    }
                    if self.isOpacityBarOpen {
                        self.isOpacityBarOpen = false
                    }
                    self.onAlphaChange?()
                }
            }
            hoverExitWorkItem = exitItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: exitItem)
        }
    }

    func toggleOpacityBar() {
        isOpacityBarOpen.toggle()
        onLayoutChange?()
    }

    func setOpacity(_ rawValue: Double, persistImmediately: Bool) {
        let clamped = (min(HudSettings.maxOpacity, max(HudSettings.minOpacity, rawValue)) * 100.0).rounded() / 100.0
        if abs(settings.opacity - clamped) > 0.0005 {
            settings.opacity = clamped
            onAlphaChange?()
        }
        pendingOpacitySaveWorkItem?.cancel()
        if persistImmediately {
            pendingOpacitySaveWorkItem = nil
            saveSettings()
            writeHelperStatus()
            onStatusChange?()
        } else {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingOpacitySaveWorkItem = nil
                self.saveSettings()
                self.writeHelperStatus()
                self.onStatusChange?()
            }
            pendingOpacitySaveWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }

    func updateSettings(_ mutate: (inout HudSettings) -> Void) {
        var next = settings
        mutate(&next)
        next.opacity = next.clampedOpacity
        settings = next
        if next.pinnedExpanded {
            isCanvasExpanded = true
            isContentRevealed = true
        } else if !isHovered {
            isCanvasExpanded = false
            isContentRevealed = false
        }
        saveSettings()
        writeHelperStatus()
        onLayoutChange?()
        onAlphaChange?()
        onStatusChange?()
    }

    func saveSettings() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let tmpURL = pluginDataDir.appendingPathComponent(".settings_\(ProcessInfo.processInfo.processIdentifier).tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(settingsURL, withItemAt: tmpURL)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: settingsURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                lastSettingsMtime = mtime
            }
        } catch {
            // ignore transient write errors
        }
    }

    func writeHelperStatus() {
        let checkNow = Date()
        let serializedSessions: [[String: Any]] = sessions.map { s in
            var dict: [String: Any] = [
                "id": s.id,
                "shortId": s.shortId,
                "projectId": s.projectId,
                "conversationTitle": s.conversationTitle,
                "workspaceName": s.workspaceName,
                "displayTitle": s.displayTitle,
                "modelShortName": s.modelShortName,
                "promptTitle": s.promptTitle,
                "phase": s.phase.rawValue,
                "stage": s.lifecycleStage,
                "progress": Int(round(s.estimatedProgress(at: checkNow) * 100.0)),
                "turnToolCount": s.turnToolCount,
                "turnToolMix": s.turnToolMix,
                "detailText": s.detailText,
                "stepCount": s.stepCount,
                "timeBadge": s.primaryTimeBadge(now: checkNow),
                "updatedAt": isoFormatterWithFrac.string(from: s.updatedAt),
            ]
            if let ts = s.taskStats {
                dict["taskStats"] = [
                    "done": ts.done,
                    "inProgress": ts.inProgress,
                    "total": ts.total,
                    "percent": ts.percent,
                    "currentItem": ts.currentItem,
                ]
            }
            return dict
        }

        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "running": true,
            "visible": settings.visible,
            "pinnedExpanded": settings.pinnedExpanded,
            "soundEnabled": settings.soundEnabled,
            "autoDimIdle": settings.autoDimIdle,
            "opacity": settings.opacity,
            "positionPreset": settings.positionPreset,
            "styleMode": settings.resolvedStyleMode.rawValue,
            "theme": settings.resolvedTheme.rawValue,
            "collapsedStyle": settings.resolvedCollapsedStyle.rawValue,
            "hoverMorph": settings.resolvedHoverMorph.rawValue,
            "hoverDelay": settings.resolvedHoverDelay,
            "activeCount": activeCount,
            "totalTracked": sessions.count,
            "sessions": serializedSessions,
            "updatedAt": isoFormatterWithFrac.string(from: checkNow),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: helperStatusURL, options: .atomic)
        }
    }

    // MARK: - Click-to-Jump Navigation

    func jumpToSession(_ session: SessionSnapshot) {
        if session.id != "demo-preview-session" {
            let seqMs = Int64(Date().timeIntervalSince1970 * 1000.0)
            let req: [String: Any] = [
                "seq": seqMs,
                "conversationId": session.id,
                "projectId": session.projectId,
                "workspaceName": session.workspaceName,
                "requestedAt": seqMs,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted]) {
                let tmp = pluginDataDir.appendingPathComponent(".nav_\(seqMs).tmp")
                try? data.write(to: tmp)
                if FileManager.default.fileExists(atPath: navRequestURL.path) {
                    _ = try? FileManager.default.replaceItemAt(navRequestURL, withItemAt: tmp)
                } else {
                    try? FileManager.default.moveItem(at: tmp, to: navRequestURL)
                }
            }
        }

        jumpingSessionId = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.jumpingSessionId == session.id {
                self?.jumpingSessionId = nil
            }
        }

        if !settings.pinnedExpanded && isHovered {
            hoverExitWorkItem?.cancel()
            hoverExitWorkItem = nil
            let morph = settings.resolvedHoverMorph
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self = self, !self.settings.pinnedExpanded else { return }
                withAnimation(morph.collapseAnimation) {
                    self.isContentRevealed = false
                    self.isHovered = false
                }
                self.onAlphaChange?()
            }
        }

        activateAntigravity()
    }

    func activateAntigravity() {
        let bundleCandidates = [
            "com.google.antigravity",
            "com.google.antigravity.desktop",
        ]
        for bid in bundleCandidates {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            if let app = apps.first {
                app.unhide()
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("Antigravity")
        }) {
            app.unhide()
            app.activate(options: [.activateAllWindows])
            return
        }
        let appPath = URL(fileURLWithPath: "/Applications/Antigravity.app")
        if FileManager.default.fileExists(atPath: appPath.path) {
            NSWorkspace.shared.openApplication(at: appPath, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Watchers & Polling

    private func watchDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.loadSettingsIfNeeded(force: false)
            self.refreshAll()
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        watchSources.append(src)
    }

    private func startWatchers() {
        watchDirectory(pluginDataDir)
        if FileManager.default.fileExists(atPath: conversationsDir.path) {
            watchDirectory(conversationsDir)
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.now = Date()
                self.pulseTick.toggle()
                self.loadSettingsIfNeeded(force: false)
                self.refreshAll()
                self.onAlphaChange?()
            }
        }

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writeHelperStatus()
            }
        }
    }

    private func loadSettingsIfNeeded(force: Bool) {
        if !force && pendingOpacitySaveWorkItem != nil {
            return
        }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            if force { saveSettings() }
            return
        }
        if !force {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: settingsURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               let prev = lastSettingsMtime,
               mtime <= prev {
                return
            }
        }
        if let data = try? Data(contentsOf: settingsURL),
           var decoded = try? JSONDecoder().decode(HudSettings.self, from: data) {
            decoded.opacity = decoded.clampedOpacity
            if let attrs = try? FileManager.default.attributesOfItem(atPath: settingsURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                lastSettingsMtime = mtime
            }
            if decoded != settings {
                settings = decoded
                if decoded.pinnedExpanded {
                    isCanvasExpanded = true
                    isContentRevealed = true
                } else if !isHovered {
                    isCanvasExpanded = false
                    isContentRevealed = false
                }
                refreshAll()
                onLayoutChange?()
                onAlphaChange?()
                onStatusChange?()
            }
        }
    }

    // MARK: - Real-Time SQLite + Hook Merge

    func refreshAll() {
        let summariesMap = readConversationSummaries()
        let hookMap = readHookSessions()
        let siblingMap = readSiblingSessions()
        let prioritizedIds = Set(hookMap.keys).union(siblingMap.keys).union(summariesOrderedIds.prefix(25))
        let recentDBs = listRecentConversationDBs(limit: 40, mustInclude: prioritizedIds)

        var records: [DBCachedRecord] = []
        for item in recentDBs {
            if let rec = inspectConversationDB(convId: item.id, dbURL: item.url, effectiveMtime: item.mtime) {
                records.append(rec)
            }
        }

        let checkNow = Date()

        // First pass: find active subagents grouped by rootConversationId
        var activeSubagentsByRoot: [String: [(role: String, phase: SessionPhase, detail: String, updatedAt: Date)]] = [:]
        for rec in records where !rec.parentConversationId.isEmpty || !rec.hasUserStep {
            let sumEntry = summariesMap[rec.convId]
            let rootId = nonEmpty(rec.rootConversationId, rec.parentConversationId, sumEntry?.parentConversationId)
            guard !rootId.isEmpty && rootId != rec.convId else { continue }

            let subState = evaluatePhase(
                rec: rec,
                summaryEntry: sumEntry,
                hookEntry: hookMap[rec.convId] ?? siblingMap[rec.convId],
                activeChildren: [],
                now: checkNow
            )
            if subState.phase.isActive {
                let role = rec.subagentRole.isEmpty ? "子代理" : rec.subagentRole
                let up = Date(timeIntervalSince1970: rec.effectiveMtime)
                activeSubagentsByRoot[rootId, default: []].append(
                    (role: role, phase: subState.phase, detail: subState.detail, updatedAt: up)
                )
            }
        }

        // Second pass: build snapshots for root user conversations
        var built: [SessionSnapshot] = []
        for rec in records {
            let sumEntry = summariesMap[rec.convId]
            let isSubagent = !rec.parentConversationId.isEmpty
                || !(sumEntry?.parentConversationId.isEmpty ?? true)
                || !rec.hasUserStep
            if isSubagent {
                continue
            }

            let convId = rec.convId
            let hookEntry = hookMap[convId]
            let siblingEntry = siblingMap[convId]
            let effectiveHook = hookEntry ?? siblingEntry
            let children = activeSubagentsByRoot[convId] ?? []

            let resolved = evaluatePhase(
                rec: rec,
                summaryEntry: sumEntry,
                hookEntry: effectiveHook,
                activeChildren: children,
                now: checkNow
            )

            let convTitle = nonEmpty(
                sumEntry?.title,
                readAnnotationTitle(convId: convId)
            )

            let wsName = nonEmpty(
                rec.workspaceName,
                sumEntry?.workspaceName,
                hookEntry?["workspaceName"] as? String,
                extractWorkspaceName(from: effectiveHook?["workspacePaths"], cwd: effectiveHook?["cwd"] as? String)
            )

            let rawModel = nonEmpty(
                hookEntry?["modelName"] as? String,
                siblingEntry?["modelName"] as? String,
                rec.modelName
            )
            let modelShort = shortenModelName(rawModel)

            let promptTitle = nonEmpty(
                rec.lastUserPrompt,
                hookEntry?["lastUserInput"] as? String
            )

            let dbUpdatedDate = Date(timeIntervalSince1970: rec.effectiveMtime)
            let stepLatestDate = rec.tailCompletedAt ?? rec.tailCreatedAt ?? rec.lastUserAt
            let baseUpdatedDate = resolved.phase.isActive
                ? (maxDate(stepLatestDate, dbUpdatedDate) ?? dbUpdatedDate)
                : (stepLatestDate ?? dbUpdatedDate)
            let childLatestDate = children.map(\.updatedAt).max()
            let updatedAt = maxDate(baseUpdatedDate, childLatestDate) ?? baseUpdatedDate

            // Hide finished sessions that the user explicitly cleared (unless a newer turn happened after clearing)
            if !resolved.phase.isActive {
                let updatedTs = updatedAt.timeIntervalSince1970
                if let clearAllCutoff = settings.clearedCompletedBefore, updatedTs <= clearAllCutoff + 1.5 {
                    continue
                }
                if let singleCutoff = settings.dismissedSessions?[convId], updatedTs <= singleCutoff + 1.5 {
                    continue
                }
            }

            let turnStart = rec.lastUserAt
                ?? parseISO(hookEntry?["turnStartedAt"] as? String)
                ?? rec.tailCreatedAt
                ?? updatedAt

            let completedAt: Date? = resolved.phase.isActive
                ? nil
                : (rec.tailCompletedAt ?? parseISO(hookEntry?["completedAt"] as? String) ?? updatedAt)

            let taskStats = inspectTaskChecklist(convId: convId, hookEntry: hookEntry)

            built.append(
                SessionSnapshot(
                    id: convId,
                    shortId: String(convId.prefix(8)),
                    projectId: nonEmpty(rec.projectId, sumEntry?.projectId),
                    conversationTitle: convTitle,
                    workspaceName: wsName,
                    modelShortName: modelShort,
                    promptTitle: promptTitle,
                    phase: resolved.phase,
                    detailText: resolved.detail,
                    stepCount: rec.totalSteps,
                    turnToolCount: rec.turnToolCount + children.count,
                    turnToolMix: rec.turnToolMix,
                    taskStats: taskStats,
                    turnStartedAt: turnStart,
                    updatedAt: updatedAt,
                    completedAt: completedAt
                )
            )
        }

        built.sort { a, b in
            if a.phase.isActive != b.phase.isActive {
                return a.phase.isActive && !b.phase.isActive
            }
            if a.phase == .waiting && b.phase != .waiting { return true }
            if b.phase == .waiting && a.phase != .waiting { return false }
            return a.updatedAt > b.updatedAt
        }

        let maxCount = max(1, min(8, settings.maxSessionsShown))
        let finalSessions = Array(built.prefix(maxCount))

        applyMergedSessions(finalSessions)
    }

    private func evaluatePhase(
        rec: DBCachedRecord,
        summaryEntry: SummaryDBEntry?,
        hookEntry: [String: Any]?,
        activeChildren: [(role: String, phase: SessionPhase, detail: String, updatedAt: Date)],
        now: Date
    ) -> (phase: SessionPhase, detail: String) {
        // 1. Live active step inside SQLite (`status IN (1, 2, 8, 9)`) always wins immediately
        if let activePhase = rec.immediateActivePhase {
            return (activePhase, rec.immediateActiveDetail)
        }

        // 2. If any child subagent is actively running/waiting on behalf of this conversation
        if !activeChildren.isEmpty {
            if let waitingChild = activeChildren.first(where: { $0.phase == .waiting }) {
                return (.waiting, "子代理待确认: \(waitingChild.role)")
            }
            let first = activeChildren[0]
            if activeChildren.count > 1 {
                return (.runningTool, "\(activeChildren.count) 个子代理运行中 · \(first.role)")
            }
            return (.runningTool, "子代理 (\(first.role)): \(first.detail)")
        }

        // 2b. Authoritative idle signal from Antigravity's conversation_summaries.db
        if let sum = summaryEntry, sum.status == "CASCADE_RUN_STATUS_IDLE", !sum.notFullyIdle {
            let ageSinceWrite = now.timeIntervalSince(Date(timeIntervalSince1970: rec.effectiveMtime))
            if ageSinceWrite > 1.5 {
                if rec.tailStatus == 5 {
                    return (.canceled, "用户已中止执行")
                }
                if rec.tailStepType == 17 || rec.tailStatus == 7 {
                    return (.error, "执行遇到错误")
                }
                if rec.tailStepType == 15 && !rec.tailHasToolCalls {
                    return (.completed, "已完成本轮回复")
                }
                return (.canceled, "已停止执行")
            }
        }

        // 3. Check if lifecycle hook explicitly recorded `Stop` at or after last step
        let hookEvent = (hookEntry?["lastEvent"] as? String) ?? ""
        let hookDate = parseISO(hookEntry?["updatedAt"] as? String)
        let refStepDate = rec.tailCompletedAt ?? rec.tailCreatedAt ?? Date(timeIntervalSince1970: rec.effectiveMtime)

        if hookEvent == "Stop", let hDate = hookDate, hDate.addingTimeInterval(2.0) >= refStepDate {
            let reason = ((hookEntry?["terminationReason"] as? String) ?? "").uppercased()
            if reason == "USER_CANCELED" {
                return (.canceled, "用户已中止执行")
            }
            if reason == "ERROR" || reason == "MAX_INVOCATIONS" || reason == "MAX_TOKEN_BUDGET_EXCEEDED" {
                return (.error, "异常中止 (\(reason))")
            }
            return (.completed, "已完成本轮回复")
        }

        let age = max(0, now.timeIntervalSince(maxDate(refStepDate, Date(timeIntervalSince1970: rec.effectiveMtime)) ?? refStepDate))

        // 4. Evaluate SQLite tail step (`tailStatus` is 3/4/5/6/7)
        if rec.tailStatus == 5 {
            return (.canceled, "用户已中止执行")
        }
        if rec.tailStepType == 17 || (rec.tailStepType == 15 && rec.tailStatus == 7) {
            return (.error, "执行遇到错误")
        }

        switch rec.tailStepType {
        case 15: // PLANNER_RESPONSE (status == 3 DONE)
            if rec.tailHasToolCalls {
                if age < 30.0 {
                    let label = rec.tailFirstToolSummary.isEmpty ? "准备执行工具…" : "准备执行: \(rec.tailFirstToolSummary)"
                    return (.runningTool, label)
                }
                return (.canceled, "已停止执行")
            } else {
                // Planner finished with ZERO tool calls -> Turn is 100% COMPLETED!
                return (.completed, "已完成本轮回复")
            }

        case 132: // GENERIC tool execution
            if rec.tailStatus == 6 && age < 180.0 {
                let label = rec.tailFirstToolSummary.isEmpty ? "后台任务运行中…" : "后台任务: \(rec.tailFirstToolSummary)"
                return (.runningTool, label)
            }
            // While waiting for next model invocation TTFT / extended thinking (can take 10-120s on large contexts;
            // explicit user cancel is caught immediately in <0.1s via Stop hook above).
            if age < 180.0 {
                let msg = rec.tailFirstToolSummary.isEmpty
                    ? "模型正在推理下一步…"
                    : "推理中 · \(rec.tailFirstToolSummary)"
                return (.thinking, msg)
            }
            if rec.tailStatus == 7 {
                return (.error, "工具报错后已停止")
            }
            return (.canceled, "已停止执行")

        case 14, 101: // USER_INPUT or SYSTEM_MESSAGE waiting for first token
            if age < 180.0 {
                let msg = (rec.tailStepType == 101 && rec.turnToolCount > 0)
                    ? "收到任务回执 · 模型推理中…"
                    : "收到指令 · 模型正在思考中…"
                return (.thinking, msg)
            }
            return (.canceled, "已停止执行")

        default:
            return (.completed, "已完成本轮回复")
        }
    }

    private func applyMergedSessions(_ nextSessions: [SessionSnapshot]) {
        if hasSeededInitialPhases {
            for snap in nextSessions {
                if let prev = previousPhases[snap.id], prev != snap.phase {
                    handlePhaseTransition(session: snap, from: prev, to: snap.phase)
                }
                previousPhases[snap.id] = snap.phase
            }
        } else {
            for snap in nextSessions {
                previousPhases[snap.id] = snap.phase
            }
            hasSeededInitialPhases = true
        }

        let countChanged = sessions.count != nextSessions.count
        if sessions != nextSessions {
            sessions = nextSessions
            writeHelperStatus()
            onStatusChange?()
            if countChanged {
                onLayoutChange?()
            }
        }
    }

    private func handlePhaseTransition(session: SessionSnapshot, from oldPhase: SessionPhase, to newPhase: SessionPhase) {
        guard oldPhase.isActive else { return }

        var banner: FlashBanner? = nil
        var soundName: String? = nil

        switch newPhase {
        case .completed:
            banner = .completed(session.displayTitle)
            soundName = "Glass"
        case .waiting:
            if oldPhase != .waiting {
                banner = .waiting(session.displayTitle)
                soundName = "Tink"
            }
        case .error:
            banner = .error(session.displayTitle)
            soundName = "Basso"
        default:
            break
        }

        if let banner = banner {
            flashBanner = banner
            onLayoutChange?()
            flashClearWorkItem?.cancel()
            let clearItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.flashBanner = nil
                self.onLayoutChange?()
            }
            flashClearWorkItem = clearItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.8, execute: clearItem)
        }

        if settings.soundEnabled, let sName = soundName {
            let t = Date()
            if t.timeIntervalSince(lastChimeAt) > 2.0 {
                lastChimeAt = t
                NSSound(named: NSSound.Name(sName))?.play()
            }
        }
    }

    // MARK: - Read-Only SQLite Inspector

    private func listRecentConversationDBs(limit: Int, mustInclude: Set<String>) -> [(id: String, url: URL, mtime: TimeInterval)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var list: [(id: String, url: URL, mtime: TimeInterval)] = []
        var byId: [String: (id: String, url: URL, mtime: TimeInterval)] = [:]
        for url in entries where url.pathExtension == "db" {
            let cid = url.deletingPathExtension().lastPathComponent
            guard cid.count >= 32 else { continue }
            var mt: TimeInterval = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let d = attrs[.modificationDate] as? Date {
                mt = d.timeIntervalSince1970
            }
            let walPath = url.path + "-wal"
            if let walAttrs = try? FileManager.default.attributesOfItem(atPath: walPath),
               let wd = walAttrs[.modificationDate] as? Date {
                mt = max(mt, wd.timeIntervalSince1970)
            }
            if mt > 0 {
                let item = (cid, url, mt)
                list.append(item)
                byId[cid] = item
            }
        }
        list.sort { $0.mtime > $1.mtime }
        var selected = Array(list.prefix(limit))
        let selectedIds = Set(selected.map(\.id))
        for cid in mustInclude where !selectedIds.contains(cid) {
            if let item = byId[cid] {
                selected.append(item)
            }
        }
        return selected
    }

    private func openSQLiteReadOnly(dbURL: URL) -> OpaquePointer? {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        for suffix in ["mode=ro", "mode=ro&immutable=1"] {
            var db: OpaquePointer? = nil
            let uri = "file:\(dbURL.path)?\(suffix)"
            if sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let conn = db {
                sqlite3_busy_timeout(conn, 200)
                sqlite3_exec(conn, "PRAGMA query_only = ON;", nil, nil, nil)
                var testStmt: OpaquePointer? = nil
                let ok = sqlite3_prepare_v2(conn, "SELECT 1 FROM sqlite_master LIMIT 1;", -1, &testStmt, nil) == SQLITE_OK
                    && sqlite3_step(testStmt) == SQLITE_ROW
                if let ts = testStmt { sqlite3_finalize(ts) }
                if ok {
                    return conn
                }
                sqlite3_close(conn)
            } else if let db = db {
                sqlite3_close(db)
            }
        }
        return nil
    }

    private func inspectConversationDB(convId: String, dbURL: URL, effectiveMtime: TimeInterval) -> DBCachedRecord? {
        if let cached = dbCache[convId], cached.effectiveMtime == effectiveMtime {
            return cached
        }

        guard let conn = openSQLiteReadOnly(dbURL: dbURL) else {
            return dbCache[convId]
        }
        defer { sqlite3_close(conn) }

        // 1. trajectory_metadata_blob
        var parentId = ""
        var rootId = convId
        var projectId = ""
        var workspaceName = ""
        var subagentRole = ""

        if let blob = querySingleBlob(conn, sql: "SELECT data FROM trajectory_metadata_blob LIMIT 1") {
            let f = ProtoWire.decode(blob)
            parentId = ProtoWire.lastString(f, 5)
            let r = ProtoWire.lastString(f, 6)
            if !r.isEmpty { rootId = r }
            projectId = ProtoWire.lastString(f, 18)
            if projectId.isEmpty { projectId = ProtoWire.lastString(f, 3) }

            let wsUri = ProtoWire.lastString(f, 7)
            if !wsUri.isEmpty {
                let cleaned = wsUri.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? wsUri
                workspaceName = URL(fileURLWithPath: cleaned).lastPathComponent
            }
            if let subInfo = ProtoWire.lastBytes(f, 8) {
                let sf = ProtoWire.decode(subInfo)
                subagentRole = ProtoWire.lastString(sf, 2)
            }
        }

        // 2. Latest model name from gen_metadata (fallback)
        var modelName = ""
        if let genBlob = querySingleBlob(conn, sql: "SELECT data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT 1") {
            let root = ProtoWire.decode(genBlob)
            if let chatRaw = ProtoWire.lastBytes(root, 1) {
                let chat = ProtoWire.decode(chatRaw)
                modelName = ProtoWire.lastString(chat, 19)
            }
        }

        // 3. Total step count
        var totalSteps = 0
        do {
            var stmt: OpaquePointer? = nil
            if sqlite3_prepare_v2(conn, "SELECT count(*) FROM steps;", -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                if sqlite3_step(s) == SQLITE_ROW {
                    totalSteps = Int(sqlite3_column_int(s, 0))
                }
                sqlite3_finalize(s)
            }
        }

        // 4. Latest USER_INPUT (step_type == 14)
        var hasUserStep = false
        var lastUserIdx = -1
        var lastUserPrompt = ""
        var lastUserAt: Date? = nil
        do {
            var stmt: OpaquePointer? = nil
            let sql = "SELECT idx, metadata, step_payload FROM steps WHERE step_type = 14 ORDER BY idx DESC LIMIT 1;"
            if sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                if sqlite3_step(s) == SQLITE_ROW {
                    hasUserStep = true
                    lastUserIdx = Int(sqlite3_column_int(s, 0))
                    if let metaData = columnBlob(s, col: 1) {
                        let mf = ProtoWire.decode(metaData)
                        lastUserAt = ProtoWire.parseTimestamp(ProtoWire.lastBytes(mf, 1))
                    }
                    if let payloadData = columnBlob(s, col: 2) {
                        let pf = ProtoWire.decode(payloadData)
                        if let u19 = ProtoWire.lastBytes(pf, 19) {
                            let uf = ProtoWire.decode(u19)
                            lastUserPrompt = cleanUserPrompt(ProtoWire.lastString(uf, 2))
                        }
                    }
                }
                sqlite3_finalize(s)
            }
        }

        // 5. Tail steps + any active steps (`status IN (1, 2, 8, 9)`) since lastUserIdx
        struct RawStepRow {
            var idx: Int
            var stepType: Int
            var status: Int
            var meta: Data?
            var payload: Data?
            var permLen: Int
        }

        func readRows(sql: String, bindIdx: Int? = nil) -> [RawStepRow] {
            var out: [RawStepRow] = []
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            if let b = bindIdx {
                sqlite3_bind_int(s, 1, Int32(b))
            }
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(
                    RawStepRow(
                        idx: Int(sqlite3_column_int(s, 0)),
                        stepType: Int(sqlite3_column_int(s, 1)),
                        status: Int(sqlite3_column_int(s, 2)),
                        meta: columnBlob(s, col: 3),
                        payload: columnBlob(s, col: 4),
                        permLen: Int(sqlite3_column_int(s, 5))
                    )
                )
            }
            return out
        }

        let tailRows = readRows(
            sql: "SELECT idx, step_type, status, metadata, step_payload, COALESCE(length(permissions), 0) FROM steps ORDER BY idx DESC LIMIT 8;"
        )
        let activeRows = readRows(
            sql: "SELECT idx, step_type, status, metadata, step_payload, COALESCE(length(permissions), 0) FROM steps WHERE idx >= ? AND status IN (1, 2, 8, 9) ORDER BY idx DESC LIMIT 4;",
            bindIdx: max(0, lastUserIdx)
        )

        let highestIdx = tailRows.first?.idx ?? 0

        // Check active rows first (`status IN (1, 2, 8, 9)`)
        var immediatePhase: SessionPhase? = nil
        var immediateDetail = ""

        for row in activeRows {
            if row.stepType == 132 {
                let toolInfo = decodeGenericToolStep(row.payload)
                // Ignore backgrounded IsDaemon dev servers if conversation moved past them
                if toolInfo.isDaemon && row.idx < highestIdx {
                    continue
                }
                if toolInfo.name == "ask_question" || row.permLen > 0 || row.status == 9 {
                    immediatePhase = .waiting
                    immediateDetail = toolInfo.name == "ask_question"
                        ? "等待你回答确认选项…"
                        : "等待批准权限: \(toolInfo.summary)"
                    break
                } else {
                    immediatePhase = .runningTool
                    immediateDetail = row.idx < highestIdx
                        ? "后台执行: \(toolInfo.summary)"
                        : toolInfo.summary
                    break
                }
            } else if row.stepType == 15 {
                let plannerInfo = decodePlannerStep(row.payload)
                if plannerInfo.hasVisibleText && plannerInfo.toolCallCount == 0 {
                    immediatePhase = .streaming
                    immediateDetail = "正在流式输出最终回复…"
                } else {
                    immediatePhase = .thinking
                    immediateDetail = "正在深度思考与规划…"
                }
                break
            }
        }

        // Tally tool calls in the current turn (`idx > lastUserIdx`)
        var turnToolCount = 0
        var categoryCounts: [String: Int] = [:]
        if lastUserIdx >= 0 {
            var stmt: OpaquePointer? = nil
            let tSql = "SELECT step_payload FROM steps WHERE idx > ? AND step_type = 132 ORDER BY idx ASC LIMIT 250;"
            if sqlite3_prepare_v2(conn, tSql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                sqlite3_bind_int(s, 1, Int32(lastUserIdx))
                while sqlite3_step(s) == SQLITE_ROW {
                    let tInfo = decodeGenericToolStep(columnBlob(s, col: 0))
                    turnToolCount += 1
                    let cat: String = {
                        switch tInfo.name {
                        case "write_file", "edit_file": return "编辑"
                        case "run_command": return "终端"
                        case "read_file": return "读取"
                        case "invoke_subagent", "send_message": return "子代理"
                        case "search_web", "call_mcp_tool": return "检索"
                        default: return "工具"
                        }
                    }()
                    categoryCounts[cat, default: 0] += 1
                }
                sqlite3_finalize(s)
            }
        }
        let orderedCats = ["编辑", "终端", "子代理", "读取", "检索", "工具"]
        let rankedCats = orderedCats
            .enumerated()
            .compactMap { (rank, key) -> (key: String, count: Int, rank: Int)? in
                guard let c = categoryCounts[key], c > 0 else { return nil }
                return (key, c, rank)
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.rank < b.rank
            }
        let mixParts = rankedCats.prefix(2).map { "\($0.key) \($0.count)" }
        let turnToolMix = mixParts.joined(separator: " · ")

        // Extract tail[0] facts
        var tailStepType = 0
        var tailStatus = 3
        var tailHasToolCalls = false
        var tailFirstToolSummary = ""
        var tailCreatedAt: Date? = nil
        var tailCompletedAt: Date? = nil

        if let first = tailRows.first {
            tailStepType = first.stepType
            tailStatus = first.status
            if let m = first.meta {
                let mf = ProtoWire.decode(m)
                tailCreatedAt = ProtoWire.parseTimestamp(ProtoWire.lastBytes(mf, 1))
                tailCompletedAt = ProtoWire.parseTimestamp(ProtoWire.lastBytes(mf, 8))
            }
            if first.stepType == 15 {
                let pInfo = decodePlannerStep(first.payload)
                tailHasToolCalls = pInfo.toolCallCount > 0
                tailFirstToolSummary = pInfo.firstToolSummary
            } else if first.stepType == 132 {
                let tInfo = decodeGenericToolStep(first.payload)
                tailFirstToolSummary = tInfo.summary
            }
        }

        let record = DBCachedRecord(
            convId: convId,
            effectiveMtime: effectiveMtime,
            parentConversationId: parentId,
            rootConversationId: rootId,
            projectId: projectId,
            workspaceName: workspaceName,
            subagentRole: subagentRole,
            modelName: modelName,
            hasUserStep: hasUserStep,
            lastUserPrompt: lastUserPrompt,
            lastUserAt: lastUserAt,
            totalSteps: totalSteps,
            turnToolCount: turnToolCount,
            turnToolMix: turnToolMix,
            immediateActivePhase: immediatePhase,
            immediateActiveDetail: immediateDetail,
            tailStepType: tailStepType,
            tailStatus: tailStatus,
            tailHasToolCalls: tailHasToolCalls,
            tailFirstToolSummary: tailFirstToolSummary,
            tailCreatedAt: tailCreatedAt,
            tailCompletedAt: tailCompletedAt
        )
        dbCache[convId] = record
        return record
    }

    private func querySingleBlob(_ conn: OpaquePointer, sql: String) -> Data? {
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return columnBlob(s, col: 0)
    }

    private func columnBlob(_ stmt: OpaquePointer, col: Int32) -> Data? {
        let len = Int(sqlite3_column_bytes(stmt, col))
        guard len > 0, let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: ptr, count: len)
    }

    private func decodePlannerStep(_ payload: Data?) -> (hasVisibleText: Bool, toolCallCount: Int, firstToolSummary: String) {
        guard let payload = payload else { return (false, 0, "") }
        let pf = ProtoWire.decode(payload)
        guard let p20 = ProtoWire.lastBytes(pf, 20) else { return (false, 0, "") }
        let pr = ProtoWire.decode(p20)
        let hasVis = !ProtoWire.lastString(pr, 1).isEmpty
        let calls = ProtoWire.allBytes(pr, 7)
        var firstSummary = ""
        if let firstCall = calls.first {
            let cf = ProtoWire.decode(firstCall)
            let name = ProtoWire.lastString(cf, 2)
            let argsJson = ProtoWire.lastString(cf, 3)
            firstSummary = formatToolDescription(name: name, argsJson: argsJson).summary
        }
        return (hasVis, calls.count, firstSummary)
    }

    private func decodeGenericToolStep(_ payload: Data?) -> (name: String, summary: String, isDaemon: Bool) {
        guard let payload = payload else { return ("", "正在调用工具…", false) }
        let pf = ProtoWire.decode(payload)
        guard let p5 = ProtoWire.lastBytes(pf, 5) else { return ("", "正在调用工具…", false) }
        let m5 = ProtoWire.decode(p5)
        guard let tcRaw = ProtoWire.lastBytes(m5, 4) else { return ("", "正在调用工具…", false) }
        let tc = ProtoWire.decode(tcRaw)
        let name = ProtoWire.lastString(tc, 2)
        let argsJson = ProtoWire.lastString(tc, 3)
        let desc = formatToolDescription(name: name, argsJson: argsJson)
        return (name, desc.summary, desc.isDaemon)
    }

    private func formatToolDescription(name: String, argsJson: String) -> (summary: String, isDaemon: Bool) {
        var args: [String: Any] = [:]
        if !argsJson.isEmpty,
           let d = argsJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            args = obj
        }
        let isDaemon = (args["IsDaemon"] as? Bool) == true
        let summaryField = (args["toolSummary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pathStr = ((args["Path"] ?? args["TargetFile"] ?? args["ScriptPath"]) as? String) ?? ""
        let fileName = pathStr.isEmpty ? "" : URL(fileURLWithPath: pathStr).lastPathComponent

        if name == "ask_question" {
            return ("等待你回答确认选项…", false)
        }
        if !summaryField.isEmpty {
            return (summaryField, isDaemon)
        }
        switch name {
        case "run_command":
            let cmd = ((args["CommandLine"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (cmd.isEmpty ? "执行终端命令" : "终端: \(String(cmd.prefix(40)))", isDaemon)
        case "write_file", "edit_file":
            return (fileName.isEmpty ? "编辑代码文件" : "编辑: \(fileName)", false)
        case "read_file":
            return (fileName.isEmpty ? "读取文件" : "读取: \(fileName)", false)
        case "invoke_subagent":
            let role = ((args["Role"] ?? args["TypeName"]) as? String) ?? ""
            return (role.isEmpty ? "调用子代理" : "子代理: \(role)", false)
        case "search_web":
            let q = (args["query"] as? String) ?? ""
            return (q.isEmpty ? "搜索网页" : "搜索: \(String(q.prefix(34)))", false)
        case "call_mcp_tool":
            let srv = (args["ServerName"] as? String) ?? ""
            let tl = (args["ToolName"] as? String) ?? ""
            return (tl.isEmpty ? "调用 MCP 工具" : "MCP: \(srv.isEmpty ? tl : "\(srv)/\(tl)")", false)
        default:
            return (name.isEmpty ? "调用工具中…" : "调用: \(name)", isDaemon)
        }
    }

    private func cleanUserPrompt(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@[Quote]") {
            text = String(text.dropFirst("@[Quote]".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let startRange = text.range(of: "<USER_REQUEST>", options: .caseInsensitive),
           let endRange = text.range(of: "</USER_REQUEST>", options: .caseInsensitive),
           startRange.upperBound <= endRange.lowerBound {
            text = String(text[startRange.upperBound..<endRange.lowerBound])
        }
        if let metaRange = text.range(of: "<ADDITIONAL_METADATA>", options: .caseInsensitive) {
            text = String(text[..<metaRange.lowerBound])
        }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(120))
    }

    // MARK: - Auxiliary JSON & Checklist Readers

    private func readConversationSummaries() -> [String: SummaryDBEntry] {
        guard FileManager.default.fileExists(atPath: summariesDBURL.path) else {
            return summariesCache
        }
        var mt: TimeInterval = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: summariesDBURL.path),
           let d = attrs[.modificationDate] as? Date {
            mt = d.timeIntervalSince1970
        }
        let walPath = summariesDBURL.path + "-wal"
        if let walAttrs = try? FileManager.default.attributesOfItem(atPath: walPath),
           let wd = walAttrs[.modificationDate] as? Date {
            mt = max(mt, wd.timeIntervalSince1970)
        }
        if mt > 0 && mt == summariesCacheMtime && !summariesCache.isEmpty {
            return summariesCache
        }

        guard let conn = openSQLiteReadOnly(dbURL: summariesDBURL) else {
            return summariesCache
        }
        defer { sqlite3_close(conn) }

        let sql = """
        SELECT conversation_id, title, preview, status, not_fully_idle, parent_conversation_id, workspace_uris, project_id
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        LIMIT 60;
        """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return summariesCache
        }
        defer { sqlite3_finalize(s) }

        var nextMap: [String: SummaryDBEntry] = [:]
        var nextOrder: [String] = []

        func colStr(_ idx: Int32) -> String {
            guard let ptr = sqlite3_column_text(s, idx) else { return "" }
            return String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while sqlite3_step(s) == SQLITE_ROW {
            let cid = colStr(0)
            guard !cid.isEmpty else { continue }
            let rawTitle = colStr(1)
            let rawPreview = colStr(2)
            let status = colStr(3)
            let notIdle = sqlite3_column_int(s, 4) != 0
            let parentId = colStr(5)
            let wsJson = colStr(6)
            let projId = colStr(7)

            var wsName = ""
            if !wsJson.isEmpty,
               let d = wsJson.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [String],
               let first = arr.first, !first.isEmpty {
                let cleaned = first.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? first
                wsName = URL(fileURLWithPath: cleaned).lastPathComponent
            }

            let entry = SummaryDBEntry(
                convId: cid,
                title: rawTitle.isEmpty ? rawPreview : rawTitle,
                status: status,
                notFullyIdle: notIdle,
                parentConversationId: parentId,
                workspaceName: wsName,
                projectId: projId
            )
            nextMap[cid] = entry
            nextOrder.append(cid)
        }

        summariesCacheMtime = mt
        summariesCache = nextMap
        summariesOrderedIds = nextOrder
        return nextMap
    }

    private func readAnnotationTitle(convId: String) -> String {
        let annURL = appDataDir.appendingPathComponent("annotations/\(convId).pbtxt")
        guard let text = try? String(contentsOf: annURL, encoding: .utf8),
              let range = text.range(of: #"title:\s*"((?:\\.|[^"\\])*)""#, options: .regularExpression) else {
            return ""
        }
        let matched = String(text[range])
        guard let firstQuote = matched.firstIndex(of: "\""),
              let lastQuote = matched.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return ""
        }
        let inner = String(matched[matched.index(after: firstQuote)..<lastQuote])
        return inner.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readHookSessions() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: hudStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["sessions"] as? [String: [String: Any]] else {
            return [:]
        }
        return map
    }

    private func readSiblingSessions() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: siblingStatusURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["sessions"] as? [String: [String: Any]] else {
            return [:]
        }
        return map
    }

    private func inspectTaskChecklist(convId: String, hookEntry: [String: Any]?) -> TaskChecklistStats? {
        var candidates: [URL] = []
        if let artDir = hookEntry?["artifactDirectoryPath"] as? String, !artDir.isEmpty {
            candidates.append(URL(fileURLWithPath: artDir).appendingPathComponent("task.md"))
        }
        candidates.append(brainDir.appendingPathComponent(convId).appendingPathComponent("task.md"))

        guard let taskURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let attrs = try? FileManager.default.attributesOfItem(atPath: taskURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }

        if let cached = taskCache[convId], cached.mtime == mtime {
            return cached.stats
        }

        guard let content = try? String(contentsOf: taskURL, encoding: .utf8) else {
            return nil
        }

        var done = 0
        var inProg = 0
        var total = 0
        var currentItem = ""
        var firstPending = ""

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") else {
                continue
            }
            let chars = Array(trimmed)
            guard chars.count >= 5, chars[2] == "[", chars[4] == "]" else { continue }
            let mark = chars[3]
            guard mark == " " || mark == "x" || mark == "X" || mark == "/" else { continue }

            var label = String(chars.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            label = label.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if let commentRange = label.range(of: "<!--") {
                label = String(label[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            total += 1
            if mark == "x" || mark == "X" {
                done += 1
            } else if mark == "/" {
                inProg += 1
                if currentItem.isEmpty && !label.isEmpty {
                    currentItem = String(label.prefix(70))
                }
            } else {
                if firstPending.isEmpty && !label.isEmpty {
                    firstPending = String(label.prefix(70))
                }
            }
        }

        let stats: TaskChecklistStats? = total > 0
            ? TaskChecklistStats(
                done: done,
                inProgress: inProg,
                total: total,
                percent: Int(round((Double(done) / Double(total)) * 100.0)),
                currentItem: currentItem.isEmpty ? firstPending : currentItem
            )
            : nil

        taskCache[convId] = CachedTaskMeta(mtime: mtime, stats: stats)
        return stats
    }

    private func extractWorkspaceName(from pathsAny: Any?, cwd: String?) -> String {
        if let arr = pathsAny as? [String], let first = arr.first, !first.isEmpty {
            return URL(fileURLWithPath: first).lastPathComponent
        }
        if let cwd = cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return ""
    }

    private func shortenModelName(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw
        if let slash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: slash)...])
        }
        if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        return s
    }

    private func nonEmpty(_ candidates: String?...) -> String {
        for c in candidates {
            if let v = c?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return ""
    }

    private func parseISO(_ raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return isoFormatterWithFrac.date(from: raw) ?? isoFormatterPlain.date(from: raw)
    }

    private func maxDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}

// MARK: - SwiftUI Views & Frosted Glass Backdrop

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var alpha: CGFloat = 1.0
    var appearanceName: NSAppearance.Name = .darkAqua

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = alpha
        view.appearance = NSAppearance(named: appearanceName)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.alphaValue = alpha
        nsView.appearance = NSAppearance(named: appearanceName)
    }
}

/// Custom AppKit opacity scrubber (`mouseDownCanMoveWindow == false` + `acceptsFirstMouse == true`)
/// so dragging inside `FloatingHudPanel` smoothly adjusts opacity without moving the floating window.
final class OpacityTrackNSView: NSView {
    var value: Double = 0.94 {
        didSet {
            if abs(oldValue - value) > 0.0005 {
                needsDisplay = true
            }
        }
    }
    var isLightTheme: Bool = false {
        didSet {
            if oldValue != isLightTheme {
                needsDisplay = true
            }
        }
    }
    var onValueChanged: ((Double, Bool) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let insetX: CGFloat = 7.0
        let trackH: CGFloat = 4.5
        let usableW = max(12.0, bounds.width - insetX * 2.0)
        let midY = bounds.midY

        let norm = CGFloat(
            max(0.0, min(1.0, (value - HudSettings.minOpacity) / (HudSettings.maxOpacity - HudSettings.minOpacity)))
        )
        let thumbX = insetX + usableW * norm

        let trackRect = NSRect(x: insetX, y: midY - trackH / 2.0, width: usableW, height: trackH)
        let groovePath = NSBezierPath(roundedRect: trackRect, xRadius: trackH / 2.0, yRadius: trackH / 2.0)
        if isLightTheme {
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.14).setFill()
        } else {
            NSColor(calibratedWhite: 1.0, alpha: 0.18).setFill()
        }
        groovePath.fill()

        let fillW = max(trackH, thumbX - insetX)
        let fillRect = NSRect(x: insetX, y: midY - trackH / 2.0, width: min(usableW, fillW), height: trackH)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2.0, yRadius: trackH / 2.0)
        if isLightTheme {
            NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.92, alpha: 0.92).setFill()
        } else {
            NSColor(calibratedWhite: 0.94, alpha: 0.92).setFill()
        }
        fillPath.fill()

        let thumbR: CGFloat = 5.8
        let thumbRect = NSRect(x: thumbX - thumbR, y: midY - thumbR, width: thumbR * 2.0, height: thumbR * 2.0)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: isLightTheme ? 0.25 : 0.42)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.white.setFill()
        thumbPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let ringPath = NSBezierPath(ovalIn: thumbRect.insetBy(dx: 0.5, dy: 0.5))
        NSColor(calibratedWhite: 0.0, alpha: isLightTheme ? 0.16 : 0.12).setStroke()
        ringPath.lineWidth = 0.8
        ringPath.stroke()
    }

    private func valueForEvent(_ event: NSEvent) -> Double {
        let pt = convert(event.locationInWindow, from: nil)
        let insetX: CGFloat = 7.0
        let usableW = max(12.0, bounds.width - insetX * 2.0)
        let norm = Double(max(0.0, min(1.0, (pt.x - insetX) / usableW)))
        let raw = HudSettings.minOpacity + norm * (HudSettings.maxOpacity - HudSettings.minOpacity)
        return (raw * 100.0).rounded() / 100.0
    }

    override func mouseDown(with event: NSEvent) {
        let v = valueForEvent(event)
        value = v
        onValueChanged?(v, false)
    }

    override func mouseDragged(with event: NSEvent) {
        let v = valueForEvent(event)
        value = v
        onValueChanged?(v, false)
    }

    override func mouseUp(with event: NSEvent) {
        let v = valueForEvent(event)
        value = v
        onValueChanged?(v, true)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : -event.scrollingDeltaY
        guard abs(delta) > 0.05 else { return }
        let step = delta > 0 ? 0.02 : -0.02
        let next = min(HudSettings.maxOpacity, max(HudSettings.minOpacity, value + step))
        let rounded = (next * 100.0).rounded() / 100.0
        value = rounded
        onValueChanged?(rounded, false)
    }
}

struct HudOpacityScrubber: NSViewRepresentable {
    var value: Double
    var isLightTheme: Bool = false
    var onChange: (Double, Bool) -> Void

    func makeNSView(context: Context) -> OpacityTrackNSView {
        let v = OpacityTrackNSView()
        v.value = value
        v.isLightTheme = isLightTheme
        v.onValueChanged = onChange
        return v
    }

    func updateNSView(_ nsView: OpacityTrackNSView, context: Context) {
        nsView.value = value
        nsView.isLightTheme = isLightTheme
        nsView.onValueChanged = onChange
    }
}

/// Soft stationary ambient wash (no distracting vertical line or moving sweep across text).
struct GlassProgressWash: View {
    let session: SessionSnapshot
    let theme: HudTheme

    var body: some View {
        let isWaiting = session.phase == .waiting
        let accent = theme.ringColor(for: session.phase)
        let washAlpha: Double = theme.isLight ? (isWaiting ? 0.12 : 0.09) : (isWaiting ? 0.16 : 0.12)

        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat(min(1.0, max(0.18, session.estimatedProgress(at: timeline.date))))
            let breath = isWaiting ? CGFloat(0.68 + 0.32 * 0.5 * (1.0 + sin(t * 2.4))) : 1.0

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let softEnd = min(1.0, progress + 0.16)

                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: accent.opacity(washAlpha * 0.85), location: 0.0),
                                .init(color: accent.opacity(washAlpha * 0.55), location: progress * 0.78),
                                .init(color: .clear, location: softEnd),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(breath)
                    .frame(width: w, height: h)
            }
            .allowsHitTesting(false)
        }
    }
}

/// S6 · Living Mesh Aurora Backdrop (drifting ocean-cobalt & aurora-emerald blobs behind frosted glass).
struct LivingAuroraMeshView: View {
    let isAnimating: Bool

    var body: some View {
        let oceanBlue = Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6
        let auroraMint = Color(red: 0.06, green: 0.73, blue: 0.51)  // #10B981

        if isAnimating {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let dx1 = CGFloat(sin(t * 0.72)) * 28.0
                let dy1 = CGFloat(cos(t * 0.54)) * 16.0
                let sc1 = 1.0 + 0.12 * CGFloat(sin(t * 0.65))

                let dx2 = CGFloat(cos(t * 0.64)) * -26.0
                let dy2 = CGFloat(sin(t * 0.50)) * -18.0
                let sc2 = 1.0 + 0.12 * CGFloat(cos(t * 0.58))

                GeometryReader { geo in
                    ZStack {
                        Color(red: 0.075, green: 0.086, blue: 0.15) // #131626

                        RadialGradient(
                            colors: [oceanBlue.opacity(0.55), oceanBlue.opacity(0.18), .clear],
                            center: .center,
                            startRadius: 6,
                            endRadius: 125
                        )
                        .frame(width: 240, height: 240)
                        .scaleEffect(sc1)
                        .position(x: 34 + dx1, y: 24 + dy1)

                        RadialGradient(
                            colors: [auroraMint.opacity(0.52), auroraMint.opacity(0.16), .clear],
                            center: .center,
                            startRadius: 6,
                            endRadius: 125
                        )
                        .frame(width: 240, height: 240)
                        .scaleEffect(sc2)
                        .position(x: geo.size.width - 28 + dx2, y: geo.size.height - 20 + dy2)
                    }
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    Color(red: 0.075, green: 0.086, blue: 0.15)
                    RadialGradient(
                        colors: [oceanBlue.opacity(0.36), .clear],
                        center: .topLeading,
                        startRadius: 6,
                        endRadius: 165
                    )
                    RadialGradient(
                        colors: [auroraMint.opacity(0.32), .clear],
                        center: .bottomTrailing,
                        startRadius: 6,
                        endRadius: 165
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
}

/// P4 · Authentic Lifecycle Stage Capsules (思考 -> 执行 -> 输出 -> 完成, or task.md checklist).
struct StageMilestoneCapsules: View {
    let session: SessionSnapshot
    let theme: HudTheme
    var styleMode: HudStyleMode = .classic
    let pulseTick: Bool

    var body: some View {
        let doneColor: Color = styleMode == .aurora
            ? Color(red: 0.43, green: 0.91, blue: 0.72) // S6 Emerald #6EE7B7
            : theme.ringColor(for: session.phase)
        let activeColor: Color = styleMode == .aurora
            ? Color(red: 0.49, green: 0.83, blue: 0.99) // S6 Sky #7DD3FC
            : theme.ringColor(for: session.phase)
        let track: Color = styleMode == .aurora
            ? Color.white.opacity(0.24)
            : theme.ringTrackColor

        if let ts = session.taskStats, ts.total > 0, ts.total <= 8 {
            let activeIdx = min(ts.total - 1, ts.done)
            HStack(spacing: 3) {
                ForEach(0..<ts.total, id: \.self) { idx in
                    if idx < ts.done {
                        Capsule()
                            .fill(doneColor.opacity(0.92))
                            .frame(width: 10, height: 3.5)
                    } else if idx == activeIdx && session.phase.isActive {
                        Capsule()
                            .fill(activeColor.opacity(pulseTick ? 1.0 : 0.56))
                            .frame(width: 18, height: 3.5)
                    } else {
                        Capsule()
                            .fill(track)
                            .frame(width: 5.5, height: 3.5)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.45), value: pulseTick)
        } else {
            let stage = max(1, min(4, session.lifecycleStage))
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { idx in
                    if idx < stage {
                        Capsule()
                            .fill(doneColor.opacity(0.92))
                            .frame(width: 11, height: 3.5)
                    } else if idx == stage && session.phase.isActive {
                        Capsule()
                            .fill(activeColor.opacity(pulseTick ? 1.0 : 0.56))
                            .frame(width: 20, height: 3.5)
                    } else {
                        Capsule()
                            .fill(track)
                            .frame(width: 6, height: 3.5)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.45), value: pulseTick)
        }
    }
}

/// Custom 4-Point Curved AI Starburst (`M12 2C12.6 7.4 16.6 11.4 22 12C16.6 12.6 12.6 16.6 12 22C11.4 16.6 7.4 12.6 2 12C7.4 11.4 11.4 7.4 12 2Z`).
struct FourPointStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x / 24.0) * w, y: rect.minY + (y / 24.0) * h)
        }
        var p = Path()
        p.move(to: pt(12, 2))
        p.addCurve(to: pt(22, 12), control1: pt(12.6, 7.4), control2: pt(16.6, 11.4))
        p.addCurve(to: pt(12, 22), control1: pt(16.6, 12.6), control2: pt(12.6, 16.6))
        p.addCurve(to: pt(2, 12), control1: pt(11.4, 16.6), control2: pt(7.4, 12.6))
        p.addCurve(to: pt(12, 2), control1: pt(7.4, 11.4), control2: pt(11.4, 7.4))
        p.closeSubpath()
        return p
    }
}

/// Leading AI Starburst Pulse (active) / Checkmark (completed) / Alert (waiting or error).
struct SessionStatusGlyph: View {
    let phase: SessionPhase
    let theme: HudTheme
    var styleMode: HudStyleMode = .classic
    let pulseTick: Bool

    var body: some View {
        let accent: Color = {
            if styleMode == .aurora && phase.isActive && phase != .waiting {
                return phase == .thinking
                    ? Color(red: 0.49, green: 0.83, blue: 0.99) // Sky #7DD3FC
                    : Color(red: 0.43, green: 0.91, blue: 0.72) // Emerald #6EE7B7
            }
            return theme.ringColor(for: phase)
        }()

        if phase == .completed {
            ZStack {
                Circle()
                    .fill(theme.doneCheckBg)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(theme.doneCheckFg)
            }
            .frame(width: 18, height: 18)
        } else if phase == .waiting {
            ZStack {
                Circle()
                    .fill(accent.opacity(theme.isLight ? 0.22 : 0.26))
                Text("!")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(theme.waitingTitleAccent)
            }
            .frame(width: 18, height: 18)
        } else if phase == .error {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.22))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(accent)
            }
            .frame(width: 18, height: 18)
        } else if phase.isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let wave = 0.5 * (1.0 + sin(t * 2.85))
                let op = 0.48 + 0.52 * wave
                let scale = 0.84 + 0.30 * wave
                let deg = 18.0 * wave

                FourPointStarShape()
                    .fill(accent)
                    .frame(width: 15, height: 15)
                    .opacity(op)
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(deg))
                    .shadow(color: accent.opacity(0.38 * wave), radius: 3.5, x: 0, y: 0)
                    .frame(width: 18, height: 18)
            }
        } else {
            FourPointStarShape()
                .fill(theme.tertiaryText.opacity(0.55))
                .frame(width: 11, height: 11)
                .frame(width: 18, height: 18)
        }
    }
}

/// Liquid meniscus shape with G1 concave top bezel shoulders & continuous rounded bottom corners.
struct NotchMeniscusShape: Shape {
    var shoulderRadius: CGFloat = 9
    var bottomRadius: CGFloat = 13

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulderRadius, rect.width * 0.2, rect.height * 0.45)
        let bodyW = max(8, rect.width - 2.0 * s)
        let r = min(bottomRadius, bodyW * 0.5, max(2, rect.height - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right concave meniscus shoulder curving down into right wall
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.minY + s),
            control: CGPoint(x: rect.maxX - s, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r))
        // Bottom-right corner
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - s - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + s + r, y: rect.maxY))
        // Bottom-left corner
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + s, y: rect.maxY - r),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY + s))
        // Left concave meniscus shoulder curving back to top bezel
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + s, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// Open bottom-and-sides rim path for NotchMeniscusShape (leaves top bezel edge 100% seamless).
struct NotchMeniscusRimShape: Shape {
    var shoulderRadius: CGFloat = 9
    var bottomRadius: CGFloat = 13

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulderRadius, rect.width * 0.2, rect.height * 0.45)
        let bodyW = max(8, rect.width - 2.0 * s)
        let r = min(bottomRadius, bodyW * 0.5, max(2, rect.height - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control: CGPoint(x: rect.minX + s, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - s, y: rect.minY)
        )
        return p
    }
}

/// High-density frosted surface for micro-beacons (prevents IDE tab text bleed-through).
struct BeaconSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    var variant: Variant = .primary

    enum Variant {
        case primary
        case emerald
        case amber
    }

    func body(content: Content) -> some View {
        let solidTint = max(0.88, tintAlpha)
        let emeraldColors: [Color] = theme.isLight
            ? [Color(red: 0.86, green: 0.96, blue: 0.92), Color(red: 0.78, green: 0.92, blue: 0.87)]
            : [Color(red: 0.07, green: 0.22, blue: 0.19), Color(red: 0.04, green: 0.14, blue: 0.13)]
        let amberColors: [Color] = theme.isLight
            ? [Color(red: 0.99, green: 0.94, blue: 0.82), Color(red: 0.96, green: 0.88, blue: 0.70)]
            : [Color(red: 0.25, green: 0.17, blue: 0.07), Color(red: 0.16, green: 0.11, blue: 0.05)]

        let fillColors: [Color] = {
            switch variant {
            case .primary: return theme.glassGradientColors
            case .emerald: return emeraldColors
            case .amber: return amberColors
            }
        }()

        let borderColors: [Color] = {
            switch variant {
            case .primary:
                if styleMode == .aurora {
                    return [Color.white.opacity(0.34), Color(red: 0.43, green: 0.91, blue: 0.72).opacity(0.24)]
                }
                return theme.outerBorderColors
            case .emerald:
                return theme.isLight
                    ? [Color(red: 0.06, green: 0.58, blue: 0.45).opacity(0.50), Color(red: 0.06, green: 0.58, blue: 0.45).opacity(0.22)]
                    : [Color(red: 0.25, green: 0.88, blue: 0.64).opacity(0.48), Color(red: 0.25, green: 0.88, blue: 0.64).opacity(0.20)]
            case .amber:
                return [Color(red: 0.99, green: 0.76, blue: 0.20).opacity(0.68), Color(red: 0.99, green: 0.76, blue: 0.20).opacity(0.26)]
            }
        }()

        content
            .background(
                ZStack {
                    VisualEffectBlur(
                        material: .popover,
                        blendingMode: .behindWindow,
                        alpha: CGFloat(max(0.88, blurAlpha)),
                        appearanceName: theme.isLight ? .aqua : .darkAqua
                    )
                    if variant == .primary && styleMode == .aurora {
                        LivingAuroraMeshView(isAnimating: true)
                            .opacity(0.82)
                    } else {
                        LinearGradient(
                            colors: fillColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(solidTint)
                    }
                }
                .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: borderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: variant == .amber ? 1.15 : 1.0
                )
            )
    }
}

/// Breathing 4-point star or waiting `!` mini glyph for compact beacons.
struct BeaconMiniActiveGlyph: View {
    let isActive: Bool
    let isWaiting: Bool
    let theme: HudTheme
    var size: CGFloat = 11.5

    var body: some View {
        if isWaiting {
            Text("!")
                .font(.system(size: size * 0.92, weight: .heavy, design: .rounded))
                .foregroundColor(theme.waitingTitleAccent)
                .frame(width: size, height: size)
        } else if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let wave = 0.5 + 0.5 * sin(t * 2.8)
                FourPointStarShape()
                    .fill(theme.swatchColor)
                    .frame(width: size, height: size)
                    .scaleEffect(0.84 + 0.28 * wave)
                    .rotationEffect(.degrees(18.0 * wave))
                    .opacity(0.62 + 0.38 * wave)
            }
        } else {
            FourPointStarShape()
                .fill(theme.tertiaryText.opacity(0.60))
                .frame(width: size * 0.88, height: size * 0.88)
        }
    }
}

// MARK: - E01 ~ E10 Dual-State (Active × Completed) Micro Beacons

/// E01 · 磁吸双子微舱 (Left Pod: Active + Timer · Right Pod: Completed Emerald Check)
struct BeaconE01TwinPods: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let emeraldFg = theme.isLight ? Color(red: 0.05, green: 0.48, blue: 0.38) : Color(red: 0.43, green: 0.93, blue: 0.72)

        HStack(spacing: 5) {
            if active > 0 || done == 0 {
                HStack(spacing: 5.5) {
                    BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: theme, size: 12)
                    if active > 0 {
                        Text("\(active)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                        if let s = vm.primarySession {
                            Text(s.primaryTimeBadge(now: vm.now))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.secondaryText.opacity(0.85))
                        }
                    } else {
                        Text("待命")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .modifier(BeaconSurfaceModifier(
                    shape: Capsule(),
                    theme: theme,
                    styleMode: styleMode,
                    blurAlpha: blurAlpha,
                    tintAlpha: tintAlpha,
                    variant: waiting ? .amber : .primary
                ))
            }

            if done > 0 {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundColor(emeraldFg)
                    Text("\(done)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(emeraldFg)
                }
                .padding(.horizontal, 9.5)
                .frame(height: 32)
                .modifier(BeaconSurfaceModifier(
                    shape: Capsule(),
                    theme: theme,
                    styleMode: styleMode,
                    blurAlpha: blurAlpha,
                    tintAlpha: tintAlpha,
                    variant: .emerald
                ))
                .scaleEffect(donePopScale)
            }
        }
        .fixedSize()
    }
}

/// E02 · 双环复杂功能方表 (Outer Rotating Active Arc + Inner Emerald Done Ring + ✦/✓ Readout)
struct BeaconE02DualRingWatch: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let total = max(1, active + done)
        let doneRatio = CGFloat(done) / CGFloat(total)
        let activeColor = waiting ? theme.ringColor(for: .waiting) : theme.swatchColor
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.86, blue: 0.62)

        VStack(spacing: 4) {
            ZStack {
                TimelineView(.animation(minimumInterval: active > 0 ? (1.0 / 24.0) : 1.0)) { timeline in
                    let angle = active > 0
                        ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2 * 360.0
                        : 0.0
                    ZStack {
                        Circle()
                            .stroke(theme.primaryText.opacity(0.14), lineWidth: 2.2)
                        if active > 0 {
                            Circle()
                                .trim(from: 0.0, to: 0.42)
                                .stroke(activeColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                                .rotationEffect(.degrees(angle))
                        }
                    }
                }
                .frame(width: 30, height: 30)

                ZStack {
                    Circle()
                        .stroke(emeraldColor.opacity(0.18), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0.0, to: doneRatio)
                        .stroke(emeraldColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 21, height: 21)
                .scaleEffect(donePopScale)

                if active > 0 {
                    Text("\(active)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(emeraldColor)
                }
            }

            HStack(spacing: 4) {
                Text("✦\(active)")
                    .foregroundColor(waiting ? theme.waitingTitleAccent : activeColor)
                Spacer(minLength: 2)
                Text("✓\(done)")
                    .foregroundColor(emeraldColor)
            }
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(width: 58, height: 54)
        .modifier(BeaconSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: 15, style: .continuous),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waiting ? .amber : .primary
        ))
    }
}

/// E03 · 双腔沙漏结晶塔 (Upper Active Droplet Chamber + Lower Emerald Crystal Stack)
struct BeaconE03HourglassTotem: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.88, blue: 0.64)
        let activeColor = waiting ? theme.ringColor(for: .waiting) : theme.swatchColor

        VStack(spacing: 5) {
            VStack(spacing: 1.5) {
                BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: theme, size: 11.5)
                Text("\(active)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(active > 0 ? theme.primaryText : theme.tertiaryText)
            }

            ZStack {
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(width: 16, height: 1)
                if active > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                        let p = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Circle()
                            .fill(activeColor)
                            .frame(width: 4.5, height: 4.5)
                            .offset(y: CGFloat(-5.0 + 10.0 * p))
                            .opacity(sin(p * .pi))
                    }
                }
            }
            .frame(height: 10)

            VStack(spacing: 3) {
                HStack(spacing: 2.5) {
                    ForEach(0..<max(1, min(4, done)), id: \.self) { _ in
                        Circle()
                            .fill(done > 0 ? emeraldColor : theme.primaryText.opacity(0.16))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
                Text("✓\(done)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(emeraldColor)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(emeraldColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(donePopScale)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 7)
        .frame(width: 40)
        .modifier(BeaconSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waiting ? .amber : .primary
        ))
    }
}

/// E04 · 动静双轨星系球 (Inner Orbiting Active Comets + Outer Static Emerald Gem Bezel)
struct BeaconE04GalaxyOrb: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let activeColor = waiting ? theme.ringColor(for: .waiting) : theme.swatchColor
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.88, blue: 0.64)
        let gemCount = min(6, done)

        ZStack {
            // Outer static completed emerald gems along bezel
            ForEach(0..<gemCount, id: \.self) { idx in
                let deg = -62.0 + Double(idx) * 25.0
                Circle()
                    .fill(emeraldColor)
                    .frame(width: 4.8, height: 4.8)
                    .shadow(color: emeraldColor.opacity(0.75), radius: 3)
                    .offset(y: -21.5)
                    .rotationEffect(.degrees(deg))
            }
            .scaleEffect(donePopScale)

            // Inner orbiting active comets
            if active > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let deg = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.6) / 3.6 * 360.0
                    ZStack {
                        Circle()
                            .stroke(activeColor.opacity(0.28), lineWidth: 1.0)
                        Circle()
                            .fill(activeColor)
                            .frame(width: 5.2, height: 5.2)
                            .shadow(color: activeColor.opacity(0.85), radius: 3.5)
                            .offset(y: -16)
                        if active >= 2 {
                            Circle()
                                .fill(activeColor.opacity(0.85))
                                .frame(width: 4.4, height: 4.4)
                                .offset(y: 16)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(deg))
                }
            } else {
                Circle()
                    .stroke(theme.primaryText.opacity(0.12), lineWidth: 1.0)
                    .frame(width: 32, height: 32)
            }

            VStack(spacing: 0.5) {
                Text("\(active)↻")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(active > 0 ? activeColor : theme.tertiaryText)
                Text("\(done)✓")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(emeraldColor)
            }
        }
        .frame(width: 52, height: 52)
        .modifier(BeaconSurfaceModifier(
            shape: Circle(),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waiting ? .amber : .primary
        ))
    }
}

/// 灵动岛 · 刘海原生融黑 (Wraps directly around the MacBook hardware camera notch at y = screen.maxY!)
struct BeaconE05NotchWings: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let donePopScale: CGFloat

    var body: some View {
        let metrics = NotchScreenMetrics.current()
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let shoulder: CGFloat = 9
        let earWidth: CGFloat = 54
        let height: CGFloat = metrics.hasHardwareNotch ? metrics.menuBarHeight : 27
        let arming = vm.isHoverArming
        let rimColor: Color = {
            if arming {
                return Color(red: 0.51, green: 0.69, blue: 1.00).opacity(0.76)
            }
            if waiting {
                return Color(red: 1.00, green: 0.78, blue: 0.22).opacity(0.62)
            }
            return Color.white.opacity(0.16)
        }()

        Group {
            if metrics.hasHardwareNotch {
                // Hardware Notch MacBook: Left Ear + Exact Notch Cutout Bridge + Right Ear
                HStack(spacing: 0) {
                    // Left Ear (Active Sessions)
                    HStack(spacing: 4) {
                        BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: .cosmos, size: 11.5)
                        Text("\(active)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(
                                waiting
                                    ? Color(red: 1.00, green: 0.84, blue: 0.32)
                                    : (active > 0 ? Color(red: 0.76, green: 0.86, blue: 1.00) : Color.white.opacity(0.50))
                            )
                    }
                    .frame(width: earWidth, height: height)

                    // Center hardware camera cutout bridge (pure black behind physical notch)
                    Color.clear
                        .frame(width: metrics.notchWidth, height: height)

                    // Right Ear (Completed Sessions)
                    HStack(spacing: 3.5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(Color(red: 0.28, green: 0.90, blue: 0.64))
                        Text("\(done)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(done > 0 ? Color(red: 0.56, green: 0.96, blue: 0.76) : Color.white.opacity(0.46))
                    }
                    .scaleEffect(donePopScale)
                    .frame(width: earWidth, height: height)
                }
                .padding(.horizontal, shoulder)
                .frame(height: height)
            } else {
                // Non-Notch Display: Flush Menu-Bar Liquid Meniscus Dynamic Chin
                HStack(spacing: 12) {
                    HStack(spacing: 4.5) {
                        BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: .cosmos, size: 11.5)
                        Text("\(active)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(waiting ? Color(red: 1.00, green: 0.84, blue: 0.32) : Color(red: 0.76, green: 0.86, blue: 1.00))
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 1, height: 11)
                    HStack(spacing: 3.5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(Color(red: 0.28, green: 0.90, blue: 0.64))
                        Text("\(done)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(done > 0 ? Color(red: 0.56, green: 0.96, blue: 0.76) : Color.white.opacity(0.46))
                    }
                    .scaleEffect(donePopScale)
                }
                .padding(.horizontal, shoulder + 12)
                .frame(height: height)
            }
        }
        .background(Color.black)
        .clipShape(NotchMeniscusShape(shoulderRadius: shoulder, bottomRadius: 12))
        .overlay(
            NotchMeniscusRimShape(shoulderRadius: shoulder, bottomRadius: 12)
                .stroke(rimColor, lineWidth: arming ? 1.25 : 0.85)
        )
        .shadow(
            color: arming ? Color(red: 0.45, green: 0.64, blue: 1.00).opacity(0.45) : .clear,
            radius: 6,
            x: 0,
            y: 2
        )
        .fixedSize()
    }
}

/// 灵动岛 · 悬浮黑曜胶囊 (iPhone 16 Pro Dynamic Island Floating Pill)
struct BeaconDynamicIslandPill: View {
    @ObservedObject var vm: HudViewModel
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let accentBlue = Color(red: 0.51, green: 0.69, blue: 1.00)
        let emeraldFg = Color(red: 0.36, green: 0.93, blue: 0.69)
        let arming = vm.isHoverArming
        let rimColor: Color = {
            if arming {
                return accentBlue.opacity(0.78)
            }
            if waiting {
                return Color(red: 1.00, green: 0.78, blue: 0.22).opacity(0.68)
            }
            return Color.white.opacity(0.20)
        }()

        HStack(spacing: 10) {
            // Left Island Zone: Star + Live Mini Equalizer Bars + Active Count
            HStack(spacing: 5.5) {
                BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: .cosmos, size: 12)

                if active > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                let h = 4.5 + 7.5 * (0.5 + 0.5 * sin(t * 4.2 + Double(i) * 1.3))
                                Capsule()
                                    .fill(waiting ? Color(red: 1.00, green: 0.82, blue: 0.28) : accentBlue)
                                    .frame(width: 2.2, height: CGFloat(h))
                            }
                        }
                        .frame(height: 13)
                    }
                }

                Text("\(active)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(active > 0 ? .white : Color.white.opacity(0.50))
            }

            // Center Dynamic Island Negative-Space Bridge (or Elapsed Timer)
            if let s = vm.primarySession, active > 0 {
                Text(s.primaryTimeBadge(now: vm.now))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
            } else {
                Spacer(minLength: 10)
                    .frame(width: 12)
            }

            // Right Island Zone: Emerald Completed Badge
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundColor(emeraldFg)
                Text("\(done)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(done > 0 ? emeraldFg : Color.white.opacity(0.45))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(red: 0.08, green: 0.24, blue: 0.20).opacity(done > 0 ? 0.92 : 0.35))
            .clipShape(Capsule())
            .scaleEffect(donePopScale)
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(Color(red: 0.02, green: 0.03, blue: 0.05))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(rimColor, lineWidth: 0.95)
        )
        .fixedSize()
    }
}

/// Hardware-Notch Expanded OLED Dynamic Island Panel (melts downward seamlessly from MacBook camera cutout).
struct NotchExpandedIslandView: View {
    @ObservedObject var vm: HudViewModel

    var body: some View {
        let metrics = NotchScreenMetrics.current()
        let shoulder: CGFloat = 12
        let bodyWidth: CGFloat = 376
        let maxCount = max(1, min(8, vm.settings.maxSessionsShown))
        let visibleSessions = Array(vm.sessions.prefix(maxCount))
        let cStyle = vm.settings.resolvedCollapsedStyle

        VStack(alignment: .leading, spacing: 0) {
            if metrics.hasHardwareNotch {
                let sideWidth = max(68, (bodyWidth - metrics.notchWidth) / 2.0)
                HStack(spacing: 0) {
                    // Left of physical camera notch
                    HStack(spacing: 5) {
                        BeaconMiniActiveGlyph(isActive: vm.activeCount > 0, isWaiting: vm.waitingCount > 0, theme: .cosmos, size: 11)
                        Text(vm.activeCount > 0 ? "\(vm.activeCount) 活跃" : "全部就绪")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.90))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12)
                    .frame(width: sideWidth, height: metrics.menuBarHeight)

                    // Center physical camera housing cutout
                    Color.clear
                        .frame(width: metrics.notchWidth, height: metrics.menuBarHeight)

                    // Right of physical camera notch
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        HudHeaderIconButton(
                            theme: .cosmos,
                            helpText: "切换收起态样式（当前：\(cStyle.displayName)）",
                            action: { vm.updateSettings { $0.collapsedStyle = cStyle.nextStyle.rawValue } }
                        ) {
                            Image(systemName: cStyle.symbolName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }

                        HudHeaderIconButton(
                            theme: .cosmos,
                            isActive: vm.settings.pinnedExpanded,
                            helpText: vm.settings.pinnedExpanded ? "取消固定展开" : "固定展开灵动岛",
                            action: { vm.updateSettings { $0.pinnedExpanded.toggle() } }
                        ) {
                            Image(systemName: vm.settings.pinnedExpanded ? "pin.fill" : "pin")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(vm.settings.pinnedExpanded ? .white : .white.opacity(0.75))
                        }

                        HudHeaderIconButton(
                            theme: .cosmos,
                            helpText: "隐藏桌面浮窗",
                            action: { vm.updateSettings { $0.visible = false } }
                        ) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    .padding(.trailing, 10)
                    .frame(width: sideWidth, height: metrics.menuBarHeight)
                }
                .padding(.bottom, 6)
            } else {
                // Non-Notch Display Top Header
                HStack(spacing: 6) {
                    Text("Antigravity")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)
                    Text(vm.activeCount > 0 ? "\(vm.activeCount) 活跃" : "全部就绪")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.65, green: 0.78, blue: 1.00))
                    Spacer()
                    HStack(spacing: 4) {
                        HudHeaderIconButton(
                            theme: .cosmos,
                            helpText: "切换收起态样式（当前：\(cStyle.displayName)）",
                            action: { vm.updateSettings { $0.collapsedStyle = cStyle.nextStyle.rawValue } }
                        ) {
                            Image(systemName: cStyle.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        HudHeaderIconButton(
                            theme: .cosmos,
                            isActive: vm.settings.pinnedExpanded,
                            helpText: vm.settings.pinnedExpanded ? "取消固定展开" : "固定展开灵动岛",
                            action: { vm.updateSettings { $0.pinnedExpanded.toggle() } }
                        ) {
                            Image(systemName: vm.settings.pinnedExpanded ? "pin.fill" : "pin")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        HudHeaderIconButton(
                            theme: .cosmos,
                            helpText: "隐藏桌面浮窗",
                            action: { vm.updateSettings { $0.visible = false } }
                        ) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            if visibleSessions.isEmpty {
                HStack(spacing: 8) {
                    FourPointStarShape()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 11, height: 11)
                    Text("当前无活跃会话，新任务发起后将实时上岛")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.75))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 6.5) {
                    ForEach(visibleSessions) { session in
                        SessionCardRow(
                            session: session,
                            theme: .cosmos,
                            styleMode: .classic,
                            now: vm.now,
                            pulseTick: vm.pulseTick,
                            isJumping: vm.jumpingSessionId == session.id,
                            onActivate: { vm.jumpToSession(session) },
                            onDismiss: session.phase.isActive ? nil : { vm.dismissSession(session) }
                        )
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, vm.clearableCount > 0 ? 7 : 12)
            }

            if vm.clearableCount > 0 {
                HStack {
                    Spacer()
                    Button(action: { vm.clearCompletedSessions() }) {
                        Text("清理已完成 (\(vm.clearableCount))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.80))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(width: bodyWidth)
        .padding(.horizontal, shoulder)
        .background(Color.black)
        .clipShape(NotchMeniscusShape(shoulderRadius: shoulder, bottomRadius: 22))
        .overlay(
            NotchMeniscusRimShape(shoulderRadius: shoulder, bottomRadius: 22)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.9)
        )
    }
}

/// E06 · 多槽服务器微刀片 (1 Vertical Fiber LED Bar = 1 Real Session)
struct BeaconE06BladeRack: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    private enum SlotKind {
        case waiting, running, done, empty
    }

    var body: some View {
        let active = vm.activeCount
        let waitCnt = vm.waitingCount
        let runCnt = max(0, active - waitCnt)
        let done = vm.clearableCount
        let activeColor = theme.swatchColor
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.88, blue: 0.64)
        let amberColor = theme.ringColor(for: .waiting)

        let slots: [SlotKind] = {
            var arr: [SlotKind] = []
            arr.append(contentsOf: Array(repeating: .waiting, count: waitCnt))
            arr.append(contentsOf: Array(repeating: .running, count: runCnt))
            arr.append(contentsOf: Array(repeating: .done, count: done))
            while arr.count < 5 { arr.append(.empty) }
            return Array(arr.prefix(6))
        }()

        VStack(spacing: 4.5) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, kind in
                    switch kind {
                    case .waiting:
                        Capsule()
                            .fill(amberColor)
                            .frame(width: 5, height: 15)
                            .opacity(vm.pulseTick ? 1.0 : 0.58)
                    case .running:
                        Capsule()
                            .fill(activeColor)
                            .frame(width: 5, height: 14)
                            .opacity(vm.pulseTick ? 1.0 : 0.62)
                    case .done:
                        Capsule()
                            .fill(emeraldColor)
                            .frame(width: 5, height: 10.5)
                    case .empty:
                        Capsule()
                            .fill(theme.primaryText.opacity(0.14))
                            .frame(width: 5, height: 6.5)
                    }
                }
            }
            .frame(height: 15, alignment: .bottom)
            .scaleEffect(donePopScale)

            HStack(spacing: 6) {
                Text("RUN \(active)")
                    .foregroundColor(waitCnt > 0 ? theme.waitingTitleAccent : activeColor)
                Text("OK \(done)")
                    .foregroundColor(emeraldColor)
            }
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .modifier(BeaconSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: 11, style: .continuous),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waitCnt > 0 ? .amber : .primary
        ))
        .fixedSize()
    }
}

/// E07 · 双键客制化宏键盘 (2-Key Tactile Mechanical Macropad: Active Key + Done Key)
struct BeaconE07MacroPad: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let elapsed = vm.primarySession?.primaryTimeBadge(now: vm.now) ?? "IDLE"

        HStack(spacing: 4) {
            // Key 1: Active Blue/Amber Switch
            VStack(spacing: 1.5) {
                HStack(spacing: 2.5) {
                    BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: .cosmos, size: 9.5)
                    Text("\(active)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                }
                Text(active > 0 ? elapsed : "IDLE")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.76, green: 0.84, blue: 1.00).opacity(0.80))
                    .lineLimit(1)
            }
            .frame(width: 37, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(waiting ? Color(red: 0.28, green: 0.18, blue: 0.06) : Color(red: 0.09, green: 0.12, blue: 0.23))
                    .shadow(color: .black.opacity(0.65), radius: 0, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        waiting ? Color(red: 0.99, green: 0.78, blue: 0.24).opacity(0.55) : Color(red: 0.62, green: 0.72, blue: 1.00).opacity(0.38),
                        lineWidth: 0.9
                    )
            )

            // Key 2: Completed Emerald Switch
            VStack(spacing: 1.5) {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.64))
                    Text("\(done)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(red: 0.85, green: 0.99, blue: 0.92))
                }
                Text("DONE")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.45, green: 0.90, blue: 0.70).opacity(0.80))
            }
            .frame(width: 37, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.18, blue: 0.16))
                    .shadow(color: .black.opacity(0.65), radius: 0, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(red: 0.26, green: 0.85, blue: 0.60).opacity(0.45), lineWidth: 0.9)
            )
            .scaleEffect(donePopScale)
        }
        .padding(4.5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.28, green: 0.32, blue: 0.40), Color(red: 0.11, green: 0.13, blue: 0.19)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(red: 0.08, green: 0.10, blue: 0.15), radius: 0, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9)
        )
        .fixedSize()
    }
}

/// E08 · 内扫外锚双区声呐 (Inner Ripple Sonar Blips + Outer Emerald Progress Bezel)
struct BeaconE08SonarScope: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let total = max(1, active + done)
        let doneRatio = CGFloat(done) / CGFloat(total)
        let activeColor = waiting ? theme.ringColor(for: .waiting) : theme.swatchColor
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.88, blue: 0.64)

        ZStack {
            // Outer emerald bezel arc
            Circle()
                .stroke(theme.primaryText.opacity(0.12), lineWidth: 2.4)
                .padding(3)
            Circle()
                .trim(from: 0, to: doneRatio)
                .stroke(emeraldColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .scaleEffect(donePopScale)

            // Inner expanding sonar ripple + target blips
            if active > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    let p = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                    Circle()
                        .stroke(activeColor.opacity(1.0 - p), lineWidth: 1.2)
                        .frame(width: 10 + 30 * p, height: 10 + 30 * p)
                }

                Circle()
                    .fill(activeColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: activeColor, radius: 3)
                    .offset(x: 9, y: -9)

                if active >= 2 {
                    Circle()
                        .fill(activeColor.opacity(0.85))
                        .frame(width: 4.5, height: 4.5)
                        .offset(x: -10, y: -6)
                }
            }

            // Compact dual readout pill
            HStack(spacing: 2) {
                Text("\(active)")
                    .foregroundColor(active > 0 ? activeColor : theme.tertiaryText)
                Text("/")
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
                Text("\(done)✓")
                    .foregroundColor(emeraldColor)
            }
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(theme.isLight ? 0.08 : 0.45))
            .clipShape(Capsule())
            .offset(y: 6)
        }
        .frame(width: 54, height: 54)
        .modifier(BeaconSurfaceModifier(
            shape: Circle(),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waiting ? .amber : .primary
        ))
    }
}

/// E09 · S10 无框悬浮星珠簇 (Levitating Orb + Independent Active & Completed Micro Pills)
struct BeaconE09BeadCluster: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    var body: some View {
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let emeraldFg = theme.isLight ? Color(red: 0.05, green: 0.48, blue: 0.38) : Color(red: 0.43, green: 0.93, blue: 0.72)

        HStack(spacing: 5) {
            ZStack {
                if active > 0 || waiting {
                    BeaconMiniActiveGlyph(isActive: true, isWaiting: waiting, theme: theme, size: 13.5)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(emeraldFg)
                }
            }
            .frame(width: 34, height: 34)
            .modifier(BeaconSurfaceModifier(
                shape: Circle(),
                theme: theme,
                styleMode: styleMode,
                blurAlpha: blurAlpha,
                tintAlpha: tintAlpha,
                variant: waiting ? .amber : .primary
            ))

            VStack(alignment: .leading, spacing: 3) {
                Text("✦ \(active)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(waiting ? theme.waitingTitleAccent : theme.swatchColor)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .modifier(BeaconSurfaceModifier(
                        shape: Capsule(),
                        theme: theme,
                        styleMode: styleMode,
                        blurAlpha: blurAlpha,
                        tintAlpha: tintAlpha,
                        variant: waiting ? .amber : .primary
                    ))

                Text("✓ \(done)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(emeraldFg)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .modifier(BeaconSurfaceModifier(
                        shape: Capsule(),
                        theme: theme,
                        styleMode: styleMode,
                        blurAlpha: blurAlpha,
                        tintAlpha: tintAlpha,
                        variant: .emerald
                    ))
                    .scaleEffect(donePopScale)
            }
        }
        .fixedSize()
    }
}

/// E10 · 双色天平能量尺 (100pt Compact Telemetry Bar + Blue-to-Green Segmented Ledger)
struct BeaconE10LedgerBar: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let donePopScale: CGFloat

    private enum SegKind {
        case waiting, running, done, empty
    }

    var body: some View {
        let active = vm.activeCount
        let waitCnt = vm.waitingCount
        let runCnt = max(0, active - waitCnt)
        let done = vm.clearableCount
        let activeColor = theme.swatchColor
        let emeraldColor = theme.isLight ? Color(red: 0.06, green: 0.54, blue: 0.42) : Color(red: 0.25, green: 0.88, blue: 0.64)
        let amberColor = theme.ringColor(for: .waiting)

        let segs: [SegKind] = {
            var arr: [SegKind] = []
            arr.append(contentsOf: Array(repeating: .waiting, count: waitCnt))
            arr.append(contentsOf: Array(repeating: .running, count: runCnt))
            arr.append(contentsOf: Array(repeating: .done, count: done))
            if arr.isEmpty { arr.append(.empty) }
            return Array(arr.prefix(7))
        }()

        VStack(spacing: 4.5) {
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waitCnt > 0, theme: theme, size: 9.5)
                    Text("\(active) 进行")
                        .foregroundColor(waitCnt > 0 ? theme.waitingTitleAccent : theme.primaryText)
                }
                Spacer(minLength: 4)
                Text("\(done)✓")
                    .foregroundColor(emeraldColor)
                    .scaleEffect(donePopScale)
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))

            HStack(spacing: 3) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .waiting:
                        Capsule()
                            .fill(amberColor)
                            .opacity(vm.pulseTick ? 1.0 : 0.55)
                    case .running:
                        Capsule()
                            .fill(activeColor)
                            .opacity(vm.pulseTick ? 1.0 : 0.60)
                    case .done:
                        Capsule()
                            .fill(emeraldColor)
                    case .empty:
                        Capsule()
                            .fill(theme.primaryText.opacity(0.16))
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 9.5)
        .padding(.vertical, 6.5)
        .frame(width: 104)
        .modifier(BeaconSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: 11, style: .continuous),
            theme: theme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            variant: waitCnt > 0 ? .amber : .primary
        ))
    }
}

/// Unified Collapsed Beacon Dispatcher (E01 ~ E10 + Classic Wide Capsule)
struct CollapsedBeaconDispatcherView: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let styleMode: HudStyleMode
    let blurAlpha: Double
    let tintAlpha: Double
    let needsAttention: Bool
    let attentionColor: Color

    @State private var donePopScale: CGFloat = 1.0

    var body: some View {
        let collapsedStyle = vm.settings.resolvedCollapsedStyle

        Group {
            switch collapsedStyle {
            case .e01:
                BeaconE01TwinPods(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e02:
                BeaconE02DualRingWatch(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e03:
                BeaconE03HourglassTotem(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e04:
                BeaconE04GalaxyOrb(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e05:
                BeaconE05NotchWings(vm: vm, theme: theme, donePopScale: donePopScale)
            case .island:
                BeaconDynamicIslandPill(vm: vm, donePopScale: donePopScale)
            case .e06:
                BeaconE06BladeRack(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e07:
                BeaconE07MacroPad(vm: vm, theme: theme, donePopScale: donePopScale)
            case .e08:
                BeaconE08SonarScope(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e09:
                BeaconE09BeadCluster(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .e10:
                BeaconE10LedgerBar(vm: vm, theme: theme, styleMode: styleMode, blurAlpha: blurAlpha, tintAlpha: tintAlpha, donePopScale: donePopScale)
            case .capsule:
                CollapsedCapsuleView(vm: vm, theme: theme, styleMode: styleMode)
                    .modifier(BeaconSurfaceModifier(
                        shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                        theme: theme,
                        styleMode: styleMode,
                        blurAlpha: blurAlpha,
                        tintAlpha: tintAlpha,
                        variant: needsAttention ? .amber : .primary
                    ))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = vm.primarySession {
                vm.jumpToSession(s)
            } else {
                vm.activateAntigravity()
            }
        }
        .onChange(of: vm.clearableCount) { oldCount, newCount in
            if newCount > oldCount {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.52)) {
                    donePopScale = 1.18
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        donePopScale = 1.0
                    }
                }
            }
        }
    }
}

/// Expanded Container Envelope (dispatches S10 Frameless vs Classic/S6 Aurora).
struct ExpandedEnvelopeView: View {
    @ObservedObject var vm: HudViewModel
    let styleMode: HudStyleMode
    let effectiveTheme: HudTheme
    let normOp: Double
    let blurAlpha: Double
    let tintAlpha: Double
    let needsAttention: Bool
    let attentionColor: Color

    var body: some View {
        let collapsedStyle = vm.settings.resolvedCollapsedStyle

        if collapsedStyle == .e05 {
            NotchExpandedIslandView(vm: vm)
        } else if collapsedStyle == .island {
            // Pure OLED Black Dynamic Island Expanded Card
            ExpandedHudView(vm: vm, theme: .cosmos, styleMode: .classic)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(red: 0.03, green: 0.04, blue: 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            needsAttention
                                ? attentionColor.opacity(0.75)
                                : Color.white.opacity(0.18),
                            lineWidth: 1.0
                        )
                )
        } else if styleMode == .frameless {
            FramelessExpandedHudView(
                vm: vm,
                theme: effectiveTheme,
                blurAlpha: blurAlpha,
                tintAlpha: tintAlpha
            )
        } else {
            let cornerRadius: CGFloat = (styleMode == .aurora) ? 20 : 18

            ExpandedHudView(vm: vm, theme: effectiveTheme, styleMode: styleMode)
                .background(
                    ZStack {
                        VisualEffectBlur(
                            material: .popover,
                            blendingMode: .behindWindow,
                            alpha: CGFloat(blurAlpha),
                            appearanceName: effectiveTheme.isLight ? .aqua : .darkAqua
                        )

                        if styleMode == .aurora {
                            LivingAuroraMeshView(isAnimating: vm.activeCount > 0)
                                .opacity(0.68 + 0.26 * normOp)
                        } else {
                            LinearGradient(
                                colors: effectiveTheme.glassGradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .opacity(tintAlpha)

                            RadialGradient(
                                colors: [
                                    effectiveTheme.swatchColor.opacity(effectiveTheme.isLight ? 0.16 : 0.13),
                                    Color.clear,
                                ],
                                center: .topLeading,
                                startRadius: 6,
                                endRadius: 210
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            needsAttention
                                ? LinearGradient(
                                    colors: [attentionColor.opacity(0.82), attentionColor.opacity(0.28)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: styleMode == .aurora
                                        ? [Color.white.opacity(0.32), Color(red: 0.43, green: 0.91, blue: 0.72).opacity(0.20)]
                                        : effectiveTheme.outerBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: needsAttention ? 1.2 : 1.0
                        )
                )
        }
    }
}

// MARK: - 120Hz ProMotion Liquid Morph Engine (Single-Shell Velocity Handoff)

enum HudLiquidCurves {
    static func clamp01(_ v: CGFloat) -> CGFloat {
        min(1.0, max(0.0, v))
    }
}

private struct HudSizeReader: View {
    let onChange: (CGSize, Bool) -> Void
    @State private var didAppear = false

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    onChange(geo.size, false)
                    didAppear = true
                }
                .onChange(of: geo.size) { _, newSize in
                    onChange(newSize, didAppear)
                }
        }
    }
}

private struct CanvasHitBoxReader: View {
    let vm: HudViewModel
    var enabled: Bool = true

    var body: some View {
        GeometryReader { geo in
            let _: Void = enabled ? vm.recordActiveCanvasRect(geo.frame(in: .named("hudCanvas"))) : ()
            Color.clear
        }
    }
}

/// 120Hz Dual-Axis Harmonic Stage for MacBook Hardware-Notch Dynamic Island (`.e05`).
private struct AnimatableNotchIslandStage<GlyphView: View, ActionButtons: View, Drawer: View>: View, Animatable {
    var widthProgress: CGFloat
    var heightProgress: CGFloat
    let vm: HudViewModel
    let metrics: NotchScreenMetrics
    let activeCount: Int
    let doneCount: Int
    let isWaiting: Bool
    let donePopScale: CGFloat
    let drawerHeight: CGFloat
    let isOpenInteractive: Bool
    let onTapCollapsed: () -> Void
    let glyphView: GlyphView
    let actionButtons: ActionButtons
    let drawer: Drawer

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(widthProgress, heightProgress) }
        set {
            widthProgress = newValue.first
            heightProgress = newValue.second
        }
    }

    var body: some View {
        let wP = max(0, widthProgress)
        let hP = max(0, heightProgress)
        let p01 = HudLiquidCurves.clamp01(max(wP * 0.5, hP))
        let peekGlow = HudLiquidCurves.clamp01(wP / 0.22) * (1.0 - HudLiquidCurves.clamp01((hP - 0.14) / 0.28))
        let headerCross = HudLiquidCurves.clamp01((wP - 0.26) / 0.52)
        let cardAlpha = HudLiquidCurves.clamp01((hP - 0.14) / 0.68)

        // Symmetrical center camera clearance + generous outer framing
        let notchBridgeW: CGFloat = metrics.hasHardwareNotch
            ? ceil((metrics.notchWidth + 8.0) / 2.0) * 2.0
            : 0
        let collapsedEarW: CGFloat = 60
        let collapsedBodyW: CGFloat = metrics.hasHardwareNotch ? (notchBridgeW + collapsedEarW * 2.0) : 164
        let expandedBodyW: CGFloat = 424
        let curBodyW = max(140, collapsedBodyW + (expandedBodyW - collapsedBodyW) * wP)

        let collapsedHeaderH: CGFloat = metrics.hasHardwareNotch ? max(36, metrics.notchHeight + 4.0) : 32
        let expandedHeaderH: CGFloat = metrics.hasHardwareNotch ? max(38, metrics.notchHeight + 6.0) : 40
        let curHeaderH = collapsedHeaderH + (expandedHeaderH - collapsedHeaderH) * min(1.0, hP)
        let safeDrawerH = max(72, drawerHeight)
        let curTotalH = max(collapsedHeaderH, curHeaderH + (safeDrawerH + 6.0) * hP)

        let curShoulder: CGFloat = 10.0 + 4.0 * min(1.1, wP)
        let curBottomRadius: CGFloat = 14.0 + 13.0 * min(1.05, hP)
        let totalOuterW = curBodyW + curShoulder * 2.0

        // Record exact hit-test rect analytically (zero GeometryReader layout pass during 120Hz morph!)
        let _: Void = vm.recordActiveCanvasRect(
            CGRect(
                x: (HudCanvasMetrics.width - totalOuterW) * 0.5,
                y: 0,
                width: totalOuterW,
                height: curTotalH
            )
        )

        let baseRimColor: Color = isWaiting
            ? Color(red: 1.00, green: 0.78, blue: 0.22).opacity(0.66)
            : Color.white.opacity(0.17 + 0.04 * Double(p01))
        let rimColor: Color = peekGlow > 0.05
            ? Color(red: 0.51, green: 0.69, blue: 1.00).opacity(0.32 + 0.46 * Double(peekGlow))
            : baseRimColor

        Color.black
            .frame(width: totalOuterW, height: curTotalH)
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    // Top Meniscus Header Bar (strictly bounded per-ear overlays prevent any overflow/clipping!)
                    if metrics.hasHardwareNotch {
                        let sideWidth = max(collapsedEarW, (curBodyW - notchBridgeW) * 0.5)
                        HStack(spacing: 0) {
                            // Left Wing: strictly `sideWidth` wide
                            Color.clear
                                .frame(width: sideWidth, height: curHeaderH)
                                .overlay(alignment: .leading) {
                                    HStack(spacing: 4.5) {
                                        glyphView
                                        ZStack(alignment: .leading) {
                                            Text("\(activeCount)")
                                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                                .foregroundColor(
                                                    isWaiting
                                                        ? Color(red: 1.00, green: 0.84, blue: 0.32)
                                                        : (activeCount > 0 ? Color(red: 0.78, green: 0.88, blue: 1.00) : Color.white.opacity(0.52))
                                                )
                                                .fixedSize()
                                                .opacity(Double(1.0 - headerCross))
                                                .offset(y: -4.0 * headerCross)

                                            Text(activeCount > 0 ? "\(activeCount) 活跃" : "全部就绪")
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.92))
                                                .fixedSize()
                                                .opacity(Double(headerCross))
                                                .offset(y: 4.0 * (1.0 - headerCross))
                                        }
                                    }
                                    .padding(.leading, 15.0 + 1.0 * headerCross)
                                    .padding(.bottom, 1.5 * (1.0 - headerCross))
                                }

                            // Center Hardware Camera Cutout Bridge
                            Color.clear
                                .frame(width: notchBridgeW, height: curHeaderH)

                            // Right Wing: strictly `sideWidth` wide (overlays never push layout bounds!)
                            Color.clear
                                .frame(width: sideWidth, height: curHeaderH)
                                .overlay(alignment: .trailing) {
                                    HStack(spacing: 3.5) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9.5, weight: .heavy))
                                            .foregroundColor(Color(red: 0.28, green: 0.90, blue: 0.64))
                                        Text("\(doneCount)")
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(doneCount > 0 ? Color(red: 0.56, green: 0.96, blue: 0.76) : Color.white.opacity(0.48))
                                    }
                                    .fixedSize()
                                    .scaleEffect(donePopScale * (1.0 - 0.12 * headerCross), anchor: .trailing)
                                    .opacity(Double(1.0 - headerCross))
                                    .offset(x: 5.0 * headerCross)
                                    .padding(.trailing, 15)
                                    .padding(.bottom, 1.5)
                                    .allowsHitTesting(false)
                                }
                                .overlay(alignment: .trailing) {
                                    actionButtons
                                        .scaleEffect(0.86 + 0.14 * headerCross, anchor: .trailing)
                                        .opacity(Double(headerCross))
                                        .offset(x: 6.0 * (1.0 - headerCross))
                                        .padding(.trailing, 15)
                                        .allowsHitTesting(isOpenInteractive)
                                }
                        }
                        .frame(width: curBodyW, height: curHeaderH)
                    } else {
                        // Non-Notch Display Header
                        Color.clear
                            .frame(width: curBodyW, height: curHeaderH)
                            .overlay {
                                HStack(spacing: 12) {
                                    HStack(spacing: 4.5) {
                                        glyphView
                                        Text("\(activeCount)")
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(isWaiting ? Color(red: 1.00, green: 0.84, blue: 0.32) : Color(red: 0.78, green: 0.88, blue: 1.00))
                                    }
                                    Rectangle()
                                        .fill(Color.white.opacity(0.16))
                                        .frame(width: 1, height: 11)
                                    HStack(spacing: 3.5) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9.5, weight: .heavy))
                                            .foregroundColor(Color(red: 0.28, green: 0.90, blue: 0.64))
                                        Text("\(doneCount)")
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(doneCount > 0 ? Color(red: 0.56, green: 0.96, blue: 0.76) : Color.white.opacity(0.48))
                                    }
                                    .scaleEffect(donePopScale)
                                }
                                .fixedSize()
                                .opacity(Double(1.0 - headerCross))
                                .allowsHitTesting(false)
                            }
                            .overlay {
                                HStack(spacing: 6) {
                                    Text("Antigravity")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(activeCount > 0 ? "\(activeCount) 活跃" : "全部就绪")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Color(red: 0.65, green: 0.78, blue: 1.00))
                                    Spacer()
                                    actionButtons
                                }
                                .padding(.horizontal, 16)
                                .opacity(Double(headerCross))
                                .allowsHitTesting(isOpenInteractive)
                            }
                    }

                    // Drawer placed via true VStack layout (zero residual .offset when hP == 1.0 -> 100% accurate hit-testing!)
                    drawer
                        .scaleEffect(0.92 + 0.08 * min(1.0, wP), anchor: .top)
                        .offset(y: -10.0 * (1.0 - min(1.0, hP)))
                        .opacity(Double(cardAlpha))
                        .allowsHitTesting(isOpenInteractive)
                }
            }
            .overlay {
                if !isOpenInteractive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTapCollapsed)
                }
            }
            .clipShape(NotchMeniscusShape(shoulderRadius: curShoulder, bottomRadius: curBottomRadius))
            .overlay(
                NotchMeniscusRimShape(shoulderRadius: curShoulder, bottomRadius: curBottomRadius)
                    .stroke(rimColor, lineWidth: peekGlow > 0.05 ? 1.20 : 0.95)
            )
            .shadow(
                color: .black.opacity(0.20 + 0.35 * Double(p01)),
                radius: 5.0 + 13.0 * p01,
                x: 0,
                y: 2.5 + 7.5 * p01
            )
    }
}

/// Persistent Single-Shell MacBook Hardware-Notch Dynamic Island View.
struct UnifiedNotchDynamicIslandView: View {
    @ObservedObject var vm: HudViewModel
    @State private var drawerHeight: CGFloat = 180
    @State private var donePopScale: CGFloat = 1.0

    var body: some View {
        let metrics = NotchScreenMetrics.current()
        let open = vm.isExpanded
        let peeking = vm.isHoverArming && !open
        let targetW: CGFloat = open ? 1.0 : (peeking ? 0.22 : 0.0)
        let targetH: CGFloat = open ? 1.0 : (peeking ? 0.032 : 0.0)
        let maxCount = max(1, min(8, vm.settings.maxSessionsShown))
        let visibleSessions = Array(vm.sessions.prefix(maxCount))
        let cStyle = vm.settings.resolvedCollapsedStyle
        let pinnedExpanded = vm.settings.pinnedExpanded

        let glyphView = BeaconMiniActiveGlyph(
            isActive: vm.activeCount > 0,
            isWaiting: vm.waitingCount > 0,
            theme: .cosmos,
            size: 11.5
        )

        let actionButtons = HStack(spacing: 4) {
            HudHeaderIconButton(
                theme: .cosmos,
                helpText: "切换收起态样式（当前：\(cStyle.displayName)）",
                action: { vm.updateSettings { $0.collapsedStyle = cStyle.nextStyle.rawValue } }
            ) {
                Image(systemName: cStyle.symbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }

            HudHeaderIconButton(
                theme: .cosmos,
                isActive: pinnedExpanded,
                helpText: pinnedExpanded ? "取消固定展开" : "固定展开灵动岛",
                action: { vm.updateSettings { $0.pinnedExpanded.toggle() } }
            ) {
                Image(systemName: pinnedExpanded ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(pinnedExpanded ? .white : .white.opacity(0.75))
            }

            HudHeaderIconButton(
                theme: .cosmos,
                helpText: "隐藏桌面浮窗",
                action: { vm.updateSettings { $0.visible = false } }
            ) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .fixedSize()

        // CRITICAL: `.fixedSize(horizontal: true, vertical: true)` ensures drawer ALWAYS lays out at full
        // uncompressed 424pt width & full multi-card height even while collapsed!
        let drawerContent = VStack(alignment: .leading, spacing: 0) {
            if let banner = vm.flashBanner {
                HStack(spacing: 6) {
                    Text(banner.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6.5)
                .background(banner.color.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 15)
                .padding(.bottom, 8)
            }

            if visibleSessions.isEmpty {
                HStack(spacing: 8) {
                    FourPointStarShape()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 11, height: 11)
                    Text("当前无活跃会话，新任务发起后将实时上岛")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.75))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 7) {
                    ForEach(visibleSessions) { session in
                        SessionCardRow(
                            session: session,
                            theme: .cosmos,
                            styleMode: .classic,
                            now: vm.now,
                            pulseTick: vm.pulseTick,
                            isJumping: vm.jumpingSessionId == session.id,
                            onActivate: { vm.jumpToSession(session) },
                            onDismiss: session.phase.isActive ? nil : { vm.dismissSession(session) }
                        )
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, vm.clearableCount > 0 ? 9 : 15)
            }

            if vm.clearableCount > 0 {
                HStack {
                    Spacer()
                    Button(action: { vm.clearCompletedSessions() }) {
                        Text("清理已完成 (\(vm.clearableCount))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 13)
            }
        }
        .frame(width: 424)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            HudSizeReader { size, animated in
                guard size.height > 30 else { return }
                if abs(drawerHeight - size.height) > 0.5 {
                    if animated && open {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            drawerHeight = size.height
                        }
                    } else {
                        drawerHeight = size.height
                    }
                }
            }
        )

        AnimatableNotchIslandStage(
            widthProgress: targetW,
            heightProgress: targetH,
            vm: vm,
            metrics: metrics,
            activeCount: vm.activeCount,
            doneCount: vm.clearableCount,
            isWaiting: vm.waitingCount > 0,
            donePopScale: donePopScale,
            drawerHeight: drawerHeight,
            isOpenInteractive: open,
            onTapCollapsed: {
                if let s = vm.primarySession {
                    vm.jumpToSession(s)
                } else {
                    vm.activateAntigravity()
                }
            },
            glyphView: glyphView,
            actionButtons: actionButtons,
            drawer: drawerContent
        )
        .onChange(of: vm.clearableCount) { oldCount, newCount in
            if newCount > oldCount {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.52)) {
                    donePopScale = 1.18
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        donePopScale = 1.0
                    }
                }
            }
        }
    }
}

/// 120Hz Dual-Axis Stage for Floating Obsidian Pill Dynamic Island (`.island`).
private struct AnimatableFloatingIslandStage<CollapsedContent: View, ExpandedContent: View>: View, Animatable {
    var widthProgress: CGFloat
    var heightProgress: CGFloat
    let vm: HudViewModel
    let pillSize: CGSize
    let expandedSize: CGSize
    let isBottomAnchored: Bool
    let needsAttention: Bool
    let attentionColor: Color
    let isOpenInteractive: Bool
    let onTapCollapsed: () -> Void
    let collapsedContent: CollapsedContent
    let expandedContent: ExpandedContent

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(widthProgress, heightProgress) }
        set {
            widthProgress = newValue.first
            heightProgress = newValue.second
        }
    }

    var body: some View {
        let wP = max(0, widthProgress)
        let hP = max(0, heightProgress)
        let p01 = HudLiquidCurves.clamp01(max(wP * 0.5, hP))
        let peekGlow = HudLiquidCurves.clamp01(wP / 0.22) * (1.0 - HudLiquidCurves.clamp01((hP - 0.14) / 0.28))
        let crossOut = HudLiquidCurves.clamp01((wP - 0.24) / 0.42)
        let crossIn = HudLiquidCurves.clamp01((hP - 0.14) / 0.66)

        let baseW = max(124, pillSize.width)
        let baseH = max(34, pillSize.height)
        let expW = max(336, expandedSize.width)
        let expH = max(96, expandedSize.height)

        let curW = max(124, baseW + (expW - baseW) * wP)
        let curH = max(34, baseH + (expH - baseH) * hP)
        let curRadius: CGFloat = 17.0 + 9.0 * min(1.05, hP)
        let vAlign: Alignment = isBottomAnchored ? .bottom : .top

        let rimColor: Color = {
            if peekGlow > 0.05 {
                return Color(red: 0.51, green: 0.69, blue: 1.00).opacity(0.32 + 0.46 * Double(peekGlow))
            }
            if needsAttention {
                return attentionColor.opacity(0.72)
            }
            return Color.white.opacity(0.19)
        }()

        Color(red: 0.025, green: 0.035, blue: 0.06)
            .frame(width: curW, height: curH)
            .overlay(alignment: vAlign) {
                expandedContent
                    .scaleEffect(0.92 + 0.08 * min(1.02, wP), anchor: isBottomAnchored ? .bottom : .top)
                    .offset(y: (isBottomAnchored ? 10.0 : -10.0) * (1.0 - min(1.0, hP)))
                    .opacity(Double(crossIn))
                    .allowsHitTesting(isOpenInteractive)
            }
            .overlay(alignment: vAlign) {
                collapsedContent
                    .frame(height: baseH)
                    .scaleEffect(1.0 + 0.025 * peekGlow - 0.08 * crossOut)
                    .opacity(Double(1.0 - crossOut))
                    .allowsHitTesting(false)
            }
            .overlay {
                if !isOpenInteractive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTapCollapsed)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: curRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: curRadius, style: .continuous)
                    .strokeBorder(rimColor, lineWidth: peekGlow > 0.05 ? 1.15 : 0.95)
            )
            .shadow(
                color: .black.opacity(0.24 + 0.28 * Double(p01)),
                radius: 6.0 + 11.0 * p01,
                x: 0,
                y: 3.0 + 6.0 * p01
            )
            .background(CanvasHitBoxReader(vm: vm))
    }
}

/// Persistent Single-Shell Floating Pill Dynamic Island View (`.island`).
struct UnifiedFloatingIslandView: View {
    @ObservedObject var vm: HudViewModel
    let needsAttention: Bool
    let attentionColor: Color

    @State private var pillSize: CGSize = CGSize(width: 146, height: 34)
    @State private var expandedSize: CGSize = CGSize(width: 356, height: 220)
    @State private var donePopScale: CGFloat = 1.0

    var body: some View {
        let open = vm.isExpanded
        let peeking = vm.isHoverArming && !open
        let targetW: CGFloat = open ? 1.0 : (peeking ? 0.24 : 0.0)
        let targetH: CGFloat = open ? 1.0 : (peeking ? 0.07 : 0.0)
        let active = vm.activeCount
        let done = vm.clearableCount
        let waiting = vm.waitingCount > 0
        let accentBlue = Color(red: 0.51, green: 0.69, blue: 1.00)
        let emeraldFg = Color(red: 0.36, green: 0.93, blue: 0.69)

        let pillInner = HStack(spacing: 11) {
            HStack(spacing: 5.5) {
                BeaconMiniActiveGlyph(isActive: active > 0, isWaiting: waiting, theme: .cosmos, size: 12)
                if active > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                let h = 4.5 + 7.5 * (0.5 + 0.5 * sin(t * 4.2 + Double(i) * 1.3))
                                Capsule()
                                    .fill(waiting ? Color(red: 1.00, green: 0.82, blue: 0.28) : accentBlue)
                                    .frame(width: 2.2, height: CGFloat(h))
                            }
                        }
                        .frame(height: 13)
                    }
                }
                Text("\(active)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(active > 0 ? .white : Color.white.opacity(0.50))
            }

            if let s = vm.primarySession, active > 0 {
                Text(s.primaryTimeBadge(now: vm.now))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
            } else {
                Spacer(minLength: 12)
                    .frame(width: 14)
            }

            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundColor(emeraldFg)
                Text("\(done)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(done > 0 ? emeraldFg : Color.white.opacity(0.45))
            }
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3.5)
            .background(Color(red: 0.08, green: 0.24, blue: 0.20).opacity(done > 0 ? 0.92 : 0.35))
            .clipShape(Capsule())
            .scaleEffect(donePopScale)
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .frame(height: 34)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            HudSizeReader { size, _ in
                if size.width > 60 && abs(pillSize.width - size.width) > 0.5 {
                    pillSize = size
                }
            }
        )

        let expandedInner = ExpandedHudView(vm: vm, theme: .cosmos, styleMode: .classic, panelWidth: 356)
            .fixedSize(horizontal: true, vertical: true)
            .background(
                HudSizeReader { size, animated in
                    guard size.height > 50 else { return }
                    if abs(expandedSize.width - size.width) > 0.5 || abs(expandedSize.height - size.height) > 0.5 {
                        if animated && open {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                expandedSize = size
                            }
                        } else {
                            expandedSize = size
                        }
                    }
                }
            )

        AnimatableFloatingIslandStage(
            widthProgress: targetW,
            heightProgress: targetH,
            vm: vm,
            pillSize: pillSize,
            expandedSize: expandedSize,
            isBottomAnchored: vm.isBottomAnchored,
            needsAttention: needsAttention,
            attentionColor: attentionColor,
            isOpenInteractive: open,
            onTapCollapsed: {
                if let s = vm.primarySession {
                    vm.jumpToSession(s)
                } else {
                    vm.activateAntigravity()
                }
            },
            collapsedContent: pillInner,
            expandedContent: expandedInner
        )
        .onChange(of: vm.clearableCount) { oldCount, newCount in
            if newCount > oldCount {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.52)) {
                    donePopScale = 1.18
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        donePopScale = 1.0
                    }
                }
            }
        }
    }
}

/// 120Hz Dual-Axis Glass Shell Stage for Corner/Edge Beacons (`e01`~`e10`, `capsule`).
private struct AnimatableCornerGlassStage<BeaconView: View, ExpandedInner: View>: View, Animatable {
    var widthProgress: CGFloat
    var heightProgress: CGFloat
    let vm: HudViewModel
    let beaconSize: CGSize
    let expandedSize: CGSize
    let collapsedRadius: CGFloat
    let expandedRadius: CGFloat
    let styleMode: HudStyleMode
    let effectiveTheme: HudTheme
    let morph: HudHoverMorph
    let normOp: Double
    let blurAlpha: Double
    let tintAlpha: Double
    let needsAttention: Bool
    let attentionColor: Color
    let activeCount: Int
    let anchorAlignment: Alignment
    let unitAnchor: UnitPoint
    let isOpenInteractive: Bool
    let idleAlpha: Double
    let beacon: BeaconView
    let expandedInner: ExpandedInner

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(widthProgress, heightProgress) }
        set {
            widthProgress = newValue.first
            heightProgress = newValue.second
        }
    }

    var body: some View {
        let wP = max(0, widthProgress)
        let hP = max(0, heightProgress)
        let p01 = HudLiquidCurves.clamp01(max(wP * 0.5, hP))
        let peekScale = 1.0 + 0.050 * HudLiquidCurves.clamp01(wP / 0.20) * (1.0 - HudLiquidCurves.clamp01((hP - 0.12) / 0.28))
        let shellAlpha = HudLiquidCurves.clamp01((wP - 0.08) / 0.28)
        let bcnFade = HudLiquidCurves.clamp01((wP - 0.22) / 0.36)
        let cardAlpha = HudLiquidCurves.clamp01((hP - 0.14) / 0.64)

        let bw = max(36, beaconSize.width)
        let bh = max(28, beaconSize.height)
        let ew = max(300, expandedSize.width)
        let eh = max(96, expandedSize.height)

        let curW = max(36, bw + (ew - bw) * wP)
        let curH = max(28, bh + (eh - bh) * hP)
        let curRadius = collapsedRadius + (expandedRadius - collapsedRadius) * min(1.0, wP)

        Color.clear
            .frame(width: curW, height: curH)
            .overlay(alignment: anchorAlignment) {
                ZStack {
                    VisualEffectBlur(
                        material: .popover,
                        blendingMode: .behindWindow,
                        alpha: CGFloat(blurAlpha),
                        appearanceName: effectiveTheme.isLight ? .aqua : .darkAqua
                    )

                    if styleMode == .aurora {
                        LivingAuroraMeshView(isAnimating: activeCount > 0)
                            .opacity(0.68 + 0.26 * normOp)
                    } else {
                        LinearGradient(
                            colors: effectiveTheme.glassGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(tintAlpha)

                        RadialGradient(
                            colors: [
                                effectiveTheme.swatchColor.opacity(effectiveTheme.isLight ? 0.16 : 0.13),
                                Color.clear,
                            ],
                            center: .topLeading,
                            startRadius: 6,
                            endRadius: 210
                        )
                    }
                }
                .frame(width: curW, height: curH)
                .overlay(alignment: anchorAlignment) {
                    expandedInner
                        .scaleEffect(0.93 + 0.07 * min(1.02, wP), anchor: unitAnchor)
                        .blur(radius: morph == .m4 ? (1.0 - cardAlpha) * 6.0 : 0)
                        .opacity(Double(cardAlpha))
                        .allowsHitTesting(isOpenInteractive)
                }
                .clipShape(RoundedRectangle(cornerRadius: curRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: curRadius, style: .continuous)
                        .strokeBorder(
                            needsAttention
                                ? LinearGradient(
                                    colors: [attentionColor.opacity(0.82), attentionColor.opacity(0.28)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: styleMode == .aurora
                                        ? [Color.white.opacity(0.32), Color(red: 0.43, green: 0.91, blue: 0.72).opacity(0.20)]
                                        : effectiveTheme.outerBorderColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: needsAttention ? 1.2 : 1.0
                        )
                )
                .opacity(Double(shellAlpha))
            }
            .overlay(alignment: anchorAlignment) {
                beacon
                    .scaleEffect(peekScale + 0.06 * bcnFade, anchor: unitAnchor)
                    .blur(radius: morph == .m4 ? bcnFade * 5.0 : 0)
                    .opacity(Double(1.0 - bcnFade) * idleAlpha)
                    .allowsHitTesting(!isOpenInteractive)
            }
            .shadow(
                color: .black.opacity(0.16 + 0.24 * Double(p01)),
                radius: 5.0 + 11.0 * p01,
                x: 0,
                y: 2.5 + 6.0 * p01
            )
            .background(CanvasHitBoxReader(vm: vm))
    }
}

/// 120Hz Animatable Detached / Frameless Stage (`M2` Beacon Stay or `S10` Frameless Stack).
private struct AnimatableDetachedCornerStage<BeaconView: View, ExpandedView: View>: View, Animatable {
    var widthProgress: CGFloat
    var heightProgress: CGFloat
    let vm: HudViewModel
    let isM2Stay: Bool
    let isBottomAnchored: Bool
    let horizontalAlignment: HorizontalAlignment
    let anchorAlignment: Alignment
    let unitAnchor: UnitPoint
    let isOpenInteractive: Bool
    let idleAlpha: Double
    let beacon: BeaconView
    let expanded: ExpandedView

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(widthProgress, heightProgress) }
        set {
            widthProgress = newValue.first
            heightProgress = newValue.second
        }
    }

    var body: some View {
        let wP = max(0, widthProgress)
        let hP = max(0, heightProgress)
        let p01 = HudLiquidCurves.clamp01(max(wP * 0.5, hP))
        let peekT = HudLiquidCurves.clamp01(wP / 0.20)
        let cardAlpha = HudLiquidCurves.clamp01((hP - 0.12) / 0.66)
        let bcnFade = HudLiquidCurves.clamp01((wP - 0.22) / 0.36)

        if isM2Stay {
            VStack(alignment: horizontalAlignment, spacing: 7) {
                if isBottomAnchored {
                    expanded
                        .scaleEffect(0.93 + 0.07 * min(1.02, wP), anchor: unitAnchor)
                        .offset(y: 12.0 * (1.0 - min(1.0, hP)))
                        .opacity(Double(cardAlpha))
                        .allowsHitTesting(isOpenInteractive)

                    beacon
                        .scaleEffect(1.0 + 0.045 * peekT - 0.015 * p01, anchor: unitAnchor)
                        .opacity(idleAlpha)
                        .background(CanvasHitBoxReader(vm: vm, enabled: !isOpenInteractive))
                } else {
                    beacon
                        .scaleEffect(1.0 + 0.045 * peekT - 0.015 * p01, anchor: unitAnchor)
                        .opacity(idleAlpha)
                        .background(CanvasHitBoxReader(vm: vm, enabled: !isOpenInteractive))

                    expanded
                        .scaleEffect(0.93 + 0.07 * min(1.02, wP), anchor: unitAnchor)
                        .offset(y: -12.0 * (1.0 - min(1.0, hP)))
                        .opacity(Double(cardAlpha))
                        .allowsHitTesting(isOpenInteractive)
                }
            }
            .shadow(color: .black.opacity(0.16 + 0.18 * Double(p01)), radius: 5.0 + 8.0 * p01, x: 0, y: 3.0 + 4.0 * p01)
            .background(CanvasHitBoxReader(vm: vm, enabled: isOpenInteractive))
        } else {
            ZStack(alignment: anchorAlignment) {
                expanded
                    .scaleEffect(0.90 + 0.10 * min(1.02, wP), anchor: unitAnchor)
                    .offset(y: (isBottomAnchored ? 10.0 : -10.0) * (1.0 - min(1.0, hP)))
                    .opacity(Double(cardAlpha))
                    .allowsHitTesting(isOpenInteractive)
                    .background(CanvasHitBoxReader(vm: vm, enabled: isOpenInteractive))

                beacon
                    .scaleEffect(1.0 + 0.050 * peekT * (1.0 - bcnFade) - 0.08 * bcnFade, anchor: unitAnchor)
                    .opacity(Double(1.0 - bcnFade) * idleAlpha)
                    .allowsHitTesting(!isOpenInteractive)
                    .background(CanvasHitBoxReader(vm: vm, enabled: !isOpenInteractive))
            }
            .shadow(color: .black.opacity(0.16 + 0.18 * Double(p01)), radius: 5.0 + 8.0 * p01, x: 0, y: 3.0 + 4.0 * p01)
        }
    }
}

/// Persistent Corner/Edge Morph View keeping both Beacon & Expanded subtrees permanently mounted.
struct UnifiedCornerMorphView: View {
    @ObservedObject var vm: HudViewModel
    let styleMode: HudStyleMode
    let effectiveTheme: HudTheme
    let morph: HudHoverMorph
    let collapsedStyle: HudCollapsedStyle
    let normOp: Double
    let blurAlpha: Double
    let tintAlpha: Double
    let needsAttention: Bool
    let attentionColor: Color

    @State private var beaconSize: CGSize = CGSize(width: 96, height: 34)
    @State private var expandedSize: CGSize = CGSize(width: 348, height: 220)

    private var collapsedCornerRadius: CGFloat {
        switch collapsedStyle {
        case .e01, .capsule, .island: return 20
        case .e04, .e08: return 26
        case .e02, .e03: return 14
        default: return 12
        }
    }

    var body: some View {
        let open = vm.isExpanded
        let peeking = vm.isHoverArming && !open
        let targetW: CGFloat = open ? 1.0 : (peeking ? 0.22 : 0.0)
        let targetH: CGFloat = open ? 1.0 : (peeking ? 0.07 : 0.0)
        let idleAlpha: Double = vm.isAllIdleForLong ? 0.80 : 1.0

        let beaconMeasured = CollapsedBeaconDispatcherView(
            vm: vm,
            theme: effectiveTheme,
            styleMode: styleMode,
            blurAlpha: blurAlpha,
            tintAlpha: tintAlpha,
            needsAttention: needsAttention,
            attentionColor: attentionColor
        )
        .fixedSize(horizontal: true, vertical: true)
        .background(
            HudSizeReader { size, _ in
                if size.width > 20 && size.height > 16 {
                    if abs(beaconSize.width - size.width) > 0.5 || abs(beaconSize.height - size.height) > 0.5 {
                        beaconSize = size
                    }
                }
            }
        )

        let isM2Detached = (morph == .m2 && !vm.settings.pinnedExpanded)

        if styleMode == .frameless || isM2Detached {
            let detachedExpanded = ExpandedEnvelopeView(
                vm: vm,
                styleMode: styleMode,
                effectiveTheme: effectiveTheme,
                normOp: normOp,
                blurAlpha: blurAlpha,
                tintAlpha: tintAlpha,
                needsAttention: needsAttention,
                attentionColor: attentionColor
            )
            .fixedSize(horizontal: true, vertical: true)

            AnimatableDetachedCornerStage(
                widthProgress: targetW,
                heightProgress: targetH,
                vm: vm,
                isM2Stay: isM2Detached,
                isBottomAnchored: vm.isBottomAnchored,
                horizontalAlignment: vm.horizontalAlignment,
                anchorAlignment: vm.anchorAlignment,
                unitAnchor: vm.anchorUnitPoint,
                isOpenInteractive: open,
                idleAlpha: idleAlpha,
                beacon: beaconMeasured,
                expanded: detachedExpanded
            )
        } else {
            let expandedInnerMeasured = ExpandedHudView(vm: vm, theme: effectiveTheme, styleMode: styleMode, panelWidth: 348)
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    HudSizeReader { size, animated in
                        guard size.width > 200, size.height > 50 else { return }
                        if abs(expandedSize.width - size.width) > 0.5 || abs(expandedSize.height - size.height) > 0.5 {
                            if animated && open {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    expandedSize = size
                                }
                            } else {
                                expandedSize = size
                            }
                        }
                    }
                )

            AnimatableCornerGlassStage(
                widthProgress: targetW,
                heightProgress: targetH,
                vm: vm,
                beaconSize: beaconSize,
                expandedSize: expandedSize,
                collapsedRadius: collapsedCornerRadius,
                expandedRadius: styleMode == .aurora ? 22 : 20,
                styleMode: styleMode,
                effectiveTheme: effectiveTheme,
                morph: morph,
                normOp: normOp,
                blurAlpha: blurAlpha,
                tintAlpha: tintAlpha,
                needsAttention: needsAttention,
                attentionColor: attentionColor,
                activeCount: vm.activeCount,
                anchorAlignment: vm.anchorAlignment,
                unitAnchor: vm.anchorUnitPoint,
                isOpenInteractive: open,
                idleAlpha: idleAlpha,
                beacon: beaconMeasured,
                expandedInner: expandedInnerMeasured
            )
        }
    }
}

struct HudRootView: View {
    @ObservedObject var vm: HudViewModel

    var body: some View {
        let styleMode = vm.settings.resolvedStyleMode
        let baseTheme = vm.settings.resolvedTheme
        let effectiveTheme: HudTheme = (styleMode == .aurora) ? .cosmos : baseTheme
        let morph = vm.settings.resolvedHoverMorph
        let collapsedStyle = vm.settings.resolvedCollapsedStyle

        let clampedOp = vm.settings.clampedOpacity
        let normOp = max(0.0, min(1.0, (clampedOp - HudSettings.minOpacity) / (HudSettings.maxOpacity - HudSettings.minOpacity)))
        let blurAlpha = 0.45 + 0.55 * normOp
        let tintAlpha = effectiveTheme.isLight ? (0.56 + 0.34 * normOp) : (0.52 + 0.38 * normOp)

        let needsAttention = vm.flashBanner != nil || vm.primarySession?.phase == .waiting
        let attentionColor = vm.flashBanner?.color ?? effectiveTheme.ringColor(for: .waiting)

        Group {
            if collapsedStyle == .e05 {
                UnifiedNotchDynamicIslandView(vm: vm)
                    .padding(.top, 0)
                    .padding(.horizontal, 12)
                    .padding(.bottom, HudCanvasMetrics.vPad)
                    .frame(
                        width: HudCanvasMetrics.width,
                        height: HudCanvasMetrics.height,
                        alignment: .top
                    )
            } else if collapsedStyle == .island {
                UnifiedFloatingIslandView(
                    vm: vm,
                    needsAttention: needsAttention,
                    attentionColor: attentionColor
                )
                .padding(.horizontal, HudCanvasMetrics.hPad)
                .padding(.vertical, HudCanvasMetrics.vPad)
                .frame(
                    width: HudCanvasMetrics.width,
                    height: HudCanvasMetrics.height,
                    alignment: vm.anchorAlignment
                )
            } else {
                UnifiedCornerMorphView(
                    vm: vm,
                    styleMode: styleMode,
                    effectiveTheme: effectiveTheme,
                    morph: morph,
                    collapsedStyle: collapsedStyle,
                    normOp: normOp,
                    blurAlpha: blurAlpha,
                    tintAlpha: tintAlpha,
                    needsAttention: needsAttention,
                    attentionColor: attentionColor
                )
                .padding(.horizontal, HudCanvasMetrics.hPad)
                .padding(.vertical, HudCanvasMetrics.vPad)
                .frame(
                    width: HudCanvasMetrics.width,
                    height: HudCanvasMetrics.height,
                    alignment: vm.anchorAlignment
                )
            }
        }
        .coordinateSpace(name: "hudCanvas")
        .animation(
            vm.isExpanded ? morph.expandAnimation : morph.collapseAnimation,
            value: vm.settings.pinnedExpanded
        )
    }
}

struct CollapsedCapsuleView: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    var styleMode: HudStyleMode = .classic

    var body: some View {
        let primary = vm.primarySession

        ZStack {
            if let s = primary, s.phase.isActive, styleMode != .aurora {
                GlassProgressWash(session: s, theme: theme)
            }

            HStack(spacing: 9) {
                if let s = primary {
                    SessionStatusGlyph(phase: s.phase, theme: theme, styleMode: styleMode, pulseTick: vm.pulseTick)
                } else {
                    FourPointStarShape()
                        .fill(theme.tertiaryText.opacity(0.60))
                        .frame(width: 11, height: 11)
                }

                if let banner = vm.flashBanner {
                    Text(banner.message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                } else if let s = primary {
                    let subtitle: String = {
                        if s.phase.isActive {
                            if let ts = s.taskStats, !ts.currentItem.isEmpty, s.phase == .thinking {
                                return ts.currentItem
                            }
                            return s.detailText.isEmpty ? s.phase.badgeText : s.detailText
                        }
                        if !s.workspaceName.isEmpty {
                            return "\(s.workspaceName) · \(s.phase.badgeText)"
                        }
                        return s.phase.badgeText
                    }()

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(s.primaryTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            if s.phase == .waiting {
                                Text("待确认")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.waitingTitleAccent)
                                    .fixedSize()
                            } else if s.phase.isActive {
                                StageMilestoneCapsules(session: s, theme: theme, styleMode: styleMode, pulseTick: vm.pulseTick)
                                    .fixedSize()
                            }
                        }

                        HStack(spacing: 6) {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundColor(s.phase == .waiting ? theme.waitingDetailColor : theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            HStack(spacing: 5) {
                                if vm.activeCount > 1 {
                                    Text("+\(vm.activeCount - 1)")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(theme.primaryText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(theme.controlBg)
                                        .clipShape(Capsule())
                                }

                                Text(s.primaryTimeBadge(now: vm.now))
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .fixedSize()
                        }
                    }
                } else {
                    Text("Antigravity · 待命")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
        }
        .frame(width: 316)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = primary {
                vm.jumpToSession(s)
            } else {
                vm.activateAntigravity()
            }
        }
    }
}

struct HudHeaderIconButton<Content: View>: View {
    let theme: HudTheme
    var isActive: Bool = false
    let helpText: String
    let action: () -> Void
    @ViewBuilder let label: () -> Content
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 22, height: 22)
                .background(
                    isActive
                        ? theme.controlActiveBg
                        : (isHovered ? theme.controlActiveBg.opacity(0.75) : theme.controlBg)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(helpText)
    }
}

/// S10 · Frameless Levitating Stack (each session floats independently over transparent desktop air).
struct FramelessExpandedHudView: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    let blurAlpha: Double
    let tintAlpha: Double

    var body: some View {
        let maxCount = max(1, min(8, vm.settings.maxSessionsShown))
        let visibleSessions = Array(vm.sessions.prefix(maxCount))

        VStack(alignment: .trailing, spacing: 8) {
            // 1. Self-contained floating top-right control pill
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.activeCount > 0 ? theme.swatchColor : theme.doneCheckFg)
                    .frame(width: 6.5, height: 6.5)

                Text(vm.activeCount > 0 ? "\(vm.activeCount) 活跃" : "全部就绪")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 3) {
                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "切换主题风格（当前：S10 无框悬浮，点击切换回经典毛玻璃）",
                        action: { vm.updateSettings { $0.styleMode = HudStyleMode.frameless.nextStyle.rawValue } }
                    ) {
                        Image(systemName: HudStyleMode.frameless.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                    }

                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "切换色彩基底（当前：\(theme.displayName)）",
                        action: { vm.updateSettings { $0.theme = theme.nextTheme.rawValue } }
                    ) {
                        Circle()
                            .fill(theme.swatchColor)
                            .overlay(
                                Circle().strokeBorder(theme.primaryText.opacity(0.32), lineWidth: 0.7)
                            )
                            .frame(width: 8.5, height: 8.5)
                    }

                    let cStyle = vm.settings.resolvedCollapsedStyle
                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "切换收起态样式（当前：\(cStyle.displayName)，移开鼠标即可预览）",
                        action: { vm.updateSettings { $0.collapsedStyle = cStyle.nextStyle.rawValue } }
                    ) {
                        Image(systemName: cStyle.symbolName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }

                    HudHeaderIconButton(
                        theme: theme,
                        isActive: vm.settings.pinnedExpanded,
                        helpText: vm.settings.pinnedExpanded ? "取消固定展开" : "固定展开面板",
                        action: { vm.updateSettings { $0.pinnedExpanded.toggle() } }
                    ) {
                        Image(systemName: vm.settings.pinnedExpanded ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(vm.settings.pinnedExpanded ? theme.primaryText : theme.secondaryText)
                    }

                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "隐藏桌面浮窗",
                        action: { vm.updateSettings { $0.visible = false } }
                    ) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    VisualEffectBlur(
                        material: .popover,
                        blendingMode: .behindWindow,
                        alpha: CGFloat(blurAlpha),
                        appearanceName: theme.isLight ? .aqua : .darkAqua
                    )
                    LinearGradient(
                        colors: theme.glassGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(tintAlpha)
                }
                .clipShape(Capsule())
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: theme.outerBorderColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )

            // 2. Standalone Flash Banner Pill (if active)
            if let banner = vm.flashBanner {
                HStack(spacing: 6) {
                    Text(banner.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 332)
                .background(
                    ZStack {
                        VisualEffectBlur(
                            material: .popover,
                            blendingMode: .behindWindow,
                            alpha: CGFloat(blurAlpha),
                            appearanceName: theme.isLight ? .aqua : .darkAqua
                        )
                        banner.color.opacity(0.26)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(banner.color.opacity(0.55), lineWidth: 1.0)
                )
            }

            // 3. Independent Levitating Session Capsules
            if visibleSessions.isEmpty {
                HStack(spacing: 8) {
                    FourPointStarShape()
                        .fill(theme.tertiaryText.opacity(0.6))
                        .frame(width: 11, height: 11)
                    Text("当前无活跃会话，新任务发起后自动同步")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: 332)
                .background(
                    ZStack {
                        VisualEffectBlur(
                            material: .popover,
                            blendingMode: .behindWindow,
                            alpha: CGFloat(blurAlpha),
                            appearanceName: theme.isLight ? .aqua : .darkAqua
                        )
                        LinearGradient(
                            colors: theme.glassGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(tintAlpha)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: theme.outerBorderColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
            } else {
                ForEach(visibleSessions) { session in
                    SessionCardRow(
                        session: session,
                        theme: theme,
                        styleMode: .frameless,
                        isStandaloneFloating: true,
                        blurAlpha: blurAlpha,
                        tintAlpha: tintAlpha,
                        now: vm.now,
                        pulseTick: vm.pulseTick,
                        isJumping: vm.jumpingSessionId == session.id,
                        onActivate: { vm.jumpToSession(session) },
                        onDismiss: session.phase.isActive ? nil : { vm.dismissSession(session) }
                    )
                    .frame(width: 332)
                }
            }

            // 4. Standalone Clear Pill
            if vm.clearableCount > 0 {
                Button(action: {
                    vm.clearCompletedSessions()
                }) {
                    Text("清理已完成 (\(vm.clearableCount))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            ZStack {
                                VisualEffectBlur(
                                    material: .popover,
                                    blendingMode: .behindWindow,
                                    alpha: CGFloat(blurAlpha),
                                    appearanceName: theme.isLight ? .aqua : .darkAqua
                                )
                                LinearGradient(
                                    colors: theme.glassGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .opacity(tintAlpha)
                            }
                            .clipShape(Capsule())
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: theme.outerBorderColors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.9
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("一键清理所有已完成或已停止的会话记录")
            }
        }
        .frame(width: 332)
    }
}

struct ExpandedHudView: View {
    @ObservedObject var vm: HudViewModel
    let theme: HudTheme
    var styleMode: HudStyleMode = .classic
    var panelWidth: CGFloat = 348

    var body: some View {
        let maxCount = max(1, min(8, vm.settings.maxSessionsShown))
        let visibleSessions = Array(vm.sessions.prefix(maxCount))

        VStack(alignment: .leading, spacing: 0) {
            // Clean Glass Header
            HStack(spacing: 6) {
                Text("Antigravity")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text(vm.activeCount > 0 ? "\(vm.activeCount) 活跃" : "全部就绪")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(styleMode == .aurora ? Color(red: 0.65, green: 0.95, blue: 0.84) : theme.tertiaryText)

                Spacer()

                HStack(spacing: 4) {
                    // 1-Click Style Mode Switcher (经典 -> S6 流体极光 -> S10 无框悬浮)
                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "切换主题风格（当前：\(styleMode.displayName)，点击切换下一个）",
                        action: { vm.updateSettings { $0.styleMode = styleMode.nextStyle.rawValue } }
                    ) {
                        Image(systemName: styleMode.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(styleMode == .aurora ? Color(red: 0.43, green: 0.91, blue: 0.72) : theme.secondaryText)
                    }

                    // Color Palette Swatch (shown in Classic mode)
                    if styleMode == .classic {
                        HudHeaderIconButton(
                            theme: theme,
                            helpText: "切换色彩基底（当前：\(theme.displayName)）",
                            action: { vm.updateSettings { $0.theme = theme.nextTheme.rawValue } }
                        ) {
                            Circle()
                                .fill(theme.swatchColor)
                                .overlay(
                                    Circle().strokeBorder(theme.primaryText.opacity(0.32), lineWidth: 0.7)
                                )
                                .frame(width: 9, height: 9)
                        }
                    }

                    // 1-Click Collapsed Beacon Switcher (E01 -> E02 -> ... -> E10 -> 宽胶囊)
                    let cStyle = vm.settings.resolvedCollapsedStyle
                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "切换收起态样式（当前：\(cStyle.displayName)，移开鼠标即可预览）",
                        action: { vm.updateSettings { $0.collapsedStyle = cStyle.nextStyle.rawValue } }
                    ) {
                        Image(systemName: cStyle.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }

                    HudHeaderIconButton(
                        theme: theme,
                        isActive: vm.settings.pinnedExpanded,
                        helpText: vm.settings.pinnedExpanded ? "取消固定展开" : "固定展开面板",
                        action: { vm.updateSettings { $0.pinnedExpanded.toggle() } }
                    ) {
                        Image(systemName: vm.settings.pinnedExpanded ? "pin.fill" : "pin")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(vm.settings.pinnedExpanded ? theme.primaryText : theme.secondaryText)
                    }

                    HudHeaderIconButton(
                        theme: theme,
                        helpText: "隐藏桌面浮窗",
                        action: { vm.updateSettings { $0.visible = false } }
                    ) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 9)

            // Flash banner
            if let banner = vm.flashBanner {
                HStack(spacing: 6) {
                    Text(banner.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(banner.color.opacity(theme.isLight ? 0.16 : 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
            }

            // Session List
            if visibleSessions.isEmpty {
                HStack(spacing: 8) {
                    FourPointStarShape()
                        .fill(theme.tertiaryText.opacity(0.6))
                        .frame(width: 11, height: 11)
                    Text("当前无活跃会话，新任务发起后将自动同步")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 7) {
                    ForEach(visibleSessions) { session in
                        SessionCardRow(
                            session: session,
                            theme: theme,
                            styleMode: styleMode,
                            now: vm.now,
                            pulseTick: vm.pulseTick,
                            isJumping: vm.jumpingSessionId == session.id,
                            onActivate: { vm.jumpToSession(session) },
                            onDismiss: session.phase.isActive ? nil : { vm.dismissSession(session) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, vm.clearableCount > 0 ? 8 : 11)
            }

            // Minimal conditional footer
            if vm.clearableCount > 0 {
                HStack {
                    Spacer()
                    Button(action: {
                        vm.clearCompletedSessions()
                    }) {
                        Text("清理已完成 (\(vm.clearableCount))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(theme.controlBg)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("一键清理所有已完成或已停止的会话记录")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: panelWidth)
    }
}

struct SessionCardRow: View {
    let session: SessionSnapshot
    let theme: HudTheme
    var styleMode: HudStyleMode = .classic
    var isStandaloneFloating: Bool = false
    var blurAlpha: Double = 0.9
    var tintAlpha: Double = 0.8
    let now: Date
    let pulseTick: Bool
    let isJumping: Bool
    let onActivate: () -> Void
    let onDismiss: (() -> Void)?
    @State private var isRowHovered: Bool = false

    var body: some View {
        let isActive = session.phase.isActive
        let isWaiting = session.phase == .waiting
        let isError = session.phase == .error

        let cornerRad: CGFloat = isStandaloneFloating ? 16 : (styleMode == .aurora ? 13 : 12)
        let cardShape = RoundedRectangle(cornerRadius: cornerRad, style: .continuous)

        let rowFill: Color = {
            if isJumping {
                return theme.controlActiveBg
            }
            if isWaiting {
                return isRowHovered ? theme.waitingCardFill.opacity(1.25) : theme.waitingCardFill
            }
            if styleMode == .aurora {
                return isRowHovered
                    ? Color.white.opacity(isActive ? 0.14 : 0.09)
                    : Color.white.opacity(isActive ? 0.09 : 0.05)
            }
            if isActive {
                return isRowHovered ? theme.activeCardHoverFill : theme.activeCardFill
            }
            return isRowHovered ? theme.doneCardHoverFill : theme.doneCardFill
        }()

        let rowBorder: Color = {
            if isJumping {
                return theme.ringColor(for: .thinking).opacity(0.65)
            }
            if isWaiting {
                return theme.waitingCardBorder
            }
            if styleMode == .aurora {
                return isRowHovered ? Color.white.opacity(0.24) : Color.white.opacity(isActive ? 0.16 : 0.08)
            }
            if isActive {
                return isRowHovered ? Color.white.opacity(theme.isLight ? 0.95 : 0.28) : theme.activeCardBorder
            }
            return isRowHovered ? Color.white.opacity(theme.isLight ? 0.75 : 0.14) : Color.white.opacity(theme.isLight ? 0.45 : 0.05)
        }()

        ZStack(alignment: .center) {
            Button(action: onActivate) {
                Group {
                    if isActive || isError {
                        let statusLine: String = {
                            if let ts = session.taskStats,
                               !ts.currentItem.isEmpty,
                               session.phase == .thinking {
                                return ts.currentItem
                            }
                            return session.detailText.isEmpty ? session.phase.badgeText : session.detailText
                        }()

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                SessionStatusGlyph(phase: session.phase, theme: theme, styleMode: styleMode, pulseTick: pulseTick)

                                Text(session.primaryTitle)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 6)

                                if isJumping {
                                    Text("跳转中…")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(theme.ringColor(for: .thinking))
                                        .fixedSize()
                                } else if isWaiting {
                                    Text("待确认")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(theme.waitingTitleAccent)
                                        .fixedSize()
                                } else if isActive {
                                    StageMilestoneCapsules(session: session, theme: theme, styleMode: styleMode, pulseTick: pulseTick)
                                        .fixedSize()
                                }
                            }

                            HStack(spacing: 8) {
                                Text(statusLine)
                                    .font(.system(size: 11))
                                    .foregroundColor(
                                        isWaiting
                                            ? theme.waitingDetailColor
                                            : (isError ? theme.ringColor(for: .error) : theme.secondaryText)
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 6)

                                Text(session.primaryTimeBadge(now: now))
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(
                                        styleMode == .aurora
                                            ? Color(red: 0.65, green: 0.95, blue: 0.84)
                                            : theme.tertiaryText
                                    )
                                    .fixedSize()
                            }
                            .padding(.leading, 25)
                        }
                        .padding(.horizontal, isStandaloneFloating ? 13 : 11)
                        .padding(.vertical, 10)
                    } else {
                        HStack(spacing: 9) {
                            SessionStatusGlyph(phase: session.phase, theme: theme, styleMode: styleMode, pulseTick: pulseTick)

                            Text(session.primaryTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 6)

                            Text(session.primaryTimeBadge(now: now))
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .fixedSize()
                                .padding(.trailing, onDismiss != nil ? 20 : 0)
                        }
                        .padding(.horizontal, isStandaloneFloating ? 13 : 11)
                        .padding(.vertical, 8.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        if isStandaloneFloating {
                            ZStack {
                                VisualEffectBlur(
                                    material: .popover,
                                    blendingMode: .behindWindow,
                                    alpha: CGFloat(blurAlpha),
                                    appearanceName: theme.isLight ? .aqua : .darkAqua
                                )
                                LinearGradient(
                                    colors: theme.glassGradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .opacity(isActive ? tintAlpha : tintAlpha * 0.88)

                                if isWaiting {
                                    theme.waitingCardFill
                                } else if isRowHovered {
                                    Color.white.opacity(theme.isLight ? 0.20 : 0.06)
                                }
                            }
                            .clipShape(cardShape)
                        } else {
                            cardShape.fill(rowFill)
                        }

                        if isActive && styleMode != .aurora {
                            GlassProgressWash(session: session, theme: theme)
                                .clipShape(cardShape)
                        }
                    }
                }
                .overlay(
                    cardShape
                        .strokeBorder(
                            isStandaloneFloating && !isWaiting && !isJumping
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: theme.outerBorderColors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(rowBorder),
                            lineWidth: isStandaloneFloating ? 1.0 : 0.8
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDismiss = onDismiss {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 18, height: 18)
                            .background(theme.controlBg)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, isStandaloneFloating ? 10 : 8)
                    .help("移除此会话记录")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isRowHovered = hovering
            }
        }
    }
}

// MARK: - Non-Activating Floating NSPanel & Hover Tracking

final class FloatingHudPanel: NSPanel {
    var onWindowDragBegan: (() -> Void)?
    var onWindowDragEnded: (() -> Void)?

    private var trackingMouseDown = false
    private(set) var isDraggingPanel = false
    private var dragStartMouseScreen: NSPoint = .zero
    private var dragStartPanelOrigin: NSPoint = .zero

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow hardware-notch Dynamic Island mode & transparent canvas margins to span screen edges freely
        return frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let hit = contentView?.hitTest(event.locationInWindow), hit is OpacityTrackNSView {
                trackingMouseDown = false
                isDraggingPanel = false
                super.sendEvent(event)
                return
            }
            trackingMouseDown = true
            isDraggingPanel = false
            dragStartMouseScreen = NSEvent.mouseLocation
            dragStartPanelOrigin = frame.origin
            super.sendEvent(event)

        case .leftMouseDragged:
            guard trackingMouseDown else {
                super.sendEvent(event)
                return
            }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragStartMouseScreen.x
            let dy = mouse.y - dragStartMouseScreen.y
            if !isDraggingPanel && hypot(dx, dy) > 4.5 {
                isDraggingPanel = true
                onWindowDragBegan?()
            }
            if isDraggingPanel {
                setFrameOrigin(
                    NSPoint(
                        x: round(dragStartPanelOrigin.x + dx),
                        y: round(dragStartPanelOrigin.y + dy)
                    )
                )
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if isDraggingPanel {
                trackingMouseDown = false
                isDraggingPanel = false
                // Deliver synthetic mouseUp outside interactive bounds so SwiftUI buttons clear pressed state without firing actions
                if let cancelUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: NSPoint(x: -500, y: -500),
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: 0,
                    pressure: 0
                ) {
                    super.sendEvent(cancelUp)
                }
                onWindowDragEnded?()
                return
            }
            trackingMouseDown = false
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }
}

final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - Application Delegate & Menu Bar Controller

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var vm: HudViewModel!
    private var panel: FloatingHudPanel!
    private var hostingView: HoverTrackingHostingView<HudRootView>!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private weak var menuOpacityValueLabel: NSTextField?
    private weak var opacityParentMenuItem: NSMenuItem?
    private var isProgrammaticMove = false
    private var isUserDraggingWindow = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        vm = HudViewModel()

        setupFloatingPanel()
        setupMouseHoverMonitors()
        setupStatusBarMenu()

        vm.onLayoutChange = { [weak self] in
            DispatchQueue.main.async {
                self?.syncPanelVisibilityAndFrame()
            }
        }
        vm.onLayoutChangeNow = { [weak self] in
            self?.syncPanelVisibilityAndFrame()
        }
        vm.onAlphaChange = { [weak self] in
            self?.syncPanelAlpha()
        }
        vm.onStatusChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        if vm.settings.pinnedExpanded {
            vm.isCanvasExpanded = true
            vm.isContentRevealed = true
        }
        syncPanelVisibilityAndFrame()
        syncPanelAlpha()
        updateStatusItemAppearance()
        vm.writeHelperStatus()
    }

    private func setupFloatingPanel() {
        let rootView = HudRootView(vm: vm)
        hostingView = HoverTrackingHostingView(rootView: rootView)

        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: HudCanvasMetrics.width,
            height: HudCanvasMetrics.height
        )
        panel = FloatingHudPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // WindowServer shadow disabled: GPU SwiftUI shadows render inside the fixed 500x600 canvas with zero resize hitches!
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView

        panel.onWindowDragBegan = { [weak self] in
            guard let self = self else { return }
            self.isUserDraggingWindow = true
            self.panel.ignoresMouseEvents = false
            self.vm.cancelPendingHoverDwellForDrag()
        }
        panel.onWindowDragEnded = { [weak self] in
            self?.commitUserWindowDrag()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func setupMouseHoverMonitors() {
        let globalMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateMouseHover()
            }
        }

        let localMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .mouseEntered, .mouseExited
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: localMask) { [weak self] event in
            self?.evaluateMouseHover()
            return event
        }

        // Lightweight 25Hz screen-coordinate fallback ensures click-through & hover stay synced across Spaces/scrolls
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateMouseHover()
            }
        }
    }

    private func evaluateMouseHover() {
        guard let panel = panel, vm.settings.visible, panel.isVisible else {
            if panel?.ignoresMouseEvents == false {
                panel?.ignoresMouseEvents = true
            }
            if vm.isHovered || vm.isHoverArming {
                vm.setHovering(false)
            }
            return
        }

        // Keep window interactive while user is actively dragging or pressing mouse inside the HUD
        if isUserDraggingWindow || panel.isDraggingPanel || ((NSEvent.pressedMouseButtons & 1) != 0 && !panel.ignoresMouseEvents) {
            return
        }

        let mouse = NSEvent.mouseLocation
        let pf = panel.frame
        let cr = vm.activeCanvasRect
        let pad: CGFloat = vm.isExpanded ? 8.0 : 4.5

        let hitRect = NSRect(
            x: pf.minX + cr.minX - pad,
            y: pf.maxY - cr.maxY - pad,
            width: cr.width + pad * 2.0,
            height: cr.height + pad * 2.0
        )

        let inside = hitRect.contains(mouse)
        if panel.ignoresMouseEvents != !inside {
            panel.ignoresMouseEvents = !inside
        }
        vm.setHovering(inside)
    }

    @objc private func screenParametersDidChange(_ note: Notification) {
        syncPanelVisibilityAndFrame()
    }

    private func commitUserWindowDrag() {
        isUserDraggingWindow = false
        guard let panel = panel else { return }

        let pf = panel.frame
        let cr = vm.activeCanvasRect
        let visLeftX = pf.minX + cr.minX
        let visRightX = pf.minX + cr.maxX
        let visMidX = pf.minX + cr.midX
        let visTopY = pf.maxY - cr.minY
        let visBottomY = pf.maxY - cr.maxY
        let visMidY = (visTopY + visBottomY) * 0.5
        let mouse = NSEvent.mouseLocation

        let currentStyle = vm.settings.resolvedCollapsedStyle

        // Check magnetic snap onto MacBook hardware camera notch when dragging Dynamic Island styles (`.e05` / `.island`)
        if currentStyle == .e05 || currentStyle == .island {
            if let notchScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                let metrics = NotchScreenMetrics.current(for: notchScreen)
                let nearNotchX = abs(visMidX - metrics.notchCenterX) < 120 || abs(mouse.x - metrics.notchCenterX) < 120
                let nearNotchTop = visTopY >= metrics.screenFrame.maxY - 46 || mouse.y >= metrics.screenFrame.maxY - 46
                if metrics.hasHardwareNotch && nearNotchX && nearNotchTop {
                    vm.updateSettings {
                        $0.collapsedStyle = HudCollapsedStyle.e05.rawValue
                        $0.positionPreset = "top_center"
                        $0.customTopCenterX = nil
                        $0.customTopY = nil
                        $0.customBottomY = nil
                        $0.customVerticalMode = nil
                        $0.customAnchorMode = nil
                        $0.customAnchorX = nil
                    }
                    return
                }
            }
        }

        let dropPoint = NSPoint(x: visMidX, y: visMidY)
        let dropScreen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -60, dy: -60).contains(dropPoint) })
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleRect = dropScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var nextSettings = vm.settings
        // If user dragged the hardware-notch meniscus away from the top bezel, morph seamlessly into the Floating Pill Island!
        let detachedFromNotch = (currentStyle == .e05)
        if detachedFromNotch {
            nextSettings.collapsedStyle = HudCollapsedStyle.island.rawValue
        }

        nextSettings.positionPreset = "custom"
        nextSettings.customTopCenterX = Double(visMidX)

        if detachedFromNotch {
            nextSettings.customAnchorMode = "center"
            nextSettings.customAnchorX = Double(visMidX)
        } else if visMidX > visibleRect.midX + 110 {
            nextSettings.customAnchorMode = "right"
            nextSettings.customAnchorX = Double(visRightX)
        } else if visMidX < visibleRect.midX - 110 {
            nextSettings.customAnchorMode = "left"
            nextSettings.customAnchorX = Double(visLeftX)
        } else {
            nextSettings.customAnchorMode = "center"
            nextSettings.customAnchorX = Double(visMidX)
        }

        if !detachedFromNotch && visMidY < visibleRect.minY + visibleRect.height * 0.32 {
            nextSettings.customVerticalMode = "bottom"
            nextSettings.customBottomY = Double(visBottomY)
            nextSettings.customTopY = Double(visTopY)
        } else {
            nextSettings.customVerticalMode = "top"
            nextSettings.customTopY = Double(visTopY)
            nextSettings.customBottomY = nil
        }

        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            vm.settings = nextSettings
        }
        vm.saveSettings()
        vm.writeHelperStatus()
        syncPanelVisibilityAndFrame()
        hostingView.layoutSubtreeIfNeeded()
        updateStatusItemAppearance()
        evaluateMouseHover()
    }

    private func syncPanelVisibilityAndFrame() {
        guard panel != nil else { return }
        if isUserDraggingWindow || panel.isDraggingPanel {
            return
        }
        if !vm.settings.visible {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }

        let canvasW = HudCanvasMetrics.width
        let canvasH = HudCanvasMetrics.height
        let hPad = HudCanvasMetrics.hPad
        let vPad = HudCanvasMetrics.vPad
        let collapsedStyle = vm.settings.resolvedCollapsedStyle
        let margin: CGFloat = 14

        if collapsedStyle == .e05 {
            // Hardware-Notch / Menu-Bar Fused Dynamic Island: fixed 500x600 canvas locked to camera notch!
            let notchScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            let targetScreen = notchScreen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
            let metrics = NotchScreenMetrics.current(for: targetScreen)
            let vis = metrics.visibleFrame
            let topEdge = metrics.hasHardwareNotch ? metrics.screenFrame.maxY : vis.maxY
            let originX = round(metrics.notchCenterX - canvasW / 2.0)
            let originY = round(topEdge - canvasH)

            let notchLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            if panel.level != notchLevel {
                panel.level = notchLevel
            }

            let newFrame = NSRect(x: originX, y: originY, width: canvasW, height: canvasH)
            if panel.frame != newFrame {
                isProgrammaticMove = true
                panel.setFrame(newFrame, display: true, animate: false)
                isProgrammaticMove = false
            }
            syncPanelAlpha()
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            evaluateMouseHover()
            return
        }

        if panel.level != .statusBar {
            panel.level = .statusBar
        }

        var originX: CGFloat
        var originY: CGFloat

        switch vm.settings.positionPreset {
        case "top_center":
            let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
            let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            originX = round(visibleRect.midX - canvasW / 2.0)
            originY = round((visibleRect.maxY - 6 + vPad) - canvasH)

        case "bottom_right":
            let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
            let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            originX = round((visibleRect.maxX - margin + hPad) - canvasW)
            originY = round(visibleRect.minY + margin - vPad)

        case "bottom_left":
            let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
            let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            originX = round(visibleRect.minX + margin - hPad)
            originY = round(visibleRect.minY + margin - vPad)

        case "custom":
            let probeX = CGFloat(vm.settings.customAnchorX ?? vm.settings.customTopCenterX ?? 800)
            let probeY = CGFloat(vm.settings.customBottomY ?? vm.settings.customTopY ?? 600)
            let probePt = NSPoint(x: probeX, y: probeY)
            let customScreen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -80, dy: -80).contains(probePt) })
                ?? panel.screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let visibleRect = customScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            if vm.isBottomAnchored {
                let rawBottomY = CGFloat(vm.settings.customBottomY ?? Double(visibleRect.minY + margin))
                let clampedBottomY = max(visibleRect.minY + 2, min(rawBottomY, visibleRect.maxY - 36))
                originY = round(clampedBottomY - vPad)
            } else {
                let rawTopY = CGFloat(vm.settings.customTopY ?? Double(visibleRect.maxY - margin))
                let clampedTopY = max(visibleRect.minY + 36, min(rawTopY, visibleRect.maxY - 2))
                originY = round((clampedTopY + vPad) - canvasH)
            }

            let mode = vm.settings.customAnchorMode ?? "right"
            if mode == "right", let ax = vm.settings.customAnchorX {
                let clampedRight = max(visibleRect.minX + 60, min(CGFloat(ax), visibleRect.maxX - 2))
                originX = round((clampedRight + hPad) - canvasW)
            } else if mode == "left", let ax = vm.settings.customAnchorX {
                let clampedLeft = max(visibleRect.minX + 2, min(CGFloat(ax), visibleRect.maxX - 60))
                originX = round(clampedLeft - hPad)
            } else if let cx = vm.settings.customTopCenterX {
                let clampedCenter = max(visibleRect.minX + 48, min(CGFloat(cx), visibleRect.maxX - 48))
                originX = round(clampedCenter - canvasW / 2.0)
            } else {
                originX = round((visibleRect.maxX - margin + hPad) - canvasW)
            }

        default: // "top_right" (auto-centers if floating Dynamic Island `.island` is selected!)
            let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
            let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            if collapsedStyle == .island {
                originX = round(visibleRect.midX - canvasW / 2.0)
                originY = round((visibleRect.maxY - 6 + vPad) - canvasH)
            } else {
                originX = round((visibleRect.maxX - margin + hPad) - canvasW)
                originY = round((visibleRect.maxY - margin + vPad) - canvasH)
            }
        }

        let newFrame = NSRect(x: originX, y: originY, width: canvasW, height: canvasH)
        if panel.frame != newFrame {
            isProgrammaticMove = true
            panel.setFrame(newFrame, display: true, animate: false)
            isProgrammaticMove = false
        }

        syncPanelAlpha()

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        evaluateMouseHover()
    }

    private func syncPanelAlpha() {
        guard panel != nil else { return }
        let cs = vm.settings.resolvedCollapsedStyle
        if cs == .e05 {
            // Must remain 100% opaque pitch-black so it merges seamlessly with hardware camera bezel
            if abs(panel.alphaValue - 1.0) > 0.002 {
                panel.alphaValue = 1.0
            }
            return
        }
        let base = vm.settings.clampedOpacity
        let target: Double
        if cs == .island {
            target = max(0.95, base)
        } else if vm.flashBanner != nil {
            target = max(base, 0.92)
        } else if vm.isAllIdleForLong {
            target = cs == .capsule
                ? max(0.32, base * 0.65)
                : max(0.85, base * 0.92)
        } else {
            target = base
        }
        if abs(panel.alphaValue - CGFloat(target)) > 0.002 {
            panel.alphaValue = CGFloat(target)
        }
    }

    private func setupStatusBarMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self
        populateStatusMenu(statusMenu)
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateStatusMenu(menu)
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let active = vm.activeCount
        let waiting = vm.sessions.contains(where: { $0.phase == .waiting })

        let iconName: String
        if waiting {
            iconName = "exclamationmark.bubble.fill"
        } else if active > 0 {
            iconName = "bolt.horizontal.circle.fill"
        } else {
            iconName = "checkmark.circle"
        }

        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "AGY HUD")
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleVis = NSMenuItem(
            title: vm.settings.visible ? "隐藏桌面悬浮窗" : "显示桌面悬浮窗",
            action: #selector(toggleVisible),
            keyEquivalent: "h"
        )
        toggleVis.target = self
        menu.addItem(toggleVis)

        let togglePin = NSMenuItem(
            title: "固定展开多会话面板",
            action: #selector(togglePinned),
            keyEquivalent: "p"
        )
        togglePin.target = self
        togglePin.state = vm.settings.pinnedExpanded ? .on : .off
        menu.addItem(togglePin)

        let toggleSound = NSMenuItem(
            title: "完成与待确认提示音",
            action: #selector(toggleSoundAlert),
            keyEquivalent: "m"
        )
        toggleSound.target = self
        toggleSound.state = vm.settings.soundEnabled ? .on : .off
        menu.addItem(toggleSound)

        let toggleDim = NSMenuItem(
            title: "空闲时自动半透明收敛",
            action: #selector(toggleAutoDim),
            keyEquivalent: ""
        )
        toggleDim.target = self
        toggleDim.state = vm.settings.autoDimIdle ? .on : .off
        menu.addItem(toggleDim)

        let styleMenu = NSMenu()
        for s in HudStyleMode.allCases {
            let item = NSMenuItem(title: s.displayName, action: #selector(selectStyleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = (vm.settings.resolvedStyleMode == s) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleParent = NSMenuItem(title: "主题风格（\(vm.settings.resolvedStyleMode.shortLabel)）", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)

        let themeMenu = NSMenu()
        for t in HudTheme.allCases {
            let item = NSMenuItem(title: t.displayName, action: #selector(selectThemePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.rawValue
            item.state = (vm.settings.resolvedTheme == t) ? .on : .off
            themeMenu.addItem(item)
        }
        let themeParent = NSMenuItem(title: "色彩基底（\(vm.settings.resolvedTheme.shortLabel)）", action: nil, keyEquivalent: "")
        themeParent.submenu = themeMenu
        menu.addItem(themeParent)

        let collapsedMenu = NSMenu()
        for cs in HudCollapsedStyle.allCases {
            let item = NSMenuItem(title: cs.displayName, action: #selector(selectCollapsedStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cs.rawValue
            item.state = (vm.settings.resolvedCollapsedStyle == cs) ? .on : .off
            collapsedMenu.addItem(item)
        }
        let collapsedParent = NSMenuItem(title: "收起态样式（\(vm.settings.resolvedCollapsedStyle.shortLabel)）", action: nil, keyEquivalent: "")
        collapsedParent.submenu = collapsedMenu
        menu.addItem(collapsedParent)

        let morphMenu = NSMenu()
        for hm in HudHoverMorph.allCases {
            let item = NSMenuItem(title: hm.displayName, action: #selector(selectHoverMorph(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hm.rawValue
            item.state = (vm.settings.resolvedHoverMorph == hm) ? .on : .off
            morphMenu.addItem(item)
        }
        morphMenu.addItem(.separator())
        let delayHeader = NSMenuItem(title: "悬停触发延迟（预热防误触）", action: nil, keyEquivalent: "")
        delayHeader.isEnabled = false
        morphMenu.addItem(delayHeader)
        let currentDelay = vm.settings.resolvedHoverDelay
        let delayPresets: [(sec: Double, title: String)] = [
            (0.10, "100ms · 极速响应"),
            (0.18, "180ms · 丝滑蓄力（默认）"),
            (0.32, "320ms · 强防误触"),
            (0.50, "500ms · 慢速驻留"),
        ]
        for dp in delayPresets {
            let item = NSMenuItem(title: dp.title, action: #selector(selectHoverDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dp.sec
            item.state = abs(currentDelay - dp.sec) < 0.04 ? .on : .off
            morphMenu.addItem(item)
        }
        let delayMs = Int(round(currentDelay * 1000.0))
        let morphParent = NSMenuItem(
            title: "悬停展开动效（\(vm.settings.resolvedHoverMorph.shortLabel) · \(delayMs)ms）",
            action: nil,
            keyEquivalent: ""
        )
        morphParent.submenu = morphMenu
        menu.addItem(morphParent)

        let posMenu = NSMenu()
        let presets: [(id: String, title: String)] = [
            ("top_right", "右上角（推荐）"),
            ("top_center", "顶部居中（灵动岛下方）"),
            ("bottom_right", "右下角"),
            ("bottom_left", "左下角"),
        ]
        for preset in presets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPositionPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = (vm.settings.positionPreset == preset.id) ? .on : .off
            posMenu.addItem(item)
        }
        let posParent = NSMenuItem(title: "悬浮窗位置", action: nil, keyEquivalent: "")
        posParent.submenu = posMenu
        menu.addItem(posParent)

        // Opacity submenu with live NSSlider + quick presets
        let currentPct = Int(round(vm.settings.clampedOpacity * 100.0))
        let opMenu = NSMenu()

        let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 32))
        let slider = NSSlider(
            value: vm.settings.clampedOpacity,
            minValue: HudSettings.minOpacity,
            maxValue: HudSettings.maxOpacity,
            target: self,
            action: #selector(menuOpacitySliderChanged(_:))
        )
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 6, width: 162, height: 20)
        sliderContainer.addSubview(slider)

        let valLabel = NSTextField(labelWithString: "\(currentPct)%")
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        valLabel.alignment = .right
        valLabel.frame = NSRect(x: 178, y: 7, width: 40, height: 18)
        sliderContainer.addSubview(valLabel)
        self.menuOpacityValueLabel = valLabel

        let sliderItem = NSMenuItem()
        sliderItem.view = sliderContainer
        opMenu.addItem(sliderItem)
        opMenu.addItem(.separator())

        let opacityPresets: [(pct: Int, title: String)] = [
            (100, "100%（完全不透明）"),
            (94, "94%（默认微透）"),
            (75, "75%（轻度通透）"),
            (55, "55%（半透明）"),
            (35, "35%（高透视水印）"),
        ]
        for op in opacityPresets {
            let item = NSMenuItem(title: op.title, action: #selector(selectOpacityPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = op.pct
            item.state = abs(currentPct - op.pct) <= 2 ? .on : .off
            opMenu.addItem(item)
        }

        let opParent = NSMenuItem(title: "悬浮窗透明度（\(currentPct)%）", action: nil, keyEquivalent: "")
        opParent.submenu = opMenu
        self.opacityParentMenuItem = opParent
        menu.addItem(opParent)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: "清理已完成任务",
            action: #selector(clearCompletedFromMenu),
            keyEquivalent: "k"
        )
        clearItem.target = self
        menu.addItem(clearItem)

        let openAgy = NSMenuItem(
            title: "切回 Antigravity 主窗口",
            action: #selector(openAntigravityWindow),
            keyEquivalent: "o"
        )
        openAgy.target = self
        menu.addItem(openAgy)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出悬浮窗助手",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleVisible() {
        vm.updateSettings { $0.visible.toggle() }
    }

    @objc private func togglePinned() {
        vm.updateSettings { $0.pinnedExpanded.toggle() }
    }

    @objc private func toggleSoundAlert() {
        vm.updateSettings { $0.soundEnabled.toggle() }
    }

    @objc private func toggleAutoDim() {
        vm.updateSettings { $0.autoDimIdle.toggle() }
    }

    @objc private func selectStyleMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.styleMode = raw
        }
    }

    @objc private func selectThemePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.theme = raw
        }
    }

    @objc private func selectCollapsedStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.collapsedStyle = raw
        }
    }

    @objc private func selectHoverMorph(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.hoverMorph = raw
        }
    }

    @objc private func selectHoverDelay(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Double else { return }
        vm.updateSettings {
            $0.hoverDelay = sec
        }
    }

    @objc private func selectPositionPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.positionPreset = preset
            $0.customTopCenterX = nil
            $0.customTopY = nil
            $0.customBottomY = nil
            $0.customVerticalMode = nil
            $0.customAnchorMode = nil
            $0.customAnchorX = nil
        }
    }

    @objc private func menuOpacitySliderChanged(_ sender: NSSlider) {
        let val = sender.doubleValue
        let pct = Int(round(val * 100.0))
        menuOpacityValueLabel?.stringValue = "\(pct)%"
        opacityParentMenuItem?.title = "悬浮窗透明度（\(pct)%）"
        vm.setOpacity(val, persistImmediately: false)
    }

    @objc private func selectOpacityPreset(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        vm.setOpacity(Double(pct) / 100.0, persistImmediately: true)
    }

    @objc private func clearCompletedFromMenu() {
        vm.clearCompletedSessions()
    }

    @objc private func openAntigravityWindow() {
        vm.activateAntigravity()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

@main
struct AgyFloatingHudMain {
    static func main() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.biTQm.agy-floating-hud" && $0.processIdentifier != myPID
        }
        if !existing.isEmpty {
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
