#!/usr/bin/env python3
"""Pair a TV with this laptop and run narrowly scoped, subscription-backed requests."""
import argparse
import contextlib
from collections import deque
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from approved_captions import import_captions, load_captions
from contracts import MAX_BODY, VIDEO_ID, Problem, decode, fields, require, valid_answer, valid_request

IMAGE = "freetube-codex:0.172.0"
ROOT = Path(__file__).resolve().parent


def private_write(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        try:
            f.write(value)
            f.flush()
            os.fsync(f.fileno())
            os.replace(f.name, path)
        finally:
            Path(f.name).unlink(missing_ok=True)


def identity(directory):
    path = directory / "identity.pem"
    if not path.exists():
        with tempfile.TemporaryDirectory(dir=directory) as temp:
            key, cert = Path(temp) / "key", Path(temp) / "cert"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                            "-days", "3650", "-subj", "/CN=Free Tube Helper", "-keyout", str(key),
                            "-out", str(cert)], check=True, stderr=subprocess.DEVNULL)
            private_write(path, key.read_bytes() + cert.read_bytes())
    cert = path.read_text().split("-----BEGIN CERTIFICATE-----", 1)[1]
    der = ssl.PEM_cert_to_DER_cert("-----BEGIN CERTIFICATE-----" + cert)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(path))
    return context, hashlib.sha256(der).hexdigest()


class Pairing:
    def __init__(self, directory, pin, now=time.monotonic):
        self.directory, self.pin, self.now = directory, pin, now
        self.lock = threading.Lock()
        self.code = "%08d" % secrets.randbelow(100000000)
        self.expires = now() + 300
        self.attempts = 0
        self.path = directory / "paired-tv.sha256"
        self.digest = self.path.read_text().strip() if self.path.exists() else ""

    def pair(self, value):
        if isinstance(value, str) and value.startswith(self.pin + "."):
            value = value[len(self.pin) + 1:]
        with self.lock:
            if self.attempts >= 5:
                raise Problem(429, "rate_limited", "Restart the helper for a fresh pairing code.")
            if self.code is None or self.now() >= self.expires:
                raise Problem(403, "invalid_pairing", "The code expired or was used. Restart the helper.")
            self.attempts += 1
            if not isinstance(value, str) or not re.fullmatch(r"[0-9]{8}", value) or not hmac.compare_digest(self.code, value):
                raise Problem(403, "invalid_pairing", "Check the code displayed on the laptop.")
            token = secrets.token_urlsafe(32)
            digest = hashlib.sha256(token.encode()).hexdigest()
            private_write(self.path, (digest + "\n").encode())
            self.digest, self.code = digest, None
            return {"token": token}

    def authenticated(self, header):
        if not header or not re.fullmatch(r"Bearer [A-Za-z0-9_-]{43}", header):
            return False
        digest = hashlib.sha256(header[7:].encode()).hexdigest()
        with self.lock:
            return hmac.compare_digest(self.digest, digest)


class DockerRunner:
    def __init__(self, directory, pin):
        self.volume = "freetube-codex-" + pin[:16]
        # Empty Docker client config prevents automatic proxy or credential injection.
        config = directory / "docker-cli"
        config.mkdir(mode=0o700, exist_ok=True)
        candidates = [Path.home() / ".docker/run/docker.sock", Path("/var/run/docker.sock")]
        if os.environ.get("XDG_RUNTIME_DIR"):
            candidates.append(Path(os.environ["XDG_RUNTIME_DIR"]) / "docker.sock")
        endpoint = next((s for s in candidates if s.is_socket()), candidates[0])
        self.docker = [shutil.which("docker") or "docker", "--host", "unix://" + str(endpoint),
                       "--config", str(config)]

    def command(self, action, name):
        return self.docker + ["run", "--rm", "--pull=never", "--name", name,
                              "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
                              "--pids-limit=160", "--cpus=1", "--memory=768m", "--memory-swap=768m",
                              "--user", "10001:10001", "--workdir", "/work",
                              "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777",
                              "--mount", "type=volume,source=" + self.volume + ",target=/session",
                              "-i", IMAGE, action]

    def run(self, action, data=None):
        name = "freetube-" + secrets.token_hex(12)
        timeout = 120 if action == "ask" and data and data.get("kind") == "research" else 90
        try:
            # The runner emits only its small response envelope. The CLI stream is capped inside the container.
            result = subprocess.run(self.command(action, name),
                                    input=json.dumps(data).encode() if data is not None else b"",
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=timeout if action == "ask" else 13)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(OSError, subprocess.TimeoutExpired):
                subprocess.run(self.docker + ["rm", "-f", name], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=4)
            raise Problem(504, "timeout", "Codex timed out. Retry when the laptop is ready.")
        except OSError:
            raise Problem(503, "unavailable", "Install Docker and build the helper image on the laptop.")
        if result.returncode or len(result.stdout) > 65536:
            raise Problem(503, "unavailable", "Start Docker and check that the pinned helper image is built.")
        try:
            response = decode(result.stdout)
            if action == "ask" and "answer" in response:
                return response["answer"]
            if response.get("state") not in ("ready", "unavailable", "signed_out") or not isinstance(response.get("detail"), str):
                raise ValueError
            if action == "ask":
                raise Problem(503, response["state"], response["detail"])
            return response
        except (ValueError, TypeError, AttributeError):
            raise Problem(503, "unavailable", "Check the dedicated Codex installation on the laptop.")

    def login(self):
        return subprocess.call(self.command("login", "freetube-login-" + secrets.token_hex(8)))


class Service:
    def __init__(self, directory, pairing, runner):
        self.directory, self.pairing, self.runner = directory, pairing, runner
        self.lock = threading.Lock()
        self.last_status = None
        self.last_check = 0
        self.requests = deque()

    def status(self):
        if self.last_status and time.monotonic() - self.last_check < 5:
            return self.last_status
        if not self.lock.acquire(blocking=False):
            return self.last_status or {"state": "unavailable", "detail": "The helper is working on another request."}
        try:
            try:
                self.last_status = self.runner.run("status")
            except Problem as exc:
                self.last_status = {"state": "unavailable", "detail": exc.detail}
            self.last_check = time.monotonic()
            return self.last_status
        finally:
            self.lock.release()

    def ask(self, data):
        data = valid_request(data)
        if data["cues"]:
            approved = {cue["index"]: cue for cue in load_captions(self.directory, data["videoID"])}
            require(all(approved.get(cue["index"]) == cue for cue in data["cues"]),
                    "These excerpts do not match the current approved caption track. Check captions again.")
        if not self.lock.acquire(blocking=False):
            raise Problem(429, "busy", "The helper is finishing another request. Try again shortly.")
        try:
            now = time.monotonic()
            while self.requests and self.requests[0] <= now - 600:
                self.requests.popleft()
            if len(self.requests) >= 30:
                raise Problem(429, "rate_limited", "The helper allows 30 requests every ten minutes.")
            self.requests.append(now)
            return valid_answer(data, self.runner.run("ask", data))
        finally:
            self.last_check = 0
            self.lock.release()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log request content, authorization headers, or video IDs.

    def body(self):
        if self.headers.get_content_type() != "application/json":
            raise Problem(415, "invalid_request", "Send JSON with Content-Type application/json.")
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,10}", lengths[0]):
            raise Problem(400, "invalid_request", "Supply one valid Content-Length.")
        size = int(lengths[0])
        if size > MAX_BODY:
            raise Problem(413, "too_large", "The request exceeds 192 KiB.")
        return decode(self.rfile.read(size))

    def dispatch(self):
        service = self.server.service
        if self.command == "POST" and self.path == "/v1/pair":
            obj = self.body()
            fields(obj, ("code",))
            return service.pairing.pair(obj["code"])
        if not service.pairing.authenticated(self.headers.get("Authorization")):
            raise Problem(401, "unauthorized", "Pair this TV with the helper.")
        if self.command == "GET" and self.path == "/v1/status":
            return service.status()
        if self.command == "POST" and self.path == "/v1/ask":
            return service.ask(self.body())
        prefix = "/v1/captions/"
        if self.command == "GET" and self.path.startswith(prefix):
            video = self.path[len(prefix):]
            require(VIDEO_ID.fullmatch(video), "Invalid video ID.")
            return {"videoID": video, "cues": load_captions(service.directory, video)}
        raise Problem(404, "not_found", "Unknown helper endpoint.")

    def request_json(self):
        try:
            result, status = self.dispatch(), 200
        except Problem as e:
            result, status = {"error": e.code, "detail": e.detail}, e.status
        except (ValueError, RecursionError, UnicodeError):
            result, status = {"error": "invalid_request", "detail": "Invalid JSON or text encoding."}, 400
        except OSError:
            result, status = {"error": "unavailable", "detail": "Check the helper's private storage."}, 503
        payload = json.dumps(result, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = request_json


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, context, service):
        self.context, self.service = context, service
        self.slots = threading.BoundedSemaphore(16)
        self.address_family = socket.AF_INET6 if ":" in address[0] else socket.AF_INET
        super().__init__(address, Handler)

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def process_request(self, request, client_address):
        if self.slots.acquire(blocking=False):
            super().process_request(request, client_address)
        else:
            request.close()

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(8)
            with self.context.wrap_socket(request, server_side=True) as tls:
                self.finish_request(tls, client_address)
        except (OSError, ssl.SSLError):
            pass
        finally:
            request.close()
            self.slots.release()


def advertise(name, port):
    dns, avahi = shutil.which("dns-sd"), shutil.which("avahi-publish-service") or shutil.which("avahi-publish")
    if dns:
        cmd = [dns, "-R", name, "_freetube-ai._tcp", "local.", str(port), "v=1"]
    elif avahi:
        cmd = [avahi] + (["-s"] if Path(avahi).name == "avahi-publish" else []) + [name, "_freetube-ai._tcp", str(port), "v=1"]
    else:
        raise RuntimeError("Install Bonjour dns-sd or Linux avahi-utils for discovery.")
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".freetube-helper")
    cmds = parser.add_subparsers(dest="command", required=True)
    for name in ("serve", "login"):
        sub = cmds.add_parser(name)
        sub.add_argument("--provider", required=True, choices=["codex"])
        if name == "serve":
            sub.add_argument("--bind", default="::" if socket.has_dualstack_ipv6() else "0.0.0.0")
            sub.add_argument("--port", type=int, default=8714)
    imp = cmds.add_parser("import-captions")
    imp.add_argument("video_id")
    imp.add_argument("file", type=Path)
    imp.add_argument("--permitted", required=True, action="store_true", help="Confirm you may use these captions.")
    args = parser.parse_args()
    os.umask(0o077)
    directory = args.state_dir.expanduser().resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.stat().st_mode & 0o077:
        parser.exit(1, "The dedicated state directory must be private (mode 700).\n")
    if args.command == "import-captions":
        import_captions(directory, args.video_id, args.file)
        print("Caption track imported.")
        return 0
    with (directory / "identity.lock").open("a") as identity_lock:
        fcntl.flock(identity_lock, fcntl.LOCK_EX)
        context, pin = identity(directory)
    runner = DockerRunner(directory, pin)
    if args.command == "login":
        return runner.login()
    with (directory / "server.lock").open("a") as server_lock:
        try:
            fcntl.flock(server_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, "This helper is already running.\n")
        service = Service(directory, Pairing(directory, pin), runner)
        name = "Free Tube " + pin[:8]
        ipaddress.ip_address(args.bind)
        with Server((args.bind, args.port), context, service) as server:
            port = server.server_address[1]
            publisher = advertise(name, port)
            try:
                print(f"{name} • port {port}\nPairing code (valid 5 minutes)\n{pin}.{service.pairing.code}", flush=True)
                server.timeout = 1
                while publisher.poll() is None:
                    server.handle_request()
                raise RuntimeError("Bonjour registration stopped. Check the discovery service, then restart.")
            except KeyboardInterrupt:
                return 0
            finally:
                publisher.terminate()
                publisher.wait()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
