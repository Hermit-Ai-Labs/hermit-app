import XCTest
@testable import HermitUI
import HermitCore

/// AppModel and toast logic: project.md reaching the model, site approvals, stale links, the batch follow-up and the
/// toast kind. No network, nothing written to disk (snapshot mode turns saving off).

/// Records what the model would get for its system prompt.
private final class RecordingAgent: Agent, @unchecked Sendable {
    var contexts: [[String]] = []
    func reply(to prompt: String) -> AsyncStream<AgentEvent> { AsyncStream { cont in cont.finish() } }
    func reset() {}
    func setContext(name: String, memory: [String]) { contexts.append(memory) }
}

@MainActor
final class ShellLogicTests: XCTestCase {

    private func makeModel(_ agent: RecordingAgent = RecordingAgent()) -> AppModel {
        let was = SnapshotMode.active
        SnapshotMode.active = true
        defer { SnapshotMode.active = was }
        return AppModel(agent: agent)
    }

    func testProjectInstructionsReachTheModel() {
        let agent = RecordingAgent()
        let m = makeModel(agent)
        m.addProject(name: "Yield", template: "DeFi yield", budget: 0)
        m.projectMD["Yield"] = "# Yield\n\nOnly stablecoins.\n\nReply in one line."
        m.newChat(project: "Yield")
        XCTAssertEqual(agent.contexts.last?.first, "This chat is in the user's project Yield. Follow its instructions (project.md): Only stablecoins. Reply in one line.")

        // The placeholder text and a chat outside the project send no project note.
        let note = { (ctx: [String]?) -> Bool in (ctx ?? []).contains { $0.hasPrefix("This chat is in the user's project") } }
        m.newChat(project: nil)
        XCTAssertFalse(note(agent.contexts.last))
        if let p = m.project("Yield") { m.projectMD["Yield"] = p.defaultInstructions }
        m.newChat(project: "Yield")
        XCTAssertFalse(note(agent.contexts.last))
    }

    func testSiteApprovalsAreNotChatCards() {
        let site = Approval(kind: "Transaction from app.uniswap.org", title: "Approve USDC", lines: [], checks: [], success: "Sent to Base")
        let connect = Approval(kind: "Connect a site", title: "Connect to app.uniswap.org", lines: [], checks: [], success: "Connected")
        let chat = Approval(kind: "Send on Base", title: "Approve USDC", lines: [], checks: [], success: "Sent")
        XCTAssertTrue(AppModel.fromSite(site))
        XCTAssertTrue(AppModel.fromSite(connect))
        XCTAssertFalse(AppModel.fromSite(chat))

        let m = makeModel()
        m.approved(site, hash: "0xabc")
        XCTAssertFalse(m.approvedIDs.contains("Approve USDC"))
    }

    func testUnknownLinkOpensNothing() {
        let m = makeModel()
        m.run(Action("Review", open: "some-old-link"))
        XCTAssertNil(m.fundGoal)
        m.run(Action("Add funds", open: "fund-wallet"))
        XCTAssertNotNil(m.fundGoal)
    }

    func testSavingAnAutomationTwiceKeepsItsRuns() {
        let m = makeModel()
        m.addAutomation(Automation(name: "Quests", trigger: "When you run it", action: "Finish quests", limit: "", on: false, last: "Not run yet"))
        m.automations[0].thread.append(Message(role: .assistant, text: "Sent to Hermit in a new chat.", run: "Nov 1, 09:00"))
        let runs = m.automations[0].thread.count
        m.addAutomation(Automation(name: "Quests", trigger: "When you run it", action: "Finish quests", limit: "", on: false, last: "Not run yet"))
        XCTAssertEqual(m.automations.count, 1)
        XCTAssertEqual(m.automations[0].thread.count, runs)
    }

    func testDeletingTheOpenChatStopsIt() {
        let m = makeModel()
        m.send("hello")
        guard let id = m.currentID else { return XCTFail("no chat") }
        m.deleteConversation(id)
        XCTAssertFalse(m.busy)
        XCTAssertNil(m.currentID)
        XCTAssertTrue(m.messages.isEmpty)
    }

    func testNetworkFollowUpNeedsAQuestion() {
        let asked = Message(role: .assistant, blocks: [.text(""), .text("I found 3 addresses in payees.csv. Which token should go out, and on which network?")])
        XCTAssertTrue(AppModel.asksNetwork(asked))
        XCTAssertFalse(AppModel.asksNetwork(Message(role: .assistant, text: "Base fees are low today.")))
        XCTAssertFalse(AppModel.asksNetwork(nil))
    }

    func testToastKind() {
        XCTAssertEqual(ToastCenter.guess("You need at least 1 USDC in the wallet first"), .error)
        XCTAssertEqual(ToastCenter.guess("Blocked by your spending policy"), .error)
        XCTAssertEqual(ToastCenter.guess("Couldn't save your changes"), .error)
        XCTAssertEqual(ToastCenter.guess("Getting a quote from Jupiter…"), .progress)
        XCTAssertEqual(ToastCenter.guess("Address copied"), .info)
        XCTAssertEqual(ToastCenter.guess("Instructions saved"), .success)
        XCTAssertEqual(ToastCenter.guess("Saved to Automations. Schedules are coming soon, so it won't run by itself yet."), .success)
    }
}
