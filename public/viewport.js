// Safari shrinks and pans the visual viewport for the keyboard while leaving
// 100dvh at the layout viewport's height. Fit the whole app to the visible area.
export function trackAppViewport() {
  const viewport = window.visualViewport;
  const root = document.documentElement;
  const scroller = document.getElementById("messageScroller");
  const touchInput = window.matchMedia("(pointer: coarse)");
  let frame = null;

  function update() {
    // Mobile Safari's Page Zoom expands the layout width but keeps outerWidth
    // in screen points. Pinch zoom leaves the layout width unchanged. Compensate
    // only for page zoom so text remains at least 16 screen points when zoomed out.
    const layoutWidth = root.clientWidth;
    const pageZoom = touchInput.matches && window.outerWidth > 0 && layoutWidth > 0
      ? Math.min(1, window.outerWidth / layoutWidth) : 1;
    const controlFontSize = Math.ceil(1600 / pageZoom) / 100;
    root.style.setProperty("--control-font-size", `${controlFontSize}px`);

    if (!viewport || viewport.height <= 0) return;
    // Keep native pinch zoom: changing layout to match a zoomed viewport would
    // move the content beneath the user's fingers. Compare widths, since a
    // non-default Page Zoom need not report a visual viewport scale of 1.
    if (Math.abs(viewport.width - layoutWidth) > 1) return;

    const atBottom = scroller
      && scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 96;
    root.style.setProperty("--app-viewport-height", `${viewport.height}px`);
    root.style.setProperty("--app-viewport-top", `${viewport.offsetTop}px`);
    if (atBottom) scroller.scrollTo({ top: scroller.scrollHeight, behavior: "instant" });
  }

  function scheduleUpdate() {
    if (frame === null) frame = requestAnimationFrame(() => {
      frame = null;
      update();
    });
  }

  viewport?.addEventListener("resize", scheduleUpdate);
  viewport?.addEventListener("scroll", scheduleUpdate);
  window.addEventListener("resize", scheduleUpdate);
  window.addEventListener("pageshow", scheduleUpdate);
  // Apply a changed Page Zoom before Safari evaluates a newly tapped field.
  document.addEventListener("pointerdown", (event) => {
    if (event.target.closest("input, textarea, select")) update();
  }, true);
  update();
}
