import assert from "node:assert/strict";
import { startTestApp } from "./browser-fixture.mjs";
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const app = await startTestApp();
const simulation = `${process.env.SIMULATION_URL}/messaging`;
const mid = `m-${"a".repeat(32)}`;
const bob = `m-${"b".repeat(32)}`;
const carol = `m-${"c".repeat(32)}`;
const secret = "test-admin-secret-".padEnd(32, "x");
const errors = [];
async function control(path, body) {
  const response = await fetch(`${simulation}/simulation/${path}`, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : {});
  assert.equal(response.status, 200);
  return response.json();
}
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}) });
async function open(options = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 850 } });
  if (options.mailbox !== false) await context.addInitScript(({ mid, bob, suffix, storageFailure }) => {
    if (!sessionStorage.getItem("test.seeded")) {
      sessionStorage.setItem("agent-comm.session.v1", JSON.stringify({ mid, token: `${mid}.${suffix}`, label: "Alice", conversations: {
        [bob]: { thread: "old-thread", seq: 0, messages: [{ id: "1", text: "Existing message", type: "msg", mine: false, ts: 1720000000000 }] },
      } }));
      sessionStorage.setItem("test.seeded", "yes");
    }
    if (storageFailure) Storage.prototype.setItem = function () { throw new DOMException("Full", "QuotaExceededError"); };
  }, { mid, bob, suffix: options.suffix || "valid", storageFailure: options.storageFailure || false });
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(app.url);
  if (options.mailbox !== false) await page.getByRole("button", { name: /^Bob,/ }).click();
  return page;
}
async function send(page, text) {
  await page.locator("#messageInput").fill(text);
  await page.locator("#messageInput").press("Enter");
}
async function pollNow(page) {
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
}
async function admin(page) {
  await page.locator(".brand-controls").hover();
  await page.locator("#openAdminButton").click();
  await page.locator("#adminSecret").fill(secret);
  await page.locator("#adminLoginButton").click();
}
try {
  await control("reset", {});
  let page = await open({ suffix: "fault-after-accept" });
  await send(page, "Original uncertain message");
  await page.locator("#sendRecovery").waitFor({ state: "visible" });
  await page.locator("#messageInput").fill("New draft to keep");
  await page.waitForTimeout(300);
  await page.reload();
  await page.getByRole("button", { name: /^Bob,/ }).click();
  assert.equal(await page.locator("#messageInput").inputValue(), "New draft to keep");
  await page.locator("#retrySend").click();
  await page.waitForFunction(() => !document.querySelector('#messageList [data-delivery="queued"], #messageList [data-delivery="unconfirmed"]'));
  assert.equal(await page.locator("#messageInput").inputValue(), "New draft to keep");
  let state = await control("state");
  const sends = state.requests.filter((request) => request.path === "/v1/agent/send");
  assert.equal(sends.length, 2);
  assert.deepEqual(sends[0], sends[1]);
  assert.equal(state.accepted, 1);
  assert.equal(await page.getByText("Original uncertain message", { exact: true }).count(), 1);
  await page.context().close();
  console.log("PASS: lost send responses retry exactly once across reload and preserve a newer draft");

  await control("reset", {});
  page = await open();
  await page.evaluate(() => { window.originalMessage = document.querySelector(".message-row"); });
  await page.waitForTimeout(3200);
  assert.equal(await page.evaluate(() => document.querySelector(".message-row") === window.originalMessage), true);
  await page.evaluate(() => {
    window.testVisibility = "hidden";
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => window.testVisibility });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForTimeout(100);
  const before = (await control("state")).requests.filter((r) => r.path === "/v1/agent/poll").length;
  await page.waitForTimeout(3300);
  const after = (await control("state")).requests.filter((r) => r.path === "/v1/agent/poll").length;
  assert.equal(after, before);
  await page.evaluate(() => { window.testVisibility = "visible"; document.dispatchEvent(new Event("visibilitychange")); });
  await page.waitForTimeout(150);
  assert.ok((await control("state")).requests.filter((r) => r.path === "/v1/agent/poll").length > after);
  console.log("PASS: empty polls retain message DOM and background tabs pause/resume network polling");

  await control("inbox", { to: mid, messages: [{ id: "new-thread", from: bob, ts: Date.now(), payload: { thread: "new-thread", type: "msg", text: "A fresh conversation" } }] });
  await pollNow(page);
  await page.getByText("A fresh conversation", { exact: true }).waitFor();
  await control("inbox", { to: mid, messages: [{ id: "stale-done", from: bob, ts: Date.now(), payload: { thread: "old-thread", type: "done", text: "Old conversation ended" } }] });
  await pollNow(page);
  await page.getByText("Old conversation ended", { exact: true }).waitFor();
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  await control("inbox", { to: mid, messages: [{ id: "new-done", from: bob, ts: Date.now(), payload: { thread: "new-thread", type: "done", text: "New conversation ended" } }] });
  await pollNow(page);
  await page.locator("#newChat").waitFor({ state: "visible" });
  await page.evaluate(() => Object.defineProperty(crypto, "randomUUID", { value: undefined }));
  await page.locator("#newChat").click();
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  assert.equal(await page.getByText("Existing message", { exact: true }).count(), 1);
  await control("inbox", { to: mid, messages: [{ id: "summary-request", from: bob, ts: Date.now(), payload: { thread: "summary-thread", type: "final", text: "Please provide a final summary" } }] });
  await pollNow(page);
  await page.getByText("Please provide a final summary", { exact: true }).waitFor();
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  assert.ok((await page.locator("#messageInput").getAttribute("placeholder")).includes("final summary"));
  await send(page, "The final summary from a human");
  await page.locator("#newChat").waitFor({ state: "visible" });
  await page.waitForFunction(() => !document.querySelector('#messageList [data-delivery="queued"]'));
  state = await control("state");
  assert.equal(state.requests.filter((request) => request.path === "/v1/agent/send").at(-1).body.payload.type, "done");
  await page.context().close();
  console.log("PASS: thread changes, stale endings, LAN-safe IDs, new chats, and manual final-summary replies work");

  await control("reset", {});
  page = await open({ storageFailure: true });
  await send(page, "Storage unavailable");
  await page.getByText("Storage unavailable", { exact: true }).waitFor();
  await page.locator('.message-row[data-delivery="confirmed"]').waitFor();
  assert.ok((await page.locator("#toast").textContent()).includes("could not save"));
  await page.context().close();
  console.log("PASS: storage quota failures do not break connected chat or successful sends");

  await control("reset", {});
  page = await open();
  await page.locator("#selfAvatar").click();
  const rect = await page.locator("#profileDialog").boundingBox();
  await page.mouse.click(rect.x + 5, rect.y + 5);
  assert.equal(await page.locator("#profileDialog").evaluate((el) => el.open), true);
  await page.mouse.click(2, 2);
  assert.equal(await page.locator("#profileDialog").evaluate((el) => el.open), false);
  await control("config", { pollUnauthorized: true });
  await pollNow(page);
  await page.locator("#connectCard").waitFor({ state: "visible" });
  assert.equal(await page.evaluate(() => sessionStorage.getItem("agent-comm.session.v1")), null);
  await page.context().close();
  console.log("PASS: dialog padding does not dismiss it and expired mailbox tokens return to reconnect");

  await control("reset", {});
  await control("config", { adminListDelay: 500 });
  page = await open({ mailbox: false });
  await admin(page);
  await page.locator("#closeAdmin").click();
  await page.waitForTimeout(600);
  await page.locator(".brand-controls").hover();
  await page.locator("#openAdminButton").click();
  assert.equal(await page.locator("#adminLoginForm").isVisible(), true);
  assert.equal(await page.locator("#adminContent").isVisible(), false);
  assert.equal(await page.locator("#adminAgentList").textContent(), "");
  await page.locator("#closeAdmin").click();
  console.log("PASS: closing an in-flight admin login cannot unlock or populate a reopened console");

  await control("config", { adminListDelay: 0, failRegistry: "client", detailDelays: { Bob: 500, Carol: 0 } });
  await admin(page);
  await page.locator("#adminContent").waitFor({ state: "visible" });
  await page.getByRole("button", { name: /Bob/ }).click();
  await page.getByRole("button", { name: /Carol/ }).click();
  await page.locator("#adminAgentDetail h3").filter({ hasText: "Carol" }).waitFor();
  await page.waitForTimeout(550);
  assert.equal(await page.locator("#adminAgentDetail h3").textContent(), "Carol");
  await page.locator('[data-admin-tab="registries"]').click();
  assert.equal(await page.locator("#registryContent").isEnabled(), false);
  await control("config", { failRegistry: null, registrySaveDelay: 400 });
  await page.locator('[data-admin-tab="registries"]').click();
  await page.locator("#registryContent").waitFor();
  await page.waitForFunction(() => !document.querySelector("#registryContent").disabled);
  await page.locator("#registryType").selectOption("guide");
  await page.locator("#registryContent").fill("Submitted guide");
  await page.locator("#registryType").selectOption("policy");
  await page.locator("#registryContent").fill("Unsaved policy");
  await page.locator("#registryType").selectOption("guide");
  assert.equal(await page.locator("#registryContent").inputValue(), "Submitted guide");
  await page.locator("#saveRegistry").click();
  await page.locator("#registryContent").fill("Newer guide edits");
  await page.locator("#registryType").selectOption("policy");
  await page.waitForFunction(() => !document.querySelector("#saveRegistry").disabled);
  assert.equal(await page.locator("#registryContent").inputValue(), "Unsaved policy");
  state = await control("state");
  assert.equal(state.registries.guide, "Submitted guide");
  assert.equal(state.registries.policy, "Original policy");
  await page.locator("#registryType").selectOption("guide");
  assert.equal(await page.locator("#registryContent").inputValue(), "Newer guide edits");
  assert.ok((await page.locator("#registryFeedback").textContent()).includes("Unsaved"));
  if (process.env.AUDIT_SCREENSHOT) await page.screenshot({ path: process.env.AUDIT_SCREENSHOT });
  await page.context().close();
  console.log("PASS: admin details follow the latest selection; resource failures do not block login; registry switches and saves retain unsaved edits");
  assert.deepEqual(errors, []);
} finally { await browser.close(); app.close(); }
