import SwiftUI

/// Both presentations render the store's actual returned windows, never fixed demo values.
struct AIUsageView: View {
    @ObservedObject var store: AIUsageStore
    @State private var detail = false
    private let refreshOnAppear: Bool
    private let onBack: (() -> Void)?
    @AppStorage("aiUsage.displayMode") private var displayMode = "pace"

    init(store: AIUsageStore, startsInDetail: Bool = false, defaults: UserDefaults = .standard, refreshOnAppear: Bool = true, onBack: (() -> Void)? = nil) {
        self.onBack = onBack
        self.store = store
        self.refreshOnAppear = refreshOnAppear
        _detail = State(initialValue: startsInDetail)
        _displayMode = AppStorage(wrappedValue: "pace", "aiUsage.displayMode", store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if detail {
                Button { if let onBack { onBack() } else { detail = false } } label: {
                    Label(L10n.text("All providers"), systemImage: "chevron.left")
                        .font(Theme.caption).foregroundStyle(Theme.text2)
                }.buttonStyle(.plain)
            }
            HStack {
                Text(detail ? store.provider.name : L10n.text("AI usage")).font(Theme.displaySans)
                Spacer()
                if store.state == .refreshing { ProgressView().controlSize(.small) }
            }
            if let snapshot = store.snapshot {
                if store.state == .stale {
                    Text(L10n.text(store.issue == nil
                                   ? "Cached reading. Refresh to update."
                                   : "Connection failed. Showing the last successful reading."))
                        .font(Theme.caption).foregroundStyle(Theme.amber)
                    if let reason = store.issueDetail {
                        Text(L10n.format("Reason: %@", reason)).font(Theme.caption).foregroundStyle(Theme.text3).textSelection(.enabled)
                    }
                }
                if snapshot.isEstimated {
                    Text(L10n.text("Local estimate, not a provider measurement."))
                        .font(Theme.caption).foregroundStyle(Theme.amber)
                }
                if snapshot.isEstimated {
                    Text(L10n.text("Local records cannot establish remaining quota. Refresh after signing in to the provider dashboard."))
                        .font(Theme.body).foregroundStyle(Theme.text2)
                } else if detail {
                    Picker(L10n.text("Display mode"), selection: $displayMode) {
                        Text(L10n.text("Pace")).tag("pace")
                        Text(L10n.text(snapshot.windows.count > 1 ? "Rings" : "Ring")).tag("rings")
                    }.pickerStyle(.segmented)
                    if displayMode == "rings" {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: snapshot.windows.count > 1 ? 2 : 1), spacing: 20) {
                            ForEach(snapshot.windows, id: \.id) { window in
                                ring(window.value, title: window.title)
                            }
                        }.frame(maxWidth: .infinity)
                    } else {
                        ForEach(snapshot.windows, id: \.id) { window in
                            pace(window.value, title: window.title)
                        }
                    }
                    ForEach(Array((snapshot.details ?? []).enumerated()), id: \.offset) { _, detail in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(detail.title).font(Theme.bodyMedium)
                            ForEach(Array(detail.rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text(row.label); Spacer(); Text(row.value) }
                                    if let secondary = row.secondaryValue { Text(secondary).foregroundStyle(Theme.text3) }
                                }.font(Theme.caption)
                            }
                        }.padding(.vertical, 8)
                    }
                    Text(L10n.text("Only quota windows returned by the provider are shown."))
                        .font(Theme.caption).foregroundStyle(Theme.text3)
                } else {
                    Button { detail = true } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(store.provider.name).font(Theme.bodyMedium)
                                Spacer()
                                Image(systemName: "chevron.right").font(Theme.caption)
                            }
                            ForEach(snapshot.windows, id: \.id) { window in
                                HStack {
                                    Text(Self.localizedTitle(window.title)).foregroundStyle(Theme.text2)
                                    Spacer()
                                    Text(Self.percent(window.value.remainingPercent) + " " + L10n.text("remaining"))
                                        .font(Theme.mono)
                                }.font(Theme.body)
                                reset(window.value)
                            }
                        }.padding(12).background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("Source: %@ · collected account", snapshot.source.uppercased()))
                    HStack(spacing: 4) {
                        Text(L10n.text("Last successful reading:"))
                        Text(snapshot.updatedAt, style: .time)
                        Text(snapshot.updatedAt, style: .relative)
                        Text(L10n.text("ago"))
                    }
                }.font(Theme.caption).foregroundStyle(Theme.text3)
            } else {
                Text(emptyMessage).font(Theme.body).foregroundStyle(Theme.text2)
                if let reason = store.issueDetail {
                    Text(L10n.format("Reason: %@", reason)).font(Theme.caption).foregroundStyle(Theme.text3).textSelection(.enabled)
                }
                if store.state == .loginRequired {
                    Text(L10n.format("Check %@ login or query credentials, then refresh. Other logins are not changed.", store.provider.name))
                        .font(Theme.caption).foregroundStyle(Theme.text3)
                }
            }
            SectionDivider()
            HStack {
                Text(L10n.text("Live provider data, not local task cost."))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise").font(Theme.body)
                }.buttonStyle(.plain).disabled(store.state == .refreshing)
            }
        }
        .padding(Theme.inset)
        .environment(\.locale, L10n.locale)
        .onAppear { if displayMode != "pace" && displayMode != "rings" { displayMode = "pace" } }
        .task {
            if refreshOnAppear && (store.snapshot.map({ Date().timeIntervalSince($0.updatedAt) > 60 }) ?? true) {
                await store.refresh()
            }
        }
    }

    private var emptyMessage: String {
        if store.state == .refreshing { return L10n.text("Querying usage…") }
        if store.state == .loginRequired { return L10n.text("Sign in again to query usage.") }
        if store.issue == .configurationMissing { return L10n.text("Provider configuration is unavailable.") }
        if store.issue == .timedOut { return L10n.text("Query timed out. Try refreshing.") }
        if store.issue == .helperMissing { return L10n.text("Usage reader is not installed in this build.") }
        if store.issue == .invalidReading { return L10n.text("The provider returned an invalid reading; it is not shown.") }
        if store.issue == .rateLimited { return L10n.text("Rate limited by the provider. Will retry later.") }
        return L10n.text("No valid reading yet. Try refreshing.")
    }

    private func reset(_ window: AIUsageWindow) -> some View {
        Group {
            if let date = window.resetsAt {
                HStack(spacing: 4) {
                    Text(L10n.text("Resets:"))
                    Text(date, style: .date)
                    Text(date, style: .time)
                }
            } else { Text(L10n.text("Reset time unavailable")) }
        }.font(Theme.caption).foregroundStyle(Theme.text2)
    }

    private func pace(_ window: AIUsageWindow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.localizedTitle(title)).font(Theme.bodyMedium)
            HStack(alignment: .firstTextBaseline) {
                Text(Self.percent(window.remainingPercent)).font(Theme.display)
                Text(L10n.text("remaining")).font(Theme.caption).foregroundStyle(Theme.text2)
            }
            reset(window)
            GeometryReader { geometry in
                let expected = window.expectedUsedPercent(at: Date())
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.portColor(at: 0))
                        .frame(width: geometry.size.width * window.usedPercent / 100)
                    if let expected {
                        Rectangle().fill(Theme.text1).frame(width: 2, height: 16)
                            .offset(x: min(geometry.size.width - 2, geometry.size.width * expected / 100))
                    }
                }
            }.frame(height: 7)
            HStack {
                Text(L10n.format("Used %@", Self.percent(window.usedPercent)))
                Spacer()
                if let expected = window.expectedUsedPercent(at: Date()) {
                    Text(L10n.format("Even budget %@", String(format: "%.1f%%", expected)))
                }
            }.font(Theme.caption).foregroundStyle(Theme.text2)
            if let expected = window.expectedUsedPercent(at: Date()) {
                let delta = window.usedPercent - expected
                Text(L10n.format(delta > 0 ? "%.1f points ahead of even pace" : "%.1f points behind even pace", abs(delta)))
                    .font(Theme.caption).foregroundStyle(delta > 0 ? Theme.amber : Theme.text2)
            } else {
                Text(L10n.text("Not enough timing data to calculate pace."))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
            }
        }.padding(.vertical, 8)
    }

    private func ring(_ window: AIUsageWindow, title: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.fill, lineWidth: 6)
                Circle().trim(from: 0, to: window.remainingPercent / 100)
                    .stroke(Theme.portColor(at: title == "Weekly quota" ? 1 : 0), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Self.percent(window.remainingPercent)).font(Theme.display)
            }.frame(width: 128, height: 128)
            Text(Self.localizedTitle(title) + " · " + L10n.text("remaining")).font(Theme.caption)
            reset(window)
        }.frame(maxWidth: .infinity)
    }

    static func localizedTitle(_ title: String) -> String {
        title.components(separatedBy: " · ").map { L10n.text($0) }.joined(separator: " · ")
    }

    static func percent(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        if value > 99 && value < 100 { return ">99%" }
        return String(format: "%.0f%%", value)
    }
}
