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

BASE = os.environ.get("AGENT_MESSAGING_BASE", "https://agent-messaging.your-account.workers.dev")
CONTROL = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|[\x00-\x08\x0b-\x1f\x7f]")
TYPES = {"msg", "final", "done", "abort"}
PROMPT = "you> "


class Mailbox:
    def __init__(self, path):
        self.path, self.state = path, {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.state = json.load(f)
        self.lock = threading.Lock()     # poll thread and input thread both save

    def save(self):
        with self.lock:
            tmp = self.path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self.state, f, indent=1)
            os.replace(tmp, self.path)

    def req(self, method, path, body=None, headers=None, auth=True):
        h = {"Content-Type": "application/json", "User-Agent": "agent-messaging-human"}
        if auth:
            h["Authorization"] = "Bearer " + self.state["token"]
        h.update(headers or {})
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
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
        for attempt in range(6):
            status, r = self.req("POST", "/v1/agent/send", {"to": to, "payload": payload},
                                 {"Idempotency-Key": key})
            if status == 200:   # idempotent retries return the original id with duplicate=true
                return True
            if status in (429, 503) or status >= 500:
                time.sleep(min(30, 2 ** attempt))
                continue
            if status == 409:
                print(f"\n[send failed ({status}): idempotency key was reused with a different request: {r}]")
                return False
            print(f"\n[send failed ({status}): {r}]")
            return False
        print("\n[send failed: bus unreachable or agent inbox full]")
        return False

    def poll(self):
        out = []
        while True:
            q = urllib.parse.urlencode({"since": self.state.get("cursor", "0"), "limit": 100})
            status, r = self.req("GET", "/v1/agent/poll?" + q)
            if status != 200:
                return out
            out.extend(r["messages"])
            self.state["cursor"] = r["cursor"]
            self.save()
            if not r.get("has_more") or not r["messages"]:
                return out


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
        self.name = a.peer_label or "agent"
        s["peer"] = self.peer
        s.setdefault("thread", uuid.uuid4().hex[:8])
        s.setdefault("seq", 0)
        s.setdefault("handled", [])
        self.mb.save()
        os.makedirs(a.out, exist_ok=True)
        self.transcript = os.path.join(a.out, f"{a.label}-transcript.md")
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
        if self.mb.send(self.peer, payload, f"{s['thread']}-h{s['seq']}"):
            s["seq"] += 1
            self.mb.save()
            self.log(self.a.label, kind, text)
            self.pending += 1
            return True
        return False

    def poll_loop(self):
        while not self.over.is_set():
            for m in self.mb.poll():
                if m["id"] in self.s["handled"] or m.get("from") != self.peer:
                    continue
                self.s["handled"] = (self.s["handled"] + [m["id"]])[-500:]
                self.mb.save()
                pl = m.get("payload")
                if not isinstance(pl, dict) or pl.get("type", "msg") not in TYPES \
                        or pl.get("thread") not in (None, self.s["thread"]):
                    continue
                kind, text = pl.get("type", "msg"), clean(str(pl.get("text", "")))
                self.pending = max(0, self.pending - 1)
                self.log(self.name, kind, text)
                ts = time.strftime("%H:%M")
                self.show(f"\n{self.name} [{ts}]{'' if kind == 'msg' else f' ({kind})'}:\n{text}\n")
                if kind in ("done", "abort", "final"):
                    if kind in ("done", "final"):
                        path = os.path.join(self.a.out, f"{self.a.label}-final.md")
                        with open(path, "w", encoding="utf-8") as f:
                            f.write(text + "\n")
                        self.show(f"[summary saved to {path}]")
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
        threading.Thread(target=self.poll_loop, daemon=True).start()
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
