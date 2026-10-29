import Logo from './Logo'

// Real logos for DApps, tokens and apps (files in public/logos). Unknown names fall back to a letter.
const ROUND = {
  hyperliquid: 'hyperliquid.png', aave: 'aave.png', 'aave v3': 'aave.png', pendle: 'pendle.jpg', ethena: 'ethena.png',
  jupiter: 'jupiter.jpg', uniswap: 'uniswap.png', lido: 'lido.png', 'pump.fun': 'pumpfun.png', morpho: 'morpho.png',
  kamino: 'kamino.jpg', polymarket: 'polymarket.jpg', legion: 'legion.jpg',
  eth: 'eth.svg', btc: 'btc.svg', sol: 'sol.svg', usdc: 'usdc.svg', usde: 'usde.png', hype: 'hype.jpg',
  pepe: 'pepe.jpg', wif: 'wif.jpg', pengu: 'pengu.png',
  monad: 'monad.jpg', berachain: 'berachain.png', megaeth: 'megaeth.jpg', ondo: 'ondo.png', symbiotic: 'symbiotic.png', derive: 'derive.png',
  ethereum: 'chain-ethereum.jpg', base: 'chain-base.jpg', arbitrum: 'chain-arbitrum.jpg', polygon: 'chain-polygon.jpg', solana: 'sol.svg', hyperevm: 'hyperliquid.png',
  across: 'across.png', debridge: 'debridge.jpg',
  lighter: 'lighter.jpg', aster: 'aster.jpg', paradex: 'paradex.jpg', extended: 'extended.jpg', variational: 'variational.jpg', edgex: 'edgex.jpg',
  'predict.fun': 'predict-fun.jpg', opinion: 'opinion.jpg', limitless: 'limitless.png', metadao: 'metadao.jpg', kalshi: 'kalshi.jpg',
  'jupiter lend': 'jupiter-lend.jpg', curvance: 'curvance.jpg', kuru: 'kuru.jpg', falcon: 'falcon-finance.jpg', 'usd.ai': 'usd-ai.jpg',
  maple: 'maple.png', plasma: 'plasma.jpg', kinetiq: 'kinetiq.jpg', xstocks: 'xstocks.jpg', buidl: 'blackrock-buidl.png',
  virtuals: 'virtuals-protocol.jpg', infinex: 'infinex.jpg', aerodrome: 'aerodrome.png',
  'ether.fi': 'etherfi.jpg', eigenlayer: 'eigenlayer.jpg', kaito: 'kaito.jpg', immunefi: 'immunefi.jpg',
  'trade.xyz': 'trade-xyz.jpg', tsla: 'tsla.svg', nvda: 'nvda.svg', gold: 'gold.svg', giga: 'giga.png', herm: 'herm.svg',
  echo: 'echo.jpg', infrared: 'infrared.jpg', birdeye: 'birdeye.jpg', nansen: 'nansen.jpg', dune: 'dune.jpg', flap: 'flap.jpg', 'flap.sh': 'flap.jpg',
  'black forest labs': 'bfl.png', elevenlabs: 'elevenlabs.png', firecrawl: 'firecrawl.png',
  'coinbase sales': 'coinbase.svg', coinbase: 'coinbase.svg', x402: 'x402.svg', usdt: 'usdt.png', bnb: 'bnb.png', xrp: 'xrp.png', doge: 'doge.png', sui: 'sui.png', tia: 'tia.jpg',
  mon: 'monad.jpg', lit: 'lighter.jpg', aster: 'aster.jpg', xpl: 'plasma.jpg', khype: 'kinetiq.jpg', jup: 'jupiter.jpg', ena: 'ethena.png',
}
const APP = {
  gmail: 'gmail.svg', 'google calendar': 'googlecalendar.svg', notion: 'notion.svg', 'x / twitter': 'x.svg', x: 'x.svg',
  telegram: 'telegram.svg', discord: 'discord.svg', 'openai api': 'openai.svg', openai: 'openai.svg',
  'perplexity api': 'perplexity.svg', perplexity: 'perplexity.svg', github: 'github.svg', figma: 'figma.svg', vercel: 'vercel.svg',
}

export default function Mark({ name, size = 28 }) {
  const k = name.toLowerCase()
  const style = { width: size, height: size, fontSize: size * 0.4 }
  if (k === 'hermit') return <span className="mark app" style={style}><Logo size={size * 0.34} /></span>
  if (ROUND[k]) return <img className="mark round" src={`/logos/${ROUND[k]}`} alt={name} style={style} />
  if (APP[k]) return <img className="mark app" src={`/logos/${APP[k]}`} alt={name} style={{ ...style, padding: size * 0.22 }} />
  return <span className={`mark fallback ${size < 32 ? 'round' : 'app'}`} style={{ ...style, border: 0, padding: 0 }}>{name.replace(/[^A-Za-z]/g, '')[0].toUpperCase()}</span>
}
