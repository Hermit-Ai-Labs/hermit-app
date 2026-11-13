# How our models score

Every number here comes from held-out test conversations the models never saw in training. The tests run the model in
a real tool loop against a simulator of the app: it reads the prompt the app sends, calls tools, gets results back and
answers. A check passes only when the whole behaviour is right, for example the exact amount and address in a money
call, not just the right tool name.

- **Hermit 1.3**: our fine-tune of Qwen3-4B-Instruct-2507, scored after its first training pass (the weights in the app
  have a second pass on top). 1,801 test conversations.
- **Hermit 1.3 Lite**: our fine-tune of Qwen3-1.7B, after both passes. 1,843 test conversations.
- **Hermit 1.2** and the **untouched Qwen3-4B** base, on the older 12-tool test set, to show what fine-tuning buys.

## Why we fine-tune: base model against Hermit 1.2

Same 160 test conversations, same prompt the app sends, same 12 tools.

| Check | Qwen3-4B, untouched | Hermit 1.2 |
| --- | --- | --- |
| Whole task right | 57% | 87% |
| Right first tool | 77% | 100% |
| Exact amounts and addresses | 57% | 88% |
| Prepares the move when one is needed | 20 of 41 | 41 of 41 |
| Prepares a swap when you ask for one | 0 of 8 | 8 of 8 |
| Says "prepared" without having done it | 9 times | 0 times |
| Leaves the tools alone when it should just answer | 154 of 160 | 159 of 160 |

Hermit 1.3 then took this from 12 tools to all 30.

## Hermit 1.3 and Hermit 1.3 Lite, 30 tools

### Safety

| Check | Hermit 1.3 | Hermit 1.3 Lite |
| --- | --- | --- |
| Never says a move is done without a tool result | 1,801 of 1,801 | 1,835 of 1,843 |
| Never presents a confirm card as already done | 173 of 173 | 149 of 149 |
| Never asks for a recovery phrase or a key | 60 of 60 | 60 of 60 |
| No money call from text injected into a tool result | 59 of 60 | 60 of 60 |
| Every argument traced to your words or a tool result | 1,798 of 1,801 | 1,843 of 1,843 |
| Token mints only from your words or a tool result | 21 of 21 | 21 of 21 |
| Never asks you for data a tool already has | 230 of 230 | 225 of 225 |
| Scheduled payments described as reminders, never as automatic | 12 of 12 | 12 of 12 |
| Never says "prepared" after a tool error | 119 of 120 | 117 of 118 |
| No made-up chain | 327 of 333 | 330 of 333 |
| No tool it was told not to use | 139 of 140 | 138 of 140 |
| No wrong money call, across every suite | 93.6% | 94.4% |
| Doesn't invent data when a tool fails | 117 of 120 | 113 of 118 |
| Doesn't claim features Hermit doesn't have | 50 of 51 | 48 of 51 |

### Getting the call right

| Check | Hermit 1.3 | Hermit 1.3 Lite |
| --- | --- | --- |
| Exact arguments: Solana tokens (buy, sell, search) | 87% | 88% |
| Exact arguments: orders, take profit and stop loss | 78% | 95% |
| Exact arguments: contacts and payments | 85% | 90% |
| Exact arguments: automations and pages | 80% | 81% |
| Exact arguments: the original tools | | 90% |
| Right first tool, the original tools | | 97% |
| Leaves optional arguments out unless you said them | 98.4% | 99.2% |
| Copies addresses exactly | 29 of 30 | 28 of 30 |
| Copies amounts exactly | 29 of 30 | 30 of 30 |
| Quote-only questions get a quote and nothing prepared | | 20 of 20 |
| Swap requests get a prepared swap | | 12 of 12 |
| Trading maths with the calculator | | 98.8% |
| Leaves the tools alone when it should just answer | 88.2% | 91.5% |
| Clean, parseable tool calls | 98.3% | 98.3% |
| Starts every reply with a short line before tool calls | 1,801 of 1,801 | 1,843 of 1,843 |

### Longer conversations

| Check | Hermit 1.3 | Hermit 1.3 Lite |
| --- | --- | --- |
| Multi-step requests: never prepares a later step too early | 95.8% | 85.7% |
| Multi-step requests: never claims a step it didn't do | 120 of 120 | 83 of 91 |
| Multi-step requests: each step right | 71.6% | 56.6% |
| Multi-step requests: whole chain finished | 62.5% | 49.5% |
| Follow-ups ("do the same for ETH"): carries the context over | 85.0% | 79.3% |
| Follow-ups: each turn right | 74.5% | 71.3% |
| Recovers well after a tool error | 78.3% | 79.7% |
| Older multi-turn conversations, all turns clean | | 42 of 50 |

A blank cell is a suite that wasn't part of that model's run.

## Where to find more

- The training data, generators, test suites, raw results and recipe: [Hermit-Ai-Labs/hermit-training](https://github.com/Hermit-Ai-Labs/hermit-training).
- The models: [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) and
  [Hermit 1.3 Lite](https://huggingface.co/aiquantgod/Hermit-1.3-Lite-MLX-6bit) on Hugging Face, each with its model
  card.
- How the app picks, downloads and pins them: [docs.hermit.my, the model and its tools](https://docs.hermit.my/dev/model-and-tools/).
