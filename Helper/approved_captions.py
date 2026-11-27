"""User-approved, video-bound WebVTT cues. No network or model access."""
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import tempfile

VIDEO = re.compile(r"[A-Za-z0-9_-]{11}")
TIME = re.compile(r"(?:(\d{2,}):)?([0-5]\d):([0-5]\d)\.(\d{3})")
MAX_FILE = 800_000


def _destination(state_dir, video_id):
    if not isinstance(video_id, str) or not VIDEO.fullmatch(video_id):
        raise ValueError("Enter the 11-character video ID.")
    key = hashlib.sha256(video_id.encode("ascii")).hexdigest()
    return Path(state_dir) / "approved-captions" / (key + ".json")


def _seconds(stamp):
    match = TIME.fullmatch(stamp)
    if not match:
        raise ValueError("Invalid WebVTT timestamp.")
    h, m, s, ms = match.groups()
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000


def parse_vtt(data):
    if len(data) > MAX_FILE:
        raise ValueError("Caption file is too large.")
    text = data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n[ \t]*\n", text.strip())
    if not re.match(r"^WEBVTT(?:[ \t\n]|$)", blocks[0]) or "X-TIMESTAMP-MAP" in text:
        raise ValueError("Use a standalone WebVTT file timed from the start of this video.")
    cues = []
    for block in blocks[1:]:
        lines = block.splitlines()
        if not lines or lines[0] in ("STYLE", "REGION") or re.match(r"^NOTE(?:[ \t]|$)", lines[0]):
            continue
        if "-->" not in lines[0]:
            lines = lines[1:]
        if not lines or "-->" not in lines[0]:
            raise ValueError("Invalid caption block.")
        left, _, right = lines[0].partition("-->")
        start = _seconds(left.strip())
        end = _seconds(right.strip().split()[0]) if right.strip() else -1
        if not math.isfinite(end) or end <= start or end > 7 * 86400:
            raise ValueError("Invalid caption interval.")
        plain = " ".join(html.unescape(re.sub(r"<[^>]*>", "", " ".join(lines[1:]))).split())
        if not plain:
            continue
        if len(plain.encode()) > 2000:
            raise ValueError("Split caption cues longer than 2,000 bytes.")
        cues.append({"start": start, "end": end, "text": plain})
    if not 0 < len(cues) <= 2400:
        raise ValueError("Use a track containing 1 to 2,400 cues.")
    cues.sort(key=lambda cue: cue["start"])
    return [dict(index=i, **cue) for i, cue in enumerate(cues)]


def parse_track(data):
    if len(data) > MAX_FILE:
        raise ValueError("Caption file is too large.")
    text = data.decode("utf-8-sig").strip()
    if text.startswith("WEBVTT"):
        return parse_vtt(data)
    if "-->" in text:
        # SRT uses the same video-relative intervals with decimal commas.
        text = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})(?=\s|$)", r"\1.\2", text)
        return parse_vtt(("WEBVTT\n\n" + text).encode())
    # The tvOS text field can flatten a multiline paste from the iPhone keyboard.
    if "\n" not in text and re.match(r"^(?:\d{1,3}:)?\d{1,3}:[0-5]\d\s", text):
        text = re.sub(r"(?<=\s)(?=(?:\d{1,3}:)?\d{1,3}:[0-5]\d\s)", "\n", text)
    entries = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        match = re.fullmatch(r"((?:\d{1,3}:)?\d{1,3}:[0-5]\d)(?:[ \t]+(.*))?", line)
        if match:
            parts = [int(part) for part in match[1].split(":")]
            if len(parts) == 3 and parts[1] >= 60:
                raise ValueError("Invalid transcript timestamp.")
            start = 0
            for part in parts:
                start = 60 * start + part
            if start >= 604800 or (entries and start < entries[-1][0]):
                raise ValueError("Transcript timestamps must follow video order.")
            if not entries or start != entries[-1][0]:
                entries.append((start, []))
            if match[2]:
                entries[-1][1].append(match[2])
        elif entries:
            entries[-1][1].append(line)
        else:
            raise ValueError("Paste timestamped transcript lines or a WebVTT or SRT track.")
    cues = []
    for index, (start, lines) in enumerate(entries):
        line = " ".join(" ".join(lines).split())
        if not line or len(line.encode()) > 2000:
            raise ValueError("Each timestamp needs caption text of up to 2,000 bytes.")
        # Copied transcripts give start times only. Cites and jumps use start;
        # use a minimal interval for the last cue when no following boundary exists.
        end = entries[index + 1][0] if index + 1 < len(entries) else start + 0.001
        cues.append(dict(index=index, start=start, end=end, text=line))
    if not 0 < len(cues) <= 2400:
        raise ValueError("Supply 1 to 2,400 timestamped captions.")
    return cues


def import_captions(state_dir: Path, video_id: str, source: Path):
    with Path(source).open("rb") as file:
        cues = parse_track(file.read(MAX_FILE + 1))
    return save_captions(state_dir, video_id, cues)


def save_captions(state_dir, video_id, cues):
    destination = _destination(state_dir, video_id)
    encoded = json.dumps({"videoID": video_id, "cues": cues}, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) > 900_000:
        raise ValueError("Split or shorten this track before importing.")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as file:
        try:
            file.write(encoded)
            file.flush()
            os.fsync(file.fileno())
            file.close()
            os.replace(file.name, destination)
        finally:
            Path(file.name).unlink(missing_ok=True)
    return len(cues)


def load_captions(state_dir: Path, video_id: str):
    path = _destination(state_dir, video_id)
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("videoID") != video_id:
            raise ValueError("The caption record does not match the requested video.")
        return record["cues"]
    except FileNotFoundError:
        return []
