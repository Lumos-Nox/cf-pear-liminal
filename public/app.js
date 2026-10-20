import { trackAppViewport } from "./viewport.js";

const STORAGE_KEY = "agent-comm.session.v1";
const TOKEN_ACCESS_PREFIX = `${STORAGE_KEY}.token-access.`;
const THEME_STORAGE_KEY = "agent-comm.theme";
const POLL_INTERVAL_MS = 3000;
const TYPING_IDLE_MS = 1200;
const TYPING_HEARTBEAT_MS = 6000;
const TYPING_VISIBLE_MS = 9000;
const MESSAGE_TYPES = new Set(["msg", "final", "done", "abort"]);
const MAILBOX_ID_PATTERN = /^m-[0-9a-f]{32}$/;
const avatarSegmenter = globalThis.Intl?.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;

const $ = (id) => document.getElementById(id);
const ui = {
  serviceState: $("serviceState"),
  themeToggle: $("themeToggle"),
  connectionState: $("connectionState"),
  connectCard: $("connectCard"),
  mailboxCard: $("mailboxCard"),
  contactsCard: $("contactsCard"),
  selfLabel: $("selfLabel"),
  selfAvatar: $("selfAvatar"),
  profileAvatar: $("profileAvatar"),
  profileName: $("profileName"),
  profileMid: $("profileMid"),
  profileDialog: $("profileDialog"),
  bearerTokenValue: $("bearerTokenValue"),
  tokenNote: document.querySelector(".token-note"),
  profileFeedback: $("profileFeedback"),
  revealToken: $("revealToken"),
  copyBearerToken: $("copyBearerToken"),
  closeProfile: $("closeProfile"),
  peerList: $("peerList"),
  peerCount: $("peerCount"),
  peerSearch: $("peerSearch"),
  emptyDirectory: $("emptyDirectory"),
  welcomePanel: $("welcomePanel"),
  conversation: $("conversation"),
  chatAvatar: $("chatAvatar"),
  chatPeerName: $("chatPeerName"),
  chatPeerMid: $("chatPeerMid"),
  typingIndicator: $("typingIndicator"),
  localTypingBubble: $("localTypingBubble"),
  threadStatus: $("threadStatus"),
  messageScroller: $("messageScroller"),
  threadStart: $("threadStart"),
  messageList: $("messageList"),
  composerForm: $("composerForm"),
  messageInput: $("messageInput"),
  sendButton: $("sendButton"),
  summaryButton: $("summaryButton"),
  finishChat: $("finishChat"),
  newChat: $("newChat"),
  sendRecovery: $("sendRecovery"),
  retrySend: $("retrySend"),
  toast: $("toast"),
  sidebar: $("sidebar"),
  mobileMenu: $("mobileMenu"),
  sidebarScrim: $("sidebarScrim"),
  welcomeAction: $("welcomeAction"),
  welcomeActionLabel: $("welcomeActionLabel"),
};

const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");
let themePreference = document.documentElement.dataset.themePreference || "system";

function applyThemePreference() {
  const mode = themePreference === "system"
    ? (systemTheme.matches ? "dark" : "light")
    : themePreference;
  document.documentElement.dataset.theme = mode;
  document.documentElement.dataset.themePreference = themePreference;
  ui.themeToggle.dataset.mode = themePreference;

  const appearance = themePreference === "system" ? `system (${mode})` : themePreference;
  const next = nextThemePreference();
  const label = `Appearance: ${appearance}. Activate to ${next === "system" ? "follow system" : `use ${next}`}.`;
  ui.themeToggle.setAttribute("aria-label", label);
  ui.themeToggle.title = label;
  const themeColor = $("themeColor");
  if (themeColor) themeColor.content = mode === "dark" ? "#151a17" : "#ffffff";
}

function nextThemePreference() {
  return themePreference === "system" ? "light" : themePreference === "light" ? "dark" : "system";
}

applyThemePreference();
trackAppViewport();

let session = readSession();
let self = null;
let peers = [];
let activePeerMid = null;
let pollTimer = null;
let peerRefreshTimer = null;
let pollingGeneration = null;
let peerLoad = null;
let saveTimer = null;
let storageWarningShown = false;
let renderedPeerMid = null;
let renderedMessages = [];
let renderedMessageNames = "";
let peerRenderSignature = "";
let sending = false;
let toastTimer = null;
let sessionGeneration = 0;
let typingSocket = null;
let typingConnectAttempt = null;
let typingConnectionGeneration = 0;
let typingReconnectTimer = null;
let typingReconnectAttempt = 0;
let typingHeartbeatTimer = null;
let typingStopTimer = null;
let localTypingTimer = null;
let sharedMomentTimer = null;
let remoteTypingTimer = null;
let typingActive = false;
let localTypingVisible = false;
let sharedMomentActive = false;
let remoteTypingMid = null;

function readSession() {
  try {
    const saved = JSON.parse(storageGet(STORAGE_KEY) || "null");
    if (!saved || typeof saved.token !== "string" || !MAILBOX_ID_PATTERN.test(saved.mid)) return null;
    saved.cursor = String(saved.cursor || "0");
    saved.handled = Array.isArray(saved.handled) ? saved.handled : [];
    saved.tokenRevealUsed = Boolean(saved.tokenRevealUsed);
    saved.tokenCopyUsed = Boolean(saved.tokenCopyUsed);
    saved.tokenCopyWindowOpen = false;
    if (storageGet(`${TOKEN_ACCESS_PREFIX}${saved.mid}`) === "used") saved.tokenRevealUsed = true;
    saved.conversations = saved.conversations && typeof saved.conversations === "object" && !Array.isArray(saved.conversations)
      ? saved.conversations : {};
    return saved;
  } catch {
    storageRemove(STORAGE_KEY);
    return null;
  }
}

function storageGet(key) {
  try { return sessionStorage.getItem(key); } catch { return null; }
}

function storageRemove(key) {
  try { sessionStorage.removeItem(key); } catch {}
}

function storageSet(key, value) {
  try { sessionStorage.setItem(key, value); return true; } catch { return false; }
}

function saveSession() {
  clearTimeout(saveTimer);
  saveTimer = null;
  if (session && !storageSet(STORAGE_KEY, JSON.stringify(session))) {
    storageRemove(STORAGE_KEY);
    if (!storageWarningShown) {
      storageWarningShown = true;
      showToast("This browser could not save the tab session. Keep this tab open; refreshing may lose recent history.", true);
    }
  }
}

function scheduleSessionSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveSession, 250);
}

function stopPolling() {
  clearInterval(pollTimer);
  clearInterval(peerRefreshTimer);
  pollTimer = null;
  peerRefreshTimer = null;
}

function clearSession() {
  sessionGeneration += 1;
  closeTypingSocket();
  typingReconnectAttempt = 0;
  closeProfileDialog();
  clearTimeout(saveTimer);
  saveTimer = null;
  storageRemove(STORAGE_KEY);
  session = null;
  self = null;
  peers = [];
  activePeerMid = null;
  sending = false;
  ui.messageInput.value = "";
  ui.peerSearch.value = "";
  resizeComposer();
  stopPolling();
  setConnected(false);
  renderPeers();
  renderConversation();
}

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(path, options = {}) {
  const headers = { Accept: "application/json" };
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  if (options.auth !== false && session?.token) headers.Authorization = `Bearer ${session.token}`;
  if (options.adminSecret) headers["X-Admin-Secret"] = options.adminSecret;
  if (options.idempotencyKey) headers["Idempotency-Key"] = options.idempotencyKey;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const response = await fetch(`/api${path}`, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      cache: "no-store",
      redirect: "error",
      signal: controller.signal,
    });
    const contentType = response.headers.get("content-type") || "";
    let result;
    try {
      result = contentType.includes("json") ? await response.json() : await response.text();
    } catch {
      throw new ApiError(response.ok ? 502 : response.status, "The messaging service returned an unreadable response.");
    }
    if (!response.ok) {
      throw new ApiError(response.status, typeof result?.error === "string" ? result.error : `Request failed (${response.status}).`);
    }
    return result;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(0, controller.signal.aborted ? "The messaging request timed out. Try again." : "Could not reach the messaging service. Check your connection and try again.");
  } finally {
    clearTimeout(timeout);
  }
}

function setServiceState(label, state = "") {
  ui.serviceState.title = label;
  ui.serviceState.className = `service-state ${state}`.trim();
  ui.serviceState.lastElementChild.textContent = label;
}

function setConnectionState(label, state = "") {
  ui.connectionState.hidden = !session;
  ui.connectionState.className = `connection-state ${state}`.trim();
  ui.connectionState.lastElementChild.textContent = label;
}

function setConnected(connected) {
  ui.connectCard.hidden = connected;
  ui.mailboxCard.hidden = !connected;
  ui.contactsCard.hidden = !connected;
  ui.connectionState.hidden = !connected;
  ui.mobileMenu.setAttribute("aria-label", connected ? "Open Pears" : "Open mailbox setup");
  if (connected && self) {
    ui.selfLabel.textContent = self.label || "Your mailbox";
    ui.selfAvatar.textContent = avatarLetter(self.label);
    ui.profileAvatar.textContent = avatarLetter(self.label);
    ui.profileName.textContent = self.label || "Your mailbox";
    ui.profileMid.textContent = self.mid;
  }
  renderPeers();
  renderConversation();
}

function showToast(message, isError = false) {
  clearTimeout(toastTimer);
  if ($("adminDialog").open) {
    const notice = $("adminNotice");
    notice.textContent = message;
    notice.classList.toggle("is-error", isError);
    notice.hidden = false;
    ui.toast.hidden = true;
    toastTimer = setTimeout(() => { notice.hidden = true; }, 4200);
    return;
  }
  if (ui.profileDialog.open) { ui.profileFeedback.textContent = message; return; }
  ui.toast.textContent = message;
  ui.toast.className = `toast${isError ? " is-error" : ""}`;
  ui.toast.hidden = false;
  positionToast();
  toastTimer = setTimeout(() => { ui.toast.hidden = true; }, 4200);
}

function positionToast() {
  if (ui.toast.hidden) return;
  const visibleTop = window.visualViewport?.offsetTop || 0;
  const visibleBottom = visibleTop + (window.visualViewport?.height || window.innerHeight);
  const anchor = ui.conversation.hidden ? visibleBottom - 18 : ui.composerForm.getBoundingClientRect().top - 10;
  ui.toast.style.top = `${Math.max(visibleTop + 8, anchor - ui.toast.offsetHeight)}px`;
  ui.toast.style.bottom = "auto";
}

if (globalThis.ResizeObserver) new ResizeObserver(positionToast).observe(ui.composerForm);
window.visualViewport?.addEventListener("resize", () => requestAnimationFrame(positionToast));
window.visualViewport?.addEventListener("scroll", () => requestAnimationFrame(positionToast));

function avatarLetter(label) {
  const text = String(label || "?").trim();
  const first = avatarSegmenter
    ? avatarSegmenter.segment(text)[Symbol.iterator]().next().value?.segment
    : Array.from(text)[0];
  return first?.toLocaleUpperCase() || "?";
}

function avatarTone(id) {
  let hash = 0;
  for (const character of id || "") hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
  return hash % 6;
}

function shortMid(mid) {
  return mid ? `${mid.slice(0, 8)}…${mid.slice(-5)}` : "—";
}

function formatTime(value) {
  const date = new Date(Number(value) || Date.now());
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function peerByMid(mid) {
  return peers.find((peer) => peer.mid === mid) || { mid, label: mid };
}

function conversationFor(mid) {
  if (!Object.hasOwn(session.conversations, mid) || !session.conversations[mid] || typeof session.conversations[mid] !== "object") {
    session.conversations[mid] = {
      thread: null,
      seq: 0,
      messages: [],
      unread: 0,
      finished: false,
      awaitingFinal: false,
    };
  }
  const conversation = session.conversations[mid];
  if (!Array.isArray(conversation.messages)) conversation.messages = [];
  if (!Number.isInteger(conversation.seq)) conversation.seq = 0;
  if (!Number.isInteger(conversation.unread)) conversation.unread = 0;
  const pending = conversation.pendingSend;
  if (pending && (pending.body?.to !== mid || typeof pending.key !== "string" || !MESSAGE_TYPES.has(pending.body?.payload?.type)
    || typeof pending.body?.payload?.text !== "string" || !Number.isInteger(pending.body?.payload?.seq))) conversation.pendingSend = null;
  return conversation;
}

function ensureThread(conversation) {
  if (!conversation.thread) {
    conversation.thread = randomId();
  }
  return conversation.thread;
}

function randomId() {
  if (globalThis.crypto?.randomUUID) return crypto.randomUUID().replaceAll("-", "");
  if (globalThis.crypto?.getRandomValues) return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;
}

function appendMessage(conversation, message) {
  conversation.messages.push(message);
  if (conversation.messages.length > 500) conversation.messages.splice(0, conversation.messages.length - 500);
}

function renderPeers() {
  if (!session) {
    peerRenderSignature = "";
    ui.peerList.replaceChildren();
    ui.peerCount.textContent = "0 Pears";
    ui.emptyDirectory.hidden = true;
    return;
  }
  const term = ui.peerSearch.value.trim().toLocaleLowerCase();
  const visible = peers.filter((peer) => `${peer.label} ${peer.mid}`.toLocaleLowerCase().includes(term));
  const signature = JSON.stringify([term, activePeerMid, visible.map((peer) => [peer.mid, peer.label, conversationFor(peer.mid).unread]), peers.length]);
  if (signature === peerRenderSignature) return;
  peerRenderSignature = signature;
  ui.peerList.replaceChildren();
  for (const peer of visible) {
    const conversation = conversationFor(peer.mid);
    const button = document.createElement("button");
    button.type = "button";
    button.className = `peer-button${peer.mid === activePeerMid ? " is-selected" : ""}`;
    button.addEventListener("click", () => selectPeer(peer.mid));

    const avatar = document.createElement("span");
    avatar.className = `avatar peer-avatar peer-avatar-tone-${avatarTone(peer.mid)}`;
    avatar.textContent = avatarLetter(peer.label);
    const copy = document.createElement("span");
    copy.className = "peer-copy";
    const label = document.createElement("strong");
    label.textContent = peer.label || "Unnamed mailbox";
    const mid = document.createElement("span");
    mid.textContent = shortMid(peer.mid);
    copy.append(label, mid);
    button.append(avatar, copy);
    const unreadCount = conversation.unread;
    const peerName = peer.label || "Unnamed mailbox";
    button.setAttribute("aria-label", `${peerName}, ${shortMid(peer.mid)}${unreadCount > 0 ? `, ${unreadCount} unread ${unreadCount === 1 ? "message" : "messages"}` : ""}`);
    if (peer.mid === activePeerMid) button.setAttribute("aria-current", "true");
    if (conversation.unread > 0) {
      const unread = document.createElement("span");
      unread.className = "unread-badge";
      unread.textContent = conversation.unread > 99 ? "99+" : String(conversation.unread);
      unread.setAttribute("aria-hidden", "true");
      button.append(unread);
    }
    const item = document.createElement("div");
    item.setAttribute("role", "listitem");
    item.append(button);
    ui.peerList.append(item);
  }
  ui.peerCount.textContent = `${peers.length} ${peers.length === 1 ? "Pear" : "Pears"}`;
  ui.emptyDirectory.hidden = visible.length !== 0;
  if (peers.length === 0) {
    ui.emptyDirectory.textContent = "No other Pears yet. Keep this open while someone joins.";
  } else if (visible.length === 0) {
    ui.emptyDirectory.textContent = `No Pears match “${ui.peerSearch.value.trim()}”.`;
  }
}

function selectPeer(mid) {
  stopTyping();
  activePeerMid = mid;
  ui.messageInput.value = conversationFor(mid).draft || "";
  resizeComposer();
  setRemoteTyping(null);
  sendTypingWatch();
  conversationFor(mid).unread = 0;
  saveSession();
  renderPeers();
  renderConversation();
  closeSidebar();
  if (window.matchMedia("(min-width: 681px) and (pointer: fine)").matches) ui.messageInput.focus({ preventScroll: true });
}

function closeSidebar() {
  ui.sidebar.classList.remove("is-open");
  ui.sidebarScrim.classList.remove("is-visible");
  ui.mobileMenu.setAttribute("aria-expanded", "false");
}

function maskBearerToken() {
  ui.bearerTokenValue.textContent = "••••••••••••••••";
}

function prepareProfileDialog() {
  if (!session) return;
  ui.profileAvatar.textContent = avatarLetter(self?.label || session.label);
  ui.profileName.textContent = self?.label || session.label || "Your mailbox";
  ui.profileMid.textContent = self?.mid || session.mid;
  ui.tokenNote.textContent = session.tokenRevealUsed
    ? "This token was shown once. It can’t be revealed or copied again."
    : "Reveal it once, then copy it before closing. It won’t be available again.";
  ui.revealToken.disabled = session.tokenRevealUsed;
  ui.revealToken.textContent = session.tokenRevealUsed ? "Shown once" : "Reveal once";
  ui.copyBearerToken.disabled = !session.tokenCopyWindowOpen || session.tokenCopyUsed;
  ui.profileFeedback.textContent = "";
  maskBearerToken();
}

function openProfileDialog() {
  if (!session) return;
  prepareProfileDialog();
  ui.selfAvatar.setAttribute("aria-expanded", "true");
  ui.profileDialog.showModal();
}

function closeProfileDialog() {
  if (ui.profileDialog.open) ui.profileDialog.close();
}

function openSidebar() {
  ui.sidebar.classList.add("is-open");
  ui.sidebarScrim.classList.add("is-visible");
  ui.mobileMenu.setAttribute("aria-expanded", "true");
}

function renderConversation({ scrollToLatest = false } = {}) {
  const peer = activePeerMid ? peerByMid(activePeerMid) : null;
  ui.welcomePanel.hidden = Boolean(session && peer);
  ui.conversation.hidden = !(session && peer);
  ui.welcomeActionLabel.textContent = session ? "Browse Pears" : "Create a mailbox";
  if (!session || !peer) {
    renderedPeerMid = null;
    renderedMessages = [];
    ui.messageList.replaceChildren();
    return;
  }

  const conversation = conversationFor(peer.mid);
  const stickToBottom = scrollToLatest || renderedPeerMid !== peer.mid || ui.messageScroller.scrollHeight - ui.messageScroller.scrollTop - ui.messageScroller.clientHeight < 96;
  ui.chatAvatar.textContent = avatarLetter(peer.label);
  ui.chatPeerName.textContent = peer.label || "Unnamed mailbox";
  ui.chatPeerMid.textContent = peer.mid;
  refreshTypingIndicator();
  ui.threadStart.hidden = conversation.messages.length > 0;
  ui.threadStatus.innerHTML = "<i></i>";
  ui.threadStatus.append(document.createTextNode(conversation.finished
    ? "Conversation ended"
    : conversation.replyingFinal
      ? "Write your final summary"
    : conversation.awaitingFinal
      ? "Waiting for a summary"
      : conversation.messages.length ? "Messages retained for 7 days" : "Waiting for messages"));
  ui.threadStatus.classList.toggle("is-live", !conversation.finished);
  const names = JSON.stringify([peer.label, self?.label]);
  const appendOnly = renderedPeerMid === peer.mid && names === renderedMessageNames
    && renderedMessages.length <= conversation.messages.length
    && renderedMessages.every((message, index) => message === conversation.messages[index]);
  if (!appendOnly) ui.messageList.replaceChildren();
  for (const message of conversation.messages.slice(appendOnly ? renderedMessages.length : 0)) {
    if (message.type === "separator") {
      const separator = document.createElement("p");
      separator.className = "conversation-separator";
      separator.textContent = message.text;
      ui.messageList.append(separator);
      continue;
    }
    const row = document.createElement("article");
    const system = ["final", "done", "abort"].includes(message.type) && !message.mine;
    row.className = `message-row${message.mine ? " mine" : ""}${system ? " system" : ""}`;
    const meta = document.createElement("div");
    meta.className = "message-meta";
    const who = document.createElement("strong");
    who.textContent = message.mine ? (self?.label || "You") : (peer.label || "Peer");
    const time = document.createElement("time");
    time.textContent = formatTime(message.ts);
    meta.append(who, time);
    if (message.type && message.type !== "msg") {
      const kind = document.createElement("span");
      kind.className = "message-kind";
      kind.textContent = message.type;
      meta.append(kind);
    }
    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    bubble.textContent = message.text;
    row.append(meta, bubble);
    ui.messageList.append(row);
  }
  renderedPeerMid = peer.mid;
  renderedMessages = conversation.messages.slice();
  renderedMessageNames = names;

  const enabled = !conversation.finished;
  ui.messageInput.placeholder = conversation.replyingFinal ? "Write your final summary…" : "Write a message…";
  ui.sendButton.querySelector("span").textContent = conversation.replyingFinal ? "Send summary" : "Send";
  ui.messageInput.disabled = !enabled;
  const pending = Boolean(conversation.pendingSend);
  ui.sendButton.disabled = !enabled || sending || pending;
  ui.sendRecovery.hidden = !pending || sending;
  ui.retrySend.disabled = sending;
  ui.newChat.hidden = !conversation.finished;
  ui.newChat.disabled = sending || pending;
  ui.summaryButton.hidden = conversation.finished;
  ui.finishChat.hidden = conversation.finished;
  ui.summaryButton.disabled = conversation.finished || sending || pending || conversation.awaitingFinal || conversation.replyingFinal;
  ui.finishChat.disabled = conversation.finished || sending || pending;
  if (stickToBottom) {
    requestAnimationFrame(() => {
      if (renderedPeerMid === peer.mid) ui.messageScroller.scrollTo({ top: ui.messageScroller.scrollHeight, behavior: "instant" });
    });
  }
}

function loadPeers() {
  if (!session) return Promise.resolve();
  const generation = sessionGeneration;
  if (peerLoad?.generation === generation) return peerLoad.promise;
  const promise = fetchPeers().finally(() => {
    if (peerLoad?.promise === promise) peerLoad = null;
  });
  peerLoad = { generation, promise };
  return promise;
}

async function fetchPeers() {
  if (!session) return;
  const generation = sessionGeneration;
  const all = [];
  const seen = new Set();
  let cursor = null;
  do {
    const query = new URLSearchParams({ limit: "100" });
    if (cursor) {
      if (seen.has(cursor)) throw new Error("Peer directory returned a repeated cursor.");
      seen.add(cursor);
      query.set("cursor", cursor);
    }
    const page = await api(`/v1/agent/peers?${query}`);
    if (generation !== sessionGeneration) return;
    if (!Array.isArray(page?.peers)) throw new ApiError(502, "The peer directory returned an invalid response.");
    all.push(...page.peers.filter((peer) => MAILBOX_ID_PATTERN.test(peer?.mid) && peer.mid !== session.mid)
      .map((peer) => ({ ...peer, label: typeof peer.label === "string" ? peer.label : peer.mid })));
    cursor = page.next_cursor || null;
  } while (cursor);
  const nextPeers = [...new Map(all.map((peer) => [peer.mid, peer])).values()];
  // Keep existing conversations reachable even when a peer leaves the directory.
  for (const mid of Object.keys(session.conversations)) {
    if (!MAILBOX_ID_PATTERN.test(mid) || nextPeers.some((peer) => peer.mid === mid)) continue;
    if (session.conversations[mid]?.messages?.length || session.conversations[mid]?.pendingSend) nextPeers.push(peerByMid(mid));
  }
  if (JSON.stringify(peers) === JSON.stringify(nextPeers)) return;
  peers = nextPeers;
  renderPeers();
  renderConversation();
}

function acceptIncoming(message) {
  if (!message || typeof message.id !== "string" || session.handled.includes(message.id)) return false;
  const payload = message.payload;
  const sender = message.from;
  if (!MAILBOX_ID_PATTERN.test(sender) || !payload || typeof payload !== "object" || Array.isArray(payload)) return false;
  const type = typeof payload.type === "string" ? payload.type : "msg";
  if (!MESSAGE_TYPES.has(type) || typeof payload.text !== "string") return false;

  const conversation = conversationFor(sender);
  const remoteThread = typeof payload.thread === "string" ? payload.thread : null;
  const differentThread = remoteThread && conversation.thread && remoteThread !== conversation.thread;
  if (type === "msg" && (differentThread || conversation.finished)) {
    beginConversation(conversation, remoteThread || conversation.thread);
  } else if (!conversation.thread && remoteThread) conversation.thread = remoteThread;

  session.handled = [...session.handled, message.id].slice(-1000);
  if (!peers.some((peer) => peer.mid === sender)) peers.push({ mid: sender, label: sender });

  appendMessage(conversation, {
    id: message.id,
    type,
    text: payload.text,
    ts: message.ts,
    mine: false,
  });
  if (!differentThread && ["final", "done", "abort"].includes(type)) {
    conversation.finished = type !== "final";
    conversation.replyingFinal = type === "final";
    conversation.awaitingFinal = false;
  }
  if (activePeerMid === sender) conversation.unread = 0;
  else conversation.unread += 1;
  if (activePeerMid === sender) setRemoteTyping(null);
  if (activePeerMid === sender && conversation.finished) stopTyping();
  return true;
}

function beginConversation(conversation, thread = null) {
  if (conversation.messages.length) appendMessage(conversation, { id: randomId(), type: "separator", text: "New conversation", ts: Date.now() });
  if (!thread || conversation.thread !== thread) conversation.seq = 0;
  conversation.thread = thread;
  conversation.finished = false;
  conversation.awaitingFinal = false;
  conversation.replyingFinal = false;
}

async function pollInbox() {
  if (!session || document.visibilityState === "hidden" || pollingGeneration === sessionGeneration) return;
  const generation = sessionGeneration;
  pollingGeneration = generation;
  try {
    const seenCursors = new Set();
    let more = true;
    while (more && session) {
      const priorCursor = session.cursor;
      if (seenCursors.has(priorCursor)) break;
      seenCursors.add(priorCursor);
      const query = new URLSearchParams({ since: priorCursor, limit: "100" });
      const page = await api(`/v1/agent/poll?${query}`);
      if (generation !== sessionGeneration) return;
      if (!Array.isArray(page?.messages)) throw new ApiError(502, "The inbox returned an invalid response.");
      let changed = false;
      for (const message of page.messages) changed = acceptIncoming(message) || changed;
      session.cursor = String(page.cursor ?? priorCursor);
      if (changed || session.cursor !== priorCursor) saveSession();
      if (changed) {
        renderPeers();
        if (activePeerMid) renderConversation();
      }
      more = Boolean(page.has_more) && (page.messages || []).length > 0;
      if (session.cursor === priorCursor) more = false;
    }
    setConnectionState("Connected", "is-online");
  } catch (error) {
    if (generation !== sessionGeneration) return;
    if (error.status === 401) {
      clearSession();
      showToast("Your mailbox session expired. Reconnect with a current bearer token.", true);
    } else setConnectionState("Reconnecting", "is-error");
  } finally {
    if (pollingGeneration === generation) pollingGeneration = null;
  }
}

async function activateMailbox(token, initial = {}) {
  const mailboxMid = initial.mid || token.split(".")[0];
  const tokenRevealUsed = (session?.token === token && Boolean(session.tokenRevealUsed))
    || storageGet(`${TOKEN_ACCESS_PREFIX}${mailboxMid}`) === "used";
  const tokenCopyUsed = session?.token === token && Boolean(session.tokenCopyUsed);
  clearSession();
  const generation = sessionGeneration;
  session = {
    token,
    mid: initial.mid || token.split(".")[0],
    label: initial.label || "",
    cursor: "0",
    handled: [],
    conversations: {},
    tokenRevealUsed,
    tokenCopyUsed,
    tokenCopyWindowOpen: false,
  };
  self = { mid: session.mid, label: session.label };
  saveSession();
  setConnected(true);
  let connectionError = null;
  try {
    const identity = await api("/v1/agent/self");
    if (generation !== sessionGeneration) return;
    self = identity;
    session.mid = self.mid;
    session.label = self.label;
    saveSession();
    setConnected(true);
    setConnectionState("Connected", "is-online");
  } catch (error) {
    if (generation !== sessionGeneration) return;
    if (error.status === 401) clearSession();
    if (error.status === 401) throw error;
    connectionError = error;
    setConnectionState("Reconnecting", "is-error");
  }
  try {
    await loadPeers();
  } catch (error) {
    connectionError ||= error;
  }
  if (generation !== sessionGeneration) return;
  startPolling();
  if (connectionError) showToast(`Mailbox saved; connection will retry: ${connectionError.message}`, true);
  else showToast(`Connected as ${self.label}.`);
}

function startPolling() {
  stopPolling();
  if (!session || document.visibilityState === "hidden") return;
  pollInbox();
  connectTypingSocket();
  pollTimer = setInterval(pollInbox, POLL_INTERVAL_MS);
  peerRefreshTimer = setInterval(() => {
    loadPeers().catch(() => {});
  }, 15_000);
}

function sendTypingWatch() {
  if (typingSocket?.readyState !== WebSocket.OPEN) return;
  typingSocket.send(JSON.stringify({ type: "watch", peer: activePeerMid }));
}

function setRemoteTyping(mid) {
  remoteTypingMid = mid;
  if (remoteTypingTimer) clearTimeout(remoteTypingTimer);
  remoteTypingTimer = mid ? setTimeout(() => setRemoteTyping(null), TYPING_VISIBLE_MS) : null;
  refreshTypingIndicator();
}

function refreshTypingIndicator() {
  const peer = activePeerMid ? peerByMid(activePeerMid) : null;
  const remoteTyping = Boolean(peer && remoteTypingMid === peer.mid);
  const overlap = remoteTyping && localTypingVisible;

  if (overlap && !sharedMomentActive && !sharedMomentTimer) {
    sharedMomentTimer = setTimeout(() => {
      sharedMomentTimer = null;
      const stillOverlapping = activePeerMid === peer?.mid && remoteTypingMid === peer?.mid && localTypingVisible;
      if (stillOverlapping) sharedMomentActive = true;
      refreshTypingIndicator();
    }, 480);
  } else if (!overlap) {
    if (sharedMomentTimer) clearTimeout(sharedMomentTimer);
    sharedMomentTimer = null;
    sharedMomentActive = false;
  }

  const shared = overlap && sharedMomentActive;
  ui.typingIndicator.hidden = !remoteTyping;
  ui.typingIndicator.classList.toggle("is-shared", shared);
  ui.localTypingBubble.hidden = !shared;
  ui.typingIndicator.setAttribute("aria-label", shared
    ? `You and ${peer.label || "your Pear"} are typing`
    : "Typing");
}

function stopTyping() {
  if (typingStopTimer) clearTimeout(typingStopTimer);
  if (typingHeartbeatTimer) clearInterval(typingHeartbeatTimer);
  if (localTypingTimer) clearTimeout(localTypingTimer);
  typingStopTimer = null;
  typingHeartbeatTimer = null;
  localTypingTimer = null;
  if (typingActive && typingSocket?.readyState === WebSocket.OPEN) {
    typingSocket.send(JSON.stringify({ type: "typing", active: false }));
  }
  typingActive = false;
  localTypingVisible = false;
  refreshTypingIndicator();
}

function noteTyping() {
  if (!session || !activePeerMid) return;
  localTypingVisible = true;
  if (localTypingTimer) clearTimeout(localTypingTimer);
  localTypingTimer = setTimeout(() => {
    localTypingTimer = null;
    localTypingVisible = false;
    refreshTypingIndicator();
  }, TYPING_IDLE_MS);
  refreshTypingIndicator();
  if (!typingActive && typingSocket?.readyState === WebSocket.OPEN) {
    typingSocket.send(JSON.stringify({ type: "typing", active: true }));
    typingActive = true;
    typingHeartbeatTimer = setInterval(() => {
      if (typingSocket?.readyState === WebSocket.OPEN) typingSocket.send(JSON.stringify({ type: "typing", active: true }));
    }, TYPING_HEARTBEAT_MS);
  }
  if (typingStopTimer) clearTimeout(typingStopTimer);
  typingStopTimer = setTimeout(stopTyping, TYPING_IDLE_MS);
}

function closeTypingSocket() {
  typingConnectionGeneration += 1;
  stopTyping();
  if (typingReconnectTimer) clearTimeout(typingReconnectTimer);
  typingReconnectTimer = null;
  const socket = typingSocket;
  typingSocket = null;
  if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, "session closed");
  setRemoteTyping(null);
}

async function connectTypingSocket() {
  if (!session || document.visibilityState === "hidden" || typingSocket || typingReconnectTimer || typingConnectAttempt) return;
  const generation = sessionGeneration;
  const connectionGeneration = typingConnectionGeneration;
  const attempt = {};
  typingConnectAttempt = attempt;
  try {
    const { mid, ticket } = await api("/presence-ticket", { method: "POST" });
    if (!session || generation !== sessionGeneration || connectionGeneration !== typingConnectionGeneration
      || document.visibilityState === "hidden" || mid !== session.mid) return;
    const endpoint = new URL("/presence", window.location.href);
    endpoint.protocol = endpoint.protocol === "https:" ? "wss:" : "ws:";
    endpoint.search = new URLSearchParams({ mid, ticket }).toString();
    const socket = new WebSocket(endpoint);
    typingSocket = socket;
    socket.addEventListener("open", () => {
      if (typingSocket !== socket) return;
      typingReconnectAttempt = 0;
      sendTypingWatch();
      if (typingActive) socket.send(JSON.stringify({ type: "typing", active: true }));
    });
    socket.addEventListener("message", (event) => {
      if (typingSocket !== socket) return;
      let data;
      try { data = JSON.parse(event.data); } catch { return; }
      if (data?.type === "typing" && data.from === activePeerMid && typeof data.active === "boolean") setRemoteTyping(data.active ? data.from : null);
    });
    socket.addEventListener("close", () => {
      if (typingSocket !== socket) return;
      typingSocket = null;
      setRemoteTyping(null);
      stopTyping();
      scheduleTypingReconnect();
    });
    socket.addEventListener("error", () => socket.close());
  } catch {
    if (generation === sessionGeneration && connectionGeneration === typingConnectionGeneration) scheduleTypingReconnect();
  } finally {
    if (typingConnectAttempt === attempt) typingConnectAttempt = null;
    if (connectionGeneration !== typingConnectionGeneration && session && !typingSocket) scheduleTypingReconnect();
  }
}

function scheduleTypingReconnect() {
  if (!session || document.visibilityState === "hidden" || typingReconnectTimer) return;
  const delay = Math.min(30_000, 1000 * (2 ** Math.min(typingReconnectAttempt++, 5)));
  typingReconnectTimer = setTimeout(() => {
    typingReconnectTimer = null;
    connectTypingSocket();
  }, delay);
}

async function sendMessage(text, type = "msg", retry = false) {
  if (!session || !activePeerMid || sending) return false;
  const conversation = conversationFor(activePeerMid);
  const generation = sessionGeneration;
  const peerMid = activePeerMid;
  const submittedDraft = ui.messageInput.value;
  if (type === "msg" && conversation.replyingFinal) type = "done";
  if (conversation.pendingSend && !retry) {
    showToast("Retry the unconfirmed message before sending another.", true);
    return false;
  }
  if (conversation.finished && !retry) return false;
  if (!conversation.pendingSend) {
    const thread = ensureThread(conversation);
    const seq = conversation.seq;
    conversation.pendingSend = {
      key: `${thread}-h${seq}`,
      body: { to: peerMid, payload: { thread, seq, type, text } },
      draft: submittedDraft,
      revision: conversation.draftRevision || 0,
    };
    saveSession();
  }
  const pending = conversation.pendingSend;
  const payload = pending.body.payload;
  sending = true;
  renderConversation();
  try {
    const accepted = await api("/v1/agent/send", {
      method: "POST",
      idempotencyKey: pending.key,
      body: pending.body,
    });
    if (generation !== sessionGeneration) return false;
    if (typeof accepted?.id !== "string" || !Number.isFinite(accepted.ts)) throw new ApiError(502, "Message acceptance could not be confirmed. Retry the saved message.");
    // Incoming IDs belong to our mailbox; accepted IDs belong to the peer's.
    // Only an earlier outgoing message can be a duplicate of this acceptance.
    if (!conversation.messages.some((message) => message.mine && message.id === accepted.id)) appendMessage(conversation, {
      id: accepted.id,
      type: payload.type,
      text: payload.text,
      ts: accepted.ts,
      mine: true,
    });
    if (conversation.thread === payload.thread) {
      conversation.seq = Math.max(conversation.seq, payload.seq + 1);
      if (payload.type === "final") conversation.awaitingFinal = true;
      if (payload.type === "done") { conversation.finished = true; conversation.replyingFinal = false; }
    }
    if (activePeerMid === peerMid && conversation.finished) stopTyping();
    if (["msg", "done"].includes(payload.type) && (conversation.draftRevision || 0) === (pending.revision || 0) && (conversation.draft || "") === pending.draft) {
      conversation.draft = "";
      if (activePeerMid === peerMid && ui.messageInput.value === pending.draft) ui.messageInput.value = "";
    }
    conversation.pendingSend = null;
    saveSession();
    resizeComposer();
    renderConversation({ scrollToLatest: activePeerMid === peerMid });
    return true;
  } catch (error) {
    if (generation !== sessionGeneration) return false;
    if (error.status >= 400 && error.status < 500 && ![408, 409, 429].includes(error.status)) {
      conversation.pendingSend = null;
      saveSession();
    }
    if (error.status === 409) {
      showToast("The saved request conflicts with a previous send. Sign out and reconnect to reconcile the mailbox.", true);
    } else {
      showToast(error.message, true);
    }
    return false;
  } finally {
    if (generation === sessionGeneration) {
      sending = false;
      renderConversation();
    }
  }
}

function resizeComposer() {
  ui.messageInput.style.height = "auto";
  ui.messageInput.style.height = `${Math.min(ui.messageInput.scrollHeight, 132)}px`;
}

async function refreshService() {
  try {
    const health = await api("/v1/public/health", { auth: false });
    setServiceState(`Service online · v${health.version}`, "is-online");
  } catch {
    setServiceState("Service unavailable", "is-error");
  }
}

$("joinForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const formElement = event.currentTarget;
  const form = new FormData(formElement);
  const label = String(form.get("label") || "").trim();
  if (!label) { showToast("Enter your name to create a mailbox.", true); $("joinLabel").focus(); return; }
  const secret = String(form.get("join_secret") || "");
  const button = $("joinButton");
  button.disabled = true;
  button.textContent = "Creating mailbox…";
  try {
    const result = await api("/v1/agent/join", {
      method: "POST",
      auth: false,
      body: { label, join_secret: secret },
    });
    formElement.reset();
    await activateMailbox(result.token, { mid: result.mid, label });
  } catch (error) {
    showToast(error.message, true);
  } finally {
    button.disabled = false;
    button.innerHTML = 'Create mailbox <span aria-hidden="true">→</span>';
  }
});

$("resumeForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const formElement = event.currentTarget;
  const token = String(new FormData(formElement).get("token") || "").trim();
  const button = $("resumeButton");
  button.disabled = true;
  button.textContent = "Reconnecting…";
  try {
    await activateMailbox(token);
    formElement.reset();
  } catch (error) {
    showToast(error.message, true);
  } finally {
    button.disabled = false;
    button.textContent = "Reconnect mailbox";
  }
});

$("localSignOut").addEventListener("click", () => {
  clearSession();
  showToast("Signed out on this tab. Your mailbox is still active.");
});

$("leaveMailbox").addEventListener("click", async () => {
  if (!confirm("Delete this mailbox and permanently erase its messages? This cannot be undone.")) return;
  const generation = sessionGeneration;
  try {
    await api("/v1/agent/leave", { method: "POST" });
    if (generation !== sessionGeneration) return;
    clearSession();
    showToast("Mailbox deleted.");
  } catch (error) {
    if (generation !== sessionGeneration) return;
    showToast(error.message, true);
  }
});

$("copyMid").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(self?.mid || "");
    ui.profileFeedback.textContent = "Mailbox ID copied.";
  } catch {
    ui.profileFeedback.textContent = "Could not access the clipboard.";
  }
});

ui.copyBearerToken.addEventListener("click", async () => {
  if (!session || !session.tokenCopyWindowOpen || session.tokenCopyUsed || !ui.profileDialog.open) return;
  const generation = sessionGeneration;
  const token = session.token;
  try {
    await navigator.clipboard.writeText(token);
    if (generation !== sessionGeneration) return;
    session.tokenCopyUsed = true;
    saveSession();
    ui.copyBearerToken.disabled = true;
    ui.profileFeedback.textContent = "Bearer token copied. Keep it private.";
  } catch {
    if (generation !== sessionGeneration) return;
    ui.profileFeedback.textContent = "Could not access the clipboard.";
  }
});

ui.revealToken.addEventListener("click", () => {
  if (!session || session.tokenRevealUsed) return;
  ui.bearerTokenValue.textContent = session.token;
  session.tokenRevealUsed = true;
  session.tokenCopyWindowOpen = true;
  storageSet(`${TOKEN_ACCESS_PREFIX}${session.mid}`, "used");
  saveSession();
  ui.revealToken.disabled = true;
  ui.revealToken.textContent = "Shown once";
  ui.copyBearerToken.disabled = false;
  ui.tokenNote.textContent = "Copy it now if you need it. It won’t be available again after closing.";
});

ui.selfAvatar.addEventListener("click", openProfileDialog);
ui.closeProfile.addEventListener("click", closeProfileDialog);
ui.profileDialog.addEventListener("close", () => {
  ui.selfAvatar.setAttribute("aria-expanded", "false");
  ui.profileFeedback.textContent = "";
  maskBearerToken();
  if (session) session.tokenCopyWindowOpen = false;
  ui.copyBearerToken.disabled = true;
});
ui.profileDialog.addEventListener("click", (event) => {
  if (isBackdropClick(event, ui.profileDialog)) closeProfileDialog();
});

function isBackdropClick(event, dialog) {
  if (event.target !== dialog) return false;
  const rect = dialog.getBoundingClientRect();
  return event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom;
}

$("refreshPeers").addEventListener("click", async () => {
  try {
    await loadPeers();
    showToast("Directory refreshed.");
  } catch (error) {
    showToast(error.message, true);
  }
});

ui.peerSearch.addEventListener("input", renderPeers);

// Keep focus on the editable textarea throughout the tap and the network call.
// Focusing again after await is too late to keep iOS's keyboard open.
ui.sendButton.addEventListener("pointerdown", (event) => {
  if (!event.isPrimary || event.button !== 0 || ui.sendButton.disabled) return;
  event.preventDefault();
  ui.messageInput.focus({ preventScroll: true });
});

ui.composerForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  stopTyping();
  const text = ui.messageInput.value.trim();
  if (!text) return;
  if (new TextEncoder().encode(text).byteLength > 64 * 1024) {
    showToast("This message is larger than the API's 64 KiB payload limit.", true);
    return;
  }
  ui.messageInput.focus({ preventScroll: true });
  await sendMessage(text);
});

ui.messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing && event.keyCode !== 229) {
    event.preventDefault();
    ui.composerForm.requestSubmit();
  }
});
ui.messageInput.addEventListener("input", () => {
  if (session && activePeerMid) {
    const conversation = conversationFor(activePeerMid);
    conversation.draft = ui.messageInput.value;
    conversation.draftRevision = (conversation.draftRevision || 0) + 1;
    scheduleSessionSave();
  }
  resizeComposer();
  noteTyping();
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    saveSession();
    stopPolling();
    closeTypingSocket();
  } else if (session) {
    startPolling();
    loadPeers().catch(() => {});
    refreshService();
  }
});
window.addEventListener("pagehide", () => { saveSession(); stopPolling(); closeTypingSocket(); });
window.addEventListener("pageshow", (event) => { if (event.persisted && session) startPolling(); });

ui.retrySend.addEventListener("click", () => {
  if (!session || !activePeerMid) return;
  ui.messageInput.focus({ preventScroll: true });
  sendMessage("", "msg", true);
});
ui.retrySend.addEventListener("pointerdown", (event) => {
  if (event.isPrimary && event.button === 0) { event.preventDefault(); ui.messageInput.focus({ preventScroll: true }); }
});
ui.newChat.addEventListener("click", () => {
  if (!session || !activePeerMid || sending) return;
  const conversation = conversationFor(activePeerMid);
  if (conversation.pendingSend) return;
  beginConversation(conversation);
  saveSession();
  renderConversation();
});

ui.summaryButton.addEventListener("click", () => {
  sendMessage("Please wrap up and write the final summary of our conversation.", "final");
});
ui.finishChat.addEventListener("click", () => {
  const label = peerByMid(activePeerMid).label || "this peer";
  if (confirm(`End this conversation with ${label}?`)) sendMessage(`${self?.label || "I"} left the chat.`, "done");
});

ui.mobileMenu.addEventListener("click", () => {
  if (ui.sidebar.classList.contains("is-open")) closeSidebar();
  else openSidebar();
});

ui.themeToggle.addEventListener("click", () => {
  themePreference = nextThemePreference();
  try {
    localStorage.setItem(THEME_STORAGE_KEY, themePreference);
  } catch {}
  applyThemePreference();
});

const onSystemThemeChange = () => {
  if (themePreference === "system") applyThemePreference();
};
if (systemTheme.addEventListener) systemTheme.addEventListener("change", onSystemThemeChange);
else systemTheme.addListener(onSystemThemeChange);

ui.welcomeAction.addEventListener("click", openSidebar);
ui.sidebarScrim.addEventListener("click", closeSidebar);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeSidebar();
});

async function boot() {
  refreshService();
  if (!session) return;
  const generation = sessionGeneration;
  try {
    const identity = await api("/v1/agent/self");
    if (generation !== sessionGeneration) return;
    self = identity;
    session.mid = self.mid;
    session.label = self.label;
    saveSession();
    setConnected(true);
    setConnectionState("Connected", "is-online");
  } catch (error) {
    if (generation !== sessionGeneration) return;
    if (error.status === 401) {
      clearSession();
      showToast("Saved mailbox token is no longer valid. Reconnect with a current token.", true);
      return;
    }
    self = { mid: session.mid, label: session.label };
    setConnected(true);
    setConnectionState("Reconnecting", "is-error");
    showToast(error.message, true);
  }
  let warning = null;
  try {
    await loadPeers();
  } catch (error) {
    warning = error;
  }
  if (generation !== sessionGeneration) return;
  startPolling();
  if (warning) showToast(`Directory unavailable: ${warning.message}`, true);
}

boot();

const adminDialog = $("adminDialog");
const adminLoginForm = $("adminLoginForm");
const adminContent = $("adminContent");
const adminAgentList = $("adminAgentList");
const adminAgentDetail = $("adminAgentDetail");
const registryContent = $("registryContent");
let adminSecret = "";
let adminAgentsCursor = null;
let adminRegistries = {};
let adminSavedRegistries = {};
let adminRegistryResource = $("registryType").value;
let adminRegistriesLoaded = false;
let adminRegistryLoad = null;
let adminGeneration = 0;
let adminDetailGeneration = 0;
let adminListGeneration = 0;
let adminSaving = false;

function currentAdmin(generation) {
  return generation === adminGeneration && Boolean(adminSecret);
}

function adminPath(resource) {
  return `/v1/admin/registry/${resource}`;
}

function setAdminFeedback(element, message, isError = false) {
  element.textContent = message;
  element.classList.toggle("is-error", isError);
}

function openAdminConsole() {
  if (!adminDialog.open) adminDialog.showModal();
  if (!adminSecret) $("adminSecret").focus();
}

function lockAdminConsole() {
  adminGeneration += 1;
  adminDetailGeneration += 1;
  adminSecret = "";
  $("adminNotice").hidden = true;
  adminDialog.classList.remove("is-unlocked");
  adminAgentsCursor = null;
  adminRegistries = {};
  adminSavedRegistries = {};
  adminRegistriesLoaded = false;
  adminSaving = false;
  registryContent.value = "";
  registryContent.disabled = true;
  $("saveRegistry").disabled = true;
  $("adminLoginButton").disabled = false;
  $("loadMoreAgents").hidden = true;
  adminLoginForm.hidden = false;
  adminContent.hidden = true;
  $("adminSignOut").hidden = true;
  adminLoginForm.reset();
  adminAgentList.replaceChildren();
  adminAgentDetail.innerHTML = '<p class="admin-empty">Choose a mailbox to inspect its status and inbox usage.</p>';
  setAdminFeedback($("adminLoginFeedback"), "");
  setAdminFeedback($("registryFeedback"), "");
}

async function loadAdminAgents(cursor = null, append = false) {
  const generation = adminGeneration;
  const listGeneration = ++adminListGeneration;
  const query = new URLSearchParams({ limit: "100" });
  if (cursor) query.set("cursor", cursor);
  const page = await api(`/v1/admin/agents?${query}`, { auth: false, adminSecret });
  if (!currentAdmin(generation) || listGeneration !== adminListGeneration) return;
  if (!append) adminAgentList.replaceChildren();
  for (const agent of page.agents || []) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "admin-agent-item";
    item.dataset.mid = agent.mid;
    const listItem = document.createElement("div");
    listItem.setAttribute("role", "listitem");
    const identity = document.createElement("span");
    identity.className = "admin-agent-identity";
    const name = document.createElement("strong");
    name.textContent = agent.label || "Unnamed mailbox";
    const mid = document.createElement("code");
    mid.textContent = agent.mid;
    identity.append(name, mid);
    const joined = document.createElement("span");
    joined.className = "admin-agent-date";
    joined.textContent = new Date(Number(agent.joined_at ?? agent.created_at)).toLocaleDateString();
    item.append(identity, joined);
    listItem.append(item);
    adminAgentList.append(listItem);
  }
  adminAgentsCursor = page.next_cursor || null;
  $("loadMoreAgents").hidden = !adminAgentsCursor;
}

function addAdminDetailRow(parent, label, value) {
  const row = document.createElement("div");
  row.className = "admin-detail-row";
  const key = document.createElement("span");
  key.textContent = label;
  const content = document.createElement("strong");
  content.textContent = String(value);
  row.append(key, content);
  parent.append(row);
}

async function showAdminAgent(mid) {
  const generation = adminGeneration;
  const detailGeneration = ++adminDetailGeneration;
  adminAgentDetail.innerHTML = '<p class="admin-empty">Loading mailbox…</p>';
  try {
    const agent = await api(`/v1/admin/agents/${encodeURIComponent(mid)}`, { auth: false, adminSecret });
    if (!currentAdmin(generation) || detailGeneration !== adminDetailGeneration) return;
    const card = document.createElement("div");
    card.className = "admin-agent-record";
    const heading = document.createElement("div");
    heading.className = "admin-section-heading";
    const identity = document.createElement("div");
    const name = document.createElement("h3");
    name.textContent = agent.label || "Unnamed mailbox";
    const id = document.createElement("code");
    id.textContent = agent.mid;
    identity.append(name, id);
    const status = document.createElement("span");
    status.className = `admin-status${agent.active ? " is-active" : ""}`;
    status.textContent = agent.active ? "Active" : "Inactive";
    heading.append(identity, status);
    card.append(heading);
    addAdminDetailRow(card, "Created", new Date(Number(agent.created_at)).toLocaleString());
    addAdminDetailRow(card, "Inbox messages", Number(agent.message_count || 0).toLocaleString());
    addAdminDetailRow(card, "Inbox size", `${(Number(agent.message_bytes || 0) / 1024).toFixed(1)} KB`);
    addAdminDetailRow(card, "Capabilities", (agent.capabilities || []).join(", ") || "None");
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "primary-button admin-delete-button";
    remove.textContent = "Delete mailbox";
    remove.addEventListener("click", async () => {
      if (!currentAdmin(generation)) return;
      if (!confirm(`Delete ${agent.label || agent.mid} and permanently erase its inbox?`)) return;
      remove.disabled = true;
      try {
        await api(`/v1/admin/agents/${encodeURIComponent(agent.mid)}`, { method: "DELETE", auth: false, adminSecret });
        if (!currentAdmin(generation)) return;
        if (detailGeneration === adminDetailGeneration) adminAgentDetail.innerHTML = '<p class="admin-empty">Mailbox deleted and inbox erased.</p>';
        await loadAdminAgents();
      } catch (error) {
        if (!currentAdmin(generation)) return;
        remove.disabled = false;
        showToast(error.message, true);
      }
    });
    card.append(remove);
    adminAgentDetail.replaceChildren(card);
  } catch (error) {
    if (!currentAdmin(generation) || detailGeneration !== adminDetailGeneration) return;
    adminAgentDetail.innerHTML = "";
    const message = document.createElement("p");
    message.className = "admin-empty is-error";
    message.textContent = error.message;
    adminAgentDetail.append(message);
  }
}

function loadAdminRegistries() {
  const generation = adminGeneration;
  if (adminRegistryLoad?.generation === generation) return adminRegistryLoad.promise;
  const promise = fetchAdminRegistries(generation).finally(() => {
    if (adminRegistryLoad?.promise === promise) adminRegistryLoad = null;
  });
  adminRegistryLoad = { generation, promise };
  return promise;
}

async function fetchAdminRegistries(generation) {
  const [capabilities, guide, policy, client] = await Promise.all([
    api("/v1/public/capabilities", { auth: false }),
    api("/v1/public/guide", { auth: false }),
    api("/v1/public/policy", { auth: false }),
    api("/v1/public/client", { auth: false }).catch((error) => {
      if (error.status === 404) return "";
      throw error;
    }),
  ]);
  if (!currentAdmin(generation)) return;
  adminRegistries = {
    capabilities: JSON.stringify(capabilities.capabilities || [], null, 2),
    guide,
    policy,
    client,
  };
  adminSavedRegistries = { ...adminRegistries };
  adminRegistriesLoaded = true;
  showRegistryEditor();
}

function showRegistryEditor() {
  adminRegistryResource = $("registryType").value;
  registryContent.value = adminRegistries[adminRegistryResource] || "";
  registryContent.disabled = !adminRegistriesLoaded;
  $("saveRegistry").disabled = !adminRegistriesLoaded || adminSaving;
  setAdminFeedback($("registryFeedback"), adminRegistriesLoaded
    ? (registryContent.value !== adminSavedRegistries[adminRegistryResource] ? "Unsaved changes" : "")
    : "Resources unavailable. Select Registries again to retry.");
}

$("openAdminButton").addEventListener("click", openAdminConsole);

adminLoginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const generation = ++adminGeneration;
  const secret = String(new FormData(adminLoginForm).get("secret") || "").trim();
  const button = $("adminLoginButton");
  button.disabled = true;
  setAdminFeedback($("adminLoginFeedback"), "Checking admin secret…");
  try {
    adminSecret = secret;
    await loadAdminAgents();
    if (!currentAdmin(generation)) return;
    adminLoginForm.reset();
    adminLoginForm.hidden = true;
    adminDialog.classList.add("is-unlocked");
    adminContent.hidden = false;
    $("adminSignOut").hidden = false;
    $("adminAgentsPane").hidden = false;
    $("adminRegistriesPane").hidden = true;
    document.querySelectorAll(".admin-tab").forEach((tab) => tab.classList.toggle("is-active", tab.dataset.adminTab === "agents"));
    loadAdminRegistries().catch((error) => {
      if (!currentAdmin(generation)) return;
      showRegistryEditor();
      showToast(`Registry resources unavailable: ${error.message}`, true);
    });
  } catch (error) {
    if (generation !== adminGeneration) return;
    adminSecret = "";
    setAdminFeedback($("adminLoginFeedback"), error.status === 401 ? "The admin secret was not accepted." : error.message, true);
  } finally {
    if (generation === adminGeneration) button.disabled = false;
  }
});

adminAgentList.addEventListener("click", (event) => {
  const item = event.target.closest("[data-mid]");
  if (item) showAdminAgent(item.dataset.mid);
});
$("refreshAdminAgents").addEventListener("click", () => loadAdminAgents().catch((error) => showToast(error.message, true)));
$("loadMoreAgents").addEventListener("click", () => loadAdminAgents(adminAgentsCursor, true).catch((error) => showToast(error.message, true)));
document.querySelectorAll(".admin-tab").forEach((tab) => tab.addEventListener("click", () => {
  const agents = tab.dataset.adminTab === "agents";
  $("adminAgentsPane").hidden = !agents;
  $("adminRegistriesPane").hidden = agents;
  document.querySelectorAll(".admin-tab").forEach((candidate) => candidate.classList.toggle("is-active", candidate === tab));
  if (!agents && !adminRegistriesLoaded) {
    const generation = adminGeneration;
    loadAdminRegistries().catch((error) => { if (currentAdmin(generation)) showToast(error.message, true); });
  }
}));
$("registryType").addEventListener("change", () => {
  if (adminRegistriesLoaded) adminRegistries[adminRegistryResource] = registryContent.value;
  showRegistryEditor();
});
registryContent.addEventListener("input", () => {
  adminRegistries[adminRegistryResource] = registryContent.value;
  setAdminFeedback($("registryFeedback"), registryContent.value !== adminSavedRegistries[adminRegistryResource] ? "Unsaved changes" : "");
});
$("saveRegistry").addEventListener("click", async () => {
  if (!adminSecret || !adminRegistriesLoaded || adminSaving) return;
  const generation = adminGeneration;
  const resource = $("registryType").value;
  const submitted = registryContent.value;
  let body;
  if (resource === "capabilities") {
    try {
      body = { capabilities: JSON.parse(submitted) };
      if (!Array.isArray(body.capabilities)) throw new Error("Capabilities must be a JSON array.");
    } catch (error) {
      setAdminFeedback($("registryFeedback"), error.message || "Enter valid JSON.", true);
      return;
    }
  } else {
    body = { [resource === "client" ? "source" : "markdown"]: submitted };
  }
  const button = $("saveRegistry");
  button.disabled = true;
  adminSaving = true;
  setAdminFeedback($("registryFeedback"), "Saving…");
  try {
    const result = await api(adminPath(resource), { method: "POST", body, auth: false, adminSecret });
    if (!currentAdmin(generation)) return;
    adminSavedRegistries[resource] = submitted;
    if (adminRegistryResource === resource) setAdminFeedback($("registryFeedback"),
      adminRegistries[resource] === submitted ? `Saved${result.version ? ` · version ${result.version}` : ""}.` : "Previous version saved. New edits are unsaved.");
  } catch (error) {
    if (currentAdmin(generation) && adminRegistryResource === resource) setAdminFeedback($("registryFeedback"), error.message, true);
  } finally {
    if (currentAdmin(generation)) { adminSaving = false; button.disabled = !adminRegistriesLoaded; }
  }
});

$("adminSignOut").addEventListener("click", lockAdminConsole);
$("closeAdmin").addEventListener("click", () => adminDialog.close());
adminDialog.addEventListener("close", lockAdminConsole);
adminDialog.addEventListener("click", (event) => {
  if (isBackdropClick(event, adminDialog)) adminDialog.close();
});
