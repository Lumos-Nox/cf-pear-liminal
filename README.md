# agent-comm

Two small Python scripts for talking across machines over **agent-messaging**, an async HTTPS message bus. Each party owns a mailbox, sends JSON messages and polls its inbox.

| Script | Runs on | Purpose |
|---|---|---|
| `bridge.py` | a machine with [Kiro CLI](https://kiro.dev) | Connects a mailbox to `kiro-cli`, so an AI agent answers incoming messages. Two bridges can hold an agent-to-agent conversation, or one bridge can chat with a human. |
| `human.py` | any machine with Python | A terminal chat client for a person talking to a remote `bridge.py` agent. One file, standard library only. |

```
 machine A                    agent-messaging bus                 machine B
┌───────────┐  send / poll   ┌──────────────┐  send / poll  ┌────────────┐
│ bridge.py │ ─────────────► │  mailboxes   │ ◄──────────── │ bridge.py  │
│ kiro-cli  │ ◄───────────── │ (Cloudflare  │ ─────────────►│ or human.py│
└───────────┘                │   Worker)    │               └────────────┘
                             └──────────────┘
```

## Requirements

- Python 3.9+ (standard library only; no `pip install`)
- An agent-messaging **join secret**, read from `JOIN_SECRET`.
- For `bridge.py` only: `kiro-cli` installed and logged in
- Optional: `AGENT_MESSAGING_BASE` to point at a different bus. The default is `https://agent-messaging.charcoal.workers.dev`.

## How it works

**`bridge.py` loop:** poll inbox → validate the message → build a prompt (persona, topic, context files, pinned agreed points, recent history, the new message) → run one stateless `kiro-cli chat --no-interactive` turn → send the reply → repeat.

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

**Chat mode** (`--chat`): natural replies with no agreed-points protocol and no automatic wrap-up. The human ends the chat from `human.py`.

**Reliability:**
- State is saved atomically with mode 0600 after every step, and rerunning with the same `--state` resumes the conversation.
- Network errors and 429/5xx responses are retried with backoff.
- Sends use idempotency keys, so a resend after a crash is not delivered twice.

## Usage

Every party needs the join secret and its **own** `--state` file:

```bash
export JOIN_SECRET=...   # keep it out of git and shell history
```

### Two agents talking

Start the responder first, then the opener (the side with `--start`):

```bash
# machine A: responder
./bridge.py --state critic.json --label critic --peer-label architect --out review \
  --topic "Retry and dead-letter strategy for the webhook consumer" \
  --context docs/webhooks.md --context src/consumer.py \
  --persona "You are critic, a reliability reviewer. Be blunt, one sharp point per reply." \
  --duration-min 30 --max-turns 20 --leave-on-exit

# machine B: opener
./bridge.py --state architect.json --label architect --peer-label critic --out review \
  --topic "Retry and dead-letter strategy for the webhook consumer" \
  --context docs/webhooks.md --context src/consumer.py \
  --persona "You are architect, owner of the consumer. Propose concrete, minimal designs." \
  --start "Proposal: exponential backoff, 5 tries, then a DLQ table with a replay CLI. What breaks first?" \
  --duration-min 30 --max-turns 20 --leave-on-exit
```

### A human chatting with an agent

```bash
# agent machine
./bridge.py --chat --state agent.json --label helper --peer-label alice \
  --topic "Help with our deployment scripts" --persona "You are helper, a friendly DevOps expert." \
  --context docs/deploy.md --duration-min 240 --max-turns 200

# your machine
./human.py --state me.json --label alice --peer-label helper
```

In `human.py`:

| input | effect |
|---|---|
| text + Enter | send a message (end a line with `\` to continue on the next line) |
| `/end` | ask the agent for a final summary, save it, and both sides exit |
| `/quit` or Ctrl-D | tell the agent you left; both sides exit |
| `/help` | list commands |
| Ctrl-C | leave silently; rerun with the same `--state` to continue |

### Outputs

| file | written by | content |
|---|---|---|
| `<out>/<label>-transcript.md` | both | the full conversation |
| `<out>/<label>-final.md` | both | final artifact or chat summary |
| `<out>/<label>-events.jsonl` | bridge | per turn: prompt and reply size (chars), latency, success |
| `--state` file | both | mailbox token, cursor, history (mode 0600; treat as a secret) |

The default `<out>` is `artifacts/` for the bridge and `chat/` for human.py.

### Key options

`bridge.py` (run `./bridge.py --help` for the full list):

| option | default | notes |
|---|---|---|
| `--peer-label` / `--peer-mid` | n/a | `--peer-mid` pins the peer by mailbox ID (safer than labels) |
| `--topic`, `--persona` | n/a | shown on every turn |
| `--context FILE` | none | repeatable; the agent's **only** source of facts |
| `--start TEXT` | none | set on exactly one side |
| `--model` | `claude-sonnet-4.5` | e.g. `claude-haiku-4.5` for cheap, fast runs |
| `--duration-min` / `--max-turns` | 60 / 40 | upper limits before wrap-up |
| `--stall` | 4 | wrap up after this many messages with an unchanged agreed list |
| `--history` | 16 | recent messages per prompt |
| `--chat` | off | the peer is a human |
| `--leave-on-exit` | off | erase the mailbox when finished |

`human.py`: `--state`, `--label`, `--peer-label`/`--peer-mid`, `--out`, `--interval` (3s), `--peer-wait` (600s), `--final-wait` (600s), `--leave-on-exit`.

To start a **fresh** conversation, use a new `--state` file. Reusing an old one resumes the old conversation, or hits its turn cap.

## Use cases

1. **Design review:** a proposer and a critic with different personas converge on a plan and each write an actionable artifact. Where the two finals disagree is usually where a human needs to decide.
2. **Pre-PR code review:** write `git diff main...HEAD` to a file, pass it as `--context`, and let two reviewers (for example security and correctness) challenge each other's findings.
3. **Cross-machine agents:** agents on different hosts, each with its own local context files, coordinate over the bus. Use `--peer-mid` and a cheap `--model` for quick exploration.
4. **Ask a remote expert agent:** a teammate on any machine chats with an agent loaded with project docs, using `human.py` with nothing to install.
5. **Brainstorm, then hand off:** run a timed agent-to-agent session and feed the `*-final.md` "reusable prompts" and "open questions" sections into the next run or a coding agent.

## Limitations

**Agent capability**
- **No tools.** The agent can't read files, run commands or browse. It only knows `--context` files and the conversation, and with thin context it **invents details**. Everything must be pasted in, which costs tokens on every turn.
- **Stateless turns.** Each reply is a fresh `kiro-cli` process that sees the last `--history` messages plus the pinned agreed list. Details outside that window are lost.
- **Latency:** each reply takes about 15–30 seconds of model time plus up to `--interval` of polling. There's no streaming and no "typing" indicator.
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

**Bus limits** (from `GET /v1/policy`)
- 64 KiB per payload, 128 KiB per request, JSON only.
- 6,000 authenticated requests per minute per mailbox. 50,000 messages or 128 MiB per inbox, and messages expire after 7 days.
- 10 joins per hour per IP.
- Delivery is at-least-once. The scripts deduplicate by message ID.

**Tested vs untested**
- Tested live: agent-to-agent runs up to 1 hour, the stall-based and turn-cap wrap-ups, the final/done handshake, resume after a process restart, `--chat` with `human.py` (scripted input) including `/end`, and `--leave-on-exit`.
- Not tested: the mutual-`[WRAP]` path, deadline-triggered wrap-up after the rewrite, `abort` handling, and `human.py` in an interactive terminal (redrawing while you type).
