import Foundation

struct ScanConfig {
    var minPort: Int
    var maxPort: Int
    var allowlist: Set<String>
    var protected: Set<String> = Set(Preferences.defaultProtected)
    var linkClaude = true
    var linkCodex = true
    var linkConductor = true
    var showBranches = true
}

/// Builds the list of servers from sockets and the process table. Holds the
/// state that has to persist between scans (CPU deltas, history, caches), so it
/// must only be used from one serial queue.
final class ScanEngine: @unchecked Sendable {
    static let historyWindow: TimeInterval = 10 * 60

    /// Processes that sit between a shell and the actual server, e.g. `npm run dev`.
    private static let runners: Set<String> = [
        "node", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "turbo", "nx",
        "python", "python3", "Python", "uv", "poetry", "pipenv",
        "ruby", "bundle", "rails", "go", "air", "cargo", "java", "gradle", "mvn",
        "dotnet", "php", "mix", "beam.smp", "elixir",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    private static let agentNames: Set<String> = ["claude", "codex", "Conductor"]
    /// Path fragments that identify an agent launched via a runtime like node.
    private static let agentPathMarkers = ["@anthropic-ai/claude-code", "com.conductor.app", "/codex/"]

    private let projects = ProjectResolver()
    private let agents = AgentSessionResolver()
    private var previousCPU: [pid_t: (nanoseconds: UInt64, at: Date)] = [:]
    private var histories: [String: [Sample]] = [:]
    private var lastActive: [String: Date] = [:]
    private var argsCache: [pid_t: (start: Date, args: ProcArgs?)] = [:]
    private var launchdLabels: [pid_t: (start: Date, label: String?)] = [:]

    func scan(_ config: ScanConfig) -> [Server] {
        let now = Date()
        let sockets = SocketScanner.scan()
        let processes = ProcessInspector.allProcesses()

        var children: [pid_t: [pid_t]] = [:]
        for process in processes.values { children[process.ppid, default: []].append(process.pid) }
        var listeningPorts: [pid_t: Set<Int>] = [:]
        for socket in sockets.listening { listeningPorts[socket.pid, default: []].insert(socket.port) }

        var servers: [Server] = []
        var seenKeys = Set<String>()
        var livePids = Set<pid_t>()

        for socket in sockets.listening {
            guard socket.port >= config.minPort, socket.port <= config.maxPort,
                  Self.isAllowed(socket.command, in: config.allowlist),
                  let listener = processes[socket.pid] else { continue }

            let root = rootProcess(for: listener, port: socket.port, in: processes, listeningPorts: listeningPorts)
            let tree = descendants(of: root.pid, children: children, processes: processes)
            livePids.formUnion(tree.map { $0.0.pid })

            var memory: UInt64 = 0
            var cpuPercent = 0.0
            var nodes: [ServerProcess] = []
            var starts: [pid_t: Date] = [:]
            for (process, depth) in tree {
                let usage = ProcessInspector.usage(process.pid)
                let footprint = usage?.footprint ?? 0
                memory += footprint
                if let usage {
                    if let previous = previousCPU[process.pid], usage.cpuNanoseconds >= previous.nanoseconds {
                        let elapsed = now.timeIntervalSince(previous.at)
                        if elapsed > 0 {
                            cpuPercent += Double(usage.cpuNanoseconds - previous.nanoseconds) / (elapsed * 1_000_000_000) * 100
                        }
                    }
                    previousCPU[process.pid] = (usage.cpuNanoseconds, now)
                }
                starts[process.pid] = process.startTime
                nodes.append(ServerProcess(pid: process.pid, name: displayName(for: process), depth: depth, memory: footprint))
            }

            let rootArgs = args(for: root)
            let cwd = ProcessInspector.currentDirectory(listener.pid) ?? ProcessInspector.currentDirectory(root.pid)
            // Apps that embed a node or python backend aren't dev servers.
            if cwd == "/" || [rootArgs?.executablePath, args(for: listener)?.executablePath].contains(where: { $0.map(Self.isInsideApp) == true }) {
                continue
            }
            let environment = inheritedEnvironment(from: listener, root: root, in: processes)
            let command = rootArgs.map { Self.prettyCommand($0.arguments, comm: root.comm) }
            var project = projects.resolve(cwd: cwd, command: command)
            if !config.showBranches { project.branch = nil }

            // Restart from the highest process whose argv wasn't overwritten by a
            // title; e.g. the `sh -c "next dev -p 3000"` that npm spawns.
            let launcher = tree.map(\.0).first { Self.hasIntactArguments(args(for: $0)) } ?? root

            let service = brewService(for: root)
            let key = "\(socket.port)-\(root.pid)"
            seenKeys.insert(key)
            let connections = sockets.inboundConnections[socket.port] ?? 0
            if cpuPercent >= 2 || connections > 0 || lastActive[key] == nil {
                lastActive[key] = now
            }

            var history = histories[key] ?? []
            history.append(Sample(time: now, memory: memory, cpu: cpuPercent))
            history.removeAll { now.timeIntervalSince($0.time) > Self.historyWindow }
            histories[key] = history

            servers.append(Server(
                port: socket.port,
                pid: listener.pid,
                rootPid: root.pid,
                processName: socket.command,
                addresses: socket.addresses,
                cwd: cwd,
                cwdExists: cwd.map { FileManager.default.fileExists(atPath: $0) } ?? true,
                command: command,
                launch: args(for: launcher),
                launchDirectory: ProcessInspector.currentDirectory(launcher.pid) ?? cwd,
                startedAt: root.startTime,
                project: project,
                conductorWorkspace: config.linkConductor ? environment["CONDUCTOR_WORKSPACE_NAME"] : nil,
                agent: agents.resolve(environment: environment, cwd: cwd, claude: config.linkClaude, codex: config.linkCodex),
                processes: nodes,
                processStarts: starts,
                memory: memory,
                cpu: cpuPercent,
                connections: connections,
                history: history,
                lastActive: lastActive[key] ?? now,
                // Homebrew services are managed like databases: kept out of
                // Clean up and alerts, and stopped only after confirmation.
                isProtected: config.protected.contains(socket.command) || service != nil,
                brewService: service
            ))
        }

        histories = histories.filter { seenKeys.contains($0.key) }
        lastActive = lastActive.filter { seenKeys.contains($0.key) }
        previousCPU = previousCPU.filter { livePids.contains($0.key) }
        argsCache = argsCache.filter { processes[$0.key] != nil }
        launchdLabels = launchdLabels.filter { processes[$0.key] != nil }
        return servers
    }

    // MARK: - Filters

    /// Interpreters can report their version in the process name
    /// (`python3.13`), so a dotted version also matches the plain name.
    static func isAllowed(_ command: String, in allowlist: Set<String>) -> Bool {
        if allowlist.contains(command) { return true }
        guard let range = command.range(of: #"[0-9]+(\.[0-9]+)+$"#, options: .regularExpression),
              range.lowerBound > command.startIndex else { return false }
        return allowlist.contains(String(command[..<range.lowerBound]))
    }

    /// Whether an executable belongs to a desktop app, whose embedded node or
    /// python backends aren't dev servers. Python's framework builds (Homebrew,
    /// python.org) run from a stub Python.app inside Python.framework, and
    /// Xcode's developer tools include a python3; neither is an app backend.
    static func isInsideApp(_ path: String) -> Bool {
        guard let range = path.range(of: ".app/Contents/") else { return false }
        let bundle = path[..<range.lowerBound]
        if bundle.contains(".framework/") { return false }
        let isXcode = bundle.hasSuffix("/Xcode") || bundle.contains("/Xcode-")
        return !(isXcode && path[range.upperBound...].hasPrefix("Developer/"))
    }

    // MARK: - Homebrew services

    /// The Homebrew service a launchd job runs as, from its label
    /// (`sh.brew.postgresql@16`). Services like redis overwrite their
    /// environment with a process title, so ask launchd rather than reading
    /// `XPC_SERVICE_NAME`. Cached per process, so launchctl only runs when a
    /// new launchd-started process begins listening.
    private func brewService(for root: ProcSnapshot) -> String? {
        guard root.ppid == 1 else { return nil }
        if let cached = launchdLabels[root.pid], cached.start == root.startTime {
            return cached.label.flatMap(Self.brewServiceName(forLabel:))
        }
        let label = Self.launchdLabels(fromList: Self.runLaunchctlList())[root.pid]
        launchdLabels[root.pid] = (root.startTime, label)
        return label.flatMap(Self.brewServiceName(forLabel:))
    }

    /// Homebrew labels services `sh.brew.<name>`; services started by older
    /// versions keep `homebrew.mxcl.<name>` until they're restarted.
    static func brewServiceName(forLabel label: String) -> String? {
        for prefix in ["sh.brew.", "homebrew.mxcl."] where label.hasPrefix(prefix) && label.count > prefix.count {
            return String(label.dropFirst(prefix.count))
        }
        return nil
    }

    /// Parses `launchctl list`: a header, then `PID<tab>Status<tab>Label` rows,
    /// with `-` for jobs that aren't running.
    static func launchdLabels(fromList output: String) -> [pid_t: String] {
        var labels: [pid_t: String] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2)
            guard columns.count == 3, let pid = pid_t(columns[0]) else { continue }
            labels[pid] = String(columns[2])
        }
        return labels
    }

    private static func runLaunchctlList() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Process tree

    /// Climbs from the listening process to the command the user actually ran,
    /// e.g. from `next-server` up to `npm run dev`. Stops at shells, terminals
    /// and coding agents so stopping a server never takes its launcher with it.
    /// Also stops at a parent serving another port: that's a separate server
    /// (e.g. a dev tool that spawns previews), and stopping this one mustn't stop it.
    func rootProcess(for listener: ProcSnapshot, port: Int, in processes: [pid_t: ProcSnapshot],
                     listeningPorts: [pid_t: Set<Int>]) -> ProcSnapshot {
        var current = listener
        while true {
            guard current.ppid > 1, let parent = processes[current.ppid] else { break }
            if let ports = listeningPorts[parent.pid], !ports.contains(port) { break }
            if Self.runners.contains(parent.comm), !isAgent(parent) {
                current = parent
                continue
            }
            // Package managers run scripts through `sh -c`; step over that shell
            // only when a package manager sits directly above it.
            if Self.shells.contains(parent.comm), parent.ppid > 1,
               let grandparent = processes[parent.ppid],
               Self.runners.contains(grandparent.comm), !isAgent(grandparent) {
                current = grandparent
                continue
            }
            break
        }
        return current
    }

    private func isAgent(_ process: ProcSnapshot) -> Bool {
        if Self.agentNames.contains(process.comm) { return true }
        guard let args = args(for: process) else { return false }
        let joined = ([args.executablePath] + args.arguments.prefix(3)).joined(separator: " ")
        return Self.agentPathMarkers.contains(where: joined.contains)
    }

    private func descendants(of root: pid_t, children: [pid_t: [pid_t]], processes: [pid_t: ProcSnapshot]) -> [(ProcSnapshot, Int)] {
        guard let rootProcess = processes[root] else { return [] }
        var result: [(ProcSnapshot, Int)] = []
        func visit(_ process: ProcSnapshot, depth: Int) {
            result.append((process, depth))
            for child in (children[process.pid] ?? []).sorted() {
                if let childProcess = processes[child] { visit(childProcess, depth: depth + 1) }
            }
        }
        visit(rootProcess, depth: 0)
        return result
    }

    /// Merges environments from the listener up through its launcher. Tools that
    /// rename their process (Next.js sets `process.title = "next-server"`)
    /// overwrite the memory their environment is read from, so the session
    /// variables often only survive on a parent like `npm`.
    private func inheritedEnvironment(from listener: ProcSnapshot, root: ProcSnapshot, in processes: [pid_t: ProcSnapshot]) -> [String: String] {
        var chain: [ProcSnapshot] = [listener]
        var current = listener
        var extraHops = 2
        while current.ppid > 1, let parent = processes[current.ppid], chain.count < 10 {
            if current.pid == root.pid || chain.contains(where: { $0.pid == root.pid }) {
                guard extraHops > 0 else { break }
                extraHops -= 1
            }
            chain.append(parent)
            current = parent
        }
        var environment: [String: String] = [:]
        for process in chain.reversed() {
            environment.merge(args(for: process)?.environment ?? [:]) { _, closer in closer }
        }
        return environment
    }

    private static func hasIntactArguments(_ args: ProcArgs?) -> Bool {
        guard let args else { return false }
        let parts = args.arguments.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.count > 1 || (parts.count == 1 && !parts[0].contains(" "))
    }

    private func args(for process: ProcSnapshot) -> ProcArgs? {
        if let cached = argsCache[process.pid], cached.start == process.startTime { return cached.args }
        let args = ProcessInspector.arguments(process.pid)
        argsCache[process.pid] = (process.startTime, args)
        return args
    }

    // MARK: - Names

    private func displayName(for process: ProcSnapshot) -> String {
        guard let args = args(for: process), !args.arguments.isEmpty else { return process.comm }
        let command = Self.prettyCommand(args.arguments, comm: process.comm)
        // `process.title` renames like "next-server (v16.0.0)" read better without the version.
        if let paren = command.range(of: " (") { return String(command[..<paren.lowerBound]) }
        return command
    }

    /// Turns raw argv into what someone would have typed, e.g.
    /// `node /…/npm-cli.js run dev` becomes `npm run dev`.
    static func prettyCommand(_ arguments: [String], comm: String) -> String {
        let arguments = arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = arguments.first else { return comm }
        var parts = arguments
        let executable = (first as NSString).lastPathComponent

        if executable == "node" || executable == "bun" || executable == "deno", parts.count > 1 {
            let script = parts[1]
            let tools = ["npm", "npx", "pnpm", "yarn", "vite", "next", "astro", "nuxt", "storybook", "tsx", "turbo"]
            if let tool = tools.first(where: { script.contains("/\($0)/") || script.contains("/\($0)-cli") || (script as NSString).lastPathComponent == $0 }) {
                parts = [tool] + parts.dropFirst(2)
            } else if script.hasPrefix("/") || script.hasPrefix(".") {
                parts = [(script as NSString).lastPathComponent] + parts.dropFirst(2)
            }
        } else {
            parts[0] = executable
        }
        return parts.map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }.joined(separator: " ")
    }
}
