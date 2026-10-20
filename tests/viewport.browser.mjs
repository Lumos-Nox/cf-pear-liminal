import assert from "node:assert/strict";
import http from "node:http";
import { readFile } from "node:fs/promises";
import { once } from "node:events";

// Use an installed Playwright package, or supply its module path explicitly.
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const assets = new Map([
  ["/", ["index.html", "text/html"]],
  ["/app.js", ["app.js", "text/javascript"]],
  ["/viewport.js", ["viewport.js", "text/javascript"]],
  ["/styles.css", ["styles.css", "text/css"]],
]);
const server = http.createServer(async (request, response) => {
  const asset = assets.get(new URL(request.url, "http://localhost").pathname);
  if (!asset) { response.writeHead(404); response.end(); return; }
  const body = await readFile(new URL(`../public/${asset[0]}`, import.meta.url));
  response.writeHead(200, { "content-type": asset[1] });
  response.end(body);
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
let browser;
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}),
  });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    const viewport = Object.assign(new EventTarget(), { width: 390, height: 760, offsetTop: 0, scale: 1 });
    Object.defineProperty(window, "visualViewport", { value: viewport });
    window.testViewport = viewport;
  });
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.waitForFunction(() => document.documentElement.style.getPropertyValue("--app-viewport-height") === "760px");

  async function setViewport(height, offsetTop, scale = 1, event = "resize") {
    await page.evaluate(({ height, offsetTop, scale, event }) => {
      Object.assign(window.testViewport, { width: document.documentElement.clientWidth / scale, height, offsetTop, scale });
      window.testViewport.dispatchEvent(new Event(event));
    }, { height, offsetTop, scale, event });
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  }
  async function checkLayout(top, height, conversation = false) {
    const rects = await page.evaluate(() => {
      const rect = (selector) => {
        const { top, bottom, height } = document.querySelector(selector).getBoundingClientRect();
        return { top, bottom, height };
      };
      return { shell: rect(".app-shell"), topbar: rect(".topbar"), workspace: rect(".workspace"), chat: rect(".chat-header"), composer: rect(".composer") };
    });
    assert.ok(Math.abs(rects.shell.top - top) < 1, JSON.stringify(rects));
    assert.ok(Math.abs(rects.shell.height - height) < 1, JSON.stringify(rects));
    assert.ok(Math.abs(rects.topbar.top - top) < 1, JSON.stringify(rects));
    assert.ok(Math.abs(rects.workspace.bottom - (top + height)) < 1, JSON.stringify(rects));
    if (conversation) {
      assert.ok(rects.chat.top >= rects.topbar.bottom - 1, JSON.stringify(rects));
      assert.ok(rects.composer.bottom <= top + height + 1, JSON.stringify(rects));
      assert.ok(rects.composer.height > 80, JSON.stringify(rects));
    }
  }

  await checkLayout(0, 760);
  await page.locator("#mobileMenu").click();
  await page.locator("#joinLabel").focus();
  await setViewport(400, 210);
  await checkLayout(210, 400);
  await page.locator("#joinSecret").scrollIntoViewIfNeeded();
  await page.locator("#joinSecret").focus();
  assert.equal(await page.evaluate(() => window.scrollY), 0);
  console.log("PASS: name and secret fields scroll inside the keyboard-sized sidebar");

  await page.evaluate(() => {
    document.querySelector("#sidebar").classList.remove("is-open");
    document.querySelector("#welcomePanel").hidden = true;
    document.querySelector("#conversation").hidden = false;
    document.querySelector("#messageInput").disabled = false;
    const list = document.querySelector("#messageList");
    for (let i = 0; i < 50; i++) {
      const message = document.createElement("div");
      message.className = "message-bubble";
      message.textContent = `Message ${i}: retained chat history`;
      list.append(message);
    }
    const scroller = document.querySelector("#messageScroller");
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: "instant" });
  });
  await page.locator("#messageInput").focus();
  await setViewport(350, 284);
  await checkLayout(284, 350, true);
  const distance = await page.locator("#messageScroller").evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight);
  assert.ok(distance < 2, `Latest messages hidden by ${distance}px`);
  await setViewport(350, 310, 1, "scroll");
  await checkLayout(310, 350, true);
  console.log("PASS: keyboard resize and Safari pan preserve header, composer, and latest messages");

  for (const id of ["profileDialog", "adminDialog"]) {
    await page.locator(`#${id}`).evaluate((el) => el.showModal());
    const rect = await page.locator(`#${id}`).boundingBox();
    assert.ok(rect.y >= 310 && rect.y + rect.height <= 661, `${id} lies outside the visible viewport`);
    await page.locator(`#${id}`).evaluate((el) => el.close());
  }
  console.log("PASS: profile and admin dialogs fit above the keyboard");

  await page.locator("#messageScroller").evaluate((el) => { el.scrollTo({ top: 100, behavior: "instant" }); });
  await setViewport(420, 240);
  assert.equal(await page.locator("#messageScroller").evaluate((el) => el.scrollTop), 100);
  await setViewport(760, 0);
  await checkLayout(0, 760, true);
  console.log("PASS: keyboard dismissal restores full height without snapping older history to the bottom");

  await setViewport(380, 100, 2);
  await checkLayout(0, 760, true);
  await setViewport(500, 70);
  await checkLayout(70, 500, true);
  console.log("PASS: pinch zoom keeps layout stable and updates resume after zooming out");
  await page.setViewportSize({ width: 844, height: 390 });
  await setViewport(330, 0);
  await checkLayout(0, 330, true);
  console.log("PASS: landscape layout fits the visible viewport");

  const zoomPage = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  zoomPage.on("pageerror", (error) => errors.push(error.message));
  // Safari's browser width stays in screen points while Page Zoom changes the
  // layout width. Emulate those measurements, independently of pinch zoom.
  await zoomPage.addInitScript(() => Object.defineProperty(window, "outerWidth", { get: () => 390 }));
  await zoomPage.goto(`http://127.0.0.1:${server.address().port}`);
  for (const zoom of [0.5, 0.75, 0.85, 1, 1.25]) {
    const width = Math.round(390 / zoom);
    await zoomPage.setViewportSize({ width, height: Math.round(844 / zoom) });
    const expectedFloor = Math.ceil(1600 / Math.min(1, 390 / width)) / 100;
    await zoomPage.waitForFunction((floor) => Math.abs(parseFloat(getComputedStyle(document.querySelector("#joinLabel")).fontSize) - floor) < 0.01, expectedFloor);
    const fields = await zoomPage.locator("input, textarea, select").evaluateAll((elements) => elements.map((el) => ({ id: el.id, font: parseFloat(getComputedStyle(el).fontSize) })));
    for (const field of fields) assert.ok(field.font * (390 / width) >= 15.999, `Page Zoom ${zoom}: ${JSON.stringify(field)}`);
  }
  console.log("PASS: all eight text controls remain at least 16 screen points at 50%, 75%, 85%, 100%, and 125% Page Zoom");
  const initialFont = await zoomPage.locator("#joinLabel").evaluate((el) => getComputedStyle(el).fontSize);
  const cdp = await zoomPage.context().newCDPSession(zoomPage);
  await cdp.send("Emulation.setPageScaleFactor", { pageScaleFactor: 2 });
  await zoomPage.waitForFunction(() => window.visualViewport.scale > 1.9);
  assert.equal(await zoomPage.locator("#joinLabel").evaluate((el) => getComputedStyle(el).fontSize), initialFont);
  console.log("PASS: native pinch zoom does not resize text controls");
  for (const mode of ["light", "dark", "system"]) {
    await page.locator("#themeToggle").click();
    assert.equal(await page.locator("html").getAttribute("data-theme-preference"), mode);
  }
  console.log("PASS: the appearance button cycles through all three supported modes");
  assert.deepEqual(errors, []);
} finally {
  if (browser) await browser.close();
  server.closeAllConnections();
  server.close();
}
