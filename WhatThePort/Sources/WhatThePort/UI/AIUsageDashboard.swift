import SwiftUI
import Charts

struct AIUsageDashboard: View {
    @ObservedObject var catalog: AIUsageCatalog
    var refreshOnAppear = true
    /// Snapshot review only: lay out the whole page instead of a scrolling viewport.
    var fullHeight = false
    @ObservedObject private var tokens = TokenUsageModel.shared
    @State private var selected: AIUsageProvider?
    @State private var showsIssues = true

    var body: some View {
        ScrollView {
            if let selected {
                AIUsageView(store: catalog.store(for: selected), startsInDetail: true, onBack: { self.selected = nil })
                    .id(selected)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    AIUsageHeader(catalog: catalog)
                    AIUsageSummaryGrid(catalog: catalog, tokens: tokens.summary)
                    if let summary = tokens.summary { TokenChartCard(summary: summary) }
                    let healthy = catalog.stores.filter { !AIUsageIssue.needsAttention($0) }
                    let attention = catalog.stores.filter { AIUsageIssue.needsAttention($0) }
                    if !healthy.isEmpty {
                        AIUsageCaption(left: L10n.text("Quotas"), right: L10n.text("Remaining · resets in"))
                        AIUsageCard {
                            ForEach(Array(healthy.enumerated()), id: \.element.provider) { index, store in
                                if index > 0 { AIUsageHairline() }
                                AIUsageQuotaRow(store: store) { selected = store.provider }
                            }
                        }
                    }
                    if !attention.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showsIssues.toggle() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showsIssues ? 90 : 0))
                                Text(L10n.format("Needs attention · %d", attention.count))
                            }.font(Theme.caption).foregroundStyle(Theme.text3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showsIssues {
                            AIUsageCard {
                                ForEach(Array(attention.enumerated()), id: \.element.provider) { index, store in
                                    if index > 0 { AIUsageHairline() }
                                    AIUsageIssueRow(store: store) { selected = store.provider }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 14)
            }
        }
        .frame(height: fullHeight ? nil : 540)
        .scrollDisabled(fullHeight)
        .environment(\.locale, L10n.locale)
        .onAppear { catalog.isVisible = refreshOnAppear }
        .onDisappear { catalog.isVisible = false }
        .task {
            guard refreshOnAppear else { return }
            catalog.startSchedule()
            while !Task.isCancelled {
                await tokens.load()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }
}

// MARK: - Local token totals

@MainActor
final class TokenUsageModel: ObservableObject {
    static let shared = TokenUsageModel()
    @Published private(set) var summary: TokenUsageSummary?

    func load() async {
        let result = await LocalTokenUsage.shared.summary()
        summary = result.week.values.reduce(0, +) > 0 ? result : nil
    }
}

// MARK: - Building blocks

enum AIUsagePalette {
    static let green = Theme.adaptive(light: 0x2F9E5B, dark: 0x3DD68C)
    static let card = Theme.adaptive(light: 0xFFFFFF, dark: 0x2A2A2F)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.36, green: 0.42, blue: 0.94)

    static func health(used: Double) -> Color {
        used >= 90 ? Theme.red : used >= 70 ? Theme.amber : green
    }

    static func agent(_ agent: TokenAgent) -> Color { agent == .claude ? claude : codex }
}

struct AIUsageCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(AIUsagePalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator, lineWidth: 0.5))
    }
}

struct AIUsageHairline: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 0.5) }
}

private struct AIUsageCaption: View {
    let left: String
    let right: String
    var body: some View {
        HStack { Text(left); Spacer(); Text(right) }
            .font(Theme.caption).foregroundStyle(Theme.text3).padding(.horizontal, 4).padding(.top, 4)
    }
}

private struct AIUsageHeader: View {
    @ObservedObject var catalog: AIUsageCatalog

    private var latest: Date? { catalog.stores.compactMap { $0.snapshot?.updatedAt }.max() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("AI usage")).font(Font.custom("Geist-SemiBold", fixedSize: 15))
            Spacer()
            if catalog.refreshingAll || catalog.stores.contains(where: { $0.state == .refreshing }) {
                ProgressView().controlSize(.mini)
            } else if let latest {
                Text(L10n.format("Updated %@", latest.formatted(date: .omitted, time: .shortened)))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
            }
            Button { Task { await catalog.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.plain).disabled(catalog.refreshingAll)
            .help(L10n.text("Refresh all"))
        }.padding(.horizontal, 4).padding(.top, 2)
    }
}

/// Two-by-two figures: today's and this week's tokens, the tightest quota and the soonest reset.
private struct AIUsageSummaryGrid: View {
    @ObservedObject var catalog: AIUsageCatalog
    let tokens: TokenUsageSummary?

    private struct Entry { let provider: AIUsageProvider; let title: String; let window: AIUsageWindow }

    private var entries: [Entry] {
        catalog.stores.flatMap { store -> [Entry] in
            guard let snapshot = store.snapshot, !AIUsageIssue.needsAttention(store) else { return [] }
            return snapshot.windows.map { Entry(provider: store.provider, title: AIUsageIssue.compactTitle($0.title), window: $0.value) }
        }
    }

    var body: some View {
        let tightest = entries.max { $0.window.usedPercent < $1.window.usedPercent }
        let soonest = entries.filter { ($0.window.resetsAt ?? .distantPast) > Date() }
            .min { ($0.window.resetsAt ?? .distantFuture) < ($1.window.resetsAt ?? .distantFuture) }
        AIUsageCard {
            if let tokens {
                HStack(spacing: 0) {
                    cell(L10n.text("Tokens today"), Self.tokens(tokens.today.values.reduce(0, +)),
                         TokenAgent.allCases.map { "\($0.label) \(Self.tokens(tokens.today[$0] ?? 0))" }.joined(separator: " · "))
                    Rectangle().fill(Theme.separator).frame(width: 0.5)
                    let week = tokens.week.values.reduce(0, +)
                    cell(L10n.text("Last 7 days"), Self.tokens(week), L10n.format("%@ a day", Self.tokens(week / 7)))
                }
                AIUsageHairline()
            }
            HStack(spacing: 0) {
                cell(L10n.text("Tightest quota"),
                     tightest.map { AIUsageView.percent($0.window.remainingPercent) } ?? "—",
                     tightest.map { "\($0.provider.name) · \($0.title)" } ?? L10n.text("No readings yet"),
                     color: tightest.map { $0.window.usedPercent >= 70 ? AIUsagePalette.health(used: $0.window.usedPercent) : Theme.text1 })
                Rectangle().fill(Theme.separator).frame(width: 0.5)
                cell(L10n.text("Next reset"),
                     soonest.flatMap { $0.window.resetsAt }.map(AIUsageWindowRow.countdown) ?? "—",
                     soonest.map { "\($0.provider.name) · \($0.title)" } ?? "")
            }
        }
    }

    private func cell(_ title: String, _ value: String, _ detail: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.text3)
            Text(value).font(Font.custom("Geist-SemiBold", fixedSize: 21)).foregroundStyle(color ?? Theme.text1)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1e9 { return String(format: "%.1fB", number / 1e9) }
        if number >= 1e6 { return String(format: "%.0fM", number / 1e6) }
        if number >= 1e3 { return String(format: "%.0fK", number / 1e3) }
        return "\(value)"
    }
}

extension TokenAgent {
    var label: String { self == .claude ? "Claude" : "Codex" }
}

/// Stacked token bars for today (by hour) or the last seven days, with one line per agent below.
private struct TokenChartCard: View {
    let summary: TokenUsageSummary
    @State private var week = false

    private struct Bar: Identifiable { let id: String; let x: Date; let agent: TokenAgent; let tokens: Int }

    private var bars: [Bar] {
        if week {
            return summary.daily.flatMap { day in
                TokenAgent.allCases.map { Bar(id: "\(day.day)-\($0.rawValue)", x: day.day, agent: $0, tokens: day.tokens[$0] ?? 0) }
            }
        }
        let start = Calendar.current.startOfDay(for: summary.updatedAt)
        return summary.hourly.enumerated().flatMap { hour, values in
            TokenAgent.allCases.map { agent in
                Bar(id: "\(hour)-\(agent.rawValue)", x: start.addingTimeInterval(Double(hour) * 3600), agent: agent, tokens: values[agent] ?? 0)
            }
        }
    }

    private var totals: [TokenAgent: Int] { week ? summary.week : summary.today }

    var body: some View {
        AIUsageCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("", selection: $week) {
                        Text(L10n.text("Today")).tag(false)
                        Text(L10n.text("7 days")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    Spacer()
                    Text(L10n.text(week ? "Per day · tokens" : "Per hour · tokens")).font(Theme.caption).foregroundStyle(Theme.text3)
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Time", bar.x, unit: week ? .day : .hour), y: .value("Tokens", bar.tokens))
                        .foregroundStyle(AIUsagePalette.agent(bar.agent))
                        .cornerRadius(2)
                }
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.separator)
                        AxisValueLabel { if let number = value.as(Int.self) { Text(AIUsageSummaryGrid.tokens(number)) } }
                            .font(Theme.monoCaption).foregroundStyle(Theme.text3)
                    }
                }
                .chartXAxis {
                    if week {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true).font(Theme.caption).foregroundStyle(Theme.text3)
                        }
                    } else {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(String(format: "%02d:00", Calendar.current.component(.hour, from: date)))
                                }
                            }.font(Theme.monoCaption).foregroundStyle(Theme.text3)
                        }
                    }
                }
                .frame(height: 112)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            let total = max(1, totals.values.reduce(0, +))
            VStack(spacing: 8) {
                ForEach(TokenAgent.allCases, id: \.self) { agent in
                    let value = totals[agent] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(AIUsagePalette.agent(agent)).frame(width: 8, height: 8)
                            Text(agent == .claude ? "Claude Code" : "Codex").font(Theme.caption).foregroundStyle(Theme.text1)
                            Spacer()
                            Text(AIUsageSummaryGrid.tokens(value)).font(Font.custom("GeistMono-Medium", fixedSize: 11))
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.memoryTrack)
                                Capsule().fill(AIUsagePalette.agent(agent)).frame(width: geometry.size.width * Double(value) / Double(total))
                            }
                        }.frame(height: 4).padding(.leading, 14)
                        Text(L10n.format("%d%% of the total", Int((Double(value) / Double(total) * 100).rounded())))
                            .font(Theme.caption).foregroundStyle(Theme.text3).padding(.leading, 14)
                    }
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

/// One provider: brand mark, name and plan, the tightest quota as a large figure, then one line per window.
private struct AIUsageQuotaRow: View {
    @ObservedObject var store: AIUsageStore
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = store.snapshot {
                    let windows = snapshot.windows
                    let tightest = windows.max { $0.value.usedPercent < $1.value.usedPercent }
                    HStack(alignment: .top, spacing: 10) {
                        AIProviderMark(provider: store.provider, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.provider.name).font(Font.custom("Geist-SemiBold", fixedSize: 13))
                            subtitle(snapshot, windowCount: windows.count)
                        }
                        Spacer()
                        if let tightest {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(AIUsageView.percent(tightest.value.remainingPercent))
                                    .font(Font.custom("GeistMono-Medium", fixedSize: 18))
                                    .foregroundStyle(tightest.value.usedPercent >= 70 ? AIUsagePalette.health(used: tightest.value.usedPercent) : Theme.text1)
                                Text(AIUsageIssue.compactTitle(tightest.title) + " · " + (tightest.value.resetsAt.map(AIUsageWindowRow.countdown) ?? "—"))
                                    .font(Theme.caption).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                        }
                    }
                    VStack(spacing: 5) {
                        ForEach(windows, id: \.id) { window in
                            AIUsageWindowRow(title: AIUsageIssue.compactTitle(window.title), window: window.value)
                        }
                    }.padding(.leading, 32)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func subtitle(_ snapshot: AIUsageSnapshot, windowCount: Int) -> some View {
        HStack(spacing: 5) {
            if store.state == .stale {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text(L10n.format("Last reading %@", snapshot.updatedAt.formatted(.relative(presentation: .named))))
            } else if let plan = snapshot.labels?["plan"] {
                Circle().fill(AIUsagePalette.green).frame(width: 6, height: 6)
                Text(plan)
            } else {
                Text(L10n.format("%d quotas", windowCount))
            }
        }.font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1)
    }
}

/// A provider without a usable reading: greyed mark, name, and a short reason.
private struct AIUsageIssueRow: View {
    @ObservedObject var store: AIUsageStore
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                AIProviderMark(provider: store.provider, size: 20).grayscale(1).opacity(0.5)
                Text(store.provider.name).font(Font.custom("Geist-Medium", fixedSize: 13)).foregroundStyle(Theme.text2)
                Spacer()
                let issue = AIUsageIssue.describe(store)
                Text(issue.text).font(Theme.caption).foregroundStyle(issue.warns ? Theme.amber : Theme.text2)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((issue.warns ? Theme.amber : Theme.text3).opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(store.issueDetail ?? "")
    }
}

enum AIUsageIssue {
    /// Short window names for the overview: "Session · 5-hour" reads "5 hours", "Total · Monthly quota" reads "Total · Month".
    static func compactTitle(_ title: String) -> String {
        let short = ["5-hour": "5 hours", "Weekly quota": "Week", "Monthly quota": "Month", "Daily quota": "Day"]
        let parts = title.components(separatedBy: " · ").filter { $0 != "Session" }.map { short[$0] ?? $0 }
        return (parts.isEmpty ? [title] : parts).map { L10n.text($0) }.joined(separator: " · ")
    }

    /// Providers without a reading to show go to the attention group; a stale reading stays in the list.
    @MainActor static func needsAttention(_ store: AIUsageStore) -> Bool {
        guard let snapshot = store.snapshot else { return store.state != .refreshing || store.lastAttempt != nil }
        return snapshot.isEstimated
    }

    /// A short reason for the chip. The provider's full message is in the detail page and the tooltip.
    @MainActor static func describe(_ store: AIUsageStore) -> (text: String, warns: Bool) {
        let detail = (store.issueDetail ?? "").lowercased()
        if store.state == .refreshing { return (L10n.text("Querying usage…"), false) }
        if detail.contains("not running") { return (L10n.text("App is not running"), false) }
        if detail.contains("no active") { return (L10n.text("No active plan on this account"), false) }
        if detail.contains("subscription") { return (L10n.text("Subscription stopped; check payment"), true) }
        if detail.contains("api key not set") { return (L10n.text("API key not set"), false) }
        if store.snapshot?.isEstimated == true && store.issue == nil { return (L10n.text("Local estimate only"), true) }
        switch store.issue {
        case .loginRequired?: return (L10n.text("Sign in again"), true)
        case .rateLimited?: return (L10n.text("Rate limited; will retry"), true)
        case .invalidReading?: return (L10n.text("Invalid reading hidden"), true)
        case .timedOut?: return (L10n.text("Query timed out"), true)
        case .helperMissing?: return (L10n.text("Reader missing"), false)
        case .configurationMissing?: return (L10n.text("Not set up"), false)
        case nil where store.lastAttempt == nil: return (L10n.text("Not queried yet."), false)
        default: return (L10n.text("No reading right now"), true)
        }
    }
}

struct AIUsageWindowRow: View {
    let title: String
    let window: AIUsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            AIUsageBar(window: window)
            Text(AIUsageView.percent(window.remainingPercent))
                .font(Theme.monoCaption).foregroundStyle(hasReset ? Theme.text3 : Theme.text1)
                .frame(width: 36, alignment: .trailing)
            Text(window.resetsAt.map(Self.countdown) ?? "—")
                .font(Theme.monoCaption).foregroundStyle(Theme.text3)
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)
                .help(window.resetsAt.map { L10n.format("Resets %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? L10n.text("Reset time unavailable"))
        }.frame(height: 15)
        .opacity(hasReset ? 0.6 : 1)
    }

    /// The window reset after this reading was taken, so its numbers are out of date.
    private var hasReset: Bool { window.resetsAt.map { $0 <= Date() } ?? false }

    /// Time until reset in one unit: minutes under an hour, hours under a day, then days.
    static func countdown(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded(.up))
        if minutes <= 0 { return L10n.text("reset") }
        if minutes < 60 { return L10n.format("%d min", minutes) }
        if minutes < 1440 { return L10n.format("%d h", minutes / 60) }
        return L10n.format("%d d", Int((Double(minutes) / 1440).rounded()))
    }
}

/// Remaining quota as a thin capsule: green while comfortable, amber from 70% used, red from 90%.
/// The tick marks where an even pace would be by now; a bar shorter than the tick is ahead of pace.
struct AIUsageBar: View {
    let window: AIUsageWindow

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.memoryTrack)
                Capsule().fill(AIUsagePalette.health(used: window.usedPercent))
                    .frame(width: max(0, width * window.remainingPercent / 100))
                if let expected = window.expectedUsedPercent(at: Date()) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text2).frame(width: 1.5, height: 10)
                        .offset(x: min(width - 1.5, max(0, width * (100 - expected) / 100 - 0.75)))
                }
            }.frame(height: 4)
            .frame(maxHeight: .infinity)
        }
    }
}

/// The provider's own mark, tinted in its brand colour. Falls back to an initial if the icon is missing.
struct AIProviderMark: View {
    let provider: AIUsageProvider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(provider) {
                Image(nsImage: image).resizable().renderingMode(.template).interpolation(.high)
                    .foregroundStyle(color)
            } else {
                Text(String(provider.name.prefix(1)))
                    .font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color, in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }.frame(width: size, height: size)
    }

    @MainActor private static var cache: [AIUsageProvider: NSImage] = [:]

    @MainActor static func image(_ provider: AIUsageProvider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let name = "provider-\(provider.rawValue)"
        guard let url = L10n.resourceBundle.url(forResource: name, withExtension: "svg")
                ?? L10n.resourceBundle.url(forResource: name, withExtension: "svg", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }

    private var color: Color {
        switch provider {
        case .codex: return Color(red: 0.36, green: 0.42, blue: 0.94)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .cursor: return Theme.text1
        case .opencodego: return Theme.text1
        case .antigravity: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .zai: return Color(red: 0.18, green: 0.36, blue: 1.0)
        case .minimax: return Color(red: 0.91, green: 0.21, blue: 0.38)
        case .kimi: return Theme.text1
        case .stepfun: return Color(red: 0.14, green: 0.26, blue: 1.0)
        }
    }
}
