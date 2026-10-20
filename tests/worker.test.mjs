import assert from "node:assert/strict";
import { test } from "node:test";
import worker, { TypingPresence } from "../src/index.js";

const mid = `m-${"a".repeat(32)}`;
const peer = `m-${"b".repeat(32)}`;

function presence() {
  const records = new Map();
  const events = [];
  const sockets = [];
  const state = {
    storage: {
      list: async () => new Map(records),
      get: async (key) => records.get(key),
      put: async (key, value) => records.set(key, value),
      delete: async (key) => records.delete(key),
    },
    getWebSockets: () => sockets,
  };
  const object = new TypingPresence(state, {
    TYPING_PRESENCE: {
      idFromName: (name) => name,
      get: (recipient) => ({ fetch: async (_url, options) => {
        events.push({ recipient, ...JSON.parse(options.body) });
        return Response.json({ ok: true });
      } }),
    },
  });
  let attachment = { mid, peer, typing: false, lastSignalAt: 0 };
  const socket = {
    deserializeAttachment: () => structuredClone(attachment),
    serializeAttachment: (value) => { attachment = structuredClone(value); },
  };
  return { object, socket, events, records, sockets };
}

test("a quick typing stop reaches the recipient immediately", async () => {
  const { object, socket, events } = presence();
  await object.webSocketMessage(socket, '{"type":"typing","active":true}');
  await object.webSocketMessage(socket, '{"type":"typing","active":false}');
  assert.deepEqual(events.map((event) => event.active), [true, false]);
  assert.equal(socket.deserializeAttachment().typing, false);
});

test("repeated watches preserve typing and close still clears it", async () => {
  const { object, socket, events } = presence();
  await object.webSocketMessage(socket, '{"type":"typing","active":true}');
  await object.webSocketMessage(socket, JSON.stringify({ type: "watch", peer }));
  await object.webSocketClose(socket);
  assert.deepEqual(events.map((event) => event.active), [true, false]);
});

test("typing heartbeats remain throttled and peer changes clear old presence", async () => {
  const { object, socket, events } = presence();
  await object.webSocketMessage(socket, '{"type":"typing","active":true}');
  await object.webSocketMessage(socket, '{"type":"typing","active":true}');
  await object.webSocketMessage(socket, '{"type":"watch","peer":null}');
  assert.deepEqual(events.map((event) => event.active), [true, false]);
  assert.equal(events[1].recipient, peer);
  assert.equal(socket.deserializeAttachment().peer, null);
});

test("malformed websocket messages and null events do not throw", async () => {
  const { object, socket, events } = presence();
  for (const message of ["null", "[]", "1", '"text"', "{", "{}"]) {
    await object.webSocketMessage(socket, message);
  }
  assert.equal(events.length, 0);
  const response = await object.fetch(new Request("https://typing.internal/event", { method: "POST", body: "null" }));
  assert.equal(response.status, 400);
});

test("pending tickets are bounded and expired tickets can be replaced", async () => {
  const { object, records } = presence();
  const request = () => new Request("https://typing.internal/ticket", { method: "POST" });
  for (let i = 0; i < 5; i++) assert.equal((await object.fetch(request())).status, 200);
  assert.equal((await object.fetch(request())).status, 429);
  for (const key of records.keys()) records.set(key, Date.now() - 1);
  assert.equal((await object.fetch(request())).status, 200);
  assert.equal(records.size, 1);
});

test("unapproved routes and query parameters never reach the binding", async () => {
  const env = { MESSAGING_API: { fetch: () => assert.fail("must not forward") } };
  assert.equal((await worker.fetch(new Request("https://app/api/v1/private"), env)).status, 404);
  assert.equal((await worker.fetch(new Request("https://app/api/v1/agent/self?url=evil"), env)).status, 400);
  assert.equal((await worker.fetch(new Request("https://app/api/presence-ticket", { method: "POST" }), env)).status, 401);
});

test("one tab stopping or closing does not clear another tab's typing", async () => {
  const { object, socket, sockets, events } = presence();
  let data = { mid, peer, typing: false, lastSignalAt: 0 };
  const second = { deserializeAttachment: () => structuredClone(data), serializeAttachment: (value) => { data = value; }, close() {} };
  sockets.push(socket, second);
  await object.webSocketMessage(socket, '{"type":"typing","active":true}');
  await object.webSocketMessage(second, '{"type":"typing","active":true}');
  await object.webSocketMessage(socket, '{"type":"typing","active":false}');
  assert.deepEqual(events.map((event) => event.active), [true, true]);
  await object.webSocketClose(socket);
  assert.equal(events.length, 2);
  await object.webSocketError(second);
  assert.equal(events.at(-1).active, false);
});

test("presence connections are bounded and self-watch is ignored", async () => {
  const { object, socket, sockets, records, events } = presence();
  await object.webSocketMessage(socket, JSON.stringify({ type: "watch", peer: mid }));
  assert.equal(socket.deserializeAttachment().peer, peer);
  assert.equal(events.length, 0);
  sockets.push(...Array(10).fill(socket));
  records.set("ticket:pending", Date.now() + 30000);
  const response = await object.fetch(new Request("https://typing.internal/connect", { headers: { "x-presence-mid": mid, "x-presence-ticket": "pending" } }));
  assert.equal(response.status, 429);
  assert.ok(records.has("ticket:pending"));
});

test("oversized and failed request-body streams return controlled errors", async () => {
  const env = { MESSAGING_API: { fetch: () => assert.fail("must not forward") } };
  const large = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(130 * 1024)); controller.close(); } });
  const failed = new ReadableStream({ start(controller) { controller.error(new Error("disconnected")); } });
  for (const [body, status] of [[large, 413], [failed, 400]]) {
    const request = new Request("https://app/api/v1/agent/join", { method: "POST", body, duplex: "half" });
    assert.equal((await worker.fetch(request, env)).status, status);
  }
});

test("missing presence bindings return a controlled service error", async () => {
  const request = new Request(`https://app/presence?mid=${mid}&ticket=pending`, { headers: { upgrade: "websocket" } });
  assert.equal((await worker.fetch(request, {})).status, 503);
});

const simulationUrl = process.env.SIMULATION_URL;
test("worker routes use real HTTP against the Postman simulation", { skip: !simulationUrl }, async (t) => {
  const { object } = presence();
  const env = {
    MESSAGING_API: { fetch: (request) => {
      const url = new URL(request.url);
      return fetch(new Request(`${simulationUrl}/messaging${url.pathname}${url.search}`, request));
    } },
    TYPING_PRESENCE: { idFromName: (name) => name, get: () => ({ fetch: (url, init) => object.fetch(new Request(url, init)) }) },
  };
  const ticketRequest = (suffix) => new Request("https://app/api/presence-ticket", {
    method: "POST", headers: { authorization: `Bearer ${mid}.${suffix}` },
  });
  await t.test("valid identity issues tickets and preserves the 429 limit", async () => {
    for (let i = 0; i < 5; i++) {
      const response = await worker.fetch(ticketRequest("valid"), env);
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.mid, mid);
      assert.equal(typeof body.ticket, "string");
    }
    assert.equal((await worker.fetch(ticketRequest("valid"), env)).status, 429);
  });
  await t.test("invalid identity and upstream errors stay controlled", async () => {
    assert.equal((await worker.fetch(ticketRequest("fault-null"), env)).status, 502);
    assert.equal((await worker.fetch(ticketRequest("fault-unavailable"), env)).status, 503);
  });
  await t.test("a slow identity lookup times out with 504", async () => {
    const start = Date.now();
    assert.equal((await worker.fetch(ticketRequest("fault-slow"), env)).status, 504);
    assert.ok(Date.now() - start < 12500);
  });
  await t.test("the existing API proxy still forwards and disables caching", async () => {
    const response = await worker.fetch(new Request("https://app/api/v1/public/health"), env);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).version, "2.1.0");
    assert.equal(response.headers.get("cache-control"), "no-store");
  });
  await t.test("the proxy refuses upstream redirects", async () => {
    const configure = (redirectSelf) => fetch(`${simulationUrl}/messaging/simulation/config`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ redirectSelf }),
    });
    await configure(true);
    try {
      const response = await worker.fetch(new Request("https://app/api/v1/agent/self", { headers: { authorization: `Bearer ${mid}.valid` } }), env);
      assert.equal(response.status, 502);
      assert.equal(response.headers.get("location"), null);
    } finally { await configure(false); }
  });
});
