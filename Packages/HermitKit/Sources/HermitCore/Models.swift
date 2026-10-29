import Foundation

/// One line in a conversation.
public struct Message: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    /// While the agent works: "Checking past payments…". Cleared when the answer starts.
    public var status: String?
    /// How many tool steps the agent took (shown as "2 steps").
    public var steps: Int
    public var card: Card?
    public var actions: [Action]
    public var done: Bool

    public init(id: UUID = UUID(), role: Role, text: String = "", status: String? = nil, steps: Int = 0,
                card: Card? = nil, actions: [Action] = [], done: Bool = true) {
        self.id = id; self.role = role; self.text = text; self.status = status; self.steps = steps
        self.card = card; self.actions = actions; self.done = done
    }
}

/// Structured results the agent can post under its text. Numbers always come with a chart.
public enum Card: Equatable, Sendable {
    case bars(title: String, rows: [BarRow])
    case receipt(title: String, rows: [[String]])
}

public struct BarRow: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: Double
    public let display: String
    public let highlight: Bool
    public init(_ label: String, _ value: Double, _ display: String, highlight: Bool = false) {
        self.label = label; self.value = value; self.display = display; self.highlight = highlight
    }
}

/// A button under a reply. Money moves always open the approval sheet.
public struct Action: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let approval: Approval?
    public init(_ title: String, approval: Approval? = nil) { self.title = title; self.approval = approval }
}

/// Everything the approval sheet shows before money moves.
public struct Approval: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let kind: String
    public let title: String
    public let lines: [[String]]
    public let checks: [String]
    public let success: String
    public let receipt: Card?
    /// Does the real work after Approve (sign and send) and returns a transaction hash. nil keeps the demo flow.
    public var perform: (@Sendable () async throws -> String)?
    public init(kind: String, title: String, lines: [[String]], checks: [String], success: String, receipt: Card? = nil,
                perform: (@Sendable () async throws -> String)? = nil) {
        self.kind = kind; self.title = title; self.lines = lines; self.checks = checks; self.success = success; self.receipt = receipt
        self.perform = perform
    }
    public static func == (a: Approval, b: Approval) -> Bool {
        a.kind == b.kind && a.title == b.title && a.lines == b.lines && a.checks == b.checks && a.success == b.success && a.receipt == b.receipt
    }
}
