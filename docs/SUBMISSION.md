# NEAR HACKATHON submission checklist

Source: https://nearhackathon.com/HACKATHON.md. Re-read the live file before submitting, because dates and rules may
change. The deadline is **2026-11-14T23:59:00Z**. Submissions open 2026-11-01T00:00:00Z, and outside that window the
API answers 403.

There is **one attempt per project.** A second submission of the same repository is rejected with 409. Mistakes are
fixed at https://nearhackathon.com/request-changes, never by submitting again. Nothing in this file has been submitted.

## A. Before submitting (the team)

- [ ] The repository https://github.com/Hermit-Ai-Labs/hermit-app is **public**, with `near-hackathon` pushed, and stays
      public through judging (until 2026-11-18 at least; Q-014).
- [ ] `near-hackathon` is merged or pushed, and tag `hackathon-submission` is created and pushed. Then check that both
      compare links in the README open:
      `…/compare/pre-hackathon...hackathon-submission` and `…/compare/8fe7b71...hackathon-submission`.
- [ ] `LICENSE` is on the submitted branch (MIT).
- [ ] The README placeholders are filled: demo video link, Team, and Q-015 (other projects by the same people, or "none").
      Then `grep -n TODO README.md` prints nothing.
- [ ] On the Mac, `bash scripts/core-tests.sh > /tmp/core.txt 2>&1` ends with `0 failures`. Save it as
      `docs/logs/core-tests-<date>.txt` (XCTest lines only, as in the 2026-11-08 log) and point the README's Tests
      section at it, with its date and its `Executed N tests, with S tests skipped` line.
- [ ] The iPhone TestFlight link opens for a stranger (https://testflight.apple.com/join/ed9vUh7d). Add the Mac link
      only once Apple's beta review approves it.
- [ ] Decide whether the TestFlight build carries the shared NEAR AI key. The README describes both cases.
- [ ] The demo video is recorded ([DEMO.md](DEMO.md) section 1).
- [ ] The X post is published by the team, with the video attached. It says "built at NEAR HACKATHON" and tags
      @NEARProtocol and #NEARHackathon ([DEMO.md](DEMO.md) section 2).
- [ ] The hosted pieces stay up until 2026-11-18, ideally 2026-11-25 (Q-012): the TestFlight builds, which expire
      90 days after upload.

## B. The fields only the team decides

Fill these in yourselves. They are deliberately left blank, and nothing here is a suggestion except where marked.

| Field | Rule | Value |
| --- | --- | --- |
| Project name | 2–80 characters | |
| Team lead's name | 2–80 characters | |
| Contact email | valid, max 160 characters, at most 2 submissions per email (Q-015) | |
| Team size | exactly one of `1`, `2 - 4`, `4 - 6`, `6 - 8`, `8+` | |
| Tracks | ids from the table; every track the project fits. Suggestions with reasons are in [DEMO.md](DEMO.md) section 4: `privacy`, `defi`, `security`, maybe `agents`, `open` | |
| NEAR payout account (mainnet) | a named account such as `team.near`, or a 64-hex implicit account, created by the team in a NEAR wallet. Must match `^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$`, 2–64 characters, lowercase. **Do not use the test account from the README** (`5510e2b4…`): its phrase is public. | |
| Repository link | public http(s) URL, max 300 characters; each repository can be submitted once | |
| Demo post link | the public X post, max 300 characters | |
| What you built (`idea`) | 20–2000 characters: the problem, the product, how NEAR fits in. Draft in [DEMO.md](DEMO.md) section 3. | |
| Consent | read verbatim to the team lead: *"I agree that the organizers may use these details to review our submission and contact us about this hackathon."* | ☐ agreed |

## C. The payload shape

Send exactly these 11 fields and no others. In particular, there must be no `website` field: it is a spam trap. The
body may be at most 12000 bytes. Every `<…>` below is a placeholder to replace with the team's answer from section B.

```sh
REQUEST_ID=$(uuidgen | tr A-Z a-z)   # make it ONCE; reuse the same value on a retry after a network error or a 503
echo "$REQUEST_ID"                   # write it down
```

```json
{
  "requestId": "<REQUEST_ID>",
  "projectName": "<project name>",
  "leadName": "<team lead's name>",
  "email": "<contact email>",
  "size": "<1 | 2 - 4 | 4 - 6 | 6 - 8 | 8+>",
  "tracks": ["<track id>", "<track id>"],
  "nearAddress": "<payout account>",
  "projectUrl": "<public repository URL>",
  "demoUrl": "<public X post URL>",
  "idea": "<20-2000 characters>",
  "consent": true
}
```

Submit (only after the team has seen the printed payload and said yes):

```sh
# payload.json lives OUTSIDE the repository: it holds personal data and must never be committed.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d, indent=2, ensure_ascii=False)); print(len(json.dumps(d).encode()), "bytes")' payload.json
curl -sS -X POST https://nearhackathon.com/api/applications \
  -H 'Content-Type: application/json' \
  --data-binary @payload.json -w '\nHTTP %{http_code}\n'
```

Checks before sending:

- [ ] `size` is one of the five strings exactly, spaces included (`2 - 4`, not `2-4`).
- [ ] Every entry in `tracks` is one of `defi`, `thesis`, `privacy`, `business`, `swarms`, `security`, `agents`,
      `realworld`, `games`, `nfts`, `memecoins`, `social` or `open`, and none is listed twice.
- [ ] `nearAddress` is lowercase and matches the regex above. The account exists on mainnet.
- [ ] `idea` is between 20 and 2000 characters.
- [ ] `consent` is `true` only after the team lead agreed to the notice.

## D. Responses

| Status | Meaning | What to do |
| --- | --- | --- |
| 201 | Saved | Done. Note the date and the requestId. |
| 400 | A field failed validation | Fix the fields listed in `fields` and resend with the **same** requestId. |
| 403 | Submissions not open, or the request looked cross-site | Stop and don't retry. Check the dates. |
| 409 | Repository already submitted, or this email has 2 submissions | Don't change the link or the email to get around it. If the earlier submission has a mistake, use https://nearhackathon.com/request-changes. |
| 413 | Body too large | Shorten `idea`. |
| 503 | Storage temporarily unavailable | Wait a minute, then resend with the **same** requestId. |

The form at https://nearhackathon.com/#apply takes the same fields, if the team prefers it.
