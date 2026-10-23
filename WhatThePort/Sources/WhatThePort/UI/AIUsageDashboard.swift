import SwiftUI

struct AIUsageDashboard: View {
    @ObservedObject var catalog: AIUsageCatalog
    var refreshOnAppear = true
    @State private var selected: AIUsageProvider?

    var body: some View {
        ScrollView {
            if let selected {
                AIUsageView(store: catalog.store(for: selected), startsInDetail: true, onBack: { self.selected = nil })
                    .id(selected)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    AIUsageHeader(catalog: catalog)
                        .padding(.bottom, 6)
                    ForEach(Array(catalog.stores.enumerated()), id: \.element.provider) { index, store in
                        if index > 0 { Rectangle().fill(Theme.separator).frame(height: 0.5) }
                        AIUsageProviderSection(store: store) { selected = store.provider }
                    }
                }.padding(Theme.inset)
            }
        }
        .frame(height: 490)
        .environment(\.locale, L10n.locale)
        .onAppear { catalog.isVisible = refreshOnAppear }
        .onDisappear { catalog.isVisible = false }
        .task { if refreshOnAppear { catalog.startSchedule() } }
    }
}

private struct AIUsageHeader: View {
    @ObservedObject var catalog: AIUsageCatalog

    private var latest: Date? { catalog.stores.compactMap { $0.snapshot?.updatedAt }.max() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("AI usage")).font(Font.custom("Geist-Medium", fixedSize: 15))
            Spacer()
            if catalog.refreshingAll || catalog.stores.contains(where: { $0.state == .refreshing }) {
                ProgressView().controlSize(.mini)
            } else if let latest {
                Text(L10n.format("Updated %@", latest.formatted(date: .omitted, time: .shortened)))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
            }
            Button { Task { await catalog.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise").font(Theme.caption).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.plain).disabled(catalog.refreshingAll)
            .help(L10n.text("Refresh all"))
        }
    }
}

/// One provider: a name row, then one row per quota window (name, bar, remaining, time to reset).
/// A provider without a usable reading shows one line saying why instead of numbers.
private struct AIUsageProviderSection: View {
    @ObservedObject var store: AIUsageStore
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AIProviderMark(provider: store.provider)
                    Text(store.provider.name).font(Theme.bodyMedium)
                    Spacer()
                    if let note = statusNote {
                        Text(note.text).font(Theme.caption).foregroundStyle(note.color).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text3)
                }
                if let snapshot = store.snapshot, !snapshot.isEstimated {
                    ForEach(snapshot.windows, id: \.id) { window in
                        AIUsageWindowRow(title: AIUsageView.localizedTitle(window.title), window: window.value)
                    }
                } else if let message = emptyMessage {
                    Text(message.text).font(Theme.caption).foregroundStyle(message.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = store.issueDetail, store.state != .refreshing {
                        Text(reason).font(Theme.caption).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Short note next to the name for a reading that is shown but not current.
    private var statusNote: (text: String, color: Color)? {
        guard let snapshot = store.snapshot, !snapshot.isEstimated, store.state == .stale else { return nil }
        let age = snapshot.updatedAt.formatted(.relative(presentation: .named))
        return (L10n.format("Last reading %@", age), Date().timeIntervalSince(snapshot.updatedAt) > 86_400 ? Theme.amber : Theme.text3)
    }

    private var emptyMessage: (text: String, color: Color)? {
        if store.snapshot?.isEstimated == true {
            return (L10n.text("Only a local estimate; the provider returned no quota."), Theme.amber)
        }
        switch store.state {
        case .refreshing: return (L10n.text("Querying usage…"), Theme.text3)
        case .loginRequired: return (L10n.text("Sign in again or check the subscription."), Theme.amber)
        default: break
        }
        switch store.issue {
        case .invalidReading?: return (L10n.text("The provider returned an invalid reading; it is not shown."), Theme.red)
        case .rateLimited?: return (L10n.text("Rate limited by the provider. Will retry later."), Theme.amber)
        case .configurationMissing?: return (L10n.text("Not set up. Open to see what is missing."), Theme.text3)
        case .timedOut?: return (L10n.text("Query timed out. Try refreshing."), Theme.amber)
        case .helperMissing?: return (L10n.text("Usage reader is not installed in this build."), Theme.text3)
        case nil where store.lastAttempt == nil: return (L10n.text("Not queried yet."), Theme.text3)
        default: return (L10n.text("No valid reading yet. Try refreshing."), Theme.amber)
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
                .frame(width: 104, alignment: .leading)
            AIUsageBar(window: window)
            Text(AIUsageView.percent(window.remainingPercent))
                .font(Theme.monoCaption).foregroundStyle(hasReset ? Theme.text3 : Theme.text1)
                .frame(width: 38, alignment: .trailing)
            Text(window.resetsAt.map(Self.countdown) ?? "—")
                .font(Theme.monoCaption).foregroundStyle(Theme.text3)
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)
                .help(window.resetsAt.map { L10n.format("Resets %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? L10n.text("Reset time unavailable"))
        }.frame(height: 18)
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

/// Remaining quota as a capsule. Grey while comfortable, amber from 70% used, red from 90%.
/// The tick marks where an even pace would be by now; a bar shorter than the tick is ahead of pace.
struct AIUsageBar: View {
    let window: AIUsageWindow

    static func color(used: Double) -> Color {
        used >= 90 ? Theme.red : used >= 70 ? Theme.amber : Theme.text3
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.memoryTrack)
                Capsule().fill(Self.color(used: window.usedPercent))
                    .frame(width: max(0, width * window.remainingPercent / 100))
                if let expected = window.expectedUsedPercent(at: Date()) {
                    Rectangle().fill(Theme.text2).frame(width: 1.5, height: 10)
                        .offset(x: min(width - 1.5, max(0, width * (100 - expected) / 100 - 0.75)))
                }
            }.frame(height: 5)
            .frame(maxHeight: .infinity)
        }
    }
}

/// A coloured initial standing in for the provider's brand mark.
struct AIProviderMark: View {
    let provider: AIUsageProvider

    var body: some View {
        Text(initial)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    private var initial: String {
        switch provider {
        case .codex: return "C"
        case .claude: return "A"
        case .cursor: return "Cu"
        case .opencodego: return "O"
        case .antigravity: return "G"
        case .zai: return "Z"
        case .minimax: return "M"
        case .kimi: return "K"
        case .stepfun: return "S"
        }
    }

    private var color: Color {
        switch provider {
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .cursor: return Color(white: 0.15)
        case .opencodego: return Color(white: 0.42)
        case .antigravity: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .zai: return Color(red: 0.24, green: 0.35, blue: 1.0)
        case .minimax: return Color(red: 0.90, green: 0.28, blue: 0.30)
        case .kimi: return Color(white: 0.08)
        case .stepfun: return Color(red: 0.36, green: 0.42, blue: 1.0)
        }
    }
}
