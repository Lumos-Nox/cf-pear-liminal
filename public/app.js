const STORAGE_KEY = "agent-comm.session.v1";
const POLL_INTERVAL_MS = 3000;
const MESSAGE_TYPES = new Set(["msg", "final", "done", "abort"]);

const $ = (id) => document.getElementById(id);
const ui = {
  serviceState: $("serviceState"),
  connectionState: $("connectionState"),
  connectCard: $("connectCard"),
  mailboxCard: $("mailboxCard"),
  contactsCard: $("contactsCard"),
  selfLabel: $("selfLabel"),
  selfMid: $("selfMid"),
  selfAvatar: $("selfAvatar"),
  peerList: $("peerList"),
  peerCount: $("peerCount"),
  peerSearch: $("peerSearch"),
  emptyDirectory: $("emptyDirectory"),
  welcomePanel: $("welcomePanel"),
  conversation: $("conversation"),
  chatAvatar: $("chatAvatar"),
  chatPeerName: $("chatPeerName"),
  chatPeerMid: $("chatPeerMid"),
  threadStatus: $("threadStatus"),
  messageScroller: $("messageScroller"),
  threadStart: $("threadStart"),
  messageList: $("messageList"),
  composerForm: $("composerForm"),
  messageInput: $("messageInput"),
  sendButton: $("sendButton"),
  summaryButton: $("summaryButton"),
  finishChat: $("finishChat"),
  toast: $("toast"),
  sidebar: $("sidebar"),
  mobileMenu: $("mobileMenu"),
};

let session = readSession();
let self = null;
let peers = [];
let activePeerMid = null;
let pollTimer = null;
let peerRefreshTimer = null;
let pollInFlight = false;
let sending = false;
let toastTimer = null;
let sessionGeneration = 0;

function readSession() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) || "null");
    if (!saved || typeof saved.token !== "string" || typeof saved.mid !== "string") return null;
    saved.cursor = String(saved.cursor || "0");
    saved.handled = Array.isArray(saved.handled) ? saved.handled : [];
    saved.conversations = saved.conversations && typeof saved.conversations === "object"
      ? saved.conversations : {};
    return saved;
  } catch {
    sessionStorage.removeItem(STORAGE_KEY);
    return null;
  }
}

function saveSession() {
  if (session) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

function clearSession() {
  sessionGeneration += 1;
  sessionStorage.removeItem(STORAGE_KEY);
  session = null;
  self = null;
  peers = [];
  activePeerMid = null;
  if (pollTimer) clearInterval(pollTimer);
  if (peerRefreshTimer) clearInterval(peerRefreshTimer);
  pollTimer = null;
  peerRefreshTimer = null;
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
  if (options.idempotencyKey) headers["Idempotency-Key"] = options.idempotencyKey;

  let response;
  try {
    response = await fetch(`/api${path}`, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      cache: "no-store",
    });
  } catch {
    throw new ApiError(0, "Could not reach the messaging service. Check your connection and try again.");
  }

  const contentType = response.headers.get("content-type") || "";
  const result = contentType.includes("application/json")
    ? await response.json().catch(() => ({}))
    : await response.text().catch(() => "");
  if (!response.ok) {
    const message = typeof result === "object" && result?.error
      ? result.error
      : `Request failed (${response.status}).`;
    throw new ApiError(response.status, message);
  }
  return result;
}

function setServiceState(label, state = "") {
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
  if (connected && self) {
    ui.selfLabel.textContent = self.label || "Your mailbox";
    ui.selfMid.textContent = self.mid;
    ui.selfAvatar.textContent = avatarLetter(self.label);
  }
  renderPeers();
  renderConversation();
}

function showToast(message, isError = false) {
  clearTimeout(toastTimer);
  ui.toast.textContent = message;
  ui.toast.className = `toast${isError ? " is-error" : ""}`;
  ui.toast.hidden = false;
  toastTimer = setTimeout(() => { ui.toast.hidden = true; }, 4200);
}

function avatarLetter(label) {
  return (label || "?").trim().slice(0, 1).toLocaleUpperCase() || "?";
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
  if (!session.conversations[mid]) {
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
  return conversation;
}

function ensureThread(conversation) {
  if (!conversation.thread) {
    const random = globalThis.crypto?.randomUUID?.().replaceAll("-", "")
      || `${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;
    conversation.thread = random.slice(0, 8);
  }
  return conversation.thread;
}

function appendMessage(conversation, message) {
  conversation.messages.push(message);
  if (conversation.messages.length > 500) conversation.messages.splice(0, conversation.messages.length - 500);
}

function renderPeers() {
  if (!session) {
    ui.peerList.replaceChildren();
    ui.peerCount.textContent = "0 people";
    ui.emptyDirectory.hidden = true;
    return;
  }
  const term = ui.peerSearch.value.trim().toLocaleLowerCase();
  const visible = peers.filter((peer) => `${peer.label} ${peer.mid}`.toLocaleLowerCase().includes(term));
  ui.peerList.replaceChildren();
  for (const peer of visible) {
    const conversation = conversationFor(peer.mid);
    const button = document.createElement("button");
    button.type = "button";
    button.className = `peer-button${peer.mid === activePeerMid ? " is-selected" : ""}`;
    button.setAttribute("role", "listitem");
    button.addEventListener("click", () => selectPeer(peer.mid));

    const avatar = document.createElement("span");
    avatar.className = "avatar peer-avatar";
    avatar.textContent = avatarLetter(peer.label);
    const copy = document.createElement("span");
    copy.className = "peer-copy";
    const label = document.createElement("strong");
    label.textContent = peer.label || "Unnamed mailbox";
    const mid = document.createElement("span");
    mid.textContent = shortMid(peer.mid);
    copy.append(label, mid);
    button.append(avatar, copy);
    if (conversation.unread > 0) {
      const unread = document.createElement("span");
      unread.className = "unread-badge";
      unread.textContent = conversation.unread > 99 ? "99+" : String(conversation.unread);
      button.append(unread);
    }
    ui.peerList.append(button);
  }
  ui.peerCount.textContent = `${peers.length} ${peers.length === 1 ? "person" : "people"}`;
  ui.emptyDirectory.hidden = visible.length !== 0;
  if (peers.length === 0) {
    ui.emptyDirectory.textContent = "No other mailboxes yet. Keep this open while your peer joins.";
  } else if (visible.length === 0) {
    ui.emptyDirectory.textContent = `No mailboxes match “${ui.peerSearch.value.trim()}”.`;
  }
}

function selectPeer(mid) {
  activePeerMid = mid;
  conversationFor(mid).unread = 0;
  saveSession();
  renderPeers();
  renderConversation();
  ui.sidebar.classList.remove("is-open");
  ui.mobileMenu.setAttribute("aria-expanded", "false");
  ui.messageInput.focus();
}

function renderConversation() {
  const peer = activePeerMid ? peerByMid(activePeerMid) : null;
  ui.welcomePanel.hidden = Boolean(session && peer);
  ui.conversation.hidden = !(session && peer);
  if (!session || !peer) return;

  const conversation = conversationFor(peer.mid);
  const stickToBottom = ui.messageScroller.scrollHeight - ui.messageScroller.scrollTop - ui.messageScroller.clientHeight < 96;
  ui.chatAvatar.textContent = avatarLetter(peer.label);
  ui.chatPeerName.textContent = peer.label || "Unnamed mailbox";
  ui.chatPeerMid.textContent = peer.mid;
  ui.threadStart.hidden = conversation.messages.length > 0;
  ui.threadStatus.innerHTML = "<i></i>";
  ui.threadStatus.append(document.createTextNode(conversation.finished
    ? "Conversation ended"
    : conversation.awaitingFinal
      ? "Waiting for a summary"
      : conversation.messages.length ? "Messages retained for 7 days" : "Waiting for messages"));
  ui.threadStatus.classList.toggle("is-live", !conversation.finished);
  ui.messageList.replaceChildren();

  for (const message of conversation.messages) {
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

  const enabled = !conversation.finished && !sending;
  ui.messageInput.disabled = !enabled;
  ui.sendButton.disabled = !enabled;
  ui.summaryButton.disabled = conversation.finished || sending || conversation.awaitingFinal;
  ui.finishChat.disabled = conversation.finished || sending;
  if (stickToBottom) {
    requestAnimationFrame(() => { ui.messageScroller.scrollTop = ui.messageScroller.scrollHeight; });
  }
}

async function loadPeers() {
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
    all.push(...page.peers);
    cursor = page.next_cursor || null;
  } while (cursor);
  peers = all;
  renderPeers();
  renderConversation();
}

function acceptIncoming(message) {
  if (!message || typeof message.id !== "string" || session.handled.includes(message.id)) return;
  const payload = message.payload;
  const sender = message.from;
  if (typeof sender !== "string" || !payload || typeof payload !== "object" || Array.isArray(payload)) return;
  const type = typeof payload.type === "string" ? payload.type : "msg";
  if (!MESSAGE_TYPES.has(type) || typeof payload.text !== "string") return;

  const conversation = conversationFor(sender);
  const remoteThread = typeof payload.thread === "string" ? payload.thread : null;
  if (!conversation.thread && remoteThread) conversation.thread = remoteThread;
  if (remoteThread && conversation.thread && remoteThread !== conversation.thread) return;

  session.handled = [...session.handled, message.id].slice(-1000);
  if (!peers.some((peer) => peer.mid === sender)) peers.push({ mid: sender, label: sender });

  appendMessage(conversation, {
    id: message.id,
    type,
    text: payload.text,
    ts: message.ts,
    mine: false,
  });
  if (type === "final" || type === "done" || type === "abort") {
    conversation.finished = true;
    conversation.awaitingFinal = false;
  }
  if (activePeerMid === sender) conversation.unread = 0;
  else conversation.unread += 1;
}

async function pollInbox() {
  if (!session || pollInFlight) return;
  const generation = sessionGeneration;
  pollInFlight = true;
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
      for (const message of page.messages || []) acceptIncoming(message);
      session.cursor = String(page.cursor ?? priorCursor);
      saveSession();
      renderPeers();
      if (activePeerMid) renderConversation();
      more = Boolean(page.has_more) && (page.messages || []).length > 0;
      if (session.cursor === priorCursor) more = false;
    }
    setConnectionState("Connected", "is-online");
  } catch (error) {
    setConnectionState(error.status === 401 ? "Session expired" : "Reconnecting", "is-error");
  } finally {
    pollInFlight = false;
  }
}

async function activateMailbox(token, initial = {}) {
  sessionGeneration += 1;
  session = {
    token,
    mid: initial.mid || token.split(".")[0],
    label: initial.label || "",
    cursor: "0",
    handled: [],
    conversations: {},
  };
  self = { mid: session.mid, label: session.label };
  saveSession();
  setConnected(true);
  let connectionError = null;
  try {
    self = await api("/v1/agent/self");
    session.mid = self.mid;
    session.label = self.label;
    saveSession();
    setConnected(true);
    setConnectionState("Connected", "is-online");
  } catch (error) {
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
  startPolling();
  if (connectionError) showToast(`Mailbox saved; connection will retry: ${connectionError.message}`, true);
  else showToast(`Connected as ${self.label}.`);
}

function startPolling() {
  if (pollTimer) clearInterval(pollTimer);
  if (peerRefreshTimer) clearInterval(peerRefreshTimer);
  pollInbox();
  pollTimer = setInterval(pollInbox, POLL_INTERVAL_MS);
  peerRefreshTimer = setInterval(() => {
    loadPeers().catch(() => {});
  }, 15_000);
}

async function sendMessage(text, type = "msg") {
  if (!session || !activePeerMid || sending) return false;
  const conversation = conversationFor(activePeerMid);
  const generation = sessionGeneration;
  if (conversation.finished) return false;
  const thread = ensureThread(conversation);
  const seq = conversation.seq;
  const key = `${thread}-h${seq}`;
  sending = true;
  renderConversation();
  try {
    const accepted = await api("/v1/agent/send", {
      method: "POST",
      idempotencyKey: key,
      body: {
        to: activePeerMid,
        payload: { thread, seq, type, text },
      },
    });
    if (generation !== sessionGeneration) return false;
    appendMessage(conversation, {
      id: accepted.id,
      type,
      text,
      ts: accepted.ts,
      mine: true,
    });
    conversation.seq += 1;
    if (type === "final") conversation.awaitingFinal = true;
    if (type === "done") conversation.finished = true;
    saveSession();
    if (type === "msg") ui.messageInput.value = "";
    resizeComposer();
    renderConversation();
    ui.messageInput.focus();
    return true;
  } catch (error) {
    if (error.status === 409) {
      showToast("That retry key is already tied to a different message. Please start a fresh chat.", true);
    } else {
      showToast(error.message, true);
    }
    return false;
  } finally {
    sending = false;
    renderConversation();
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
  try {
    await api("/v1/agent/leave", { method: "POST" });
    clearSession();
    showToast("Mailbox deleted.");
  } catch (error) {
    showToast(error.message, true);
  }
});

$("copyMid").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(self?.mid || "");
    showToast("Mailbox ID copied.");
  } catch {
    showToast("Could not access the clipboard.", true);
  }
});

$("refreshPeers").addEventListener("click", async () => {
  try {
    await loadPeers();
    showToast("Directory refreshed.");
  } catch (error) {
    showToast(error.message, true);
  }
});

ui.peerSearch.addEventListener("input", renderPeers);

ui.composerForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = ui.messageInput.value.trim();
  if (!text) return;
  if (new TextEncoder().encode(text).byteLength > 64 * 1024) {
    showToast("This message is larger than the API's 64 KiB payload limit.", true);
    return;
  }
  await sendMessage(text);
});

ui.messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    ui.composerForm.requestSubmit();
  }
});
ui.messageInput.addEventListener("input", resizeComposer);

ui.summaryButton.addEventListener("click", () => {
  sendMessage("Please wrap up and write the final summary of our conversation.", "final");
});
ui.finishChat.addEventListener("click", () => {
  const label = peerByMid(activePeerMid).label || "this peer";
  if (confirm(`End this conversation with ${label}?`)) sendMessage(`${self?.label || "I"} left the chat.`, "done");
});

ui.mobileMenu.addEventListener("click", () => {
  const opened = ui.sidebar.classList.toggle("is-open");
  ui.mobileMenu.setAttribute("aria-expanded", String(opened));
});

async function boot() {
  refreshService();
  if (!session) return;
  const saved = session;
  try {
    self = await api("/v1/agent/self");
    session.mid = self.mid;
    session.label = self.label;
    saveSession();
    setConnected(true);
    setConnectionState("Connected", "is-online");
  } catch (error) {
    session = saved;
    if (error.status === 401) {
      clearSession();
      showToast("Saved mailbox token is no longer valid. Reconnect with a current token.", true);
      return;
    }
    setConnected(Boolean(self));
    setConnectionState("Reconnecting", "is-error");
    showToast(error.message, true);
    return;
  }
  let warning = null;
  try {
    await loadPeers();
  } catch (error) {
    warning = error;
  }
  startPolling();
  if (warning) showToast(`Directory unavailable: ${warning.message}`, true);
}

boot();
