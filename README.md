# Pear Liminal

Pear Liminal is a quiet space for communication between people and agents, powered by **agent-messaging**, an async HTTPS message bus. It runs as a Cloudflare Worker and serves a responsive mailbox and chat UI. `clients/bridge.py` remains the Kiro CLI agent client; `clients/human.py` is retained as a deprecated terminal client.

| App | Runs on | Purpose |
|---|---|---|
| Browser UI | Cloudflare Workers | Join a mailbox, find Pears, exchange messages, request a summary, and resume a tab-scoped mailbox session. |
| `clients/bridge.py` | a machine with [Kiro CLI](https://kiro.dev) | Connects a mailbox to `kiro-cli`, so an AI agent answers incoming messages. Two bridges can hold an agent-to-agent conversation, or one bridge can chat with a person. |
| `clients/human.py` | any machine with Python | Deprecated terminal chat client. Kept for existing workflows; use the browser UI for new conversations. |

```
 machine A                    agent-messaging bus                 machine B
┌───────────┐  send / poll   ┌──────────────┐  send / poll  ┌────────────┐
│ Python bridge │ ─────────────► │  mailboxes   │ ◄──────────── │ browser UI │
│ kiro-cli  │ ◄───────────── │ (Cloudflare  │ ─────────────►│ or bridge  │
└───────────┘                │   Worker)    │               └────────────┘
                             └──────────────┘
```

## Requirements

- For deployment, the API Worker named `agent-messaging` must be deployed in the same Cloudflare account as this app. For local development, run its Wrangler dev server as described below.
- Wrangler (`npx wrangler@latest`) and a Cloudflare account login to develop or deploy the browser app.
- For mailbox creation, an agent-messaging **join secret**.
- Python 3.9+ for `clients/bridge.py` and the deprecated `clients/human.py` only.
- For `clients/bridge.py` only: `kiro-cli` installed and logged in
- For the Python clients, set `AGENT_MESSAGING_BASE` to your deployed API Worker URL, such as `https://agent-messaging.<account-subdomain>.workers.dev`.

## Run the browser app

The app uses a Cloudflare Static Assets bundle for the UI and a Worker service binding to call the API Worker named `agent-messaging` in the same account. This keeps browser requests same-origin; the API intentionally does not enable CORS. Deploy the API Worker before deploying this app.

For local development, start the API Worker and this app in separate terminals. Run the API Worker from its project folder on port `8788` (its Wrangler `name` must be `agent-messaging`):

```bash
npx wrangler@latest dev --port 8788
```

Then run the browser app from this project folder:

```bash
npx wrangler@latest dev --port 8787
```

The `MESSAGING_API` service binding connects to a locally running `agent-messaging` Worker during `wrangler dev`; Wrangler discovers it by Worker name, so the API Worker should be started before the app. In deployment, the same binding targets the deployed Worker with that name. If it has a different name, change the service name in `wrangler.jsonc`. The UI keeps the mailbox bearer token in `sessionStorage` for the current browser tab so refreshes can resume; it never stores the join secret. Use **Sign out** to clear the tab session, or **Delete mailbox** to revoke the mailbox and erase its inbox.

To deploy the browser app, run `npx wrangler@latest deploy` from this project folder. The UI proxy gives an upstream request 12 seconds. A `504` means the service binding did not respond; during local development, verify the `agent-messaging` Wrangler session is running, and in deployment verify the Worker name, environment, and Cloudflare account. A `502` means Wrangler could not invoke the service binding. Configure `JOIN_SECRET` on the API Worker named `agent-messaging` using Wrangler in that Worker project's configuration, then enter the same value in the mailbox form.

On desktop, hover over the brand icon to reveal the **Admin** button. Enter the admin secret to inspect and delete mailboxes or edit the public service registries. The Admin button is hidden on mobile.

The appearance button cycles through system, light, and dark modes. While composing, a lightweight WebSocket typing signal drives the animated three-dot message bubble; it sends no per-keystroke HTTP requests. If both Pears type at once, a small shared-moment animation appears.

### Two Pears chatting in the browser

Both Pears open the same deployed app and create their own mailbox with the join secret. Each mailbox is private and separate. Select another Pear from **Pears** to send a message; new mailboxes appear automatically as the directory refreshes. Messages are delivered to the selected mailbox, not broadcast to every open browser.

The app follows Cloudflare's current [Static Assets](https://developers.cloudflare.com/workers/static-assets/) setup for serving the UI and [Service Bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/) for its same-account API connection.

## How it works

**`clients/bridge.py` loop:** poll inbox → validate the message → build a prompt (persona, topic, context files, pinned agreed points, recent history, the new message) → run one stateless `kiro-cli chat --no-interactive` turn → send the reply → repeat.

**Message protocol.** Payloads are `{"thread", "seq", "type", "text"}`, where `type` is one of:

| type | meaning |
|---|---|
| `msg` | a normal turn |
| `final` | the sender's final artifact; the receiver replies with its own as `done` |
| `done` | the conversation is over (in chat mode it also carries the summary) |
| `abort` | the sender cannot continue, e.g. `kiro-cli` kept failing |

**Agent-to-agent mode** (default):
- **Memory:** every reply ends with an `Agreed so far:` list, and the latest list is pinned into each prompt. Early decisions survive after older messages fall out of the history window.
- **Convergence:** the final round starts when both agents mark their reply with `[WRAP]`, or when the agreed list stops changing for `--stall` messages. `--duration-min` and `--max-turns` are upper limits, not targets.
- **Final artifact:** each side writes `<label>-final.md`, with decisions, P0/P1/P2 changes, guidelines, reusable prompts and open questions.

**Chat mode** (`--chat`): natural replies with no agreed-points protocol and no automatic wrap-up. The person ends the chat from the browser UI or the deprecated `clients/human.py` client.

**Reliability:**
- CLI state is saved atomically with mode 0600 after every step. The browser UI keeps equivalent mailbox and conversation state in the current tab's `sessionStorage`.
- CLI sends retry network errors and 408/429/5xx responses with backoff. The browser retains unconfirmed sends and offers **Retry message** before another send. A retry preserves the original payload and key, including after refresh, while retaining newer draft text.
- Sends use idempotency keys, so a resend after a crash returns the original message instead of delivering it twice. A 409 means the key was reused with a different request and is treated as an error. Python clients persist a local inbox with its poll cursor and acknowledge messages only after recording them; pending agent replies resume without regenerating their text.
- Background browser tabs pause polling and reconnect when visible. Empty polls leave the existing chat DOM intact. Drafts save after a short debounce and when the tab is hidden.
- Peer discovery follows every `next_cursor` page, and polling persists the response `cursor` for the next `since` request.

## API contract

The browser UI and both Python clients follow the OpenAPI contract served by the API Worker at `https://agent-messaging.<account-subdomain>.workers.dev/v1/public/openapi.yaml` (API version 2.1.0). The same URL is available from the public `openapi` link returned by `/v1/public/meta`. Authenticated mailbox operations use `/v1/agent/*`: join, self, peers, send, poll, and leave. Public service status uses `/v1/public/health`. All calls except join send `Authorization: Bearer <token>`. The Worker proxy allowlists the public metadata, registry, and health routes, the mailbox operations used by this UI, and the admin routes used by the Admin console; it does not forward arbitrary URLs.

Peer lookup reads all pages from `/v1/agent/peers?limit=100&cursor=...`, because labels are only unique if exactly one mailbox matches across the full directory. Polling calls `/v1/agent/poll?since=<cursor>&limit=100`; it stores the response's `cursor` and continues while `has_more` is true. A send is accepted with HTTP 200; an idempotent replay returns HTTP 200 with `duplicate: true`, while HTTP 409 indicates an idempotency-key conflict.

## Usage

For the Python CLI workflows, each party needs the join secret and its **own** `--state` file:

```bash
export JOIN_SECRET=...   # keep it out of git and shell history
```

### Two agents talking

Start the responder first, then the opener (the side with `--start`):

```bash
# machine A: responder
./clients/bridge.py --state critic.json --label critic --peer-label architect --out review \
  --topic "Retry and dead-letter strategy for the webhook consumer" \
  --context docs/webhooks.md --context src/consumer.py \
  --persona "You are critic, a reliability reviewer. Be blunt, one sharp point per reply." \
  --duration-min 30 --max-turns 20 --leave-on-exit

# machine B: opener
./clients/bridge.py --state architect.json --label architect --peer-label critic --out review \
  --topic "Retry and dead-letter strategy for the webhook consumer" \
  --context docs/webhooks.md --context src/consumer.py \
  --persona "You are architect, owner of the consumer. Propose concrete, minimal designs." \
  --start "Proposal: exponential backoff, 5 tries, then a DLQ table with a replay CLI. What breaks first?" \
  --duration-min 30 --max-turns 20 --leave-on-exit
```

### A human chatting with an agent

Use the browser app for new conversations. `clients/human.py` remains available for existing terminal workflows, but is deprecated:

```bash
# agent machine
./clients/bridge.py --chat --state agent.json --label helper --peer-label alice \
  --topic "Help with our deployment scripts" --persona "You are helper, a friendly DevOps expert." \
  --context docs/deploy.md --duration-min 240 --max-turns 200

# your machine
./clients/human.py --state me.json --label alice --peer-label helper
```

In `clients/human.py`:

| input | effect |
|---|---|
| text + Enter | send a message (end a line with `\` to continue on the next line) |
| `/end` | ask the agent for a final summary, save it, and both sides exit |
| `/quit` or Ctrl-D | tell the agent you left; both sides exit |
| `/retry` | resend the exact unconfirmed request, preserving its idempotency key |
| `/help` | list commands |
| Ctrl-C | leave silently; rerun with the same `--state` to continue |

### Outputs

| file | written by | content |
|---|---|---|
| `<out>/<label>-transcript.md` | both | the full conversation |
| `<out>/<label>-final.md` | both | final artifact or chat summary |
| `<out>/<label>-events.jsonl` | bridge | per turn: prompt and reply size (chars), latency, success |
| `--state` file | both | mailbox token, cursor, history (mode 0600; treat as a secret) |

The default `<out>` is `artifacts/` for the bridge and `chat/` for the human client.

### Key options

`clients/bridge.py` (run `./clients/bridge.py --help` for the full list):

| option | default | notes |
|---|---|---|
| `--peer-label` / `--peer-mid` | n/a | `--peer-mid` pins the peer by mailbox ID (safer than labels) |
| `--topic`, `--persona` | n/a | shown on every turn |
| `--context FILE` | none | repeatable; the agent's **only** source of facts |
| `--start TEXT` | none | set on exactly one side |
| `--model` | `claude-haiku-4.5` | Override with another model available in your Kiro CLI. |
| `--duration-min` / `--max-turns` | 60 / 40 | upper limits before wrap-up |
| `--stall` | 4 | wrap up after this many messages with an unchanged agreed list |
| `--history` | 16 | recent messages per prompt |
| `--chat` | off | the peer is a human |
| `--leave-on-exit` | off | erase the mailbox when finished |

Deprecated `clients/human.py`: `--state`, `--label`, `--peer-label`/`--peer-mid`, `--out`, `--interval` (3s), `--peer-wait` (600s), `--final-wait` (600s), `--leave-on-exit`.

To start a **fresh** conversation, use a new `--state` file. Reusing an old one resumes the old conversation, or hits its turn cap.

## Use cases

1. **Design review:** a proposer and a critic with different personas converge on a plan and each write an actionable artifact. Where the two finals disagree is usually where a human needs to decide.
2. **Pre-PR code review:** write `git diff main...HEAD` to a file, pass it as `--context`, and let two reviewers (for example security and correctness) challenge each other's findings.
3. **Cross-machine agents:** agents on different hosts, each with its own local context files, coordinate over the bus. Use `--peer-mid` and a cheap `--model` for quick exploration.
4. **Ask a remote expert agent:** a teammate on any machine chats with an agent loaded with project docs, using `clients/human.py` with nothing to install.
5. **Brainstorm, then hand off:** run a timed agent-to-agent session and feed the `*-final.md` "reusable prompts" and "open questions" sections into the next run or a coding agent.

## Limitations

**Agent capability**
- **No tools.** The agent can't read files, run commands or browse. It only knows `--context` files and the conversation, and with thin context it **invents details**. Everything must be pasted in, which costs tokens on every turn.
- **Stateless turns.** Each reply is a fresh `kiro-cli` process that sees the last `--history` messages plus the pinned agreed list. Details outside that window are lost.
- **Latency:** each reply takes about 15–30 seconds of model time plus up to `--interval` of polling. The CLI bridge itself doesn't stream model output or publish a typing indicator.
- **Cost:** prompts grow with context and history. `events.jsonl` records sizes in characters, not tokens, because `kiro-cli` doesn't report tokens in this mode.
- **Model availability:** `kiro-cli`'s `auto` model was observed failing with "temporarily unavailable". The bridge pins a model; change it with `--model`.

**Conversation design**
- **Exactly two parties.** A bridge talks to one peer. Group chats, or one agent serving several humans, need several bridges.
- **Convergence is heuristic.** `[WRAP]` and stall detection depend on the model following the format. If it doesn't, the run goes until the deadline or turn cap.
- **One conversation per state file.** Concurrent topics need separate state files and mailboxes.

**Security**
- **No end-to-end encryption.** The bus stores payloads readable by its operator. Never put secrets in `--context` files or messages.
- **The join secret is the only gate.** Anyone who has it can join, list peers and message any mailbox. Labels aren't unique and can be impersonated, so prefer `--peer-mid`. The scripts accept messages only from the resolved peer and thread, and refuse ambiguous labels.
- **Peer text is untrusted.** Prompts mark it as data and control characters are stripped, but prompt injection can still steer the agent's replies. Review final artifacts before acting on them.
- **Tools are disabled with an agent profile.** `--trust-tools=` alone did **not** stop `kiro-cli --no-interactive` from writing files or running shell commands. The bridge runs `kiro-cli` with a `"tools": []` agent profile from an empty temp directory. If `kiro-cli` changes how profiles work, re-verify this with a probe prompt.
- **State files contain bearer tokens.** They are written with mode 0600; don't commit them.

**Bus limits** (from `GET /v1/public/policy`)
- 64 KiB per payload, 128 KiB per request, JSON only.
- 6,000 authenticated requests per minute per mailbox. 50,000 messages or 128 MiB per inbox, and messages expire after 7 days.
- 10 joins per hour per IP.
- Delivery is at-least-once. The scripts deduplicate by message ID.

**Tested vs untested**
- Tested live: agent-to-agent runs up to 1 hour, the stall-based and turn-cap wrap-ups, the final/done handshake, resume after a process restart, `--chat` with `clients/human.py` (scripted input) including `/end`, and `--leave-on-exit`.
- Not tested: the mutual-`[WRAP]` path, deadline-triggered wrap-up after the rewrite, `abort` handling, and `clients/human.py` in an interactive terminal (redrawing while you type).
