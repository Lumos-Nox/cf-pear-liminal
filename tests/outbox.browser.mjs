import assert from "node:assert/strict";
import { startTestApp } from "./browser-fixture.mjs";

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const app = await startTestApp();
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}) });
const mid = `m-${"a".repeat(32)}`;
const bob = `m-${"b".repeat(32)}`;
const carol = `m-${"c".repeat(32)}`;
const errors = [];

async function control(path, body) {
  const response = await fetch(`${process.env.SIMULATION_URL}/messaging/simulation/${path}`, body ? {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  } : {});
  assert.equal(response.status, 200);
  return response.json();
}
async function open(conversations = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 850 } });
  await context.addInitScript((saved) => {
    if (sessionStorage.getItem("test.outbox.seeded")) return;
    sessionStorage.setItem("agent-comm.session.v1", JSON.stringify(saved));
    sessionStorage.setItem("test.outbox.seeded", "yes");
  }, { mid, label: "Alice", token: `${mid}.valid`, conversations });
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  page.on("pageerror", (error) => errors.push(error.stack));
  await page.goto(app.url);
  await select(page, "Bob");
  return page;
}
async function select(page, name) { await page.getByRole("button", { name: new RegExp(`^${name},`) }).click(); }
async function send(page, text) {
  await page.locator("#messageInput").fill(text);
  await page.locator("#messageInput").press("Enter");
  assert.equal(await page.locator("#messageInput").inputValue(), "");
  assert.equal(await page.locator("#sendButton").isDisabled(), false);
  assert.equal(await page.locator(".message-bubble").last().textContent(), text);
  assert.equal(await page.evaluate(() => document.activeElement.id), "messageInput");
}
async function saved(page) { return page.evaluate(() => JSON.parse(sessionStorage.getItem("agent-comm.session.v1"))); }
async function delivered(page) {
  await page.waitForFunction(() => Object.values(JSON.parse(sessionStorage.getItem("agent-comm.session.v1")).conversations)
    .every((conversation) => !conversation.outbox?.length));
}

try {
  await control("reset", {});
  await control("config", { sendDelay: 1500 });
  let page = await open();
  await send(page, "First queued note");
  await send(page, "Second queued note");
  const queue = (await saved(page)).conversations[bob].outbox;
  assert.equal(queue.length, 2);
  assert.deepEqual(queue.map((pending) => pending.body.payload.seq), [0, 1]);
  assert.notEqual(queue[0].key, queue[1].key);
  assert.equal(await page.locator(".message-delivery:visible").count(), 0);
  await select(page, "Carol");
  await send(page, "Independent peer note");
  let requests = (await control("state")).requests.filter((request) => request.path === "/v1/agent/send");
  assert.equal(requests.filter((request) => request.body.to === bob).length, 1, "Notes to Bob must deliver serially");
  assert.equal(requests.filter((request) => request.body.to === carol).length, 1, "A send to Carol must not wait for Bob");
  await select(page, "Bob");
  await page.evaluate(() => { window.firstQueuedRow = document.querySelector(".message-row"); });
  await page.locator("#messageInput").fill("New draft while both notes deliver");
  await delivered(page);
  assert.equal(await page.evaluate(() => document.querySelector(".message-row") === window.firstQueuedRow), true);
  assert.equal(await page.locator("#messageInput").inputValue(), "New draft while both notes deliver");
  assert.deepEqual(await page.locator(".message-bubble").allTextContents(), ["First queued note", "Second queued note"]);
  requests = (await control("state")).requests.filter((request) => request.path === "/v1/agent/send" && request.body.to === bob);
  assert.deepEqual(requests.map((request) => request.body.payload.seq), [0, 1]);
  await page.context().close();
  console.log("PASS: immediate notes, rapid sends, per-peer ordering, independent peers, stable rows, and newer drafts");

  await control("reset", {});
  await control("config", { sendDelay: 300, failSendResponses: true });
  page = await open();
  await send(page, "Accepted but response lost");
  await page.locator("#sendRecovery").waitFor({ state: "visible" });
  const first = (await saved(page)).conversations[bob].outbox[0];
  await send(page, "Queued after the failure");
  assert.equal((await saved(page)).conversations[bob].outbox.length, 2);
  assert.equal((await control("state")).accepted, 1);
  await page.locator("#messageInput").fill("Keep this draft after recovery");
  await page.reload();
  await select(page, "Bob");
  assert.deepEqual(await page.locator(".message-bubble").allTextContents(), ["Accepted but response lost", "Queued after the failure"]);
  await control("config", { failSendResponses: false, sendDelay: 300 });
  await page.locator("#retrySend").click();
  await page.locator("#sendRecovery").waitFor({ state: "hidden" });
  await delivered(page);
  assert.equal(await page.locator("#messageInput").inputValue(), "Keep this draft after recovery");
  assert.equal(await page.locator(".message-bubble").count(), 2);
  let state = await control("state");
  requests = state.requests.filter((request) => request.path === "/v1/agent/send");
  assert.equal(requests.length, 3);
  assert.deepEqual(requests[0], requests[1]);
  assert.equal(requests[1].key, first.key);
  assert.equal(state.accepted, 2);
  await page.context().close();
  console.log("PASS: failures keep new sends available; reload and exact retry recover the entire queue without duplicates");

  await control("reset", {});
  const legacy = { key: "old-thread-h0", body: { to: bob, payload: { thread: "old-thread", seq: 0, type: "msg", text: "Legacy unconfirmed note" } }, draft: "Legacy unconfirmed note", revision: 1 };
  page = await open({ [bob]: { thread: "old-thread", seq: 0, messages: [{ id: "1", text: "Incoming ID overlap", mine: false, ts: Date.now(), type: "msg" }],
    pendingSend: legacy, draft: "A newer saved draft", draftRevision: 2 } });
  assert.equal(await page.locator("#messageInput").inputValue(), "A newer saved draft");
  await send(page, "Next note after migration");
  assert.deepEqual((await saved(page)).conversations[bob].outbox.map((pending) => pending.body.payload.seq), [0, 1]);
  await page.locator("#retrySend").click();
  await delivered(page);
  assert.deepEqual(await page.locator(".message-bubble").allTextContents(), ["Incoming ID overlap", "Legacy unconfirmed note", "Next note after migration"]);
  state = await control("state");
  requests = state.requests.filter((request) => request.path === "/v1/agent/send");
  assert.equal(requests[0].key, legacy.key);
  assert.deepEqual(requests[0].body, legacy.body);
  await page.context().close();
  console.log("PASS: existing unconfirmed requests migrate without losing text, keys, sequence reservations, or incoming messages");

  await control("reset", {});
  await control("config", { sendDelay: 1000 });
  page = await open();
  await send(page, "Reload during delivery");
  await send(page, "Waiting behind the active request");
  const beforeReload = (await saved(page)).conversations[bob].outbox;
  await page.reload();
  await select(page, "Bob");
  assert.deepEqual((await saved(page)).conversations[bob].outbox.map((entry) => entry.key), beforeReload.map((entry) => entry.key));
  await page.locator("#retrySend").click();
  await delivered(page);
  state = await control("state");
  assert.equal(state.accepted, 2);
  assert.deepEqual(await page.locator(".message-bubble").allTextContents(), ["Reload during delivery", "Waiting behind the active request"]);
  await page.context().close();
  console.log("PASS: reload during an active request preserves both notes and safely reconciles acceptance");

  await control("reset", {});
  await control("config", { sendDelay: 500 });
  page = await open();
  await send(page, "Last note in the old chat");
  page.on("dialog", (dialog) => dialog.accept());
  await page.locator("#finishChat").click();
  await page.locator("#newChat").click();
  await send(page, "First note in the new chat");
  await delivered(page);
  requests = (await control("state")).requests.filter((request) => request.path === "/v1/agent/send");
  assert.deepEqual(requests.map((request) => request.body.payload.seq), [0, 1, 0]);
  assert.deepEqual(requests.map((request) => request.body.payload.type), ["msg", "done", "msg"]);
  assert.notEqual(requests[0].body.payload.thread, requests[2].body.payload.thread);
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  assert.equal(await page.locator("#sendButton").isEnabled(), true);
  await page.context().close();
  console.log("PASS: ending and reopening a chat preserves queue order without an old acknowledgement closing the new chat");

  await control("reset", {});
  await control("config", { sendDelay: 900 });
  page = await open();
  await send(page, "Old session request");
  await page.locator("#localSignOut").click();
  await page.waitForTimeout(1100);
  assert.equal(await saved(page), null);
  assert.equal(await page.locator(".message-bubble").count(), 0);
  assert.equal(await page.locator("#connectCard").isVisible(), true);
  await page.context().close();
  console.log("PASS: late delivery cannot restore chat or credentials after sign-out");
  assert.deepEqual(errors, []);
} finally {
  await browser.close();
  app.close();
}
