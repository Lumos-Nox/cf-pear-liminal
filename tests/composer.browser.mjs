import assert from "node:assert/strict";
import { startTestApp } from "./browser-fixture.mjs";
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const app = await startTestApp();
let browser;
try {
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}) });
  const errors = [];
  async function openMailbox(suffix = "valid", messages = []) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await context.addInitScript(({ suffix, messages }) => {
      const mid = `m-${"a".repeat(32)}`;
      sessionStorage.setItem("agent-comm.session.v1", JSON.stringify({ mid, label: "Alice", token: `${mid}.${suffix}`,
        conversations: { [`m-${"b".repeat(32)}`]: { thread: crypto.randomUUID(), messages } },
      }));
    }, { suffix, messages });
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(app.url);
    await page.locator("#mobileMenu").tap();
    await page.getByRole("button", { name: /^Bob,/ }).tap();
    await page.locator("#messageInput").tap();
    await page.evaluate(() => {
      window.composerBlurred = false;
      window.originalComposer = document.querySelector("#messageInput");
      window.originalComposer.addEventListener("blur", () => { window.composerBlurred = true; });
    });
    return page;
  }
  async function assertEditing(page) {
    const state = await page.locator("#messageInput").evaluate((el) => ({
      focused: el === document.activeElement,
      editable: !el.disabled && !el.readOnly,
      sameNode: el === window.originalComposer,
      blurred: window.composerBlurred,
    }));
    assert.deepEqual(state, { focused: true, editable: true, sameNode: true, blurred: false });
  }
  async function waitForSend(page) {
    await page.waitForFunction(() => !document.querySelector("#sendButton").disabled);
  }

  const page = await openMailbox();
  await page.locator("#messageInput").fill("Send by touch");
  await page.locator("#sendButton").tap();
  assert.equal(await page.locator("#sendButton").isDisabled(), true);
  await assertEditing(page);
  await waitForSend(page);
  assert.equal(await page.locator("#messageInput").inputValue(), "");
  await assertEditing(page);
  assert.equal(await page.locator(".message-bubble").last().textContent(), "Send by touch");
  console.log("PASS: tapping Send keeps the same editable composer focused throughout a successful send");

  for (const width of [320, 375, 390]) {
    await page.setViewportSize({ width, height: 844 });
    const boxes = await page.locator("#themeToggle, #serviceState, #connectionState, #mobileMenu").evaluateAll((elements) => elements.map((el) => ({ id: el.id, left: el.getBoundingClientRect().left, right: el.getBoundingClientRect().right })));
    for (const box of boxes) assert.ok(box.left >= 0 && box.right <= width, `Header overflow at ${width}px: ${JSON.stringify(box)}`);
  }
  console.log("PASS: connected mobile header controls fit 320px, 375px, and 390px screens");

  await page.locator("#messageInput").fill("Send by Enter");
  await page.locator("#messageInput").press("Enter");
  assert.equal(await page.locator("#sendButton").isDisabled(), true);
  await assertEditing(page);
  await waitForSend(page);
  await assertEditing(page);
  assert.equal(await page.locator("#messageInput").inputValue(), "");
  console.log("PASS: Enter submission keeps composer focus and editability");

  await page.locator("#messageInput").fill("Previous message");
  await page.locator("#sendButton").tap();
  assert.equal(await page.locator("#sendButton").isDisabled(), true);
  await page.locator("#messageInput").fill("Next draft typed while sending");
  await waitForSend(page);
  assert.equal(await page.locator("#messageInput").inputValue(), "Next draft typed while sending");
  await assertEditing(page);
  console.log("PASS: completing a send preserves text typed while it was pending");

  await page.locator("#sendButton").tap();
  await page.locator("#mobileMenu").focus();
  await waitForSend(page);
  assert.equal(await page.evaluate(() => document.activeElement.id), "mobileMenu");
  console.log("PASS: completed sends respect a deliberate focus change");

  const reset = await fetch(`${process.env.SIMULATION_URL}/messaging/simulation/reset`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  });
  assert.equal(reset.status, 200);
  const history = Array.from({ length: 40 }, (_, index) => ({
    id: `${index + 1}`, type: "msg", text: `Earlier message ${index}`, mine: false, ts: Date.now(),
  }));
  const longChat = await openMailbox("valid", history);
  await longChat.locator("#messageScroller").evaluate((el) => el.scrollTo({ top: 0, behavior: "instant" }));
  const expected = history.map((message) => message.text);
  for (const text of ["Visible immediately after sending", "Still visible after sending again"]) {
    await longChat.locator("#messageInput").fill(text);
    await longChat.locator("#sendButton").tap();
    await waitForSend(longChat);
    expected.push(text);
    assert.deepEqual(await longChat.locator(".message-bubble").allTextContents(), expected,
      "An incoming message with the same mailbox-local ID must not suppress an outgoing message");
    await longChat.waitForFunction((text) => {
      const latest = document.querySelector(".message-row:last-child .message-bubble");
      const scroller = document.querySelector("#messageScroller").getBoundingClientRect();
      const rect = latest?.getBoundingClientRect();
      return latest?.textContent === text && rect.top >= scroller.top && rect.bottom <= scroller.bottom;
    }, text, { timeout: 2000 });
    await assertEditing(longChat);
  }
  assert.deepEqual(await longChat.locator(".message-bubble").allTextContents(), expected);
  console.log("PASS: repeated sends in a long chat show the latest message without refreshing and retain history");

  const failed = await openMailbox("fault-send");
  await failed.locator("#messageInput").fill("Keep this failed message");
  await failed.locator("#sendButton").tap();
  assert.equal(await failed.locator("#sendButton").isDisabled(), true);
  await assertEditing(failed);
  await failed.locator("#sendRecovery").waitFor({ state: "visible" });
  assert.equal(await failed.locator("#messageInput").inputValue(), "Keep this failed message");
  await assertEditing(failed);
  assert.equal(await failed.locator("#toast.is-error").isVisible(), true);
  if (process.env.COMPOSER_SCREENSHOT) {
    await failed.emulateMedia({ colorScheme: "dark" });
    await failed.screenshot({ path: process.env.COMPOSER_SCREENSHOT });
  }
  console.log("PASS: failed sends retain the message and continuous composer focus");
  assert.deepEqual(errors, []);
} finally {
  if (browser) await browser.close();
  app.close();
}
