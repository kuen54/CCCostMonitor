import Foundation

// MARK: - analyze_usage.py invocation
//
// Owns script/interpreter discovery and the Process spawn (including the
// SIGTERM→SIGKILL timeout machinery). Deliberately does NOT own any queueing:
// UsageStore's serial scriptQueue + coalescing/generation logic remain the
// single concurrency authority — this struct is only ever called from inside
// that queue's work items.
struct UsageScriptClient {
    let scriptPath: String
    let pythonPath: String

    init() {
        if let bundled = Bundle.main.path(forResource: "analyze_usage", ofType: "py") {
            scriptPath = bundled
        } else {
            scriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(
                ".claude/skills/local-cc-cost/scripts/analyze_usage.py"
            )
        }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        pythonPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"
    }

    func runScript(_ args: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + args
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Kill scans that hang (e.g. Python wedged on a dead network mount) so the
            // serial script queue can't be blocked forever. Scheduled on a global queue
            // because this thread is about to block reading the pipe. A SIGTERM'd scan
            // exits nonzero and falls into the existing failure path below.
            let timeoutItem = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
                // Escalate: SIGTERM can be ignored/queued by a wedged process, which
                // would block the serial script queue (and all future refreshes)
                // forever behind readDataToEndOfFile. SIGKILL is uncatchable.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeoutItem)
            // Read pipe BEFORE waitUntilExit to avoid deadlock when output > 64KB
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutItem.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}
