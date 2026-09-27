import SwiftUI

/// Which apps use the Mac's memory besides dev servers: the largest few, with
/// helper processes folded into their app, then everything else and the dev
/// servers for comparison. Read only: quitting an app could lose unsaved work,
/// so that's left to the app itself.
struct AppsView: View {
    @ObservedObject var monitor: ServerMonitor
    let back: () -> Void

    private let shownApps = 5

    var body: some View {
        let apps = monitor.otherApps
        let top = Array(apps.prefix(shownApps))
        let rest = apps.dropFirst(shownApps)
        let serverProcesses = monitor.servers.reduce(0) { $0 + $1.processes.count }
        VStack(spacing: 0) {
            summary(total: apps.reduce(0) { $0 + $1.memory }, count: apps.count)
            SectionDivider()
            VStack(spacing: 0) {
                ForEach(top) { app in
                    row(name: app.name, detail: L10n.format("%d processes", app.processCount), memory: app.memory) { icon(for: app) }
                }
                if !rest.isEmpty {
                    row(name: L10n.format("%d other apps", rest.count),
                        detail: L10n.format("%d processes", rest.reduce(0) { $0 + $1.processCount }),
                        memory: rest.reduce(0) { $0 + $1.memory }) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                }
                row(name: L10n.text("Servers"), detail: L10n.format("%d processes", serverProcesses), memory: monitor.totalMemory) {
                    Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Totals use Activity Monitor's Memory column, which counts compressed
    /// memory, so they can exceed the RAM in use shown on the servers page.
    private func summary(total: UInt64, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L10n.text("Apps"), back: back)
            HStack(alignment: .center) {
                let amount = Format.total(total)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(amount.number).font(Theme.display).foregroundStyle(Theme.text1)
                        .contentTransition(.numericText())
                    Text(amount.unit).font(Theme.mono).foregroundStyle(Theme.text3)
                }
                Spacer()
                Text(L10n.format("%d apps", count)).font(Theme.mono).foregroundStyle(Theme.text2)
            }
            Text(L10n.text("Measured like Activity Monitor’s Memory column, including compressed memory, so the total can be larger than Other apps."))
                .font(Theme.caption)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 12, leading: Theme.inset, bottom: 16, trailing: Theme.inset))
    }

    private func row<Icon: View>(name: String, detail: String, memory: UInt64, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.bodyMedium).foregroundStyle(Theme.text1).lineLimit(1).help(name)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.bytesString(memory)).font(Theme.mono).foregroundStyle(Theme.text1)
        }
        .padding(.horizontal, Theme.inset)
        .frame(height: 52)
    }

    @ViewBuilder private func icon(for app: AppMemory) -> some View {
        if let path = app.bundlePath {
            Image(nsImage: AppIcons.icon(for: path)).resizable().frame(width: 20, height: 20)
        } else if let agent = app.agent {
            AgentGlyph(kind: agent, size: 14, color: Theme.text1)
        } else {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
    }
}
