#if DEBUG
import SwiftUI
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import HermitCore
import HermitWallet

/// Debug builds only: files and reviews for the simulator and Mac screenshots (scripts/phone-shots.sh, MacTour).
/// Nothing here is reachable in Release, nothing is saved, and nobody approves anything in a screenshot run.
///   -hermitAttach csv|pdf|photo   with -hermitAsk: the message goes out with a file Hermit writes to tmp and reads
///                                 like a picked one (AttachmentReader), so the chip and the model's answer are real.
///   -hermitSheet batch-review|batch-status|batch-card|aave-deposit|aave-withdraw   (DebugLaunch.applyRoot)
/// The addresses are hash-derived (sha256 of "hermit-qa-N"); nobody holds their keys and nothing is sent to them.
@MainActor
enum DebugFixtures {
    static let rows: [(address: String, amount: String)] = [
        ("0x13926a35a968A8dA47D8E5f8541105f2279e7631", "12.5"),
        ("0x95c54B94dC77a4160D62865c0aEC9b982a8F8D91", "8"),
        ("0x978fCb2100cCaae20b167ECe674650a685C7A30F", "4.25"),
    ]

    private static var dir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The file for `-hermitAttach`.
    static func file(_ kind: String) -> URL? {
        switch kind {
        case "csv":
            let u = dir.appendingPathComponent("payouts.csv")
            let body = "address,amount\n" + rows.map { "\($0.address),\($0.amount)" }.joined(separator: "\n") + "\n"
            try? body.write(to: u, atomically: true, encoding: .utf8)
            return u
        case "pdf":
            let u = dir.appendingPathComponent("payouts-november.pdf")
            var lines = ["Payouts, November", "", "Recipient                                           Amount (USDC)"]
            lines += rows.map { "\($0.address)    \($0.amount)" }
            lines += ["", "Total: 24.75 USDC on Base"]
            return pdf(lines, to: u) ? u : nil
        case "photo":
            let u = dir.appendingPathComponent("Photo.jpg")
            let lines = ["CORNER CAFE", "", "Flat white        4.50", "Croissant         3.20", "Water             1.80", "",
                         "TOTAL            9.50", "Paid by card"]
            return jpeg(lines, to: u) ? u : nil
        default: return nil
        }
    }

    // MARK: Drawing

    private static func line(_ text: String, size: CGFloat, bold: Bool = false) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Menlo-Regular") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private static func draw(_ lines: [String], in ctx: CGContext, height: CGFloat, left: CGFloat, top: CGFloat, size: CGFloat) {
        var y = height - top
        for (i, t) in lines.enumerated() {
            let l = line(t, size: i == 0 ? size * 1.4 : size, bold: i == 0)
            ctx.textPosition = CGPoint(x: left, y: y)
            CTLineDraw(l, ctx)
            y -= (i == 0 ? size * 2.2 : size * 1.7)
        }
    }

    private static func pdf(_ lines: [String], to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        draw(lines, in: ctx, height: box.height, left: 54, top: 80, size: 11)
        ctx.endPDFPage()
        ctx.closePDF()
        return true
    }

    private static func jpeg(_ lines: [String], to url: URL) -> Bool {
        let w = 900, h = 1200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(lines, in: ctx, height: CGFloat(h), left: 90, top: 160, size: 40)
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Launch

    /// `-hermitAsk` with `-hermitAttach`: read the fixture like a picked file, then send.
    static func ask(_ q: String, attach kind: String, model: AppModel) {
        guard let u = file(kind) else { model.send(q); return }
        Task { @MainActor in
            let a = await AttachmentReader.read(u)
            model.send(q, attachment: a)
        }
    }

    /// The test wallet (-hermitTestWallet YES), once it's loaded.
    static func wallet() async -> WalletAccount? {
        let vm = WalletsViewModel.shared
        for _ in 0..<50 {
            if let w = vm.wallets.first { return w }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// A batch of the three rows on Base, in review (`status` false) or part-way through (two sent, one failed).
    static func batch(walletID: UUID, status: Bool) -> BatchPlan? {
        let usdc = Chain.base.token("USDC")
        func row(_ i: Int) -> [String: Any] {
            var r: [String: Any] = ["line": i + 1, "input": "\(rows[i].address),\(rows[i].amount)", "address": rows[i].address,
                                    "amount": rows[i].amount, "status": "ready"]
            if status {
                switch i {
                case 0: r["status"] = "confirmed"; r["hash"] = "0x3f9a1c7e5b2d4086a1e9c3b7d5f2048e6a1c9b3d7f5e2a4c6b8d0f1e3a5c7b9d"
                case 1: r["status"] = "confirmed"; r["hash"] = "0x8b2e4d6f1a3c5e7b9d0f2a4c6e8b1d3f5a7c9e0b2d4f6a8c1e3b5d7f9a0c2e4b"
                default: r["status"] = "failed"; r["error"] = "Not enough ETH left for the network fee"
                }
            }
            return r
        }
        let json: [String: Any] = [
            "id": status ? "debug-batch-status" : "debug-batch-review", "walletID": walletID.uuidString, "chainID": Chain.base.id,
            "symbol": "USDC", "tokenAddress": usdc?.address ?? "", "decimals": usdc?.decimals ?? 6,
            "rows": (0..<rows.count).map(row), "total": "24.75", "feeText": "0.000006 ETH", "gasLimit": 65_000,
            "checks": ["Every address is valid and checksummed", "No duplicate addresses", "Balance covers the total and every network fee",
                       "Within your daily limit"],
            "warnings": ["First payment to all 3 addresses. Check them against your file."], "blocks": [String](),
            "origin": "user", "source": "payouts.csv", "created": Date().timeIntervalSinceReferenceDate - (status ? 120 : 0),
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(BatchPlan.self, from: d)
    }

    /// The `-hermitSheet` names this file handles. Returns false for other names.
    static func applyRoot(_ s: String, model: AppModel) -> Bool {
        switch s {
        case "batch-review", "batch-status", "batch-card":
            Task { @MainActor in
                guard let w = await wallet(), let p = batch(walletID: w.record.id, status: s != "batch-review") else { return }
                BatchStore.shared.debugShow(p, open: s != "batch-card")
                if s != "batch-review", let u = file("csv") {
                    let a = await AttachmentReader.read(u)
                    model.messages.append(Message(role: .user, text: "Send these amounts in USDC on Base", attachment: a))
                    model.messages.append(Message(role: .assistant, blocks: [.card(.batchSend(p.id))]))
                }
            }
        case "aave-deposit":
            Task { @MainActor in
                guard let w = await wallet(), let token = AaveV3.tokens(on: .base).first(where: { $0.symbol == "USDC" }),
                      let aavePool = AaveV3.pool(on: .base), let owner = EVMAddress(w.record.evmAddress),
                      let pool = await EarnFlow.pool(chain: .base, symbol: "USDC"), let amt = try? Units.parse("25", decimals: token.decimals) else { return }
                model.approval = EarnDepositSheet.approval(pool: pool, chain: .base, token: token, amountText: "25", amount: amt, owner: owner,
                                                           aavePool: aavePool, allowance: 0, walletID: w.record.id)
            }
        case "aave-withdraw":
            Task { @MainActor in
                guard let w = await wallet(), let token = AaveV3.tokens(on: .base).first(where: { $0.symbol == "USDC" }) else { return }
                var apy: Double?
                do { apy = try await AaveV3.reserve(chain: .base, token: token, client: WalletsViewModel.shared.service.evm(.base))?.supplyAPY } catch {}
                let p = AavePosition(walletID: w.record.id, chain: .base, token: token, amount: 25_000_000, supplyAPY: apy)
                model.approval = try? HermitToolbox.withdrawApproval(p, amount: nil, label: "Hermit")
            }
        #if os(iOS)
        case "sites", "sites-empty":
            // Simulator only (its own defaults, never the Mac app's): Settings > Sites with this run's test wallet
            // connected to Uniswap (EVM) and Jupiter (Solana), or with nothing connected.
            Task { @MainActor in
                let store = DappPermissions.shared
                store.disconnectAll()
                guard s == "sites" else { return }
                _ = await wallet()
                guard let w = WalletsViewModel.shared.service.selected else { return }
                store.connectSolana(DappOrigin(scheme: "https", host: "jup.ag", port: nil), walletID: w.id, address: w.solanaAddress)
                store.connect(DappOrigin(scheme: "https", host: "app.uniswap.org", port: nil), walletID: w.id, address: w.evmAddress, chainID: 8453)
            }
        #endif
        default: return false
        }
        return true
    }
}

extension BatchStore {
    /// Screenshots: shows a batch without saving it, and opens its review.
    func debugShow(_ p: BatchPlan, open: Bool) {
        debugInsert(p)
        if open { reviewing = BatchRef(id: p.id) }
    }
}
#endif
