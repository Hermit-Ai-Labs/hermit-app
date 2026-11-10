import Foundation

/// The on-device prompt, rendered here in Swift exactly as Hermit's training data renders it
/// (hermit-lab/train/gen2/hermit_fmt.py `render`, export/chat_template_4b.jinja and chat_template_lite.jinja).
/// Rendering it here instead of through the model's Jinja template keeps it byte-identical to training whatever
/// template a downloaded model ships, and lets the KV cache be reused across tool rounds (the text only grows).
public enum HermitPrompt {
    /// How a model family frames the assistant turn.
    public enum Family: String, Sendable {
        /// Qwen3-4B-Instruct-2507 (Hermit 1.1 / 1.2): no reasoning block.
        case instruct
        /// Qwen3-1.7B (Hermit Lite): an empty think block after every assistant prefix, so it never reasons.
        case thinking
    }

    public enum Message: Equatable, Sendable {
        case system(String)
        case user(String)
        case assistant(String, calls: [ToolCall])
        case tool(String)
    }

    /// The agent system prompt Hermit 1.2 is trained on (hermit_fmt.SYSTEM_AGENT).
    public static let agentSystem = """
    You are Hermit, a private AI assistant that runs entirely on this device. You help with trading, crypto, DeFi, \
    code, writing and everyday questions.
    You have tools for live prices, the user's balances and Hyperliquid account, position maths, and for preparing \
    trades, swaps, sends and deposits. A prepared action opens a review screen and only happens when the user approves \
    it with Face ID, so never say it already happened.
    Use the calculator for any arithmetic that isn't trivial. Never state a live price, balance or position you didn't \
    get from a tool. Copy addresses and amounts exactly. If a required detail is missing, ask one short question.
    Keep answers short and plain: a few sentences, simple words, no filler. Do not use middle dots as separators. \
    If you don't know something, say so.
    """

    /// The system prompt plus the user's name and hermit.md notes, appended the way training did (hermit_fmt.with_user).
    public static func system(_ base: String = agentSystem, name: String, memory: [String]) -> String {
        var s = base
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { s += "\nThe user wants to be called \(name)." }
        var notes: [String] = [], used = 0
        for line in memory where used + line.count < 2000 { notes.append("- " + line); used += line.count }
        if !notes.isEmpty { s += "\nThe user's standing notes (hermit.md). Follow them:\n" + notes.joined(separator: "\n") }
        return s
    }

    /// hermit_tools.json as training renders it: one `json.dumps(tool, ensure_ascii=False)` per line, in order.
    public static let trainedToolLines: [String] = #"""
        {"type": "function", "function": {"name": "calculator", "description": "Evaluate an arithmetic expression exactly and return the result. Use it for any arithmetic beyond trivial; never do multi-step maths in your head. Supports + - * / ** ( ), sqrt(), ln(), log10(), exp(), abs(), min(), max(), round(x, n).", "parameters": {"type": "object", "properties": {"expression": {"type": "string", "description": "The expression to evaluate, e.g. '(2410.5 - 2311) * 0.75'."}}, "required": ["expression"]}}}
        {"type": "function", "function": {"name": "get_price", "description": "Get the live price and 24h change of a coin or token (Hyperliquid, falling back to Binance). Always call this before stating a current price; never invent prices.", "parameters": {"type": "object", "properties": {"symbol": {"type": "string", "description": "Ticker, e.g. 'BTC', 'ETH', 'SOL', 'HYPE'."}}, "required": ["symbol"]}}}
        {"type": "function", "function": {"name": "get_balances", "description": "Get the user's wallet holdings: a list of {symbol, chain, amount, usd}. Optionally filter to one chain.", "parameters": {"type": "object", "properties": {"chain": {"type": "string", "description": "Optional chain filter, e.g. 'ethereum', 'base', 'arbitrum', 'bsc', 'solana', 'hyperliquid'."}}, "required": []}}}
        {"type": "function", "function": {"name": "hyperliquid_account", "description": "Get the user's Hyperliquid account: account value, margin used, available USDC, open positions (coin, side, size, entry, liquidation price, unrealised pnl, leverage) and open orders.", "parameters": {"type": "object", "properties": {}, "required": []}}}
        {"type": "function", "function": {"name": "position_math", "description": "Compute a perp position's margin, liquidation price, and (if price is given) pnl and ROE.", "parameters": {"type": "object", "properties": {"side": {"type": "string", "enum": ["long", "short"]}, "entry": {"type": "number", "description": "Entry price in USD."}, "size_usd": {"type": "number", "description": "Position notional in USD."}, "leverage": {"type": "number", "description": "Leverage, e.g. 5 for 5x."}, "price": {"type": "number", "description": "Optional current or target price, for pnl and ROE."}, "maintenance_margin": {"type": "number", "description": "Optional maintenance margin as a fraction, e.g. 0.005 for 0.5%. Defaults to 0."}}, "required": ["side", "entry", "size_usd", "leverage"]}}}
        {"type": "function", "function": {"name": "search_markets", "description": "Search markets (perps, spot pairs, pools) matching a query. Returns name, type, price, funding (perps) and APY (pools).", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "Free text, e.g. 'SOL perp', 'PEPE', 'ETH USDC pool'."}}, "required": ["query"]}}}
        {"type": "function", "function": {"name": "get_yields", "description": "Get the top yield pools: protocol, chain, asset, apy, tvl. Optionally filter by asset and/or chain.", "parameters": {"type": "object", "properties": {"asset": {"type": "string", "description": "Optional asset, e.g. 'USDC', 'ETH'."}, "chain": {"type": "string", "description": "Optional chain, e.g. 'base', 'arbitrum'."}}, "required": []}}}
        {"type": "function", "function": {"name": "prepare_trade", "description": "Prepare a Hyperliquid perp order and open the app's review screen. The user approves it with Face ID; nothing is executed by this call. Never say the trade happened; say it is prepared for review.", "parameters": {"type": "object", "properties": {"coin": {"type": "string", "description": "Ticker, e.g. 'BTC'."}, "side": {"type": "string", "enum": ["long", "short"]}, "size_usd": {"type": "number", "description": "Notional size in USD."}, "leverage": {"type": "number"}, "order_type": {"type": "string", "enum": ["market", "limit"]}, "limit_price": {"type": "number", "description": "Required when order_type is limit."}, "take_profit": {"type": "number", "description": "Optional take-profit trigger price."}, "stop_loss": {"type": "number", "description": "Optional stop-loss trigger price."}}, "required": ["coin", "side", "size_usd", "leverage", "order_type"]}}}
        {"type": "function", "function": {"name": "prepare_swap", "description": "Prepare a swap or bridge (via Relay) and open the Swap/Bridge review screen for the user to approve. Nothing is executed by this call.", "parameters": {"type": "object", "properties": {"from_symbol": {"type": "string"}, "from_chain": {"type": "string"}, "to_symbol": {"type": "string"}, "to_chain": {"type": "string"}, "amount": {"type": "number", "description": "Amount of from_symbol to swap."}}, "required": ["from_symbol", "from_chain", "to_symbol", "to_chain", "amount"]}}}
        {"type": "function", "function": {"name": "prepare_send", "description": "Prepare a transfer and open the Send review screen for the user to approve. Copy the address character for character (keep EVM checksum case and base58 case).", "parameters": {"type": "object", "properties": {"to_address": {"type": "string"}, "amount": {"type": "number"}, "symbol": {"type": "string"}, "chain": {"type": "string"}}, "required": ["to_address", "amount", "symbol", "chain"]}}}
        {"type": "function", "function": {"name": "open_add_funds", "description": "Open the Add funds flow (deposit QR code and network choice) for the wallet or for Hyperliquid.", "parameters": {"type": "object", "properties": {"goal": {"type": "string", "enum": ["wallet", "hyperliquid"]}}, "required": ["goal"]}}}
        """#.components(separatedBy: "\n")

    /// Tools the app has beyond the trained list, in the same layout, after it: NEAR Intents quotes, batch sends and
    /// Aave deposits and withdrawals.
    public static let extraToolLines: [String] = #"""
        {"type": "function", "function": {"name": "get_quote", "description": "Get a live NEAR Intents (1Click) quote for a swap or bridge without preparing anything: amount out, dollar values, fee and time. Chains: ethereum, base, arbitrum, bsc, polygon, monad, solana, near, bitcoin (destination only), hyperliquid (USDC destination only).", "parameters": {"type": "object", "properties": {"from_symbol": {"type": "string"}, "from_chain": {"type": "string"}, "to_symbol": {"type": "string"}, "to_chain": {"type": "string"}, "amount": {"type": "number", "description": "Amount of from_symbol."}}, "required": ["from_symbol", "from_chain", "to_symbol", "to_chain", "amount"]}}}
        {"type": "function", "function": {"name": "prepare_multisend", "description": "Prepare one token transfer to many addresses (a list or a spreadsheet of address and amount) and open the Batch send review for the user to approve. Nothing is executed by this call.", "parameters": {"type": "object", "properties": {"symbol": {"type": "string"}, "chain": {"type": "string"}, "recipients": {"type": "array", "items": {"type": "object", "properties": {"address": {"type": "string"}, "amount": {"type": "number"}}, "required": ["address", "amount"]}}}, "required": ["symbol", "recipients"]}}}
        {"type": "function", "function": {"name": "prepare_deposit", "description": "Prepare a deposit into a yield pool (Aave v3 on Ethereum, Base or Arbitrum) and open the Deposit review for the user to approve. Nothing is executed by this call.", "parameters": {"type": "object", "properties": {"project": {"type": "string", "description": "Pool project, e.g. 'aave-v3'."}, "symbol": {"type": "string"}, "chain": {"type": "string"}, "amount": {"type": "number"}}, "required": ["symbol", "amount"]}}}
        {"type": "function", "function": {"name": "prepare_withdraw", "description": "Prepare a withdrawal from the user's Aave v3 deposit and open the review for the user to approve. Leave amount out to withdraw all. Nothing is executed by this call.", "parameters": {"type": "object", "properties": {"symbol": {"type": "string"}, "chain": {"type": "string"}, "amount": {"type": "number"}}, "required": ["symbol"]}}}
        """#.components(separatedBy: "\n")

    public static var toolLines: [String] { trainedToolLines + extraToolLines }

    /// Tool names in the block.
    public static func names(_ lines: [String]) -> [String] {
        lines.compactMap { JSONValue.parse($0)?["function"]?["name"]?.string }
    }

    /// hermit_fmt.TOOLS_BLOCK for the given lines.
    public static func toolsBlock(_ lines: [String] = toolLines) -> String {
        "# Tools\n\nYou may call one or more functions to assist with the user query.\n\n"
            + "You are provided with function signatures within <tools></tools> XML tags:\n<tools>"
            + lines.map { "\n" + $0 }.joined()
            + "\n</tools>\n\nFor each function call, return a json object with function name and arguments within "
            + "<tool_call></tool_call> XML tags:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"
    }

    static let thinkEmpty = "<think>\n\n</think>\n\n"

    /// hermit_fmt.render_text: the exact prompt text. `tools` nil renders a plain chat (no tool block).
    public static func render(_ messages: [Message], tools: [String]? = toolLines, family: Family, addGenerationPrompt: Bool) -> String {
        var out = ""
        let think = family == .thinking ? thinkEmpty : ""
        var start = 0
        if case .system(let s)? = messages.first {
            start = 1
            out += "<|im_start|>system\n" + s + (tools.map { "\n\n" + toolsBlock($0) } ?? "") + "<|im_end|>\n"
        } else if let tools {
            out += "<|im_start|>system\n" + toolsBlock(tools) + "<|im_end|>\n"
        }
        for i in start..<messages.count {
            switch messages[i] {
            case .system(let s): out += "<|im_start|>system\n" + s + "<|im_end|>\n"
            case .user(let s): out += "<|im_start|>user\n" + s + "<|im_end|>\n"
            case .assistant(let content, let calls):
                out += "<|im_start|>assistant\n" + think + content
                for (k, c) in calls.enumerated() {
                    if k > 0 || !content.isEmpty { out += "\n" }
                    out += c.rendered
                }
                out += "<|im_end|>\n"
            case .tool(let s):
                let prevTool = i > start && { if case .tool = messages[i - 1] { return true }; return false }()
                let nextTool = i + 1 < messages.count && { if case .tool = messages[i + 1] { return true }; return false }()
                out += (prevTool ? "" : "<|im_start|>user") + "\n<tool_response>\n" + s + "\n</tool_response>" + (nextTool ? "" : "<|im_end|>\n")
            }
        }
        if addGenerationPrompt { out += "<|im_start|>assistant\n" + think }
        return out
    }

    /// Text from outside the user's own typing (tool results, attached files) can't contain the chat's control tokens
    /// or tags: they are broken up so the tokenizer reads them as plain text and the model can't be handed a fake turn.
    public static func neutralize(_ s: String) -> String {
        var t = s
        for (a, b) in [("<|", "< |"), ("|>", "| >"), ("<tool_", "< tool_"), ("</tool_", "< /tool_"), ("<think>", "< think>"), ("</think>", "< /think>")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
