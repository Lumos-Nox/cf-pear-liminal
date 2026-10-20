const ALLOWED_ROUTES = {
  GET: new Set([
    "/v1/public/health",
    "/v1/public/meta",
    "/v1/public/capabilities",
    "/v1/public/guide",
    "/v1/public/policy",
    "/v1/public/client",
    "/v1/admin/agents",
    "/v1/agent/self",
    "/v1/agent/peers",
    "/v1/agent/poll",
  ]),
  POST: new Set([
    "/v1/agent/join",
    "/v1/agent/leave",
    "/v1/agent/send",
    "/v1/admin/registry/capabilities",
    "/v1/admin/registry/guide",
    "/v1/admin/registry/policy",
    "/v1/admin/registry/client",
  ]),
};

const ALLOWED_QUERY = {
  "/v1/agent/peers": new Set(["limit", "cursor", "capability"]),
  "/v1/agent/poll": new Set(["since", "limit"]),
  "/v1/admin/agents": new Set(["limit", "cursor"]),
};
const MAX_REQUEST_BYTES = 128 * 1024;
const UPSTREAM_TIMEOUT_MS = 12_000;
const MAILBOX_ID_PATTERN = /^m-[0-9a-f]{32}$/;
const MAX_PRESENCE_SOCKETS = 10;
const TYPING_EXPIRY_MS = 9_000;

async function fetchMessaging(request, env) {
  const controller = new AbortController();
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      reject(new DOMException("messaging API request timed out", "TimeoutError"));
      controller.abort();
    }, UPSTREAM_TIMEOUT_MS);
  });
  try {
    return await Promise.race([
      env.MESSAGING_API.fetch(new Request(request, { signal: controller.signal })),
      timeout,
    ]);
  } finally {
    clearTimeout(timeoutId);
  }
}

async function createPresenceTicket(request, env) {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let identity;
  try {
    const response = await fetchMessaging(new Request("https://agent-messaging/v1/agent/self", {
      headers: { authorization },
    }), env);
    if (!response.ok) return json({ error: response.status === 401 ? "unauthorized" : "identity unavailable" }, response.status);
    identity = await response.json();
  } catch (error) {
    return json({ error: "identity unavailable" }, error?.name === "TimeoutError" ? 504 : 502);
  }

  if (typeof identity?.mid !== "string" || !MAILBOX_ID_PATTERN.test(identity.mid)) return json({ error: "invalid identity" }, 502);
  try {
    const id = env.TYPING_PRESENCE.idFromName(identity.mid);
    const stub = env.TYPING_PRESENCE.get(id);
    const ticketResponse = await stub.fetch("https://typing.internal/ticket", { method: "POST" });
    if (!ticketResponse.ok) return json({ error: "presence unavailable" }, ticketResponse.status === 429 ? 429 : 503);
    const { ticket } = await ticketResponse.json();
    if (typeof ticket !== "string" || !ticket) return json({ error: "presence unavailable" }, 503);
    return json({ mid: identity.mid, ticket }, 200);
  } catch {
    return json({ error: "presence unavailable" }, 503);
  }
}

async function routePresenceSocket(request, env, url) {
  if (request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "websocket upgrade required" }, 426);
  }
  const mid = url.searchParams.get("mid");
  const ticket = url.searchParams.get("ticket");
  if (!mid || !MAILBOX_ID_PATTERN.test(mid) || !ticket || ticket.length > 100) return json({ error: "invalid ticket" }, 401);
  const headers = new Headers({ Upgrade: "websocket", "x-presence-mid": mid, "x-presence-ticket": ticket });
  try {
    const id = env.TYPING_PRESENCE.idFromName(mid);
    const stub = env.TYPING_PRESENCE.get(id);
    return await stub.fetch(new Request("https://typing.internal/connect", { method: "GET", headers }));
  } catch {
    return json({ error: "presence unavailable" }, 503);
  }
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function validQuery(path, searchParams) {
  const allowed = ALLOWED_QUERY[path] || new Set();
  for (const key of searchParams.keys()) {
    if (!allowed.has(key)) return false;
  }
  return true;
}

async function readLimitedBody(request) {
  if (!request.body) return { body: undefined };
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_REQUEST_BYTES) {
        await reader.cancel();
        return { error: json({ error: "request body too large" }, 413) };
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { body: bytes.buffer };
}

async function proxyApi(request, env, url) {
  const path = url.pathname.slice("/api".length);
  const adminAgentDetail = /^\/v1\/admin\/agents\/m-[0-9a-f]{32}$/.test(path);
  const routeAllowed = ALLOWED_ROUTES[request.method]?.has(path)
    || (adminAgentDetail && ["GET", "DELETE"].includes(request.method));
  if (!routeAllowed) {
    return json({ error: "not found" }, 404);
  }
  if (!validQuery(path, url.searchParams)) {
    return json({ error: "unsupported query parameter" }, 400);
  }

  const headers = new Headers();
  for (const name of ["authorization", "content-type", "idempotency-key", "x-admin-secret"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  let body;
  if (request.method !== "GET" && request.method !== "HEAD") {
    const declaredLength = Number(request.headers.get("content-length") || 0);
    if (declaredLength > MAX_REQUEST_BYTES) return json({ error: "request body too large" }, 413);
    let parsedBody;
    try { parsedBody = await readLimitedBody(request); } catch { return json({ error: "could not read request body" }, 400); }
    if (parsedBody.error) return parsedBody.error;
    body = parsedBody.body;
  }

  const upstreamUrl = new URL(`https://agent-messaging${path}`);
  upstreamUrl.pathname = path;
  upstreamUrl.search = url.search;
  const upstreamRequest = new Request(upstreamUrl, {
    method: request.method,
    headers,
    body,
    redirect: "manual",
  });

  try {
    const upstream = await fetchMessaging(upstreamRequest, env);
    if (upstream.status >= 300 && upstream.status < 400) {
      await upstream.body?.cancel();
      return json({ error: "unexpected redirect from messaging service" }, 502);
    }
    const responseHeaders = new Headers(upstream.headers);
    responseHeaders.set("cache-control", "no-store");
    responseHeaders.set("x-content-type-options", "nosniff");
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: responseHeaders,
    });
  } catch (error) {
    if (error?.name === "TimeoutError") {
      return json({
        error: "remote messaging service binding timed out; verify MESSAGING_API targets the correct Worker name and environment in the Cloudflare account used by Wrangler",
      }, 504);
    }
    return json({ error: "remote messaging service binding failed; verify the MESSAGING_API Worker name, environment, and Cloudflare account" }, 502);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/presence-ticket") {
      if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
      return createPresenceTicket(request, env);
    }
    if (url.pathname === "/presence") return routePresenceSocket(request, env, url);
    if (url.pathname.startsWith("/api/")) return proxyApi(request, env, url);
    return env.ASSETS.fetch(request);
  },
};

export class TypingPresence {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/ticket" && request.method === "POST") {
      const now = Date.now();
      const tickets = await this.state.storage.list({ prefix: "ticket:" });
      let outstanding = 0;
      for (const [key, expiresAt] of tickets) {
        if (typeof expiresAt !== "number" || expiresAt < now) await this.state.storage.delete(key);
        else outstanding += 1;
      }
      if (outstanding >= 5) return json({ error: "too many pending tickets" }, 429);
      const ticket = crypto.randomUUID();
      await this.state.storage.put(`ticket:${ticket}`, now + 30_000);
      return json({ ticket });
    }

    if (url.pathname === "/connect" && request.method === "GET") {
      const mid = request.headers.get("x-presence-mid");
      const ticket = request.headers.get("x-presence-ticket");
      if (!MAILBOX_ID_PATTERN.test(mid) || !ticket) return json({ error: "invalid ticket" }, 401);
      if (this.state.getWebSockets().length >= MAX_PRESENCE_SOCKETS) return json({ error: "too many presence connections" }, 429);
      const expiresAt = await this.state.storage.get(`ticket:${ticket}`);
      await this.state.storage.delete(`ticket:${ticket}`);
      if (typeof expiresAt !== "number" || expiresAt < Date.now()) return json({ error: "expired ticket" }, 401);

      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      server.serializeAttachment({ mid, peer: null, typing: false, lastSignalAt: 0 });
      this.state.acceptWebSocket(server);
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/event" && request.method === "POST") {
      let event;
      try { event = await request.json(); } catch { return json({ error: "invalid event" }, 400); }
      if (!event || typeof event.from !== "string" || !MAILBOX_ID_PATTERN.test(event.from) || typeof event.active !== "boolean") return json({ error: "invalid event" }, 400);
      for (const socket of this.state.getWebSockets()) {
        const attachment = socket.deserializeAttachment();
        if (attachment?.peer !== event.from) continue;
        try { socket.send(JSON.stringify({ type: "typing", from: event.from, active: event.active })); } catch {}
      }
      return json({ ok: true });
    }
    return json({ error: "not found" }, 404);
  }

  async webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > 512) return;
    let event;
    try { event = JSON.parse(message); } catch { return; }
    if (!event || typeof event !== "object" || Array.isArray(event)) return;
    const attachment = socket.deserializeAttachment();
    if (!attachment?.mid) return;

    if (event.type === "watch" && (event.peer === null || (typeof event.peer === "string" && MAILBOX_ID_PATTERN.test(event.peer)))) {
      if (event.peer === attachment.mid) return;
      if (attachment.peer === event.peer) return;
      socket.serializeAttachment({ ...attachment, peer: event.peer, typing: false, lastSignalAt: 0 });
      if (attachment.typing && attachment.peer && !this.otherSocketTyping(attachment.peer, socket)) {
        await this.forwardTyping(attachment.peer, attachment.mid, false);
      }
      return;
    }
    if (event.type !== "typing" || typeof event.active !== "boolean" || !attachment.peer) return;

    const now = Date.now();
    if (event.active && attachment.typing && now - attachment.lastSignalAt < 5_000) return;
    if (event.active === attachment.typing && event.active === false) return;
    socket.serializeAttachment({ ...attachment, typing: event.active, lastSignalAt: now });
    if (!event.active && this.otherSocketTyping(attachment.peer, socket)) return;
    await this.forwardTyping(attachment.peer, attachment.mid, event.active);
  }

  otherSocketTyping(peer, excluded) {
    return this.state.getWebSockets().some((socket) => {
      if (socket === excluded) return false;
      const data = socket.deserializeAttachment();
      return data?.peer === peer && data.typing && Date.now() - data.lastSignalAt < TYPING_EXPIRY_MS;
    });
  }

  async webSocketClose(socket, code = 1000) {
    const attachment = socket.deserializeAttachment();
    try { if (attachment) socket.serializeAttachment({ ...attachment, typing: false }); } catch {}
    try { socket.close(code === 1005 || code === 1006 ? 1000 : code, "closed"); } catch {}
    if (!attachment?.typing || !attachment.peer || this.otherSocketTyping(attachment.peer, socket)) return;
    await this.forwardTyping(attachment.peer, attachment.mid, false);
  }

  async webSocketError(socket) {
    await this.webSocketClose(socket, 1011);
  }
  async forwardTyping(recipient, from, active) {
    try {
      const recipientId = this.env.TYPING_PRESENCE.idFromName(recipient);
      const response = await this.env.TYPING_PRESENCE.get(recipientId).fetch("https://typing.internal/event", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ from, active }),
      });
      await response.body?.cancel();
    } catch {
      // Presence is best effort. A recipient failure must not close the sender's
      // socket; heartbeats retry and the recipient expires stale indicators.
    }
  }
}
