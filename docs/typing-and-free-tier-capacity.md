# Typing indicator and Free tier capacity

This note estimates the request load for the browser UI and its lightweight typing indicator. The numbers are derived from the current client intervals and Cloudflare's published Free plan quotas. They are planning estimates; the Cloudflare dashboard is the source of actual account usage.

## Existing request load

For each signed-in browser tab in the foreground, the UI currently makes:

| Operation | Interval | Requests per minute | Requests per 24 hours |
| --- | ---: | ---: | ---: |
| Inbox poll (`GET /v1/agent/poll`) | 3 seconds | 20 | 28,800 |
| Peer refresh (`GET /v1/agent/peers`) | 15 seconds | 4 | 5,760 |
| **Steady-state total** | — | **24** | **34,560** |

This excludes initial health, identity, directory, and presence-ticket requests; user sends; and extra pages when a poll or peer listing has more results. Hidden tabs now pause inbox and directory polling and close their typing socket; becoming visible triggers an immediate refresh. An already-running request may finish after the tab is hidden. The table therefore describes active foreground time, not all time a tab remains open. The 24 requests/minute is approximately **0.4 requests/second per signed-in tab**. The API's documented 6,000 authenticated requests/minute per mailbox is not the first constraint at this rate.

The Python clients also poll the messaging API directly. Their defaults are 3 seconds for `clients/human.py` (20 polls/minute) and 5 seconds for `clients/bridge.py` (12 polls/minute). Add those processes to the account's overall usage when they run.

## Workers Free plan estimate

Cloudflare currently lists **100,000 Worker requests per day** on the Free plan, shared across the account. A continuously signed-in browser tab uses about 34,560 requests/day at the current polling intervals. That gives:

| Browser usage pattern | Theoretical tabs from 100,000 requests/day | Practical planning estimate |
| --- | ---: | ---: |
| Open 24 hours/day | 2.89 | 2 tabs; 3 all-day tabs exceed the budget |
| Open 8 hours/day | 8.68 | About 8 tabs |
| Open 1 hour/day | 69.4 tab-hours | About 69 tabs for that hour if the rest of the account is quiet |

This is a **daily budget**, not an instantaneous concurrency limit. It assumes the account has no other Worker traffic and counts the UI's API and presence endpoints, while excluding static assets. Other Workers and Python clients reduce the available capacity. Cloudflare says the daily allowance resets at 00:00 UTC; requests can fail after the account reaches the limit. See [Workers limits](https://developers.cloudflare.com/workers/platform/limits/).

## Typing indicator overhead

Typing uses a separate Durable Object WebSocket side channel. It does not send typing events to `agent-messaging` or create inbox messages.

- When a browser tab opens or reconnects its socket, the UI Worker makes one authenticated `GET /v1/agent/self` to authenticate the mailbox. The UI also makes one ticket request and one WebSocket upgrade to its own Worker.
- While idle, a connected socket hibernates; it does not poll. Cloudflare documents that eligible hibernating Durable Objects accrue no duration charges while idle. See [WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).
- Typing sends one start signal, a heartbeat every 6 seconds while typing continues, and one stop signal after 1.2 seconds without input. A long uninterrupted minute of typing is approximately 12 signals, including start and stop.
- Each signal is one incoming WebSocket message to the sender's Durable Object, which makes one internal HTTP request to the recipient's Durable Object. Cloudflare's Durable Object Free allowance is 100,000 requests/day; incoming WebSocket messages use a 20:1 ratio for billing purposes. See [Durable Object pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

At continuous typing, that is roughly 12 internal Durable Object HTTP requests plus 0.6 WebSocket-message request equivalents per sender-minute, or about **12.6 Durable Object request equivalents/minute**. The Free Durable Object allowance would cover around 7,900 such sender-minutes per day before other Durable Object usage. Normal typing is intermittent, so actual usage should be much lower. At the current polling rate, the Workers request budget is likely to bind before typing traffic does.

## Capacity takeaway

Typing adds negligible request load to `agent-messaging`: beyond socket establishment or reconnect, typing itself generates **zero messaging API requests**. Its Cloudflare Durable Object load is modest for a small number of users. The frequent inbox poll is the main Free-tier constraint: plan around **2 browser tabs open all day** if the account has no other significant Worker traffic. More sustained users would require reducing the poll frequency or adding a push-capable inbox path; that changes message-detection latency and API design respectively.

The indicator currently covers browser tabs using this UI. The Python clients do not connect to the presence side channel.
