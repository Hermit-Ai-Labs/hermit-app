import XCTest
@testable import HermitUI

/// The schedule read out of an automation sentence, and the UTF-8 cut the Files page uses. No network.
@MainActor
final class AutomationDraftTests: XCTestCase {
    func testSchedules() {
        // (sentence, trigger, prompt or nil to skip, a "can't plan this yet" note expected)
        let cases: [(String, String, String?, Bool)] = [
            ("Give me 3 priorities every morning at 8", "Every day 08:00", "Give me 3 priorities", false),
            ("Top 5 gainers every Friday", "Every Friday 09:00", "Top 5 gainers", false),
            ("Every 2 hours check the ETH price", "When you run it", "Check the ETH price", true),
            ("Every 15 minutes check BTC", "When you run it", nil, true),
            ("Every evening at 9, ask me what went well today", "Every day 21:00", "Ask me what went well today", false),
            ("Every Friday and Monday at 8am brief me", "When you run it", "Brief me", true),
            ("Every weekday at 9 send me news", "When you run it", nil, true),
            ("Every month on the 1st pay rent", "When you run it", "Pay rent", true),
            ("Buy $50 of ETH every Monday at 5pm", "Every Monday 17:00", "Buy $50 of ETH", false),
            ("Every hour check gas", "Every hour", "Check gas", false),
            ("Remind me at 17:30 to stretch", "Every day 17:30", "Remind me to stretch", false),
            ("Daily at 6:45 pm check SOL", "Every day 18:45", "Check SOL", false),
        ]
        for (s, trigger, prompt, note) in cases {
            let d = AutomationDraft.from(s)
            XCTAssertEqual(d.trigger, trigger, s)
            if let prompt { XCTAssertEqual(d.prompt, prompt, s) }
            if note { XCTAssertNotNil(d.note, s) }
        }
    }

    func testUTF8Prefix() {
        XCTAssertEqual(FilesStore.utf8Prefix(Data("aé".utf8), 2), Data("a".utf8))
        XCTAssertEqual(FilesStore.utf8Prefix(Data("abc".utf8), 5), Data("abc".utf8))
    }
}
