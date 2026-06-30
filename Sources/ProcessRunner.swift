import Foundation

// MARK: - Short-lived process runner (app layer)
//
// One place for the spawn-with-watchdog pattern shared by SessionMonitor and
// SessionJumper: run a short-lived command, kill it if it hangs so the caller's
// serial queue can't wedge, and discard stderr to /dev/null (an undrained stderr
// pipe could block on >64 KB). NOT part of CCCostCore — this is impure process
// I/O. UsageScriptClient stays separate (its own SIGTERM/SIGKILL escalation +
// long timeout); QuotaService.runSecurity stays separate (no watchdog by design).
//
// MUST be called off the main thread (it blocks on the child). Returns
// (exitStatus, raw stdout) or nil on launch failure / non-UTF-8 output. Callers
// do their own trimming.
enum ProcessRunner {
    static func run(_ launchPath: String, _ args: [String],
                    timeout: TimeInterval = 5.0) -> (status: Int32, output: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        // Discard stderr to /dev/null (NOT a Pipe): an undrained Pipe whose child
        // writes >64 KB would block, stalling the caller's serial queue until the
        // watchdog fires.
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return (task.terminationStatus, out)
    }
}
