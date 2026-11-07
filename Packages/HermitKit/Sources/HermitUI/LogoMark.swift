import SwiftUI

/// Real logos for tokens, DApps, chains and apps (ported from the demo's Mark.jsx). Unknown names fall back to a letter.
public struct LogoMark: View {
    let name: String
    var size: CGFloat = 28
    public init(_ name: String, size: CGFloat = 28) { self.name = name; self.size = size }

    static let round: [String: String] = [
        "hyperliquid": "hyperliquid",
        "aave": "aave",
        "aave v3": "aave",
        "pendle": "pendle",
        "ethena": "ethena",
        "jupiter": "jupiter",
        "uniswap": "uniswap",
        "lido": "lido",
        "pump.fun": "pumpfun",
        "morpho": "morpho",
        "kamino": "kamino",
        "polymarket": "polymarket",
        "legion": "legion",
        "eth": "eth",
        "btc": "btc",
        "sol": "mk-sol",
        "usdc": "usdc",
        "usde": "usde",
        "hype": "hype",
        "pepe": "pepe",
        "wif": "wif",
        "pengu": "pengu",
        "monad": "monad",
        "berachain": "berachain",
        "megaeth": "megaeth",
        "ondo": "ondo",
        "symbiotic": "symbiotic",
        "derive": "derive",
        "ethereum": "chain-ethereum",
        "base": "chain-base",
        "arbitrum": "chain-arbitrum",
        "polygon": "chain-polygon",
        "solana": "mk-sol",
        "robinhood": "mk-hood",
        "robinhood chain": "mk-hood",
        "hyperevm": "hyperliquid",
        "across": "across",
        "debridge": "debridge",
        "lighter": "lighter",
        "aster": "aster",
        "paradex": "paradex",
        "extended": "extended",
        "variational": "variational",
        "edgex": "edgex",
        "predict.fun": "predict-fun",
        "opinion": "opinion",
        "limitless": "limitless",
        "metadao": "metadao",
        "kalshi": "kalshi",
        "jupiter lend": "jupiter-lend",
        "curvance": "curvance",
        "kuru": "kuru",
        "falcon": "falcon-finance",
        "usd.ai": "usd-ai",
        "maple": "maple",
        "plasma": "plasma",
        "kinetiq": "kinetiq",
        "xstocks": "xstocks",
        "buidl": "blackrock-buidl",
        "virtuals": "virtuals-protocol",
        "infinex": "infinex",
        "aerodrome": "aerodrome",
        "ether.fi": "etherfi",
        "eigenlayer": "eigenlayer",
        "kaito": "kaito",
        "immunefi": "immunefi",
        "trade.xyz": "trade-xyz",
        "tsla": "tsla",
        "nvda": "nvda",
        "gold": "gold",
        "giga": "giga",
        "herm": "herm",
        "echo": "echo",
        "infrared": "infrared",
        "birdeye": "birdeye",
        "nansen": "nansen",
        "dune": "dune",
        "flap": "flap",
        "flap.sh": "flap",
        "black forest labs": "bfl",
        "elevenlabs": "elevenlabs",
        "firecrawl": "firecrawl",
        "coinbase sales": "coinbase",
        "coinbase": "coinbase",
        "x402": "x402",
        "usdt": "usdt",
        "bnb": "bnb",
        "xrp": "xrp",
        "doge": "doge",
        "sui": "sui",
        "tia": "tia",
        "mon": "monad",
        "lit": "lighter",
        "xpl": "plasma",
        "khype": "kinetiq",
        "jup": "jupiter",
        "ena": "ethena",
    ]
    static let apps: [String: String] = [
        "gmail": "gmail",
        "google calendar": "googlecalendar",
        "notion": "notion",
        "x / twitter": "x",
        "x": "x",
        "telegram": "telegram",
        "discord": "discord",
        "openai api": "openai",
        "openai": "openai",
        "perplexity api": "perplexity",
        "perplexity": "perplexity",
        "github": "github",
        "figma": "figma",
        "vercel": "vercel",
    ]

    public var body: some View {
        let k = name.lowercased()
        if k == "hermit" {
            HermitMark(height: size * 0.34)
                .frame(width: size, height: size).background(Theme.bg, in: RoundedRectangle(cornerRadius: size * 0.28))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Theme.border))
        } else if let f = Self.round[k] {
            Image.logo(f).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.06)))
        } else if let f = Self.apps[k] {
            Image.logo(f).resizable().interpolation(.high).scaledToFit().padding(size * 0.22)
                .frame(width: size, height: size).background(Theme.bg, in: RoundedRectangle(cornerRadius: size * 0.28))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Theme.border))
        } else {
            Text(String(name.filter(\.isLetter).prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: size, height: size).background(Theme.hover, in: size < 32 ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.28)))
        }
    }
}

extension Image {
    static func logo(_ file: String) -> Image {
        #if os(macOS)
        if let url = Bundle.module.url(forResource: file, withExtension: "png", subdirectory: "Logos") ?? Bundle.module.url(forResource: file, withExtension: "png"),
           let img = NSImage(contentsOf: url) { return Image(nsImage: img) }
        #else
        if let url = Bundle.module.url(forResource: file, withExtension: "png", subdirectory: "Logos") ?? Bundle.module.url(forResource: file, withExtension: "png"),
           let img = UIImage(contentsOfFile: url.path) { return Image(uiImage: img) }
        #endif
        return Image(systemName: "circle.dashed")
    }
}
