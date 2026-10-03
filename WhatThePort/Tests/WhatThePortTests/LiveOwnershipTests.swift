import Foundation
import Testing
@testable import WhatThePort

/// Real sockets and processes exercise the same scan/stop path as the app.
struct LiveOwnershipTests {
    @Test func stoppingOneServiceKeepsItsSiblingAndSharedPortsCountOnce() throws {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        let node = candidates.first(where: FileManager.default.isExecutableFile)
        let nodePath = try #require(node, "Node is required for the live ownership regression")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.cjs")
        let output = directory.appendingPathComponent("ready.json")
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: nodePath)
        parent.arguments = [script.path, output.path]
        parent.currentDirectoryURL = directory
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: output.path) { Thread.sleep(forTimeInterval: 0.05) }
        struct Ready: Decodable {
            struct Worker: Decodable { let pid: pid_t; let ports: [Int] }
            let parent: pid_t
            let workers: [Worker]
        }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: output))
        let single = try #require(ready.workers.first { $0.ports.count == 1 })
        let shared = try #require(ready.workers.first { $0.ports.count == 2 })
        let engine = ScanEngine()
        let config = ScanConfig(minPort: 3000, maxPort: 65535, allowlist: ["node"],
                                linkClaude: false, linkCodex: false, linkConductor: false, showBranches: false)
        let ports = Set(single.ports + shared.ports)
        let rows = engine.scan(config).filter { ports.contains($0.port) }
        try #require(rows.count == 3)
        let target = try #require(rows.first { $0.port == single.ports[0] })
        // Never signal a process unless the scanner owns exactly our fixture worker.
        try #require(Set(target.processStarts.keys) == [single.pid])
        let sharedRows = rows.filter { shared.ports.contains($0.port) }
        #expect(sharedRows.count == 2)
        try #require(sharedRows.count == 2)
        try #require(sharedRows.allSatisfy { Set($0.processStarts.keys) == [shared.pid] })
        #expect(ServerResources(rows).memory == target.memory + sharedRows[0].memory)
        #expect(ServerResources(sharedRows).memoryByPort.values.reduce(0, +) == Double(sharedRows[0].memory))
        ProcessControl.stop(target)
        for _ in 0..<100 where ProcessInspector.snapshot(single.pid) != nil { Thread.sleep(forTimeInterval: 0.05) }
        let afterStop = engine.scan(config).filter { ports.contains($0.port) }
        #expect(Set(afterStop.map(\.port)) == Set(shared.ports))
        #expect(ProcessInspector.snapshot(ready.parent) != nil)
        #expect(ProcessInspector.snapshot(shared.pid) != nil)
        // Ensure the delayed force-stop has also run without harming the sibling.
        Thread.sleep(forTimeInterval: ProcessControl.forceQuitDelay + 0.1)
        #expect(ProcessInspector.snapshot(shared.pid) != nil)
        ProcessControl.stop(sharedRows[0])
        for _ in 0..<100 where ProcessInspector.snapshot(shared.pid) != nil { Thread.sleep(forTimeInterval: 0.05) }
        #expect(engine.scan(config).allSatisfy { !ports.contains($0.port) })
        #expect(ProcessInspector.snapshot(ready.parent) != nil)
        Thread.sleep(forTimeInterval: ProcessControl.forceQuitDelay + 0.1)
    }

    private let fixture = """
    const fs = require('fs');
    const http = require('http');
    const { fork } = require('child_process');
    const output = process.argv[2];
    if (process.argv[3] === 'worker') {
      const count = Number(process.argv[4]);
      const ports = [];
      for (let i = 0; i < count; i++) {
        http.createServer((req, res) => res.end('fixture-ok')).listen(0, '127.0.0.1', function () {
          ports.push(this.address().port);
          if (ports.length === count) process.send({ pid: process.pid, ports });
        });
      }
    } else {
      setInterval(() => {}, 1000); // keep the orchestrator alive after workers exit
      const workers = [1, 2].map(count => fork(__filename, [output, 'worker', String(count)], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] }));
      const rows = [];
      workers.forEach(worker => worker.on('message', row => {
        rows.push(row);
        if (rows.length === workers.length) fs.writeFileSync(output, JSON.stringify({ parent: process.pid, workers: rows }));
      }));
      const shutdown = () => { workers.forEach(worker => worker.kill()); process.exit(); };
      process.on('SIGTERM', shutdown);
      process.on('SIGINT', shutdown);
    }
    """
}
