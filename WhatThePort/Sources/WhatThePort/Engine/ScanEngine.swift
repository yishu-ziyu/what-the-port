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
        "python", "python3", "Python", "uv", "poetry", "pipenv", "uvicorn", "gunicorn",
        "ruby", "bundle", "rails", "go", "air", "cargo", "java", "gradle", "mvn",
        "dotnet", "php", "mix", "beam.smp", "elixir",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    private static let agentNames: Set<String> = ["claude", "codex", "Conductor"]
    /// Path fragments that identify an agent launched via a runtime like node.
    private static let agentPathMarkers = ["@anthropic-ai/claude-code", "com.conductor.app", "/codex/"]

    private let projects = ProjectResolver()
    private let agents = AgentSessionResolver()
    struct Inspector {
        var usage: (pid_t) -> ProcUsage? = ProcessInspector.usage
        var arguments: (pid_t) -> ProcArgs? = ProcessInspector.arguments
        var currentDirectory: (pid_t) -> String? = ProcessInspector.currentDirectory
    }
    private let inspector: Inspector
    init(inspector: Inspector = Inspector()) { self.inspector = inspector }

    private var previousCPU: [pid_t: (start: Date, nanoseconds: UInt64, at: Date)] = [:]
    private var histories: [String: [Sample]] = [:]
    private var lastActive: [String: Date] = [:]
    private var argsCache: [pid_t: (start: Date, args: ProcArgs?)] = [:]
    private var launchdLabels: [pid_t: (start: Date, label: String?)] = [:]

    func scan(_ config: ScanConfig) -> [Server] {
        scan(config, sockets: SocketScanner.scan(), processes: ProcessInspector.allProcesses(), now: Date())
    }

    /// Snapshot inputs keep ownership and sampling testable without real processes.
    func scan(_ config: ScanConfig, sockets: SocketScan, processes: [pid_t: ProcSnapshot], now: Date) -> [Server] {
        let ownership = ProcessTree(processes: processes, sockets: sockets)
        var sampled: [pid_t: (memory: UInt64, cpu: Double)] = [:]

        var servers: [Server] = []
        var seenKeys = Set<String>()
        // Read from launchctl at most once per scan, and only for new launchd jobs.
        var launchdList: [pid_t: String]?
        var livePids = Set<pid_t>()

        for socket in sockets.listening {
            guard socket.port >= config.minPort, socket.port <= config.maxPort,
                  Self.isAllowed(socket.command, in: config.allowlist),
                  let listener = processes[socket.pid] else { continue }

            let service = ownership.service(containing: listener.pid)
            let root = rootProcess(for: listener, in: processes, ownership: ownership, service: service)
            let tree = ownership.descendants(of: root.pid, service: service)
            livePids.formUnion(tree.map { $0.0.pid })

            var memory: UInt64 = 0
            var cpuPercent = 0.0
            var nodes: [ServerProcess] = []
            var starts: [pid_t: Date] = [:]
            for (process, depth) in tree {
                if sampled[process.pid] == nil {
                    let usage = inspector.usage(process.pid)
                    var cpu = 0.0
                    if let usage {
                        if let previous = previousCPU[process.pid], previous.start == process.startTime,
                           usage.cpuNanoseconds >= previous.nanoseconds {
                            let elapsed = now.timeIntervalSince(previous.at)
                            if elapsed > 0 {
                                cpu = Double(usage.cpuNanoseconds - previous.nanoseconds) / (elapsed * 1_000_000_000) * 100
                            }
                        }
                        previousCPU[process.pid] = (process.startTime, usage.cpuNanoseconds, now)
                    } else {
                        previousCPU.removeValue(forKey: process.pid)
                    }
                    sampled[process.pid] = (usage?.footprint ?? 0, cpu)
                }
                let sample = sampled[process.pid]!
                memory += sample.memory
                cpuPercent += sample.cpu
                starts[process.pid] = process.startTime
                nodes.append(ServerProcess(pid: process.pid, name: displayName(for: process), depth: depth,
                                           memory: sample.memory, cpu: sample.cpu))
            }

            let rootArgs = args(for: root)
            let cwd = inspector.currentDirectory(listener.pid) ?? inspector.currentDirectory(root.pid)
            // Framework Python uses Python.app even when launched from a terminal.
            if cwd == "/" || [rootArgs?.executablePath, args(for: listener)?.executablePath]
                .compactMap({ $0 }).contains(where: Self.isInsideApp) {
                continue
            }
            let environment = inheritedEnvironment(from: listener, root: root, in: processes)
            let command = rootArgs.map { Self.prettyCommand($0.arguments, comm: root.comm) }
            var project = projects.resolve(cwd: cwd, command: command)
            if !config.showBranches { project.branch = nil }

            // Restart from the highest process whose argv wasn't overwritten by a
            // title; e.g. the `sh -c "next dev -p 3000"` that npm spawns.
            var launchChain = [listener]
            var ancestor = listener
            while ancestor.pid != root.pid, let parent = processes[ancestor.ppid],
                  !launchChain.contains(where: { $0.pid == parent.pid }) {
                launchChain.append(parent)
                ancestor = parent
            }
            let launcher = launchChain.reversed().first { Self.hasIntactArguments(args(for: $0)) } ?? root

            let brew = brewService(for: root, labels: &launchdList)
            // A service's data folder can sit inside Homebrew's own git checkout,
            // whose branch says nothing about the service. Name it after the service.
            if let brew {
                project.branch = nil
                project.name = brew
            }
            let key = "\(socket.port)-\(root.pid)-\(root.startTime.timeIntervalSince1970)"
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
                launchDirectory: inspector.currentDirectory(launcher.pid) ?? cwd,
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
                isProtected: config.protected.contains(socket.command) || brew != nil,
                brewService: brew
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
        return allowlist.contains { name in
            guard command.hasPrefix(name) else { return false }
            let suffix = String(command.dropFirst(name.count))
            return suffix.range(of: #"^[0-9]*(\.[0-9]+)+$"#, options: .regularExpression) != nil
        }
    }

    /// Whether an executable belongs to a desktop app, whose embedded node or
    /// python backends aren't dev servers. Python's framework builds (Homebrew,
    /// python.org) run from a stub Python.app inside Python.framework, and
    /// Xcode's developer tools include a python3; neither is an app backend.
    static func isInsideApp(_ path: String) -> Bool {
        guard let range = path.range(of: ".app/Contents/") else { return false }
        let bundle = path[..<range.lowerBound]
        let isXcode = bundle.hasSuffix("/Xcode") || bundle.contains("/Xcode-")
        if isXcode && path[range.upperBound...].hasPrefix("Developer/") { return false }
        // Only standard framework Python wrappers are exempt, not frameworks
        // embedded inside arbitrary desktop apps.
        let marker = "/Python.framework/Versions/"
        if let framework = path.range(of: marker),
           !path[..<framework.lowerBound].contains(".app/Contents/") {
            let suffix = path[framework.upperBound...].split(separator: "/")
            if suffix.count == 6, !suffix[0].isEmpty,
               suffix.dropFirst().joined(separator: "/") == "Resources/Python.app/Contents/MacOS/Python" {
                return false
            }
        }
        return true
    }

    // MARK: - Homebrew services

    /// The Homebrew service a launchd job runs as, from its label
    /// (`sh.brew.postgresql@16`). Services like redis overwrite their
    /// environment with a process title, so ask launchd rather than reading
    /// `XPC_SERVICE_NAME`. Cached per process, so launchctl only runs when a
    /// new launchd-started process begins listening, and once for all of them.
    private func brewService(for root: ProcSnapshot, labels: inout [pid_t: String]?) -> String? {
        guard root.ppid == 1 else { return nil }
        if let cached = launchdLabels[root.pid], cached.start == root.startTime {
            return cached.label.flatMap(Self.brewServiceName(forLabel:))
        }
        if labels == nil { labels = Self.launchdLabels(fromList: Self.runLaunchctlList()) }
        let label = labels?[root.pid]
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
    private func rootProcess(for listener: ProcSnapshot, in processes: [pid_t: ProcSnapshot],
                             ownership: ProcessTree, service: Set<pid_t>) -> ProcSnapshot {
        var current = listener
        var visited: Set<pid_t> = [listener.pid]
        while true {
            guard current.ppid > 1, let parent = processes[current.ppid],
                  visited.insert(parent.pid).inserted,
                  !ownership.containsOtherService(below: parent.pid, service: service) else { break }
            if Self.isAllowed(parent.comm, in: Self.runners), !isAgent(parent) {
                current = parent
                continue
            }
            // Package managers run scripts through `sh -c`; step over that shell
            // only when a package manager sits directly above it.
            if Self.shells.contains(parent.comm), parent.ppid > 1,
               let grandparent = processes[parent.ppid],
               Self.isAllowed(grandparent.comm, in: Self.runners), !isAgent(grandparent),
               visited.insert(grandparent.pid).inserted {
                // Keep this service's sh -c command when the package manager
                // above it also supervises other servers.
                if ownership.containsOtherService(below: grandparent.pid, service: service) {
                    current = parent
                    break
                }
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
        let args = inspector.arguments(process.pid)
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
