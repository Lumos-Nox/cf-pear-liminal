import http from "node:http";
import { readFile } from "node:fs/promises";
import { once } from "node:events";
import worker from "../src/index.js";

export async function startTestApp(simulationUrl = process.env.SIMULATION_URL) {
  if (!simulationUrl) throw new Error("Start the Postman regression simulation and set SIMULATION_URL (see tests/README.md).");
  const assets = new Map([
    ["/", ["index.html", "text/html"]], ["/app.js", ["app.js", "text/javascript"]],
    ["/viewport.js", ["viewport.js", "text/javascript"]], ["/styles.css", ["styles.css", "text/css"]],
  ]);
  const env = {
    MESSAGING_API: { fetch(request) {
      const url = new URL(request.url);
      return fetch(new Request(`${simulationUrl}/messaging${url.pathname}${url.search}`, request));
    } },
    ASSETS: { async fetch(request) {
      const asset = assets.get(new URL(request.url).pathname);
      if (!asset) return new Response(null, { status: 404 });
      return new Response(await readFile(new URL(`../public/${asset[0]}`, import.meta.url)), { headers: { "content-type": asset[1] } });
    } },
  };
  const server = http.createServer(async (request, response) => {
    try {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const result = await worker.fetch(new Request(`http://localhost${request.url}`, {
        method: request.method, headers: request.headers,
        ...(["GET", "HEAD"].includes(request.method) ? {} : { body: Buffer.concat(chunks) }),
      }), env);
      response.writeHead(result.status, Object.fromEntries(result.headers));
      response.end(Buffer.from(await result.arrayBuffer()));
    } catch (error) { response.writeHead(500); response.end(error.message); }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return { url: `http://127.0.0.1:${server.address().port}`, close() { server.closeAllConnections(); server.close(); } };
}
