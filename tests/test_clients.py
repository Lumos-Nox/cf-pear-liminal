"""Local state tests plus optional real HTTP checks against the Postman fixture."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MODULES = []
for name in ("bridge", "human"):
    spec = importlib.util.spec_from_file_location(name, ROOT / "clients" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    MODULES.append(module)
SIMULATION = os.environ.get("SIMULATION_URL", "").rstrip("/")
MID = "m-" + "a" * 32
PEER = "m-" + "b" * 32


def control(path, body=None):
    request = urllib.request.Request(SIMULATION + "/messaging/simulation/" + path,
        data=None if body is None else json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


class StateTests(unittest.TestCase):
    def test_atomic_private_state_and_wrong_base_rejection(self):
        for module in MODULES:
            with self.subTest(client=module.__name__), tempfile.TemporaryDirectory() as directory:
                path = str(Path(directory) / "nested" / "state.json")
                mailbox = module.Mailbox(path)
                mailbox.state["token"] = "synthetic"
                mailbox.save()
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
                self.assertEqual(module.Mailbox(path).state["token"], "synthetic")
                mailbox.state["base"] = "https://different.example"
                mailbox.save()
                with self.assertRaises(SystemExit):
                    module.Mailbox(path)

    def test_conflicting_pending_payload_is_refused_before_network(self):
        for module in MODULES:
            with self.subTest(client=module.__name__), tempfile.TemporaryDirectory() as directory:
                mailbox = module.Mailbox(str(Path(directory) / "state.json"))
                mailbox.state["pending_send"] = {"to": PEER, "payload": {"text": "first"}, "key": "key"}
                with self.assertRaises(ValueError):
                    mailbox.send(PEER, {"text": "edited"}, "key")

    def test_bridge_ignores_unhashable_payload_types(self):
        bridge = MODULES[0].Bridge.__new__(MODULES[0].Bridge)
        bridge.peer, bridge.me, bridge.s = PEER, "test", {}
        self.assertIsNone(bridge.accept({"id": "bad", "from": PEER, "payload": {"type": [], "text": "bad"}}))


@unittest.skipUnless(SIMULATION, "SIMULATION_URL is not set")
class HttpTests(unittest.TestCase):
    def setUp(self):
        control("reset", {})
        self.directory = tempfile.TemporaryDirectory()
        for module in MODULES:
            module.BASE = SIMULATION + "/messaging"

    def tearDown(self):
        self.directory.cleanup()

    def mailbox(self, module):
        mailbox = module.Mailbox(str(Path(self.directory.name) / (module.__name__ + ".json")))
        mailbox.state.update(mid=MID, token=MID + ".valid")
        mailbox.save()
        return mailbox

    def test_polled_messages_survive_restart_until_acknowledged(self):
        for module in MODULES:
            with self.subTest(client=module.__name__):
                control("reset", {})
                message = {"id": "in-1", "from": PEER, "ts": 1, "payload": {"type": "msg", "thread": "thread", "text": "Keep me"}}
                control("inbox", {"to": MID, "messages": [message]})
                mailbox = self.mailbox(module)
                self.assertEqual(mailbox.poll(), [message])
                restarted = module.Mailbox(mailbox.path)
                self.assertEqual(restarted.state["cursor"], "1")
                self.assertEqual(restarted.poll(), [message])
                restarted.ack("in-1")
                self.assertEqual(module.Mailbox(mailbox.path).poll(), [])

    def test_accepted_send_keeps_exact_request_after_all_responses_fail(self):
        for module in MODULES:
            with self.subTest(client=module.__name__):
                control("reset", {})
                control("config", {"failSendResponses": True, "sendDelay": 0})
                mailbox = self.mailbox(module)
                payload = {"thread": "thread", "seq": 0, "type": "msg", "text": "Original"}
                with patch.object(module.time, "sleep", lambda _seconds: None):
                    if module.__name__ == "bridge":
                        with self.assertRaises(SystemExit):
                            mailbox.send(PEER, payload, "stable-key", attempts=1)
                    else:
                        self.assertFalse(mailbox.send(PEER, payload, "stable-key"))
                restarted = module.Mailbox(mailbox.path)
                self.assertEqual(restarted.state["pending_send"]["payload"], payload)
                control("config", {"failSendResponses": False})
                result = restarted.send(PEER, payload, "stable-key")
                self.assertTrue(result)
                state = control("state")
                sends = [request for request in state["requests"] if request["path"] == "/v1/agent/send"]
                self.assertEqual(state["accepted"], 1)
                self.assertTrue(all(request["body"]["payload"] == payload for request in sends))
                self.assertTrue(all(request["key"] == "stable-key" for request in sends))

    def test_credentials_are_not_forwarded_on_redirect(self):
        control("config", {"redirectSelf": True})
        for module in MODULES:
            mailbox = self.mailbox(module)
            self.assertEqual(mailbox.req("GET", "/v1/agent/self")[0], 302)
        self.assertFalse(any(request["path"] == "/simulation/redirect-target" for request in control("state")["requests"]))

    def test_bridge_replays_pending_reply_without_regenerating_it(self):
        module = MODULES[0]
        path = str(Path(self.directory.name) / "resume.json")
        mailbox = module.Mailbox(path)
        payload = {"thread": "thread", "seq": 0, "type": "msg", "text": "Saved agent reply"}
        mailbox.state.update(mid=MID, token=MID + ".valid", peer=PEER, thread="thread", history=[], sent=0,
            pending_send={"to": PEER, "payload": payload, "key": "reply-1"})
        mailbox.save()
        control("inbox", {"to": MID, "messages": [{"id": "done-1", "from": PEER, "ts": 1, "payload": {"thread": "thread", "type": "done", "text": "Done"}}]})
        args = SimpleNamespace(label="agent", state=path, peer_mid=PEER, peer_label=None, peer_wait=1, out=self.directory.name,
            context=[], start=None, duration_min=60, max_turns=40, stall=4, interval=0, final_wait=1, history=16, chat=False)
        bridge = module.Bridge(args)
        try:
            with patch.object(bridge, "generate", side_effect=AssertionError("must not regenerate the saved reply")):
                bridge.run()
            self.assertTrue(bridge.s["finished"])
            self.assertNotIn("pending_send", bridge.s)
            self.assertEqual(bridge.s["sent"], 1)
            self.assertEqual(bridge.s["history"][0]["text"], "Saved agent reply")
        finally:
            shutil.rmtree(bridge.sandbox, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
