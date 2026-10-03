import SwiftUI

struct AIUsageDashboard: View {
    @ObservedObject var catalog: AIUsageCatalog
    var refreshOnAppear = true
    @State private var selected: AIUsageProvider?
    @State private var refreshingAll = false

    var body: some View {
        ScrollView {
            if let selected {
                AIUsageView(store: catalog.store(for: selected), startsInDetail: true, onBack: { self.selected = nil })
                    .id(selected)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("AI usage")).font(Theme.displaySans)
                        Spacer()
                        Button { Task { await refreshAll() } } label: {
                            Label(L10n.text("Refresh all"), systemImage: "arrow.clockwise").font(Theme.caption)
                        }.buttonStyle(.plain).disabled(refreshingAll)
                    }
                    Text(L10n.text("Each provider uses its own quota periods."))
                        .font(Theme.caption).foregroundStyle(Theme.text3)
                    ForEach(catalog.stores, id: \.provider) { store in
                        AIUsageProviderCard(store: store) { selected = store.provider }
                    }
                }.padding(Theme.inset)
            }
        }
        .frame(height: 490)
        .task {
            // Once per page appearance; independent states remain visible throughout the query.
            if refreshOnAppear && catalog.stores.contains(where: { $0.snapshot.map { Date().timeIntervalSince($0.updatedAt) > 60 } ?? true }) {
                await refreshAll()
            }
        }
    }

    private func refreshAll() async {
        guard !refreshingAll else { return }
        refreshingAll = true
        await catalog.refreshAll()
        refreshingAll = false
    }
}

private struct AIUsageProviderCard: View {
    @ObservedObject var store: AIUsageStore
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(store.provider.name).font(Theme.bodyMedium)
                    Spacer()
                    if store.state == .refreshing { ProgressView().controlSize(.small) }
                    Image(systemName: "chevron.right").font(Theme.caption)
                }
                if let snapshot = store.snapshot {
                    if store.state == .stale {
                        Text(L10n.text("Cached reading. Refresh to update.")).foregroundStyle(Theme.amber)
                    }
                    if snapshot.isEstimated {
                        Text(L10n.text("Local estimate, not a provider measurement.")).foregroundStyle(Theme.amber)
                        Text(L10n.text("Remaining quota unavailable")).foregroundStyle(Theme.text2)
                    } else {
                        ForEach(snapshot.windows, id: \.id) { window in
                            HStack(alignment: .firstTextBaseline) {
                                Text(AIUsageView.localizedTitle(window.title)).foregroundStyle(Theme.text2)
                                Spacer()
                                Text(AIUsageView.percent(window.value.remainingPercent) + " " + L10n.text("remaining"))
                                    .font(Theme.mono)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Text(L10n.text("Last successful reading:"))
                        Text(snapshot.updatedAt, style: .time)
                    }.foregroundStyle(Theme.text3)
                } else {
                    Text(L10n.text(store.state == .refreshing ? "Querying usage…" :
                                    store.state == .loginRequired ? "Sign in again to query usage." :
                                    store.issue == .timedOut ? "Query timed out. Try refreshing." :
                                    "No valid reading yet. Try refreshing."))
                        .foregroundStyle(Theme.text2)
                }
            }.font(Theme.caption)
                .padding(12).background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
