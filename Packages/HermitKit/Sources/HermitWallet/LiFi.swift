import Foundation

/// Swaps and bridges between EVM chains through LI.FI (docs.li.fi, /v1/quote): it picks the best DEX or bridge route
/// and returns one transaction to sign. Hermit adds an approve first when the token's allowance is short.
/// Everything is signed on this phone; LI.FI never holds the keys.
public enum LiFi {
    public static let native = "0x0000000000000000000000000000000000000000"

    public struct Quote: Sendable {
        public let tool: String
        public let fromAmount: UInt128
        public let toAmount: UInt128
        public let toAmountMin: UInt128
        public let toDecimals: Int
        public let approvalAddress: EVMAddress?
        public let tx: ContractCall
        public let gasUSD: Double
        public let feeUSD: Double
        public let seconds: Int
    }

    public static func quote(from: Chain, to: Chain, fromToken: Token?, toToken: Token?, amount: UInt128, address: String,
                             slippage: Double = 0.005) async throws -> Quote {
        guard let fromID = from.chainId, let toID = to.chainId else { throw WalletError.blocked("Swaps are on EVM networks for now.") }
        var c = URLComponents(string: "https://li.quest/v1/quote")!
        c.queryItems = [
            .init(name: "fromChain", value: String(fromID)), .init(name: "toChain", value: String(toID)),
            .init(name: "fromToken", value: fromToken?.address ?? native), .init(name: "toToken", value: toToken?.address ?? native),
            .init(name: "fromAmount", value: String(amount)), .init(name: "fromAddress", value: address),
            .init(name: "slippage", value: String(slippage)), .init(name: "integrator", value: "hermit"),
        ]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let m = d["message"] as? String ?? "No route found"
            throw WalletError.blocked(m.lowercased().contains("no available quotes") || m.lowercased().contains("no route")
                                      ? "No route for this swap right now. Try a bigger amount or another token." : m)
        }
        guard let est = d["estimate"] as? [String: Any], let tr = d["transactionRequest"] as? [String: Any],
              let target = (tr["to"] as? String).flatMap(EVMAddress.init), let hex = tr["data"] as? String else {
            throw WalletError.badResponse("LI.FI quote")
        }
        let value = (tr["value"] as? String).flatMap { UInt128($0.dropFirst(2), radix: 16) } ?? 0
        let usd = { (k: String) in (est[k] as? [[String: Any]] ?? []).reduce(0.0) { $0 + (Double($1["amountUSD"] as? String ?? "") ?? 0) } }
        let toDec = ((d["action"] as? [String: Any])?["toToken"] as? [String: Any])?["decimals"] as? Int ?? 18
        let tool = (d["toolDetails"] as? [String: Any])?["name"] as? String ?? d["tool"] as? String ?? "LI.FI"
        return Quote(tool: tool, fromAmount: amount,
                     toAmount: UInt128(est["toAmount"] as? String ?? "") ?? 0, toAmountMin: UInt128(est["toAmountMin"] as? String ?? "") ?? 0,
                     toDecimals: toDec,
                     approvalAddress: fromToken == nil ? nil : (est["approvalAddress"] as? String).flatMap(EVMAddress.init),
                     tx: ContractCall(to: target, data: [UInt8](hex: hex) ?? [], value: value,
                                      label: from == to ? "Swap on \(from.name)" : "Bridge from \(from.name) to \(to.name)"),
                     gasUSD: usd("gasCosts"), feeUSD: usd("feeCosts"), seconds: est["executionDuration"] as? Int ?? 30)
    }

    /// approve (when needed) + the route's transaction.
    public static func calls(_ q: Quote, token: Token?, allowance: UInt128) -> [ContractCall] {
        var out: [ContractCall] = []
        if let t = token, let spender = q.approvalAddress, allowance < q.fromAmount {
            out.append(ContractCall(to: EVMAddress(t.address)!, data: ERC20.selector("approve(address,uint256)") + ERC20.word(spender) + ERC20.word(q.fromAmount),
                                    label: "Allow the swap to use \(Units.format(q.fromAmount, decimals: t.decimals)) \(t.symbol)"))
        }
        out.append(q.tx)
        return out
    }
}
