const ALLOWED_ROUTES = {
  GET: new Set([
    "/v1/public/health",
    "/v1/public/meta",
    "/v1/public/capabilities",
    "/v1/agent/self",
    "/v1/agent/peers",
    "/v1/agent/poll",
  ]),
  POST: new Set([
    "/v1/agent/join",
    "/v1/agent/leave",
    "/v1/agent/send",
  ]),
};

const ALLOWED_QUERY = {
  "/v1/agent/peers": new Set(["limit", "cursor", "capability"]),
  "/v1/agent/poll": new Set(["since", "limit"]),
};
const MAX_REQUEST_BYTES = 128 * 1024;
const UPSTREAM_TIMEOUT_MS = 12_000;
const MAILBOX_ID_PATTERN = /^m-[0-9a-f]{32}$/;

async function createPresenceTicket(request, env) {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let identity;
  try {
    const response = await env.MESSAGING_API.fetch(new Request("https://agent-messaging/v1/agent/self", {
      headers: { authorization },
    }));
    if (!response.ok) return json({ error: response.status === 401 ? "unauthorized" : "identity unavailable" }, response.status);
    identity = await response.json();
  } catch {
    return json({ error: "identity unavailable" }, 502);
  }

  if (typeof identity.mid !== "string" || !MAILBOX_ID_PATTERN.test(identity.mid)) return json({ error: "invalid identity" }, 502);
  const id = env.TYPING_PRESENCE.idFromName(identity.mid);
  const stub = env.TYPING_PRESENCE.get(id);
  const ticketResponse = await stub.fetch("https://typing.internal/ticket", { method: "POST" });
  if (!ticketResponse.ok) return json({ error: "presence unavailable" }, 503);
  const { ticket } = await ticketResponse.json();
  return json({ mid: identity.mid, ticket }, 200);
}

async function routePresenceSocket(request, env, url) {
  if (request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "websocket upgrade required" }, 426);
  }
  const mid = url.searchParams.get("mid");
  const ticket = url.searchParams.get("ticket");
  if (!mid || !MAILBOX_ID_PATTERN.test(mid) || !ticket || ticket.length > 100) return json({ error: "invalid ticket" }, 401);
  const id = env.TYPING_PRESENCE.idFromName(mid);
  const stub = env.TYPING_PRESENCE.get(id);
  const headers = new Headers({ Upgrade: "websocket", "x-presence-mid": mid, "x-presence-ticket": ticket });
  return stub.fetch(new Request("https://typing.internal/connect", { method: "GET", headers }));
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
  if (!ALLOWED_ROUTES[request.method]?.has(path)) {
    return json({ error: "not found" }, 404);
  }
  if (!validQuery(path, url.searchParams)) {
    return json({ error: "unsupported query parameter" }, 400);
  }

  const headers = new Headers();
  for (const name of ["authorization", "content-type", "idempotency-key"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  let body;
  if (request.method !== "GET" && request.method !== "HEAD") {
    const declaredLength = Number(request.headers.get("content-length") || 0);
    if (declaredLength > MAX_REQUEST_BYTES) return json({ error: "request body too large" }, 413);
    const parsedBody = await readLimitedBody(request);
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

  const controller = new AbortController();
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      controller.abort();
      reject(new Error("messaging API request timed out"));
    }, UPSTREAM_TIMEOUT_MS);
  });

  try {
    const upstream = await Promise.race([
      env.MESSAGING_API.fetch(new Request(upstreamRequest, { signal: controller.signal })),
      timeout,
    ]);
    const responseHeaders = new Headers(upstream.headers);
    responseHeaders.set("cache-control", "no-store");
    responseHeaders.set("x-content-type-options", "nosniff");
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: responseHeaders,
    });
  } catch {
    if (controller.signal.aborted) {
      return json({
        error: "remote messaging service binding timed out; verify MESSAGING_API targets the correct Worker name and environment in the Cloudflare account used by Wrangler",
      }, 504);
    }
    return json({ error: "remote messaging service binding failed; verify the MESSAGING_API Worker name, environment, and Cloudflare account" }, 502);
  } finally {
    clearTimeout(timeoutId);
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
      if (!mid || !ticket) return json({ error: "invalid ticket" }, 401);
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
      if (typeof event.from !== "string" || !MAILBOX_ID_PATTERN.test(event.from) || typeof event.active !== "boolean") return json({ error: "invalid event" }, 400);
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
    const attachment = socket.deserializeAttachment();
    if (!attachment?.mid) return;

    if (event.type === "watch" && (event.peer === null || (typeof event.peer === "string" && MAILBOX_ID_PATTERN.test(event.peer)))) {
      if (attachment.typing && attachment.peer && attachment.peer !== event.peer) {
        await this.forwardTyping(attachment.peer, attachment.mid, false);
      }
      socket.serializeAttachment({ ...attachment, peer: event.peer, typing: false, lastSignalAt: 0 });
      return;
    }
    if (event.type !== "typing" || typeof event.active !== "boolean" || !attachment.peer) return;

    const now = Date.now();
    if (now - attachment.lastSignalAt < 750) return;
    if (event.active && attachment.typing && now - attachment.lastSignalAt < 5_000) return;
    if (event.active === attachment.typing && event.active === false) return;
    socket.serializeAttachment({ ...attachment, typing: event.active, lastSignalAt: now });
    await this.forwardTyping(attachment.peer, attachment.mid, event.active);
  }

  async webSocketClose(socket) {
    const attachment = socket.deserializeAttachment();
    if (!attachment?.typing || !attachment.peer) return;
    await this.forwardTyping(attachment.peer, attachment.mid, false);
  }

  async forwardTyping(recipient, from, active) {
    const recipientId = this.env.TYPING_PRESENCE.idFromName(recipient);
    await this.env.TYPING_PRESENCE.get(recipientId).fetch("https://typing.internal/event", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ from, active }),
    });
  }
}
