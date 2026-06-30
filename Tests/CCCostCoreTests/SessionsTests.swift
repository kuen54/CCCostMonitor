import Foundation
import Testing
@testable import CCCostCore

@Suite struct SessionsTests {

    private func parse(_ s: String) -> SessionInfo? {
        SessionLogic.parse(jsonData: Data(s.utf8))
    }

    // MARK: - Defensive decode

    @Test func decodeFullInteractiveSession() {
        let s = parse("""
        {"pid":36442,"sessionId":"78e060d0-d5b3-487d-9dd6-b2adce031902",
         "cwd":"/Users/x/blindbox","startedAt":1782381204774,"version":"2.1.178",
         "kind":"interactive","entrypoint":"cli","status":"idle",
         "updatedAt":1782382017812,"statusUpdatedAt":1782382017812}
        """)
        #expect(s != nil)
        #expect(s?.pid == 36442)
        #expect(s?.status == .idle)
        #expect(s?.cwd == "/Users/x/blindbox")
        #expect(s?.entrypoint == "cli")
        #expect(s?.shortId == "78e060d0")
        #expect(s?.updatedAt == 1782382017812)
    }

    @Test func unknownStatusDecodesToUnknown() {
        let s = parse(#"{"pid":1,"sessionId":"a","cwd":"/x","status":"hibernating","entrypoint":"cli"}"#)
        #expect(s?.status == .unknown)
    }

    @Test func missingStatusDecodesToUnknown() {
        let s = parse(#"{"pid":1,"sessionId":"a","cwd":"/x","entrypoint":"sdk-cli"}"#)
        #expect(s != nil)
        #expect(s?.status == .unknown)
        #expect(s?.entrypoint == "sdk-cli")
    }

    @Test func extraUnknownKeysAreIgnored() {
        let s = parse("""
        {"pid":7,"sessionId":"b","cwd":"/x","status":"busy","entrypoint":"cli",
         "peerProtocol":1,"bridgeSessionId":null,"someFutureField":{"nested":true},
         "anotherNew":[1,2,3]}
        """)
        #expect(s?.status == .busy)
        #expect(s?.pid == 7)
    }

    @Test func missingPidIsSkipped() {
        #expect(parse(#"{"sessionId":"a","cwd":"/x","status":"idle","entrypoint":"cli"}"#) == nil)
    }

    @Test func missingSessionIdIsSkipped() {
        #expect(parse(#"{"pid":3,"cwd":"/x","status":"idle","entrypoint":"cli"}"#) == nil)
    }

    @Test func garbageBytesAreSkipped() {
        #expect(parse("not json at all") == nil)
        #expect(parse("") == nil)
    }

    @Test func wrongTypedOptionalDoesNotCrashIdentityKept() {
        // version sent as a number, cwd missing — identity still decodes, the
        // bad/absent optionals degrade gracefully.
        let s = parse(#"{"pid":9,"sessionId":"c","version":123,"status":"shell","entrypoint":"cli"}"#)
        #expect(s != nil)
        #expect(s?.pid == 9)
        #expect(s?.cwd == "")
        #expect(s?.version == nil)
        #expect(s?.status == .shell)
    }

    @Test func waitReasonMapping() {
        func reason(_ status: String, _ waiting: String?) -> SessionWaitReason? {
            let w = waiting.map { #","waitingFor":"\#($0)""# } ?? ""
            return parse(#"{"pid":1,"sessionId":"a","cwd":"/x","status":"\#(status)","entrypoint":"cli"\#(w)}"#)?.waitReason
        }
        #expect(reason("waiting", "permission prompt") == .needsConfirmation)
        #expect(reason("waiting", "input needed") == .needsInput)
        #expect(reason("waiting", "dialog open") == .needsInput)
        #expect(reason("waiting", "sandbox request") == .needsInput)
        #expect(reason("waiting", "worker request") == .needsInput)
        #expect(reason("waiting", "something new") == .needsInput) // forward-compat
        #expect(reason("busy", nil) == nil)                        // only while waiting
    }

    // MARK: - listable filter

    @Test func listableExcludesSdkCli() {
        let cli = SessionInfo(pid: 1, sessionId: "a", cwd: "/x", status: .idle, entrypoint: "cli")
        let sdk = SessionInfo(pid: 2, sessionId: "b", cwd: "/x", status: .unknown, entrypoint: "sdk-cli")
        #expect(SessionLogic.listable(cli) == true)
        #expect(SessionLogic.listable(sdk) == false)
    }

    @Test func listableExcludesUnknownStatusAndOtherEntrypoints() {
        let noStatus = SessionInfo(pid: 1, sessionId: "a", cwd: "/x", status: .unknown, entrypoint: "cli")
        let weird = SessionInfo(pid: 2, sessionId: "b", cwd: "/x", status: .busy, entrypoint: "vscode")
        #expect(SessionLogic.listable(noStatus) == false)
        #expect(SessionLogic.listable(weird) == false)
    }

    // MARK: - grouping

    @Test func basenameCollisionKeepsDistinctGroups() {
        let s1 = SessionInfo(pid: 1, sessionId: "a", cwd: "/Users/x/work/app", status: .idle,
                             updatedAt: 100, entrypoint: "cli")
        let s2 = SessionInfo(pid: 2, sessionId: "b", cwd: "/Users/y/other/app", status: .idle,
                             updatedAt: 200, entrypoint: "cli")
        let groups = SessionLogic.grouped([s1, s2])
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.label == "app" })  // same basename
        #expect(Set(groups.map { $0.cwd }) == ["/Users/x/work/app", "/Users/y/other/app"])
    }

    @Test func groupingMergesSameCwd() {
        let s1 = SessionInfo(pid: 1, sessionId: "a", cwd: "/x", status: .idle, updatedAt: 100, entrypoint: "cli")
        let s2 = SessionInfo(pid: 2, sessionId: "b", cwd: "/x", status: .busy, updatedAt: 50, entrypoint: "cli")
        let groups = SessionLogic.grouped([s1, s2])
        #expect(groups.count == 1)
        #expect(groups[0].sessions.count == 2)
        // Busy sorts first within the group even though its updatedAt is older.
        #expect(groups[0].sessions.first?.status == .busy)
        #expect(groups[0].anyBusy == true)
    }

    @Test func busyGroupsSortFirstThenByRecency() {
        let idleOld = SessionInfo(pid: 1, sessionId: "a", cwd: "/idle-old", status: .idle, updatedAt: 10, entrypoint: "cli")
        let idleNew = SessionInfo(pid: 2, sessionId: "b", cwd: "/idle-new", status: .idle, updatedAt: 90, entrypoint: "cli")
        let busy = SessionInfo(pid: 3, sessionId: "c", cwd: "/busy", status: .busy, updatedAt: 20, entrypoint: "cli")
        let groups = SessionLogic.grouped([idleOld, idleNew, busy])
        #expect(groups.map { $0.cwd } == ["/busy", "/idle-new", "/idle-old"])
    }

    @Test func groupingIsDeterministic() {
        let a = SessionInfo(pid: 1, sessionId: "a", cwd: "/x", status: .idle, updatedAt: 100, entrypoint: "cli")
        let b = SessionInfo(pid: 2, sessionId: "b", cwd: "/x", status: .idle, updatedAt: 100, entrypoint: "cli")
        // Equal updatedAt → tiebreak on sessionId, so order is stable across inputs.
        #expect(SessionLogic.grouped([a, b]) == SessionLogic.grouped([b, a]))
    }

    // MARK: - Otty pane matching (Phase 4)

    private func pane(_ id: String, _ cwd: String, _ title: String) -> OttyPane {
        OttyPane(id: id, cwd: cwd, title: title)
    }

    @Test func normalizeStripsClaudeGlyphAndSpinner() {
        // ✳ idle glyph and Braille spinner frames are stripped; CJK kept.
        #expect(SessionLogic.normalizeOttyTitle("✳ Add notch display mode") == "Add notch display mode")
        #expect(SessionLogic.normalizeOttyTitle("⠂ Add notch display mode") == "Add notch display mode")
        #expect(SessionLogic.normalizeOttyTitle("⠐ 调研爬虫反风控技术") == "调研爬虫反风控技术")
        #expect(SessionLogic.normalizeOttyTitle("查询 toy_series 不同值") == "查询 toy_series 不同值")
        // Symmetric: a glyphed pane title normalizes equal to a plain session title.
        #expect(SessionLogic.normalizeOttyTitle("✳ X") == SessionLogic.normalizeOttyTitle("X"))
    }

    @Test func matchTitlePlusCwdUniqueIsExact() {
        // cwd shared by several panes — title disambiguates to one.
        let panes = [
            pane("p1", "/Users/x", "✳ Chinese astrology"),
            pane("p2", "/Users/x", "✳ Crawler research"),
            pane("p3", "/Users/x", "⠂ Individual finance plan"),
        ]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x", title: "Crawler research", panes: panes)
                == .exact(paneId: "p2"))
    }

    @Test func matchTitleCollisionAcrossCwdResolvesByCwdCrossCheck() {
        // The SAME title appears in two different cwds — the cwd cross-check
        // (only panes sharing the session's cwd are considered) picks the right one.
        let panes = [
            pane("p1", "/Users/x/a", "✳ Build feature"),
            pane("p2", "/Users/x/b", "✳ Build feature"),
            pane("p3", "/Users/x/b", "✳ Something else"),
        ]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x/b", title: "Build feature", panes: panes)
                == .exact(paneId: "p2"))
    }

    @Test func matchTitleAbsentFallsBackToCwdUnique() {
        // No title → behaves exactly as before: unique cwd → exact.
        let panes = [pane("p1", "/Users/x/solo", "whatever")]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x/solo", title: nil, panes: panes)
                == .exact(paneId: "p1"))
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x/solo", title: "", panes: panes)
                == .exact(paneId: "p1"))
    }

    @Test func matchManualRenameSharedCwdIsAmbiguous() {
        // User renamed the panes, so the session title matches NO pane; cwd is
        // shared by several → degrade honestly to ambiguous (app-activate).
        let panes = [
            pane("p1", "/Users/x/mia", "热量识别探数-1"),
            pane("p2", "/Users/x/mia", "热量识别探数-2"),
        ]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x/mia",
                title: "优化餐品热量识别的分层库方案", panes: panes) == .ambiguous)
    }

    @Test func matchNoPaneInCwdIsNone() {
        let panes = [pane("p1", "/Users/x/a", "t")]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x/zzz", title: "t", panes: panes) == .none)
    }

    @Test func matchGlyphedPaneMatchesPlainSessionTitle() {
        // Pane title carries a busy spinner; session aiTitle is plain — normalize
        // both and they join.
        let panes = [
            pane("p1", "/Users/x", "⠂ Add notch display mode with hover popup"),
            pane("p2", "/Users/x", "✳ Unrelated"),
        ]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x",
                title: "Add notch display mode with hover popup", panes: panes)
                == .exact(paneId: "p1"))
    }

    @Test func matchTitleBeatsCwdAmbiguity() {
        // Five panes share the cwd (like the live /Users/lijiakun): cwd-alone is
        // ambiguous, but the ai-title resolves the exact pane.
        let panes = [
            pane("p1", "/Users/x", "✳ A"), pane("p2", "/Users/x", "✳ B"),
            pane("p3", "/Users/x", "✳ C"), pane("p4", "/Users/x", "✳ D"),
            pane("p5", "/Users/x", "✳ E"),
        ]
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x", title: "C", panes: panes)
                == .exact(paneId: "p3"))
        #expect(SessionLogic.matchOttyPane(cwd: "/Users/x", title: nil, panes: panes)
                == .ambiguous)
    }

    // MARK: - Done-unseen reducer (Phase 2)

    private func sess(_ id: String, _ status: SessionStatus) -> SessionInfo {
        SessionInfo(pid: 1, sessionId: id, cwd: "/x", status: status, entrypoint: "cli")
    }

    @Test func justFinishedBusyToIdleMarks() {
        #expect(SessionLogic.justFinished(previous: ["a": .busy], current: [sess("a", .idle)]) == ["a"])
    }

    @Test func justFinishedWaitingToIdleMarks() {
        #expect(SessionLogic.justFinished(previous: ["a": .waiting], current: [sess("a", .idle)]) == ["a"])
    }

    @Test func justFinishedBusyToShellMarks() {
        #expect(SessionLogic.justFinished(previous: ["a": .busy], current: [sess("a", .shell)]) == ["a"])
    }

    @Test func justFinishedIdleToIdleDoesNot() {
        #expect(SessionLogic.justFinished(previous: ["a": .idle], current: [sess("a", .idle)]).isEmpty)
    }

    @Test func justFinishedBusyToBusyDoesNot() {
        #expect(SessionLogic.justFinished(previous: ["a": .busy], current: [sess("a", .busy)]).isEmpty)
    }

    @Test func justFinishedFirstSeenIdleDoesNot() {
        // No previous entry → first observation, not a finish.
        #expect(SessionLogic.justFinished(previous: [:], current: [sess("a", .idle)]).isEmpty)
    }

    @Test func stepMarksFinishedAndAdvancesPrev() {
        let (prev, done) = SessionLogic.stepDoneUnseen(
            prev: ["a": .busy], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 100)
        #expect(done["a"] == 100)
        #expect(prev["a"] == .idle)
    }

    @Test func stepIdleToIdleDoesNotMark() {
        let (_, done) = SessionLogic.stepDoneUnseen(
            prev: ["a": .idle], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 1)
        #expect(done.isEmpty)
    }

    @Test func stepFirstSeenIdleDoesNotMark() {
        let (_, done) = SessionLogic.stepDoneUnseen(
            prev: [:], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 1)
        #expect(done.isEmpty)
    }

    @Test func stepGoingBusyAgainClears() {
        var (prev, done) = SessionLogic.stepDoneUnseen(
            prev: ["a": .busy], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 100)
        #expect(done["a"] == 100)
        (prev, done) = SessionLogic.stepDoneUnseen(
            prev: prev, current: [sess("a", .busy)],
            doneUnseen: done, seenAll: false, now: 110)
        #expect(done.isEmpty)                       // active again → cue cleared
    }

    @Test func stepDisappearanceClears() {
        let (_, done0) = SessionLogic.stepDoneUnseen(
            prev: ["a": .busy], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 1)
        #expect(done0["a"] == 1)
        let (_, done1) = SessionLogic.stepDoneUnseen(
            prev: ["a": .idle], current: [],
            doneUnseen: done0, seenAll: false, now: 2)
        #expect(done1.isEmpty)                      // session gone → cue cleared
    }

    @Test func stepPersistsAcrossIdleScansAndLargeElapsed() {
        // A finished session that stays idle/shell never auto-expires: it survives
        // many idle→idle scans and an arbitrarily large elapsed `now`.
        var (prev, done) = SessionLogic.stepDoneUnseen(
            prev: ["a": .busy], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 0)
        #expect(done["a"] == 0)
        // Many subsequent idle→idle scans, each advancing `now`.
        for t in 1...20 {
            (prev, done) = SessionLogic.stepDoneUnseen(
                prev: prev, current: [sess("a", .idle)],
                doneUnseen: done, seenAll: false, now: Double(t))
            #expect(done["a"] == 0)                  // still pending, finishedAt unchanged
        }
        // A single scan with a huge elapsed time (10 hours) — still no expiry.
        (prev, done) = SessionLogic.stepDoneUnseen(
            prev: prev, current: [sess("a", .idle)],
            doneUnseen: done, seenAll: false, now: 10 * 3600)
        #expect(done["a"] == 0)
        // Even shell (also a "done" status) keeps it.
        (_, done) = SessionLogic.stepDoneUnseen(
            prev: prev, current: [sess("a", .shell)],
            doneUnseen: done, seenAll: false, now: 100 * 3600)
        #expect(done["a"] == 0)
    }

    @Test func stepSeenAllClearsButAdvancesPrev() {
        let (_, done0) = SessionLogic.stepDoneUnseen(
            prev: ["a": .busy], current: [sess("a", .idle)],
            doneUnseen: [:], seenAll: false, now: 1)
        #expect(done0["a"] == 1)
        let (prev1, done1) = SessionLogic.stepDoneUnseen(
            prev: ["a": .idle], current: [sess("a", .idle)],
            doneUnseen: done0, seenAll: true, now: 2)
        #expect(done1.isEmpty)
        #expect(prev1["a"] == .idle)                // prev still advances on seenAll
    }

    // MARK: - Terminal classification helpers

    @Test func appBundlePathSlicesAtDotAppBoundary() {
        #expect(SessionLogic.appBundlePath(fromExecPath: "/Applications/Otty.app/Contents/MacOS/Otty")
                == "/Applications/Otty.app")
        // A trailing ".app" with no slash after it.
        #expect(SessionLogic.appBundlePath(fromExecPath: "/Applications/Otty.app") == "/Applications/Otty.app")
        // Must NOT mis-slice a directory that merely contains ".app" mid-name.
        #expect(SessionLogic.appBundlePath(fromExecPath: "/Users/foo.apptest/bin/term") == nil)
        #expect(SessionLogic.appBundlePath(fromExecPath: "/usr/bin/login") == nil)
    }

    @Test func isMultiplexerMatchesTmuxAndScreen() {
        #expect(SessionLogic.isMultiplexer(comm: "tmux"))
        #expect(SessionLogic.isMultiplexer(comm: "/usr/local/bin/tmux"))
        #expect(SessionLogic.isMultiplexer(comm: "tmux: server"))
        #expect(SessionLogic.isMultiplexer(comm: "screen"))
        #expect(SessionLogic.isMultiplexer(comm: "screen-256color"))
        #expect(!SessionLogic.isMultiplexer(comm: "-zsh"))
        #expect(!SessionLogic.isMultiplexer(comm: "/Applications/Otty.app/Contents/MacOS/Otty"))
    }

    @Test func classifyTerminalByBundleName() {
        #expect(SessionLogic.classifyTerminal(commPath: "/Applications/Otty.app/Contents/MacOS/Otty") == .otty)
        #expect(SessionLogic.classifyTerminal(commPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty") == .ghostty)
        #expect(SessionLogic.classifyTerminal(commPath: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == .iterm2)
        #expect(SessionLogic.classifyTerminal(commPath: "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui") == .wezterm)
        #expect(SessionLogic.classifyTerminal(commPath: "/Applications/kitty.app/Contents/MacOS/kitty") == .kitty)
        // Apple Terminal is matched LAST so its generic bundle can't shadow others.
        #expect(SessionLogic.classifyTerminal(commPath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == .appleTerminal)
        #expect(SessionLogic.classifyTerminal(commPath: "/usr/bin/login") == .unknown)
    }

    @Test func devTTYNormalizesAndRejectsNone() {
        #expect(SessionLogic.devTTY("ttys000") == "/dev/ttys000")
        #expect(SessionLogic.devTTY("/dev/ttys003") == "/dev/ttys003")
        #expect(SessionLogic.devTTY("??") == nil)
        #expect(SessionLogic.devTTY("") == nil)
        #expect(SessionLogic.devTTY(nil) == nil)
    }

    // MARK: - ps / proc table parsing

    @Test func parsePsLineSplitsLstartAndSpacedComm() throws {
        let p = try #require(SessionLogic.parsePsLine("  5185 Wed Jun 24 21:38:58 2026 /path/to/claude"))
        #expect(p.pid == 5185)
        #expect(p.lstart == "Wed Jun 24 21:38:58 2026")
        #expect(p.comm == "/path/to/claude")
    }

    @Test func parsePsLineSingleDigitDayStillFiveTokens() throws {
        // ps pads a single-digit day with an extra space; empty tokens are omitted.
        let p = try #require(SessionLogic.parsePsLine("42 Wed Jun  4 21:38:58 2026 /Applications/My App.app/x"))
        #expect(p.pid == 42)
        #expect(p.lstart == "Wed Jun 4 21:38:58 2026")
        #expect(p.comm == "/Applications/My App.app/x")   // comm keeps embedded spaces
    }

    @Test func parsePsLineRejectsShortOrNonNumeric() {
        #expect(SessionLogic.parsePsLine("not enough tokens here") == nil)
        #expect(SessionLogic.parsePsLine("xx Wed Jun 24 21:38:58 2026 /bin/claude") == nil)
        #expect(SessionLogic.parsePsLine("") == nil)
    }

    @Test func parseProcTableKeepsSpacedCommSkipsBadRows() {
        let out = """
          1 0 ?? /sbin/launchd
        100 1 ?? /Applications/My App.app/Contents/MacOS/My App
        bad row skip
        200 100 ttys001 -zsh
        """
        let t = SessionLogic.parseProcTable(out)
        #expect(t[1]?.comm == "/sbin/launchd")
        #expect(t[100]?.comm == "/Applications/My App.app/Contents/MacOS/My App")
        #expect(t[200]?.ppid == 100)
        #expect(t[200]?.tty == "ttys001")
        #expect(t.count == 3)   // "bad row skip" dropped (non-int ppid)
    }

    // MARK: - ppid-chain targeting

    private func row(_ ppid: Int, _ tty: String, _ comm: String) -> SessionLogic.ProcRow {
        SessionLogic.ProcRow(ppid: ppid, tty: tty, comm: comm)
    }

    @Test func resolveTargetWalksToOwningApp() {
        let table: [Int: SessionLogic.ProcRow] = [
            500: row(400, "ttys002", "/opt/homebrew/bin/claude"),
            400: row(300, "ttys002", "-zsh"),
            300: row(1, "??", "/Applications/Otty.app/Contents/MacOS/Otty"),
        ]
        let pt = SessionLogic.resolveTarget(table: table, pid: 500)
        #expect(pt.tty == "ttys002")
        #expect(pt.terminal == .otty)
        #expect(pt.appBundlePath == "/Applications/Otty.app")
        #expect(pt.appPid == 300)
        #expect(pt.multiplexed == false)
        #expect(pt.pidPresent == true)
    }

    @Test func resolveTargetFlagsMultiplexerAncestor() {
        let table: [Int: SessionLogic.ProcRow] = [
            5: row(4, "ttys000", "/bin/claude"),
            4: row(3, "ttys000", "tmux: server"),
            3: row(1, "??", "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ]
        let pt = SessionLogic.resolveTarget(table: table, pid: 5)
        #expect(pt.multiplexed == true)
        #expect(pt.terminal == .iterm2)
    }

    @Test func resolveTargetMissingPidIsNotPresent() {
        let pt = SessionLogic.resolveTarget(table: [:], pid: 999)
        #expect(pt.pidPresent == false)
        #expect(pt.tty == nil)
        #expect(pt.terminal == .unknown)
        #expect(pt.appPid == nil)
    }

    @Test func resolveTargetNoAppAncestorIsUnknownButPresent() {
        let table: [Int: SessionLogic.ProcRow] = [
            10: row(1, "ttys009", "/bin/claude"),  // parent is launchd, no .app
        ]
        let pt = SessionLogic.resolveTarget(table: table, pid: 10)
        #expect(pt.pidPresent == true)
        #expect(pt.tty == "ttys009")
        #expect(pt.terminal == .unknown)
        #expect(pt.appBundlePath == nil)
    }

    // MARK: - Otty pane JSON parsing

    @Test func parseOttyPanesSkipsIncompleteEntries() throws {
        let json = """
        {"data":[
          {"id":"p1","cwd":"/a","process":"✳ Title"},
          {"id":"p2","cwd":"/b"},
          {"cwd":"/c","process":"no id"},
          {"id":"p4","process":"no cwd"}
        ]}
        """
        let panes = try #require(SessionLogic.parseOttyPanes(json))
        #expect(panes.count == 2)
        #expect(panes[0] == OttyPane(id: "p1", cwd: "/a", title: "✳ Title"))
        #expect(panes[1] == OttyPane(id: "p2", cwd: "/b", title: ""))   // missing process → ""
    }

    @Test func parseOttyPanesRejectsWrongShape() {
        #expect(SessionLogic.parseOttyPanes("not json") == nil)
        #expect(SessionLogic.parseOttyPanes("[]") == nil)                 // no top-level "data"
        #expect(SessionLogic.parseOttyPanes("{\"data\":{}}") == nil)      // data not an array
    }

    // MARK: - Status dot priority

    @Test func dotKindPriority() {
        #expect(SessionLogic.dotKind(status: .busy, doneUnseen: true) == .busy)      // busy wins over done
        #expect(SessionLogic.dotKind(status: .waiting, doneUnseen: true) == .waiting) // waiting wins over done
        #expect(SessionLogic.dotKind(status: .idle, doneUnseen: true) == .doneUnseen)
        #expect(SessionLogic.dotKind(status: .shell, doneUnseen: true) == .doneUnseen)
        #expect(SessionLogic.dotKind(status: .unknown, doneUnseen: true) == .doneUnseen) // reducer keeps green on idle→unknown
        #expect(SessionLogic.dotKind(status: .idle, doneUnseen: false) == .grey)
        #expect(SessionLogic.dotKind(status: .unknown, doneUnseen: false) == .grey)
    }
}
