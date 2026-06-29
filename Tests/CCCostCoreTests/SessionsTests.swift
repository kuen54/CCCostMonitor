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
}
