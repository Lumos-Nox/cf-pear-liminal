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
    if (url.pathname.startsWith("/api/")) return proxyApi(request, env, url);
    return env.ASSETS.fetch(request);
  },
};
