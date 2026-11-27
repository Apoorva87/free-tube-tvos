#!/usr/bin/env python3
"""Sign in to the Free Tube container and verify its Bonjour advertisement on macOS."""

import argparse
import hashlib
import hmac
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys

from helper import DockerRunner, Problem, identity

STATE = Path.home() / ".freetube-helper"
HELPER = Path(__file__).with_name("helper.py").resolve()


def discover(name):
    # dns-sd stays open to report changes. Bound this snapshot to three seconds.
    try:
        result = subprocess.run(
            ["/usr/bin/dns-sd", "-L", name, "_freetube-ai._tcp", "local."],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3, check=False,
        )
        output = result.stdout
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b""
    match = re.search(rb"can be reached at ([^\s:]+\.local\.):(\d+)", output, re.I)
    if match:
        return match[1].decode(), int(match[2])
    return None


def verify_endpoint(endpoint, fingerprint):
    host, port = endpoint
    # A self-signed helper is authenticated by the same exact leaf pin as on tvOS.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection((host, port), timeout=5) as connection:
        with context.wrap_socket(connection, server_hostname=host.rstrip(".")) as tls:
            actual = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
            if not hmac.compare_digest(actual, fingerprint):
                raise ValueError("The advertised service presented a different helper certificate.")


def login():
    print("In Safari, open the OpenAI address printed below. Enter the one-time code from this Terminal window.", flush=True)
    subprocess.run([sys.executable, str(HELPER), "login", "--provider", "codex"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Check the existing login and service without starting either.")
    mode.add_argument("--login", action="store_true", help="Request a fresh Codex device sign-in.")
    args = parser.parse_args()
    os.umask(0o077)
    os.environ["PATH"] = os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin",
                                          "/Applications/Docker.app/Contents/Resources/bin"])
    has_identity = (STATE / "identity.pem").is_file()
    if not has_identity and args.check:
        raise ValueError("No helper identity exists. Run this launcher without --check to set up the helper.")
    if has_identity and STATE.stat().st_mode & 0o077:
        raise ValueError("The helper state directory must be private (mode 700).")
    if args.login or not has_identity:
        login()
    _, pin = identity(STATE)
    runner = DockerRunner(STATE, pin)
    status = runner.run("status")
    if status["state"] == "signed_out" and has_identity and not (args.check or args.login):
        login()
        status = runner.run("status")
    print(status["detail"], flush=True)
    name = "Free Tube " + pin[:8]
    endpoint = discover(name)
    child = None
    try:
        if endpoint is None and not args.check and status["state"] == "ready":
            print("Starting the helper. Keep this Terminal window open while using Ask AI.", flush=True)
            child = subprocess.Popen([sys.executable, str(HELPER), "serve", "--provider", "codex"])
            endpoint = discover(name) or discover(name)
        if endpoint is None:
            raise ValueError("Bonjour could not find this helper. Check Docker and local network access, then run the launcher again.")
        verify_endpoint(endpoint, pin)
        print(f"Bonjour found {name}. Its TLS certificate matches this Mac’s helper identity.", flush=True)
        if (STATE / "paired-tv.sha256").is_file():
            print("A TV pairing is saved. On Apple TV, open Ask AI → Helper settings → Check again.", flush=True)
        else:
            print("On Apple TV, open Ask AI → Connect or check helper and pair using the full pairing text from the helper terminal.", flush=True)
        if status["state"] != "ready":
            return 1
        if child is not None and child.poll() is None:
            return child.wait()
        return 0
    finally:
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGINT)
            child.wait()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, Problem, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
