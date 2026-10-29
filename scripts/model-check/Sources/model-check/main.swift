import Foundation
import HermitCore
import HermitModel

// model-check <models folder> [model id]
// Downloads (or resumes, then checks) the model into the folder, then asks a few questions and prints
// time to first token and tokens per second.

@MainActor
func check() async {
    let args = CommandLine.arguments
    let root = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
    let id = args.count > 2 ? args[2] : ModelCatalog.defaultID
    let store = ModelStore(root: root)
    store.select(id)

    let started = Date()
    store.download(id)
    var last = ""
    while true {
        let s = store.state(id)
        let line = "\(s)  \(store.sizeLineForCheck(id))"
        if line != last { print("download:", line); last = line }
        if s == .ready || { if case .failed = s { return true } else { return false } }() { break }
        try? await Task.sleep(for: .milliseconds(500))
    }
    guard store.state(id) == .ready else { print("FAILED"); exit(1) }
    print(String(format: "download ready in %.1fs", Date().timeIntervalSince(started)))

    let stats = StatsBox()
    let local = LocalAgent(store: store) { s in stats.add(s) }
    let hybrid = HybridAgent(store: store)

    func ask(_ agent: Agent, _ prompt: String) async {
        print("\n> \(prompt)")
        var text = ""
        for await event in agent.reply(to: prompt) {
            switch event {
            case .text(let t): text += t
            case .status(let s): print("  [\(s)]")
            case .actions(let a): print("  [actions: \(a.map(\.title))]")
            case .card: print("  [card]")
            case .steps: break
            }
        }
        print(text)
    }

    for prompt in ["Who are you, in one sentence?", "What is a stablecoin?", "And how is it different from bitcoin?"] {
        await ask(local, prompt)
        if let s = stats.last { print("  STATS \(s)") }
    }
    print("\n-- routing --")
    await ask(hybrid, "Pay alice.eth 200 USDC on Friday")
    print("\n-- cancel after 5 chunks --")
    let t0 = Date()
    var n = 0
    for await e in local.reply(to: "Write a long story about a crab.") { if case .text = e { n += 1; if n == 5 { break } } }
    print(String(format: "  stopped after %d chunks in %.2fs", n, Date().timeIntervalSince(t0)))
    await ask(local, "Say hi.")
    if let s = stats.last { print("  STATS \(s)") }
}

final class StatsBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [GenerationStats] = []
    func add(_ s: GenerationStats) { lock.lock(); items.append(s); lock.unlock() }
    var last: GenerationStats? { lock.lock(); defer { lock.unlock() }; return items.last }
}

extension ModelStore {
    func sizeLineForCheck(_ id: String) -> String {
        let got = received[id] ?? 0, total = totals[id] ?? 0
        return "\(got / 1_000_000) / \(total / 1_000_000) MB"
    }
}

await check()
