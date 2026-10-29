import { TokenCard, BarsCard, PnlCard, ActionRow } from './components/ChatCards'
import { baseChecks } from './components/Approval'
import MemoryCard from './components/MemoryCard'

// Replies built on the fly: reading an attached file, and saving to long-term memory.
// Same shape as scenarios ({ tools, blocks }) so chat renders them identically.

const txt = (html) => () => <div className="ai-text"><p dangerouslySetInnerHTML={{ __html: html }} /></div>

export function attachReply(f) {
  const read = `Reading ${f.name}`
  switch (f.kind) {
    case 'invoice': return {
      tools: [read, 'Checking the payee'],
      blocks: [
        txt('Figma invoice #2291 for <b>$45</b>, due tomorrow. Same amount and bank details as your last 6 invoices.'),
        () => <ActionRow actions={[
          { label: 'Pay $45', primary: true, approval: {
            kind: 'Bill payment', title: 'Pay Figma $45', success: 'Invoice paid',
            lines: [['To', 'Figma, Inc.'], ['Amount', '$45.00'], ['Route', 'USDC to bank via Bridge'], ['Invoice', '#2291']],
            checks: baseChecks([{ label: 'Bank details match past invoices', status: 'pass' }]),
            result: { title: 'Invoice #2291 paid', rows: [['Amount', '$45.00'], ['Arrives', '1 business day']] },
          } },
          { label: 'Pay on due date', toast: 'Scheduled for Oct 27' },
        ]} />,
      ],
    }
    case 'csv': return {
      tools: [`${read}, 412 rows`, 'Matching fills to prices'],
      blocks: [
        txt('Q3 net <b>+$2,140</b>. Funding arb carried it. Memes lost $380.'),
        () => <BarsCard title="PnL by strategy" prefix="$" rows={[
          { label: 'Funding arb', value: 1840, color: 'var(--green)' },
          { label: 'Breakout', value: 520, color: 'var(--green)' },
          { label: 'Spot', value: 160, color: 'var(--green)' },
          { label: 'Memes, loss', value: 380, color: 'var(--red)' },
        ]} />,
        () => <PnlCard title="Equity, Q3" total="+$2,140" days={90} seed={71} />,
        () => <ActionRow actions={[{ label: 'Pause meme trading', primary: true, toast: 'Meme sniper paused' }, { label: 'Save as journal', toast: 'Saved to Files' }]} />,
      ],
    }
    case 'paper': return {
      tools: [`${read}, 38 pages`, 'Checking claims on-chain'],
      blocks: [
        txt('A parallel EVM chain claiming 10,000 TPS. The live network averages about 3,100. <b>38% of supply</b> goes to team and investors after a 1-year cliff.'),
        () => <BarsCard title="Token allocation" suffix="%" rows={[{ label: 'Community', value: 40 }, { label: 'Treasury', value: 22 }, { label: 'Investors', value: 20 }, { label: 'Team', value: 18 }]} />,
        txt('Main risk: the large unlock in November 2027.'),
        () => <ActionRow actions={[{ label: 'Farm the airdrop', primary: true, ask: 'Farm the Monad airdrop for me' }, { label: 'Save to Research', toast: 'Added to Research: AI agent tokens' }]} />,
      ],
    }
    case 'chart': return {
      tools: ['Reading the chart image', 'Matching it to live PENGU data'],
      blocks: [
        txt('PENGU on the 4H. A breakout above $0.031 on rising volume. Next resistance is $0.036.'),
        () => <TokenCard sym="PENGU" name="Pudgy Penguins" price={0.0334} change={18.2} seed={11}
          marks={[{ v: 0.031, label: 'Breakout', color: '#121212' }, { v: 0.036, label: 'Resistance', color: '#7C3AED' }]}
          stats={[['Market cap', '$2.1B'], ['Liquidity', '$48M'], ['Volume 24h', '$612M'], ['Holders', '712k']]} />,
      ],
    }
    case 'code': return {
      tools: [read],
      blocks: [txt(`${f.name} runs every morning at 08:00, searches HYPE news through Perplexity, and posts a summary to Telegram. It spends about <b>$0.10 a day</b>.`)],
    }
    default: return {
      tools: [read],
      blocks: [
        txt(`<b>${f.name}</b>: three decisions and three follow-ups. The most urgent is shipping wallet onboarding by Nov 8.`),
        () => <ActionRow actions={[{ label: 'Add tasks to calendar', primary: true, toast: '3 tasks added to Calendar' }]} />,
      ],
    }
  }
}

// "Remember X", "add X to your long-term memory/knowledge" -> the line to save, or null.
export function memoryItem(text) {
  const t = text.trim()
  if (!/\b(remember|long[- ]term|memory|knowledge)\b/i.test(t)) return null
  const item = t
    .replace(/^(please\s+)?(remember( that)?|add|save|note)\s*:?\s*/i, '')
    .replace(/\s*(to|in|into)\s+(your\s+)?(long[- ]term\s+)?(memory|knowledge)\s*\.?$/i, '')
    .replace(/^["']|["']$/g, '')
    .trim()
  return item ? item[0].toUpperCase() + item.slice(1) : null
}

export function memoryReply(item) {
  return {
    tools: ['Updating hermit.md'],
    blocks: [txt("Saved. I'll follow this in every chat from now on."), () => <MemoryCard item={item} />],
  }
}
