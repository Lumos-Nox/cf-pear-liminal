#!/usr/bin/env python3
"""Chat as a human with a remote agent running clients/bridge.py over agent-messaging.

Single file, standard library only, so it can be copied to any machine.

Setup:
  Agent machine:  ./clients/bridge.py --chat --state agent.json --label helper --peer-label alice \
                      --topic "..." --persona "..." --duration-min 240 --max-turns 200
  Your machine:   export JOIN_SECRET=...
                  ./clients/human.py --state me.json --label alice --peer-label helper

Either side can start first: clients/human.py waits for the agent's mailbox to appear,
and clients/bridge.py waits for yours (--peer-wait, default 300 s).

Commands:  /end   ask the agent for a final summary, save it, and exit
           /retry retry an unconfirmed message without changing its request
           /quit  tell the agent you left, and exit
           /help  show commands
A line ending with a backslash continues on the next line.

Protocol (compatible with clients/bridge.py): payload {"thread", "seq", "type", "text"}
with type msg | final | done | abort.
Security: incoming text is stripped of control/ANSI sequences before printing,
and only messages from the resolved agent mailbox are shown. The bus has no
end-to-end encryption, so do not paste secrets.
"""
import argparse
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    import readline  # line editing and history on Linux/macOS
except ImportError:
    readline = None

BASE = os.environ.get("AGENT_MESSAGING_BASE", "https://agent-messaging.your-account.workers.dev").rstrip("/")
CONTROL = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|[\x00-\x08\x0b-\x1f\x7f]")
TYPES = {"msg", "final", "done", "abort"}
PROMPT = "you> "


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class Mailbox:
    def __init__(self, state_path):
        self.path = state_path
        self.state = {}
        self.lock = threading.RLock()
        self.opener = urllib.request.build_opener(NoRedirect())
        self.last_poll_status = 200
        if os.path.exists(state_path):
            with open(state_path, encoding="utf-8") as f:
                self.state = json.load(f)
            if self.state.get("base", BASE).rstrip("/") != BASE:
                sys.exit("state belongs to another API base URL; use a different --state file")
        self.state.setdefault("base", BASE)

    def save(self):
        with self.lock:
            directory = os.path.dirname(os.path.abspath(self.path))
            os.makedirs(directory, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=os.path.basename(self.path) + ".", dir=directory)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(self.state, f, indent=1)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, self.path)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)

    def req(self, method, path, body=None, headers=None, auth=True):
        h = {"Content-Type": "application/json", "User-Agent": "agent-messaging-human"}
        if auth:
            h["Authorization"] = "Bearer " + self.state["token"]
        h.update(headers or {})
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
        try:
            with self.opener.open(r, timeout=30) as resp:
                result = json.loads(resp.read())
                if not isinstance(result, dict):
                    raise ValueError("expected a JSON object")
                return resp.status, result
        except urllib.error.HTTPError as e:
            with e:
                return e.code, {"error": e.read().decode(errors="replace")[:300]}
        except urllib.error.URLError as e:
            return 503, {"error": str(e.reason)}
        except (OSError, ValueError) as e:
            return 503, {"error": f"{type(e).__name__}: {e}"}

    def join(self, label):
        secret = os.environ.get("JOIN_SECRET")
        if not secret:
            sys.exit("not joined and JOIN_SECRET is not set")
        status, r = self.req("POST", "/v1/agent/join", {"join_secret": secret, "label": label}, auth=False)
        if status not in (200, 201):
            sys.exit(f"join failed ({status}): {r}")
        self.state = {"mid": r["mid"], "token": r["token"], "label": label}
        self.state["base"] = BASE
        self.save()

    def find_peer(self, label, wait):
        deadline = time.time() + wait
        while time.time() < deadline:
            peers = []
            cursor = None
            seen_cursors = set()
            while True:
                params = {"limit": 100}
                if cursor:
                    if cursor in seen_cursors:
                        sys.exit("peer listing returned a repeated cursor")
                    seen_cursors.add(cursor)
                    params["cursor"] = cursor
                status, r = self.req("GET", "/v1/agent/peers?" + urllib.parse.urlencode(params))
                if status == 401:
                    sys.exit("mailbox token is no longer valid; use a new --state file")
                if status != 200:
                    break
                peers.extend(r["peers"])
                cursor = r.get("next_cursor")
                if not cursor:
                    break
            if status == 200:
                hits = [p["mid"] for p in peers if p.get("label") == label]
                if len(hits) == 1:
                    return hits[0]
                if len(hits) > 1:
                    sys.exit(f"label '{label}' matches {len(hits)} mailboxes {hits}; use --peer-mid")
            time.sleep(3)
        sys.exit(f"agent '{label}' did not appear within {wait}s")

    def send(self, to, payload, key):
        request = json.loads(json.dumps({"to": to, "payload": payload, "key": key}))
        with self.lock:
            pending = self.state.get("pending_send")
            if pending and pending != request:
                raise ValueError("an earlier send is unconfirmed; retry its exact request first")
            self.state["pending_send"] = request
            self.save()
        payload = request["payload"]
        for attempt in range(6):
            status, r = self.req("POST", "/v1/agent/send", {"to": to, "payload": payload},
                                 {"Idempotency-Key": key})
            if status == 200:   # idempotent retries return the original id with duplicate=true
                return True
            if status in (408, 429) or status >= 500:
                if attempt + 1 < 6:
                    time.sleep(min(30, 2 ** attempt))
                continue
            if status == 409:
                print(f"\n[send failed ({status}): idempotency key was reused with a different request: {r}]")
                return False
            if 400 <= status < 500 and status not in (408, 409, 429):
                with self.lock:
                    self.state.pop("pending_send", None)
                    self.save()
            print(f"\n[send failed ({status}): {r}]")
            return False
        print("\n[send failed: bus unreachable or agent inbox full]")
        return False

    def poll(self):
        # A cursor is committed only together with the messages it covers. A crash
        # before the caller records/acks them will replay this local inbox.
        with self.lock:
            if self.state.get("inbox"):
                return list(self.state["inbox"])
        seen_cursors = set()
        while True:
            cursor = str(self.state.get("cursor", "0"))
            if cursor in seen_cursors:
                break
            seen_cursors.add(cursor)
            q = urllib.parse.urlencode({"since": cursor, "limit": 100})
            status, result = self.req("GET", "/v1/agent/poll?" + q)
            self.last_poll_status = status
            if status != 200 or not isinstance(result.get("messages"), list):
                break
            with self.lock:
                inbox = self.state.setdefault("inbox", [])
                previous_size = len(inbox)
                ids = {message.get("id") for message in inbox}
                for message in result["messages"]:
                    if isinstance(message, dict) and isinstance(message.get("id"), str) and message["id"] not in ids:
                        inbox.append(message)
                        ids.add(message["id"])
                self.state["cursor"] = str(result.get("cursor", cursor))
                if len(inbox) != previous_size or self.state["cursor"] != cursor:
                    self.save()
            if not result.get("has_more") or not result["messages"]:
                break
        with self.lock:
            return list(self.state.get("inbox", []))

    def ack(self, message_id):
        with self.lock:
            self.state["inbox"] = [message for message in self.state.get("inbox", []) if message.get("id") != message_id]
            self.save()


def clean(text):
    return CONTROL.sub("", text)


class Chat:
    def __init__(self, a):
        self.a = a
        self.mb = Mailbox(a.state)
        if "token" not in self.mb.state:
            self.mb.join(a.label)
        s = self.s = self.mb.state
        print(f"[you are {a.label} = {s['mid']}]")
        if a.peer_mid:
            self.peer = a.peer_mid
        elif s.get("peer"):
            self.peer = s["peer"]
        else:
            print(f"[waiting for agent '{a.peer_label}' to join...]")
            self.peer = self.mb.find_peer(a.peer_label, a.peer_wait)
        if s.get("peer") and s["peer"] != self.peer:
            sys.exit("state belongs to another peer; use a different --state file")
        self.name = a.peer_label or "agent"
        s["peer"] = self.peer
        s.setdefault("thread", uuid.uuid4().hex[:8])
        s.setdefault("seq", 0)
        s.setdefault("handled", [])
        self.mb.save()
        os.makedirs(a.out, exist_ok=True)
        self.file_label = re.sub(r"[/\\]", "_", a.label)
        self.transcript = os.path.join(a.out, f"{self.file_label}-transcript.md")
        self.over = threading.Event()    # set when the agent sends done/abort
        self.pending = 0                 # messages sent and not yet answered
        self.input_active = False
        print(f"[connected to {self.name} = {self.peer}; thread {s['thread']}; /help for commands]")

    # -- output ------------------------------------------------------------
    def show(self, text):
        """Print above the input line without clobbering what the user is typing."""
        # A poll thread cannot reliably call readline.redisplay(). Reprint the
        # current prompt ourselves, but only reuse the buffer while input() is
        # actually waiting; GNU readline can retain the previous submitted line
        # briefly after input() returns.
        buf = readline.get_line_buffer() if readline and self.input_active else ""
        sys.stdout.write("\r\x1b[2K" + text + "\n" + PROMPT + buf)
        sys.stdout.flush()

    def log(self, who, kind, text):
        with open(self.transcript, "a", encoding="utf-8") as f:
            f.write(f"\n## [{time.strftime('%H:%M:%S')}] {who} ({kind})\n\n{text}\n")

    # -- network -----------------------------------------------------------
    def send(self, kind, text):
        s = self.s
        payload = {"thread": s["thread"], "seq": s["seq"], "type": kind, "text": text}
        try:
            accepted = self.mb.send(self.peer, payload, f"{s['thread']}-h{s['seq']}")
        except ValueError as error:
            print(f"[{error}; use /retry]")
            return False
        if accepted:
            with self.mb.lock:
                s["seq"] += 1
                s.pop("pending_send", None)
                if kind in ("done", "abort"):
                    s["finished"] = True
                if kind == "final":
                    s["awaiting_final"] = True
                self.mb.save()
            self.log(self.a.label, kind, text)
            self.pending += 1
            return True
        return False

    def retry(self):
        pending = self.s.get("pending_send")
        if not pending:
            print("[no unconfirmed message to retry]")
            return False
        payload = pending["payload"]
        return self.send(payload["type"], payload["text"])

    def poll_loop(self):
        while not self.over.is_set():
            for m in self.mb.poll():
                if m["id"] in self.s["handled"] or m.get("from") != self.peer:
                    self.mb.ack(m["id"])
                    continue
                pl = m.get("payload")
                if not isinstance(pl, dict) or not isinstance(pl.get("type", "msg"), str) or pl.get("type", "msg") not in TYPES \
                        or pl.get("thread") not in (None, self.s["thread"]):
                    self.mb.ack(m["id"])
                    continue
                kind, text = pl.get("type", "msg"), clean(str(pl.get("text", "")))
                self.pending = max(0, self.pending - 1)
                self.log(self.name, kind, text)
                ts = time.strftime("%H:%M")
                self.show(f"\n{self.name} [{ts}]{'' if kind == 'msg' else f' ({kind})'}:\n{text}\n")
                if kind in ("done", "abort", "final"):
                    if kind in ("done", "final"):
                        path = os.path.join(self.a.out, f"{self.file_label}-final.md")
                        with open(path, "w", encoding="utf-8") as f:
                            f.write(text + "\n")
                        self.show(f"[summary saved to {path}]")
                    with self.mb.lock:
                        self.s["handled"] = (self.s["handled"] + [m["id"]])[-500:]
                        self.s["finished"] = True
                        self.mb.ack(m["id"])
                    self.over.set()
                    return
                with self.mb.lock:
                    self.s["handled"] = (self.s["handled"] + [m["id"]])[-500:]
                    self.mb.ack(m["id"])
            if self.mb.last_poll_status == 401:
                self.show("[mailbox token expired; press Enter to exit]")
                self.over.set()
                return
            time.sleep(self.a.interval)


    # -- input -------------------------------------------------------------
    def read_message(self):
        self.input_active = True
        try:
            lines = [input(PROMPT)]
            while lines[-1].endswith("\\"):
                lines[-1] = lines[-1][:-1]
                lines.append(input("...  "))
            return "\n".join(lines).strip()
        finally:
            self.input_active = False

    def run(self):
        if self.s.get("finished"):
            print("[conversation already ended; use a new --state for a fresh one]")
            return
        if self.s.get("pending_send"):
            print("[retrying the saved, unconfirmed outgoing message]")
            if not self.retry():
                print("[send remains unconfirmed; use /retry]")
        if self.s.get("finished"):
            return
        threading.Thread(target=self.poll_loop, daemon=True).start()
        if self.s.get("awaiting_final"):
            self.over.wait(self.a.final_wait) or print("[no summary arrived; exiting]")
            return
        while not self.over.is_set():
            try:
                text = self.read_message()
            except EOFError:             # Ctrl-D behaves like /quit
                text = "/quit"
            if self.over.is_set():
                break
            if not text:
                continue
            if text == "/help":
                print(__doc__.split("Commands:")[1].split("Protocol")[0].rstrip())
            elif text == "/quit":
                self.send("done", f"{self.a.label} left the chat.")
                print("[left the chat]")
                return
            elif text == "/end":
                if self.send("final", "Please wrap up and write the final summary of our conversation."):
                    print(f"[asked {self.name} for a final summary; waiting up to {self.a.final_wait}s]")
                    self.over.wait(self.a.final_wait) or print("[no summary arrived; exiting]")
                return
            elif text == "/retry":
                self.retry()
            elif text.startswith("/"):
                print("[unknown command; /help lists them]")
            elif self.send("msg", text):
                if self.pending > 1:
                    print(f"[sent; {self.pending} messages waiting for a reply]")
                else:
                    print(f"[sent; waiting for {self.name}...]")
        print(f"[{self.name} ended the conversation]")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", required=True, help="your mailbox state file (created on join, 0600)")
    ap.add_argument("--label", required=True, help="your label on the bus")
    ap.add_argument("--peer-label", help="the agent's label (must be unique on the bus)")
    ap.add_argument("--peer-mid", help="the agent's mailbox id; skips label lookup")
    ap.add_argument("--out", default="chat", help="dir for transcript and final summary")
    ap.add_argument("--interval", type=float, default=3, help="poll interval seconds")
    ap.add_argument("--peer-wait", type=int, default=600, help="seconds to wait for the agent to join")
    ap.add_argument("--final-wait", type=int, default=600, help="seconds to wait for the summary on /end")
    ap.add_argument("--leave-on-exit", action="store_true", help="erase your mailbox when you exit")
    a = ap.parse_args()
    if not (a.peer_label or a.peer_mid):
        ap.error("one of --peer-label or --peer-mid is required")
    if any(value <= 0 for value in (a.interval, a.peer_wait, a.final_wait)):
        ap.error("interval and wait times must be positive")
    chat = Chat(a)
    try:
        chat.run()
    except KeyboardInterrupt:
        print("\n[interrupted; the agent was not told. Rerun with the same --state to continue]")
        return
    if a.leave_on_exit:
        print(f"[leave: {chat.mb.req('POST', '/v1/agent/leave')}]")


if __name__ == "__main__":
    main()
