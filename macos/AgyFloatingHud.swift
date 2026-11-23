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
            return Color(red: 0.35, green: 0.68, blue: 1.0)   // Sky Blue
        case .runningTool:
            return Color(red: 0.56, green: 0.48, blue: 1.0)   // Electric Indigo
        case .waiting:
            return Color(red: 0.98, green: 0.75, blue: 0.18)  // Warm Amber
        case .streaming:
            return Color(red: 0.16, green: 0.84, blue: 0.78)  // Cyan-Teal
        case .completed:
            return Color(red: 0.20, green: 0.84, blue: 0.60)  // Emerald
        case .error:
            return Color(red: 0.97, green: 0.36, blue: 0.40)  // Coral Red
        case .canceled:
            return Color(red: 0.62, green: 0.66, blue: 0.73)  // Slate
        case .idle:
            return Color(red: 0.50, green: 0.55, blue: 0.63)  // Muted Gray
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
                Color(red: 0.39, green: 0.40, blue: 0.96),
                Color(red: 0.22, green: 0.74, blue: 0.98),
                Color(red: 0.26, green: 0.90, blue: 0.95),
            ]
        case .runningTool:
            return [
                Color(red: 0.36, green: 0.35, blue: 0.95),
                Color(red: 0.56, green: 0.48, blue: 1.00),
                Color(red: 0.22, green: 0.76, blue: 0.98),
            ]
        case .waiting:
            return [
                Color(red: 0.88, green: 0.48, blue: 0.08),
                Color(red: 0.98, green: 0.75, blue: 0.18),
                Color(red: 1.00, green: 0.91, blue: 0.54),
            ]
        case .streaming:
            return [
                Color(red: 0.14, green: 0.72, blue: 0.96),
                Color(red: 0.16, green: 0.86, blue: 0.82),
                Color(red: 0.22, green: 0.88, blue: 0.64),
            ]
        case .completed:
            return [
                Color(red: 0.18, green: 0.76, blue: 0.92),
                Color(red: 0.20, green: 0.85, blue: 0.62),
            ]
        case .error:
            return [
                Color(red: 0.92, green: 0.26, blue: 0.34),
                Color(red: 0.98, green: 0.46, blue: 0.48),
            ]
        case .canceled, .idle:
            return [
                Color(red: 0.46, green: 0.52, blue: 0.62),
                Color(red: 0.62, green: 0.66, blue: 0.74),
            ]
        }
    }

    var progressGlowColor: Color {
        switch self {
        case .thinking:
            return Color(red: 0.22, green: 0.74, blue: 0.98)
        case .runningTool:
            return Color(red: 0.44, green: 0.62, blue: 1.00)
        case .waiting:
            return Color(red: 0.98, green: 0.75, blue: 0.18)
        case .streaming:
            return Color(red: 0.18, green: 0.86, blue: 0.76)
        default:
            return accentColor
        }
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
    var maxSessionsShown: Int = 5
    var clearedCompletedBefore: Double? = nil
    var dismissedSessions: [String: Double]? = nil

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
        case .completed: return Color(red: 0.20, green: 0.84, blue: 0.60)
        case .waiting: return Color(red: 0.98, green: 0.75, blue: 0.18)
        case .error: return Color(red: 0.97, green: 0.36, blue: 0.40)
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
    @Published var isOpacityBarOpen: Bool = false
    @Published var flashBanner: FlashBanner? = nil
    @Published var jumpingSessionId: String? = nil
    @Published var now: Date = Date()
    @Published var pulseTick: Bool = false

    var onLayoutChange: (() -> Void)?
    var onAlphaChange: (() -> Void)?
    var onStatusChange: (() -> Void)?

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
    private var hoverExitWorkItem: DispatchWorkItem? = nil
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

    var primarySession: SessionSnapshot? {
        sessions.first
    }

    var activeCount: Int {
        sessions.filter { $0.phase.isActive }.count
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

    func setHovering(_ hovering: Bool) {
        hoverExitWorkItem?.cancel()
        if hovering {
            if !isHovered {
                isHovered = true
                onLayoutChange?()
                onAlphaChange?()
            }
        } else {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.isHovered {
                    self.isHovered = false
                    if !self.settings.pinnedExpanded {
                        self.isOpacityBarOpen = false
                    }
                    self.onLayoutChange?()
                    self.onAlphaChange?()
                }
            }
            hoverExitWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
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
                let prefix = rec.tailFirstToolSummary.isEmpty ? "工具已完成" : "已完成 \(rec.tailFirstToolSummary)"
                return (.thinking, "\(prefix) · 模型推理中…")
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
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var alpha: CGFloat = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.alphaValue = alpha
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
        NSColor(calibratedWhite: 0.0, alpha: 0.48).setFill()
        groovePath.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
        groovePath.lineWidth = 0.6
        groovePath.stroke()

        let fillW = max(trackH, thumbX - insetX)
        let fillRect = NSRect(x: insetX, y: midY - trackH / 2.0, width: min(usableW, fillW), height: trackH)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2.0, yRadius: trackH / 2.0)
        if let grad = NSGradient(colors: [
            NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.96, alpha: 1.0),
            NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.98, alpha: 1.0),
            NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.78, alpha: 1.0),
        ]) {
            grad.draw(in: fillPath, angle: 0)
        } else {
            NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.98, alpha: 1.0).setFill()
            fillPath.fill()
        }

        let thumbR: CGFloat = 6.2
        let thumbRect = NSRect(x: thumbX - thumbR, y: midY - thumbR, width: thumbR * 2.0, height: thumbR * 2.0)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.45)
        shadow.shadowBlurRadius = 3.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.white.setFill()
        thumbPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let ringPath = NSBezierPath(ovalIn: thumbRect.insetBy(dx: 0.6, dy: 0.6))
        NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.98, alpha: 0.85).setStroke()
        ringPath.lineWidth = 1.2
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
    var onChange: (Double, Bool) -> Void

    func makeNSView(context: Context) -> OpacityTrackNSView {
        let v = OpacityTrackNSView()
        v.value = value
        v.onValueChanged = onChange
        return v
    }

    func updateNSView(_ nsView: OpacityTrackNSView, context: Context) {
        nsView.value = value
        nsView.onValueChanged = onChange
    }
}

/// Recessed obsidian-glass optical fiber progress track with internal liquid sheen,
/// focused specular laser tip, and subtle forward ambient ripple.
struct ObsidianLaserBar: View {
    let progressClosure: (Date) -> Double
    let colors: [Color]
    let glow: Color
    var height: CGFloat = 4.0
    var isPaused: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rawProgress = CGFloat(min(1.0, max(0.06, progressClosure(timeline.date))))
            let sheenPhase = CGFloat(t.truncatingRemainder(dividingBy: 1.65) / 1.65)
            let ghostPhase = CGFloat(t.truncatingRemainder(dividingBy: 2.30) / 2.30)
            let breath = isPaused ? CGFloat(0.42 + 0.42 * 0.5 * (1.0 + sin(t * 2.8))) : 0.66

            GeometryReader { geo in
                let w = geo.size.width
                let fillW = round(max(min(w, 14), min(w, w * rawProgress)) * 2.0) / 2.0
                let unlitW = max(0, w - fillW)
                let ghostW = min(64, max(26, unlitW * 0.52))
                let ghostX = fillW - 10 + (unlitW + ghostW) * ghostPhase - ghostW
                let tipW = min(16, max(6, fillW * 0.28))

                ZStack(alignment: .leading) {
                    // 1. Machined dark-glass groove + ambient ghost echo
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.black.opacity(0.46))
                        Capsule()
                            .fill(glow.opacity(0.055))

                        if !isPaused && unlitW > 18 {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, glow.opacity(0.20), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: ghostW, height: height)
                                .offset(x: ghostX)
                        }
                    }
                    .frame(width: w, height: height)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.6)
                    )

                    // 2. Luminous chromatic core + liquid sheen + seamless laser flare tip
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: colors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        VStack(spacing: 0) {
                            Capsule()
                                .fill(Color.white.opacity(0.25))
                                .frame(height: max(1.0, height * 0.28))
                            Spacer(minLength: 0)
                        }

                        if !isPaused {
                            let waveW = max(20, fillW * 0.45)
                            let waveOffset = -fillW + (fillW + waveW) * sheenPhase
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Color.white.opacity(0.40), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: waveW, height: height)
                                .offset(x: waveOffset)
                        }

                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: Color.white.opacity(isPaused ? 0.45 : 0.60), location: 0.65),
                                        .init(color: Color.white.opacity(isPaused ? 0.82 : 0.95), location: 1.0),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: tipW, height: height)
                    }
                    .frame(width: fillW, height: height)
                    .clipShape(Capsule())
                    .shadow(color: glow.opacity(breath), radius: 4.0, x: 0, y: 0)
                }
            }
            .frame(height: height)
        }
    }
}

/// Obsidian Laser Progress Track:
/// - Checklist Mode (`task.md` exists): Crisp glass milestone capsules (`<= 10`) or exact laser track (`> 10`).
/// - Open-Ended Turn Mode: Full-width machined obsidian laser rail with zero redundant stage label clutter.
struct SessionProgressTrack: View {
    let session: SessionSnapshot

    private let sky = Color(red: 0.22, green: 0.74, blue: 0.98)
    private let cyan = Color(red: 0.16, green: 0.86, blue: 0.84)
    private let mint = Color(red: 0.20, green: 0.85, blue: 0.62)

    var body: some View {
        if session.phase.isActive, let ts = session.taskStats, ts.total > 0 {
            if ts.total <= 10 {
                let activeLimit = ts.done + max(ts.inProgress, 1)
                HStack(spacing: 3.5) {
                    ForEach(0..<ts.total, id: \.self) { idx in
                        if idx < ts.done {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [sky, mint],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 4.0)
                                .shadow(color: mint.opacity(0.30), radius: 2.5)
                        } else if idx < activeLimit {
                            ObsidianLaserBar(
                                progressClosure: { _ in 0.60 },
                                colors: session.phase == .waiting ? session.phase.progressGradientColors : [sky, cyan],
                                glow: session.phase == .waiting ? session.phase.progressGlowColor : cyan,
                                height: 4.0,
                                isPaused: session.phase == .waiting
                            )
                        } else {
                            Capsule()
                                .fill(Color.black.opacity(0.46))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.6)
                                )
                                .frame(height: 4.0)
                        }
                    }
                }
                .padding(.top, 1.5)
            } else {
                ObsidianLaserBar(
                    progressClosure: { now in session.estimatedProgress(at: now) },
                    colors: [sky, cyan, mint],
                    glow: mint,
                    height: 4.0,
                    isPaused: session.phase == .waiting
                )
                .padding(.top, 1.5)
            }
        } else if session.phase.isActive {
            ObsidianLaserBar(
                progressClosure: { now in session.estimatedProgress(at: now) },
                colors: session.phase.progressGradientColors,
                glow: session.phase.progressGlowColor,
                height: 4.0,
                isPaused: session.phase == .waiting
            )
            .padding(.top, 1.5)
        }
    }
}

struct HudRootView: View {
    @ObservedObject var vm: HudViewModel

    var body: some View {
        let cornerRadius: CGFloat = vm.isExpanded ? 20 : 22
        let clampedOp = vm.settings.clampedOpacity
        let normOp = max(0.0, min(1.0, (clampedOp - HudSettings.minOpacity) / (HudSettings.maxOpacity - HudSettings.minOpacity)))
        let blurAlpha = 0.28 + 0.72 * normOp
        let tintAlpha = 0.44 + 0.42 * normOp

        let borderHighlightColor: Color = {
            if let banner = vm.flashBanner {
                return banner.color.opacity(0.92)
            }
            if let primary = vm.primarySession, primary.phase.isActive {
                return primary.phase.accentColor.opacity(vm.pulseTick ? 0.58 : 0.30)
            }
            return Color.white.opacity(0.15)
        }()

        VStack(alignment: .leading, spacing: 0) {
            if vm.isExpanded {
                ExpandedHudView(vm: vm)
            } else {
                CollapsedCapsuleView(vm: vm)
            }
        }
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, alpha: CGFloat(blurAlpha))
                Color(red: 0.05, green: 0.07, blue: 0.12)
                    .opacity(tintAlpha)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderHighlightColor, lineWidth: vm.flashBanner != nil ? 1.8 : 1.1)
        )
        .padding(6)
    }
}

struct CollapsedCapsuleView: View {
    @ObservedObject var vm: HudViewModel

    var body: some View {
        let primary = vm.primarySession
        let phase = primary?.phase ?? .idle

        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(phase.accentColor.opacity(phase.isActive ? (vm.pulseTick ? 0.34 : 0.14) : 0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: phase.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(phase.accentColor)
                }

                if let banner = vm.flashBanner {
                    Text(banner.message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(banner.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                } else if let s = primary {
                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 5) {
                            Text(s.primaryTitle)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.96))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(s.phase.badgeText)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(s.phase.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(s.phase.accentColor.opacity(0.16))
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                        Text(s.workspaceName.isEmpty ? s.detailText : "\(s.workspaceName) · \(s.detailText)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.68))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    if let ts = s.taskStats {
                        Text("\(ts.done)/\(ts.total) · \(ts.percent)%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(red: 0.24, green: 0.86, blue: 0.68))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    } else if vm.activeCount > 1 {
                        Text("\(vm.activeCount) 活跃")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.74, blue: 1.0))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    Text(s.primaryTimeBadge(now: vm.now))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.64))
                } else {
                    Text("AGY HUD · 暂无活跃会话")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, (primary?.phase.isActive == true) ? 5 : 7)

            if let s = primary, s.phase.isActive {
                ObsidianLaserBar(
                    progressClosure: { now in s.estimatedProgress(at: now) },
                    colors: s.taskStats != nil
                        ? [Color(red: 0.22, green: 0.74, blue: 0.98), Color(red: 0.16, green: 0.86, blue: 0.84), Color(red: 0.20, green: 0.85, blue: 0.62)]
                        : s.phase.progressGradientColors,
                    glow: s.taskStats != nil
                        ? Color(red: 0.20, green: 0.85, blue: 0.62)
                        : s.phase.progressGlowColor,
                    height: 2.8,
                    isPaused: s.phase == .waiting
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 5.5)
            }
        }
        .frame(width: 344)
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

struct ExpandedHudView: View {
    @ObservedObject var vm: HudViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.activeCount > 0 ? Color(red: 0.35, green: 0.68, blue: 1.0) : Color(red: 0.20, green: 0.84, blue: 0.60))
                    .frame(width: 8, height: 8)

                Text("AGY 实时会话进度")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.95))

                Text(vm.activeCount > 0 ? "\(vm.activeCount) 运行中" : "全部就绪")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())

                Spacer()

                let opacityPct = Int(round(vm.settings.clampedOpacity * 100.0))

                Button(action: {
                    vm.toggleOpacityBar()
                }) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundColor(
                            vm.isOpacityBarOpen
                                ? Color(red: 0.35, green: 0.68, blue: 1.0)
                                : (opacityPct < 90 ? Color(red: 0.48, green: 0.78, blue: 1.0) : .white.opacity(0.75))
                        )
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(vm.isOpacityBarOpen ? 0.16 : 0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("调节悬浮窗透明度（当前不透明度 \(opacityPct)%）")

                Button(action: {
                    vm.updateSettings { $0.soundEnabled.toggle() }
                }) {
                    Image(systemName: vm.settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 11))
                        .foregroundColor(vm.settings.soundEnabled ? .white.opacity(0.85) : .white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(vm.settings.soundEnabled ? "已开启完成与确认提示音" : "提示音已静音")

                Button(action: {
                    vm.updateSettings { $0.pinnedExpanded.toggle() }
                }) {
                    Image(systemName: vm.settings.pinnedExpanded ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(vm.settings.pinnedExpanded ? Color(red: 0.35, green: 0.68, blue: 1.0) : .white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(vm.settings.pinnedExpanded ? 0.16 : 0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(vm.settings.pinnedExpanded ? "取消固定展开" : "固定展开多会话面板")

                Button(action: {
                    vm.updateSettings { $0.visible = false }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("暂时隐藏桌面浮窗（可从顶部菜单栏重新显示）")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if vm.isOpacityBarOpen {
                let pct = Int(round(vm.settings.clampedOpacity * 100.0))
                let presets: [Int] = [35, 65, 94]
                HStack(spacing: 7) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                        Text("不透明度")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.78))
                            .fixedSize()
                    }

                    HudOpacityScrubber(value: vm.settings.clampedOpacity) { nextVal, isFinal in
                        vm.setOpacity(nextVal, persistImmediately: isFinal)
                    }
                    .frame(height: 20)

                    HStack(spacing: 3.5) {
                        ForEach(presets, id: \.self) { p in
                            let isCurrent = abs(pct - p) <= 2
                            Button(action: {
                                vm.setOpacity(Double(p) / 100.0, persistImmediately: true)
                            }) {
                                Text("\(p)%")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(isCurrent ? Color(red: 0.88, green: 0.96, blue: 1.0) : .white.opacity(0.58))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isCurrent ? Color(red: 0.22, green: 0.74, blue: 0.98).opacity(0.28) : Color.white.opacity(0.07))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("\(pct)%")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.35, green: 0.78, blue: 1.0))
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7)
                )
                .padding(.horizontal, 10)
            }

            if let banner = vm.flashBanner {
                HStack(spacing: 6) {
                    Text(banner.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(banner.color)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(banner.color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
            }

            Divider()
                .background(Color.white.opacity(0.10))
                .padding(.horizontal, 10)

            if vm.sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.60))
                    Text("当前无待展示会话，新任务发起后将自动出现")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.58))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.sessions.prefix(5)) { session in
                        SessionCardRow(
                            session: session,
                            now: vm.now,
                            isJumping: vm.jumpingSessionId == session.id,
                            onActivate: { vm.jumpToSession(session) },
                            onDismiss: session.phase.isActive ? nil : { vm.dismissSession(session) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            HStack {
                Text("拖拽顶部移动位置 · 点击卡片直达对应会话")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.42))
                Spacer()
                if vm.clearableCount > 0 {
                    Button(action: {
                        vm.clearCompletedSessions()
                    }) {
                        HStack(spacing: 3.5) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                            Text("清理已完成 (\(vm.clearableCount))")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.62, green: 0.78, blue: 0.98))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("一键清理所有已完成或已停止的会话记录")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
        .frame(width: 386)
    }
}

struct SessionCardRow: View {
    let session: SessionSnapshot
    let now: Date
    let isJumping: Bool
    let onActivate: () -> Void
    let onDismiss: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onActivate) {
                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Status Icon + Conversation Name + Phase Badge + Time
                    HStack(spacing: 6) {
                        Image(systemName: isJumping ? "arrow.up.forward.circle.fill" : session.phase.symbolName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(isJumping ? Color(red: 0.38, green: 0.75, blue: 1.0) : session.phase.accentColor)

                        Text(session.primaryTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.96))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(isJumping ? "正在跳转…" : session.phase.badgeText)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(isJumping ? Color(red: 0.38, green: 0.75, blue: 1.0) : session.phase.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((isJumping ? Color(red: 0.38, green: 0.75, blue: 1.0) : session.phase.accentColor).opacity(0.16))
                            .clipShape(Capsule())
                            .fixedSize()

                        Spacer(minLength: 4)

                        Text(session.primaryTimeBadge(now: now))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(session.phase.isActive ? session.phase.accentColor.opacity(0.95) : .white.opacity(0.50))
                            .fixedSize()
                            .padding(.trailing, onDismiss != nil ? 18 : 0)
                    }

                    // Row 2: Workspace tag + Model tag + Latest User Prompt (or compact finished summary)
                    HStack(spacing: 6) {
                        if !session.workspaceName.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 8.5))
                                Text(session.workspaceName)
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .foregroundColor(Color(red: 0.62, green: 0.78, blue: 0.98))
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize()
                        }

                        if !session.modelShortName.isEmpty {
                            Text(session.modelShortName)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(.white.opacity(0.42))
                                .lineLimit(1)
                                .fixedSize()
                        }

                        if session.phase.isActive {
                            if !session.promptTitle.isEmpty && session.promptTitle != session.primaryTitle {
                                Text(session.promptTitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.68))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            Spacer(minLength: 2)
                            let checklistPart: String? = {
                                guard let ts = session.taskStats else { return nil }
                                return "清单 \(ts.done)/\(ts.total)"
                            }()
                            let parts: [String] = [
                                checklistPart,
                                session.turnToolCount > 0 ? "本轮 \(session.turnToolCount) 步" : nil,
                                session.finishedTurnDurationText,
                            ].compactMap { $0 }
                            if !parts.isEmpty {
                                Text(parts.joined(separator: " · "))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.44))
                                    .fixedSize()
                            }
                        }
                    }

                    // Row 3 (Active or Error): Live action detail + compact step/checklist telemetry
                    if session.phase.isActive || session.phase == .error {
                        let statusLine: String = {
                            if let ts = session.taskStats,
                               !ts.currentItem.isEmpty,
                               session.phase == .thinking {
                                return ts.currentItem
                            }
                            return session.detailText
                        }()

                        HStack(spacing: 6) {
                            Text(statusLine)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(
                                    session.phase == .waiting || session.phase == .error
                                        ? session.phase.accentColor
                                        : .white.opacity(0.86)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            if session.phase.isActive, let ts = session.taskStats, ts.total > 0 {
                                Text("清单 \(ts.done)/\(ts.total) · \(ts.percent)%")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(red: 0.22, green: 0.86, blue: 0.64))
                                    .fixedSize()
                            } else if session.turnToolCount > 0 {
                                HStack(spacing: 3.5) {
                                    Text("\(session.turnToolCount) 步")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(session.phase.accentColor.opacity(0.95))
                                    if !session.turnToolMix.isEmpty {
                                        Text("· \(session.turnToolMix)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.46))
                                    }
                                }
                                .lineLimit(1)
                                .fixedSize()
                            }
                        }
                    }

                    // Row 4: Obsidian Laser Progress Track (Active turns only)
                    SessionProgressTrack(session: session)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, session.phase.isActive ? 8.5 : 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            isJumping
                                ? Color(red: 0.22, green: 0.45, blue: 0.78).opacity(0.26)
                                : Color.white.opacity(session.phase.isActive ? 0.085 : 0.035)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isJumping
                                ? Color(red: 0.38, green: 0.75, blue: 1.0).opacity(0.80)
                                : (session.phase.isActive ? session.phase.accentColor.opacity(0.34) : Color.white.opacity(0.06)),
                            lineWidth: isJumping ? 1.2 : 0.8
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 7)
                .padding(.trailing, 8)
                .help("从悬浮窗移除此已完成会话")
            }
        }
    }
}

// MARK: - Non-Activating Floating NSPanel & Hover Tracking

final class FloatingHudPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        vm = HudViewModel()

        setupFloatingPanel()
        setupStatusBarMenu()

        vm.onLayoutChange = { [weak self] in
            self?.syncPanelVisibilityAndFrame()
        }
        vm.onAlphaChange = { [weak self] in
            self?.syncPanelAlpha()
        }
        vm.onStatusChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        syncPanelVisibilityAndFrame()
        syncPanelAlpha()
        updateStatusItemAppearance()
        vm.writeHelperStatus()
    }

    private func setupFloatingPanel() {
        let rootView = HudRootView(vm: vm)
        hostingView = HoverTrackingHostingView(rootView: rootView)
        hostingView.onHoverChanged = { [weak self] hovering in
            self?.vm.setHovering(hovering)
        }

        let initialRect = NSRect(x: 0, y: 0, width: 344, height: 54)
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
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    @objc private func windowDidMove(_ note: Notification) {
        guard !isProgrammaticMove else { return }
        let frame = panel.frame
        vm.settings.positionPreset = "custom"
        vm.settings.customTopCenterX = Double(frame.midX)
        vm.settings.customTopY = Double(frame.maxY)
        vm.saveSettings()
        vm.writeHelperStatus()
    }

    private func syncPanelVisibilityAndFrame() {
        guard panel != nil else { return }
        if !vm.settings.visible {
            panel.orderOut(nil)
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let targetWidth = max(344, fitting.width)
        let targetHeight = max(54, fitting.height)

        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 14

        var topCenterX: CGFloat
        var topY: CGFloat

        switch vm.settings.positionPreset {
        case "top_center":
            topCenterX = visibleRect.midX
            topY = visibleRect.maxY - 8
        case "bottom_right":
            topCenterX = visibleRect.maxX - (targetWidth / 2.0) - margin
            topY = visibleRect.minY + targetHeight + margin
        case "bottom_left":
            topCenterX = visibleRect.minX + (targetWidth / 2.0) + margin
            topY = visibleRect.minY + targetHeight + margin
        case "custom":
            if let cx = vm.settings.customTopCenterX, let cy = vm.settings.customTopY {
                topCenterX = CGFloat(cx)
                topY = CGFloat(cy)
            } else {
                topCenterX = visibleRect.maxX - (targetWidth / 2.0) - margin
                topY = visibleRect.maxY - margin
            }
        default:
            topCenterX = visibleRect.maxX - (targetWidth / 2.0) - margin
            topY = visibleRect.maxY - margin
        }

        var originX = round(topCenterX - targetWidth / 2.0)
        var originY = round(topY - targetHeight)

        originX = max(visibleRect.minX + 6, min(originX, visibleRect.maxX - targetWidth - 6))
        originY = max(visibleRect.minY + 6, min(originY, visibleRect.maxY - targetHeight - 4))

        let newFrame = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
        isProgrammaticMove = true
        panel.setFrame(newFrame, display: true, animate: false)
        isProgrammaticMove = false

        syncPanelAlpha()

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func syncPanelAlpha() {
        guard panel != nil else { return }
        let base = vm.settings.clampedOpacity
        let target: Double
        if vm.flashBanner != nil {
            target = max(base, 0.90)
        } else if vm.isAllIdleForLong {
            target = max(0.16, base * 0.56)
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

    @objc private func selectPositionPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        vm.updateSettings {
            $0.positionPreset = preset
            $0.customTopCenterX = nil
            $0.customTopY = nil
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
