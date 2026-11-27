import contextlib
import fcntl
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import ssl
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from container import runner as codex
from contracts import Problem, valid_answer, valid_request
from helper import DockerRunner, Handler, Pairing, Service, identity

VIDEO = "00000000001"
NEXT = "00000000002"
CUE = {"index": 14, "start": 1.0, "end": 2.0, "text": "First, tune the guitar."}
META = {"id": NEXT, "title": "Guitar tuning", "channel": "Lessons"}
SUMMARY = {"kind": "summary", "videoID": VIDEO, "prompt": "Summarize", "candidates": [], "cues": [CUE]}


class FakeRunner:
    def run(self, action, data=None):
        if action == "status":
            return {"state": "ready", "detail": "Fixture is ready"}
        return {"points": [{"text": "Tune the guitar.", "cueIndex": 14}]}


class TransportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        cls.context, cls.pin = identity(cls.directory)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.pairing = Pairing(self.directory, self.pin)
        self.service = Service(self.directory, self.pairing, FakeRunner())

    def exchange(self, method, route, payload=None, token=None, wrong_pin=False):
        # A connected socket pair runs the exact TLS handshake and HTTP handler
        # without advertising a test service or requiring LAN/listen permission.
        left, right = socket.socketpair()
        def serve():
            try:
                with self.context.wrap_socket(left, server_side=True) as tls:
                    Handler(tls, ("127.0.0.1", 0), SimpleNamespace(service=self.service))
            except (BrokenPipeError, ConnectionResetError):
                pass
        thread = threading.Thread(target=serve)
        thread.start()
        client = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        client.check_hostname = False
        client.verify_mode = ssl.CERT_NONE  # Verify exact DER pin before sending even the one-time code.
        try:
            with client.wrap_socket(right) as tls:
                fingerprint = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
                if fingerprint != ("f" * 64 if wrong_pin else self.pin):
                    raise ValueError("pin mismatch")
                connection = http.client.HTTPSConnection("fixture.local")
                connection.sock = tls
                headers = {"Content-Type": "application/json"}
                if token:
                    headers["Authorization"] = "Bearer " + token
                connection.request(method, route, json.dumps(payload) if payload is not None else None, headers)
                response = connection.getresponse()
                return response.status, json.loads(response.read())
        finally:
            thread.join(3)
            self.assertFalse(thread.is_alive())

    def test_tls_pair_auth_model_and_captions(self):
        with self.assertRaisesRegex(ValueError, "pin mismatch"):
            self.exchange("POST", "/v1/pair", {"code": self.pairing.code}, wrong_pin=True)
        self.assertEqual(self.exchange("GET", "/v1/status")[0], 401)
        code = self.pairing.code
        status, reply = self.exchange("POST", "/v1/pair", {"code": code})
        self.assertEqual(status, 200)
        token = reply["token"]
        self.assertNotIn(token.encode(), self.pairing.path.read_bytes())
        self.assertEqual(self.exchange("POST", "/v1/pair", {"code": code})[0], 403)
        self.assertEqual(self.exchange("GET", "/v1/status", token=token)[1]["state"], "ready")
        self.assertEqual(self.exchange("POST", "/v1/ask", SUMMARY, token)[0], 422)
        with patch("helper.load_captions", return_value=[CUE]):
            status, body = self.exchange("POST", "/v1/ask", SUMMARY, token)
            forged = dict(SUMMARY, cues=[dict(CUE, text="Different caption.")])
            self.assertEqual(self.exchange("POST", "/v1/ask", forged, token)[0], 422)
            shifted = dict(SUMMARY, cues=[dict(CUE, start=1.5)])
            self.assertEqual(self.exchange("POST", "/v1/ask", shifted, token)[0], 422)
        self.assertEqual((status, body["points"][0]["cueIndex"]), (200, 14))
        self.assertEqual(self.exchange("POST", "/v1/ask", dict(SUMMARY, apiKey="x"), token)[0], 422)
        self.assertEqual(self.exchange("GET", "/v1/captions/" + VIDEO, token=token), (200, {"videoID": VIDEO, "cues": []}))
        self.assertEqual(self.exchange("GET", "/v1/captions/" + VIDEO)[0], 401)
        self.assertTrue(Pairing(self.directory, self.pin).authenticated("Bearer " + token))
        self.assertEqual(identity(self.directory)[1], self.pin)

    def test_expiry_lockout_rotation(self):
        now = [10]
        pairing = Pairing(self.directory, self.pin, lambda: now[0])
        now[0] += 301
        with self.assertRaises(Problem) as error:
            pairing.pair(pairing.code)
        self.assertEqual(error.exception.status, 403)
        for _ in range(5):
            with self.assertRaises(Problem):
                self.pairing.pair("garbage")
        with self.assertRaises(Problem) as error:
            self.pairing.pair(self.pairing.code)
        self.assertEqual(error.exception.status, 429)
        old = Pairing(self.directory, self.pin)
        old_token = old.pair(old.code)["token"]
        new = Pairing(self.directory, self.pin)
        new_token = new.pair(self.pin + "." + new.code)["token"]
        self.assertFalse(new.authenticated("Bearer " + old_token))
        self.assertTrue(new.authenticated("Bearer " + new_token))


class ContractTest(unittest.TestCase):
    def test_evidence_and_limits(self):
        query = {"kind": "query", "prompt": "Build a lesson list", "candidates": [], "cues": []}
        playlist = dict(query, kind="playlist", candidates=[META])
        followup = dict(playlist, kind="followup", videoID=VIDEO)
        jump = dict(SUMMARY, kind="jump")
        for request, answer in [(query, {"query": "guitar"}) , (playlist, {"videoIDs": [NEXT]}),
                                (followup, {"videoIDs": [NEXT]}), (jump, {"cueIndex": 14}), (jump, {})]:
            self.assertEqual(valid_answer(valid_request(request), answer), answer)
        for request, answer in [(followup, {"videoIDs": [VIDEO]}), (playlist, {"videoIDs": [NEXT, NEXT]}),
                                (jump, {"cueIndex": 99}), (SUMMARY, {"points": [{"text": "x", "cueIndex": True}]})]:
            with self.assertRaises(Problem):
                valid_answer(request, answer)
        for invalid in [dict(query, prompt="x" * 2001), dict(query, cues=[CUE]), dict(SUMMARY, cues=[CUE] * 2),
                        dict(playlist, candidates=[dict(META, durationSeconds=True)]), dict(SUMMARY, cues=[])]:
            with self.assertRaises(Problem):
                valid_request(invalid)

    def test_container_bounds_and_fixed_image(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = DockerRunner(Path(temp), "1" * 64)
            args = runner.command("ask", "fixture")
            self.assertIn("--pull=never", args)
            self.assertIn("--read-only", args)
            self.assertIn("--cap-drop=ALL", args)
            self.assertTrue(any(s.startswith("type=volume,source=freetube-codex-") for s in args))
            self.assertFalse(any("bind" in s or "type=bind" in s for s in args))
            self.assertEqual(args[-2:], ["freetube-codex:0.172.0", "ask"])


class SubscriptionTest(unittest.TestCase):
    def test_in_progress_login_returns_signed_out_without_waiting(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with (directory / "login.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                lock.write("login")
                lock.flush()
                for action in ("status", "ask"):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        self.assertEqual(codex.with_login(action, directory), 0)
                    response = json.loads(output.getvalue())
                    self.assertEqual(response["state"], "signed_out")
                    self.assertIn("Finish", response["detail"])

    def test_account_and_usage_gates(self):
        session = codex.Session(None)
        for method in (None, {"type": "apiKey"}, {"type": "amazonBedrock"}):
            with patch.object(session, "call", return_value={"account": method}):
                self.assertEqual(session.status()["state"], "signed_out")
        for allowed in (False, None):
            with patch.object(session, "call", side_effect=[{"account": {"type": "chatgpt", "planType": "pro"}},
                                                           {"ordinaryUsageAllowed": allowed}]):
                with self.assertRaises(codex.Unavailable):
                    session.status()
        with patch.object(session, "call", side_effect=[{"account": {"type": "chatgpt", "planType": "plus"}},
                                                       {"ordinaryUsageAllowed": True}]):
            self.assertEqual(session.status()["state"], "ready")

    def test_real_wire_shapes_with_fake_cli(self):
        events = [
            {"id": 1, "result": {"thread": {"id": "t"}, "model": codex.MODEL, "modelProvider": "openai",
                                 "approvalPolicy": "never", "runtimeWorkspaceRoots": [],
                                 "sandbox": {"type": "readOnly", "networkAccess": False}}},
            {"id": 2, "result": {"turn": {"id": "u"}}},
            {"method": "item/completed", "params": {"threadId": "t", "item": {
                "type": "agentMessage", "phase": "final_answer", "text": '{"query":"guitar"}'}}},
            {"method": "turn/completed", "params": {"threadId": "t", "turn": {"status": "completed"}}}
        ]
        data = {"kind": "query", "prompt": "guitar", "candidates": [], "cues": []}
        pipe = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(b"".join(json.dumps(e).encode() + b"\n" for e in events)))
        self.assertEqual(codex.Session(pipe).ask(data), {"query": "guitar"})
        thread, turn = [json.loads(v)["params"] for v in pipe.stdin.getvalue().splitlines()]
        self.assertEqual(thread["environments"], [])
        self.assertEqual(turn["environments"], [])
        self.assertFalse(thread["allowProviderModelFallback"])
        self.assertEqual(json.loads(turn["input"][0]["text"]), data)


class InstalledCLITest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("codex"), "optional pinned native Codex is not installed")
    def test_clean_signed_out_and_restricted_thread(self):
        # No provider turn is started. The only accessible CLI credentials location is empty.
        with tempfile.TemporaryDirectory() as temp:
            env = {"HOME": temp, "CODEX_HOME": temp, "PATH": os.defpath + os.pathsep + str(Path(shutil.which("codex")).parent)}
            version = subprocess.check_output(["codex", "--version"], env=env, timeout=5)
            if version.strip() != b"codex-cli 0.172.0":
                self.skipTest("a different native CLI version is installed")
            catalog = str(Path(temp) / "models.json")
            codex.build_catalog(catalog, env)
            for research in (False, True):
                args = ["codex", "app-server", "--strict-config", *codex.policy_options(catalog, research=research)]
                subprocess.run(args + ["--print-startup-config"], stdout=subprocess.DEVNULL, env=env, check=True, timeout=5)
                with subprocess.Popen(args + ["--stdio"], cwd=temp, env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
                    timer = threading.Timer(8, proc.kill)
                    timer.start()
                    try:
                        session = codex.Session(proc)
                        session.start()
                        self.assertEqual(session.status()["state"], "signed_out")
                        if research:
                            session.check_search()
                        self.assertTrue(session.new_thread(temp, research=research))
                    finally:
                        timer.cancel()
                        proc.kill()


class FreeTextTest(unittest.TestCase):
    uid = "E833495E-2695-4D6C-90BF-186D82EE0CE8"

    def test_assist_proposals_and_public_input(self):
        private = [{"id": self.uid, "title": "Private watchlist"}]
        ask = valid_request({"kind": "assist", "prompt": "Add folding tutorials to my watchlist", "playlists": private})
        self.assertEqual(ask["cues"], [])
        answer = valid_answer(ask, {"action": "append", "targetID": self.uid.lower(), "queries": ["paper folding"]})
        self.assertEqual(answer["targetID"], self.uid)
        valid_answer(ask, {"action": "create", "title": "Folding", "queries": ["origami cranes"]})
        valid_answer(ask, {"action": "answer", "message": "What difficulty level?"})
        for bad in [
            {"action": "append", "targetID": "unknown", "queries": ["folding"]},
            {"action": "append", "targetID": self.uid}, {"action": "answer", "research": True, "message": "Checking"},
            {"action": "create", "title": "Paper", "queries": ["x", "X"]},
            {"action": "delete", "targetID": self.uid}, {"action": "find", "queries": ["q"]*4},
        ]:
            with self.assertRaises(Problem):
                valid_answer(ask, bad)
        research = {"kind": "research", "prompt": "Current space telescope missions"}
        self.assertEqual(valid_request(research)["candidates"], [])
        for key, value in [("videoID", VIDEO), ("playlists", []), ("playlists", private),
                           ("cues", [CUE]), ("candidates", [META]), ("apiKey", "x")]:
            with self.assertRaises(Problem):
                valid_request(dict(research, **{key: value}))
        for lists in [[{"id": "x", "title": "valid"}], private * 41, [dict(private[0], title="t"*257)]]:
            with self.assertRaises(Problem):
                valid_request(dict(ask, playlists=lists))

    def test_only_result_urls_can_be_cited(self):
        evidence = codex.ResearchEvidence()
        url = "https://science.nasa.gov/europa/"
        evidence.observe("item/completed", {"id": "w", "action": {"type": "openPage", "url": "https://made-up.com/"},
                        "results": [{"type": "text_result", "ref_id": "turn0search0", "url": url},
                                    {"type": "text_result", "url": "https://192.168.1.1/admin"},
                                    {"type": "text_result", "snippet": "https://made-up.com/"},
                                    {"type": "unrecognized", "url": "https://never.io"}]})
        answer = evidence.finish({"message": "Europa is an icy moon.", "queries": ["Europa orbit"],
                                  "sources": ["https://made-up.com/", "turn0search0", url, "https://never.io"]})
        self.assertEqual(valid_answer({"kind": "research"}, answer)["sources"], [url])
        self.assertNotIn("sources", evidence.finish({"message": "Research", "queries": ["X"], "sources": ["bad"]}))
        for value in ["http://nasa.gov", "https://name:pass@nasa.gov", "https://box.local", "https://localhost",
                      "https://127.0.0.1", "https://[::1]", "https://test.org\\@localhost", "https://nasa.gov:7100"]:
            self.assertFalse(codex.public_source(value))
        with self.assertRaises(Problem):
            valid_answer({"kind": "research"}, dict(answer, message="See https://made-up.com/"))

    def test_live_mode_gating_and_verified_tool_use(self):
        request = {"kind": "research", "prompt": "public topic", "candidates": [], "cues": []}
        def run_with(item, supports_search=True):
            thread = {"thread": {"id": "th"}, "model": codex.MODEL, "modelProvider": "openai", "approvalPolicy": "never",
                      "runtimeWorkspaceRoots": [], "sandbox": {"type": "readOnly", "networkAccess": False}}
            event = lambda item: {"method": "item/completed", "params": {"threadId": "th", "turnId": "t", "item": item}}
            events = [{"id": 1, "result": {"config": {"web_search": "live"}}},
                      {"id": 2, "result": {"webSearch": supports_search}},
                      {"id": 3, "result": thread}]
            if item:
                events.append(event(item))  # Exercise asynchronous notifications that precede the turn/start response.
            events.extend([{"id": 4, "result": {"turn": {"id": "t"}}},
                           event({"type": "agentMessage", "text": '{"message":"Found it","queries":["Europa"],"sources":["turn0search0"]}'}),
                           {"method": "turn/completed", "params": {"threadId": "th", "turn": {"id": "t", "status": "completed"}}}])
            proc = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(b"".join(json.dumps(x).encode()+b"\n" for x in events)))
            reply = codex.Session(proc).ask(request)
            sent = [json.loads(x) for x in proc.stdin.getvalue().splitlines()]
            self.assertEqual(json.loads(sent[-1]["params"]["input"][0]["text"]), {"topic": "public topic"})
            self.assertEqual(sent[-1]["params"]["environments"], [])
            return reply
        item = {"type": "webSearch", "id": "w", "results": [{"type": "text_result", "ref_id": "turn0search0",
                                                               "url": "https://science.nasa.gov/europa/"}]}
        self.assertEqual(run_with(item)["sources"], ["https://science.nasa.gov/europa/"])
        for invalid in [None, {"type": "commandExecution"}, {"type": "mcpToolCall"},
                        {"type": "webSearch", "id": "w", "results": None}]:
            with self.assertRaises(codex.Unavailable):
                run_with(invalid)
        with self.assertRaises(codex.Unavailable):
            run_with(item, supports_search=False)
        with self.assertRaises(codex.Unavailable):
            codex.Session(None).ask(dict(request, playlists=[{"id": self.uid, "title": "private"}]))
        self.assertIn('web_search="live"', codex.policy_options(research=True))
        self.assertIn('web_search="disabled"', codex.policy_options(research=False))
