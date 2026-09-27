import Foundation
import Testing
@testable import WhatThePort

struct ScanFilterTests {
    @Test func versionedInterpretersMatchTheirPlainName() {
        let allowlist: Set<String> = ["python", "python3", "node", "ruby"]
        #expect(ScanEngine.isAllowed("python3", in: allowlist))
        #expect(ScanEngine.isAllowed("python3.13", in: allowlist))
        #expect(ScanEngine.isAllowed("ruby3.3", in: allowlist))
        #expect(!ScanEngine.isAllowed("perl5.34", in: allowlist))
        #expect(!ScanEngine.isAllowed("node22", in: allowlist))
        #expect(!ScanEngine.isAllowed("3.13", in: allowlist))
    }

    @Test func pythonFrameworkBuildsAreNotApps() {
        #expect(!ScanEngine.isInsideApp("/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"))
        #expect(!ScanEngine.isInsideApp("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"))
        #expect(!ScanEngine.isInsideApp("/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"))
        #expect(!ScanEngine.isInsideApp("/opt/homebrew/bin/node"))
    }

    @Test func rootStopsAtAParentServingAnotherPort() {
        // Fake pids well above the system limit, so no real process arguments are read.
        func process(_ pid: pid_t, _ ppid: pid_t, _ comm: String) -> ProcSnapshot {
            ProcSnapshot(pid: pid, ppid: ppid, comm: comm, startTime: Date())
        }
        let processes: [pid_t: ProcSnapshot] = [
            900_001: process(900_001, 900_000, "zsh"),
            900_002: process(900_002, 900_001, "node"),   // dev tool serving 7678
            900_003: process(900_003, 900_002, "node"),   // its worker
            900_004: process(900_004, 900_003, "Python"), // preview it spawned on 8793
            900_011: process(900_011, 900_001, "npm"),    // npm run dev
            900_012: process(900_012, 900_011, "node"),   // vite on 5173
        ]
        let listening: [pid_t: Set<Int>] = [900_002: [7678], 900_004: [8793], 900_012: [5173]]
        let engine = ScanEngine()
        #expect(engine.rootProcess(for: processes[900_004]!, port: 8793, in: processes, listeningPorts: listening).pid == 900_003)
        #expect(engine.rootProcess(for: processes[900_012]!, port: 5173, in: processes, listeningPorts: listening).pid == 900_011)
    }

    @Test func appBackendsAreStillApps() {
        #expect(ScanEngine.isInsideApp("/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app/Contents/Frameworks/Doubao Browser Framework.framework/Versions/147.0.7727.149/Helpers/Doubao Browser Helper.app/Contents/MacOS/Doubao Browser Helper"))
        #expect(ScanEngine.isInsideApp("/Applications/Cursor.app/Contents/Resources/app/node_modules/node"))
        #expect(ScanEngine.isInsideApp("/Applications/Some.app/Contents/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"))
        #expect(ScanEngine.isInsideApp("/Applications/Xcode.app/Contents/MacOS/Xcode"))
    }

    @Test func homebrewServicesComeFromLaunchdLabels() {
        let output = "PID\tStatus\tLabel\n2741\t0\thomebrew.mxcl.postgresql@16\n-\t0\thomebrew.mxcl.nginx\n2708\t0\thomebrew.mxcl.redis\n636\t0\tcom.apple.rapportd\n"
        let labels = ScanEngine.launchdLabels(fromList: output)
        #expect(labels == [2741: "homebrew.mxcl.postgresql@16", 2708: "homebrew.mxcl.redis", 636: "com.apple.rapportd"])
        #expect(ScanEngine.brewServiceName(forLabel: "homebrew.mxcl.postgresql@16") == "postgresql@16")
        #expect(ScanEngine.brewServiceName(forLabel: "sh.brew.nginx") == "nginx")
        #expect(ScanEngine.brewServiceName(forLabel: "com.apple.rapportd") == nil)
        #expect(ScanEngine.brewServiceName(forLabel: "homebrew.mxcl.") == nil)
        #expect(ScanEngine.brewServiceName(forLabel: "sh.brew.") == nil)
    }
}
