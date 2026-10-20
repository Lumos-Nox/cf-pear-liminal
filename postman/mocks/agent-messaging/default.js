// Local fixtures from agent-messaging OpenAPI 2.1.0. /simulation/* and fault-*
// token suffixes are test controls, never production routes or credentials.
const http = require("node:http");
const peers = [
  { mid: `m-${"b".repeat(32)}`, label: "Bob", joined_at: 1720000000000 },
  { mid: `m-${"c".repeat(32)}`, label: "Carol", joined_at: 1720000000000 },
];
const adminSecret = "test-admin-secret-".padEnd(32, "x");
const seen = new Set();
const accepted = new Map();
const inboxes = new Map();
let requests = [];
let config = {};
let registries = { capabilities: [], guide: "Original guide", policy: "Original policy", client: "Original client" };

async function readBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") return JSON.parse(req.body || "{}");
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString() || "{}");
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const path = url.pathname;
  const reply = (status, data) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(data));
  };
  const text = (data) => { res.writeHead(200, { "content-type": "text/plain" }); res.end(data); };
  const delay = (ms, callback) => ms ? setTimeout(callback, ms) : callback();
  const body = ["POST", "DELETE"].includes(req.method) ? await readBody(req) : undefined;
  requests.push({ method: req.method, path, key: req.headers["idempotency-key"], body });
  if (path === "/simulation/reset") {
    seen.clear(); accepted.clear(); inboxes.clear(); requests = []; config = {};
    registries = { capabilities: [], guide: "Original guide", policy: "Original policy", client: "Original client" };
    return reply(200, { ok: true });
  }
  if (path === "/simulation/config") { config = { ...config, ...body }; return reply(200, { ok: true }); }
  if (path === "/simulation/inbox") {
    inboxes.set(body.to, [...(inboxes.get(body.to) || []), ...body.messages]);
    return reply(200, { ok: true });
  }
  if (path === "/simulation/state") return reply(200, { requests, accepted: accepted.size, registries });
  if (req.method === "GET" && path === "/v1/public/health") return reply(200, { ok: true, version: "2.1.0" });
  const publicResource = path.match(/^\/v1\/public\/(capabilities|guide|policy|client)$/)?.[1];
  if (publicResource) {
    if (config.failRegistry === publicResource) return reply(503, { error: "unavailable" });
    return publicResource === "capabilities" ? reply(200, { version: 1, capabilities: registries.capabilities }) : text(registries[publicResource]);
  }
  if (path.startsWith("/v1/admin/")) {
    if (req.headers["x-admin-secret"] !== adminSecret) return reply(401, { error: "unauthorized" });
    if (path === "/v1/admin/agents") return delay(config.adminListDelay || 0, () => reply(200, { agents: peers, next_cursor: null }));
    const agent = peers.find((peer) => path === `/v1/admin/agents/${peer.mid}`);
    if (agent && req.method === "GET") return delay(config.detailDelays?.[agent.label] || 0, () => reply(200, {
      ...agent, created_at: agent.joined_at, capabilities: [], active: true, message_count: 0, message_bytes: 0,
    }));
    if (agent && req.method === "DELETE") return reply(200, { ok: true, mid: agent.mid });
    const resource = path.match(/^\/v1\/admin\/registry\/(capabilities|guide|policy|client)$/)?.[1];
    if (resource && req.method === "POST") return delay(config.registrySaveDelay || 0, () => {
      registries[resource] = body[resource === "capabilities" ? "capabilities" : resource === "client" ? "source" : "markdown"];
      reply(200, { ok: true, version: 2 });
    });
  }
  const token = (req.headers.authorization || "").replace(/^Bearer /, "");
  if (!token) return reply(401, { error: "unauthorized" });
  if (req.method === "GET" && path === "/v1/agent/self") {
    if (config.redirectSelf) { res.writeHead(302, { location: req.url.replace("/v1/agent/self", "/simulation/redirect-target") }); return res.end(); }
    if (token.endsWith(".fault-null")) return reply(200, null);
    if (token.endsWith(".fault-unavailable")) return reply(503, { error: "unavailable" });
    if (token.endsWith(".fault-once") && !seen.has(token)) {
      seen.add(token);
      return reply(503, { error: "unavailable" });
    }
    const identity = {
      mid: token.split(".")[0], label: "Alice", capabilities: [],
      created_at: 1720000000000, message_count: 0, message_bytes: 0,
    };
    return delay(token.endsWith(".fault-slow") ? 13000 : 0, () => reply(200, identity));
  }
  if (req.method === "GET" && path === "/v1/agent/peers") return reply(200, { peers, next_cursor: null });
  if (req.method === "GET" && path === "/v1/agent/poll") {
    if (config.pollUnauthorized) return reply(401, { error: "unauthorized" });
    const messages = inboxes.get(token.split(".")[0]) || [];
    const since = Number(url.searchParams.get("since") || 0);
    const page = messages.slice(since, since + Number(url.searchParams.get("limit") || 100));
    return reply(200, { messages: page, cursor: String(since + page.length), has_more: since + page.length < messages.length });
  }
  if (req.method === "POST" && path === "/v1/agent/send") {
    if (token.endsWith(".fault-send")) return delay(300, () => reply(503, { error: "unavailable" }));
    const key = `${token}:${req.headers["idempotency-key"]}`;
    const prior = accepted.get(key);
    if (prior && JSON.stringify(prior.body) !== JSON.stringify(body)) return reply(409, { error: "idempotency conflict" });
    // The service uses an independent incrementing message ID in each recipient
    // mailbox; incoming and outgoing IDs in a conversation can overlap.
    const result = prior?.result || { id: String(1 + [...accepted.values()].filter((entry) => entry.body.to === body.to).length), ts: Date.now() };
    accepted.set(key, { body, result });
    const fail = config.failSendResponses || (token.endsWith(".fault-after-accept") && !prior);
    return delay(config.sendDelay ?? 300, () => fail
      ? reply(503, { error: "response lost after acceptance" })
      : reply(200, { ...result, duplicate: Boolean(prior) }));
  }
  return reply(501, { error: "Not modeled by this regression fixture" });
}).listen(process.env.PORT || 4500, "127.0.0.1");
