"""The public LAN API accepts these fields only. Byte limits are on UTF-8 text."""
import json
import math
import re

from container.runner import public_source

VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}")
MAX_BODY = 192 * 1024
PLAYLIST_ID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
KINDS = ("assist", "research", "query", "playlist", "summary", "jump", "followup", "conversation")


class Problem(Exception):
    def __init__(self, status, code, detail):
        self.status, self.code, self.detail = status, code, detail
        super().__init__(detail)


def require(condition, detail):
    if not condition:
        raise Problem(422, "invalid_request", detail)


def fields(value, required, optional=()):
    require(type(value) is dict and set(required) <= value.keys() <= set(required) | set(optional),
            "Missing or unexpected JSON fields.")


def string(value, limit, allow_empty=False):
    require(isinstance(value, str) and (allow_empty or bool(value.strip())) and
            len(value.encode("utf-8")) <= limit and
            all(c in "\n\t\r" or ord(c) >= 32 for c in value), "Invalid or oversized text.")


def video_id(value):
    require(isinstance(value, str) and VIDEO_ID.fullmatch(value), "Invalid video ID.")


def valid_request(data):
    kind = data.get("kind") if type(data) is dict else None
    if kind in ("assist", "research"):
        allowed = ("candidates", "cues", "playlists") if kind == "assist" else ("candidates", "cues")
        fields(data, ("kind", "prompt"), allowed)
        string(data["prompt"], 2000)
        require(data.get("candidates", []) == [] and data.get("cues", []) == [],
                "This request accepts only the question and its permitted context.")
        lists = data.get("playlists", [])
        require(type(lists) is list and len(lists) <= 40, "Supply at most 40 playlists.")
        ids = set()
        for item in lists:
            fields(item, ("id", "title"))
            identifier = item["id"]
            require(type(identifier) is str and PLAYLIST_ID.fullmatch(identifier) and identifier.lower() not in ids,
                    "Supply unique playlist UUIDs.")
            ids.add(identifier.lower())
            string(item["title"], 256)
        return {"candidates": [], "cues": [], **data}
    required = ("kind", "prompt", "candidates", "cues")
    if kind == "conversation":
        fields(data, (*required, "videoID", "turns"))
    else:
        fields(data, required, ("videoID",))
    require(kind in KINDS, "Unknown request kind.")
    string(data["prompt"], 2000)
    if "videoID" in data:
        video_id(data["videoID"])
    candidates, cues = data["candidates"], data["cues"]
    require(type(candidates) is list and len(candidates) <= 50, "Supply at most 50 videos.")
    require(type(cues) is list and len(cues) <= 256, "Supply at most 256 caption cues.")
    ids = set()
    for item in candidates:
        fields(item, ("id", "title", "channel"), ("durationSeconds",))
        video_id(item["id"])
        string(item["title"], 512)
        string(item["channel"], 256, True)
        if "durationSeconds" in item:
            require(type(item["durationSeconds"]) is int and 0 <= item["durationSeconds"] <= 31536000,
                    "Invalid duration.")
        require(item["id"] not in ids, "Duplicate video ID.")
        ids.add(item["id"])
    indexes = set()
    size = 0
    for cue in cues:
        fields(cue, ("index", "start", "end", "text"))
        idx = cue["index"]
        require(type(idx) is int and 0 <= idx < 2147483648 and idx not in indexes, "Invalid cue index.")
        indexes.add(idx)
        require(all(type(t) in (int, float) and 0 <= t <= 31536000 and math.isfinite(t)
                    for t in (cue["start"], cue["end"])) and cue["start"] < cue["end"], "Invalid cue time.")
        string(cue["text"], 2000)
        size += len(cue["text"].encode())
    require(size <= 60000, "Supply at most 60,000 bytes of caption text.")
    if kind in ("query", "playlist"):
        require(not cues and "videoID" not in data, "Playlist searches accept video metadata only.")
        require((not candidates) if kind == "query" else bool(candidates), "Invalid search candidates.")
    elif kind == "followup":
        require("videoID" in data and bool(candidates), "Follow-up discovery requires a current video and candidates.")
    elif kind == "conversation":
        require(not candidates and cues, "Video conversations require approved captions for the current video.")
        turns = data["turns"]
        require(type(turns) is list and len(turns) <= 3, "Supply at most three previous exchanges.")
        for turn in turns:
            fields(turn, ("question", "answer", "cueIndices"))
            string(turn["question"], 2000)
            string(turn["answer"], 1600)
            cited = turn["cueIndices"]
            require(type(cited) is list and 1 <= len(cited) <= 3 and
                    all(type(i) is int and i in indexes for i in cited) and len(set(cited)) == len(cited),
                    "Each exchange needs one to three distinct citations from the supplied cues.")
    else:
        require("videoID" in data and bool(cues), "This action requires the video's timed captions.")
        require(ids <= {data["videoID"]}, "Only the current video's metadata is allowed.")
    return data


def check_queries(queries):
    require(type(queries) is list and 1 <= len(queries) <= 3, "Supply one to three search terms.")
    seen = set()
    for term in queries:
        string(term, 180)
        require(all(c.isprintable() for c in term) and term.strip().casefold() not in seen, "Invalid search term.")
        seen.add(term.strip().casefold())


def check_assist(data, answer):
    fields(answer, ("action",), ("message", "queries", "title", "targetID", "research"))
    action = answer["action"]
    require(action in ("answer", "find", "create", "append"), "Unknown assistant action.")
    if "message" in answer:
        string(answer["message"], 2000)
    if action == "answer":
        require("message" in answer, "A direct answer needs text.")
    if "queries" in answer:
        check_queries(answer["queries"])
    if "research" in answer:
        require(type(answer["research"]) is bool, "Invalid research flag.")
    if action != "answer" or answer.get("research"):
        require("queries" in answer, "Supply search terms.")
    if "title" in answer:
        require(action == "create", "Only proposed playlists have new titles.")
        string(answer["title"], 180)
    if "targetID" in answer:
        require(action == "append" and type(answer["targetID"]) is str, "Invalid append target.")
        ids = {row["id"].lower(): row["id"] for row in data.get("playlists", [])}
        require(answer["targetID"].lower() in ids, "Select an existing playlist.")
        answer["targetID"] = ids[answer["targetID"].lower()]


def valid_answer(data, answer):
    kind = data["kind"]
    try:
        if kind == "assist":
            check_assist(data, answer)
        elif kind == "research":
            fields(answer, ("message", "queries"), ("sources",))
            string(answer["message"], 2000)
            check_queries(answer["queries"])
            require(not re.search(r"(?:https?://|www\.)", " ".join([answer["message"], *answer["queries"]]), re.I),
                    "Source URLs belong in the checked source list.")
            sources = answer.get("sources", [])
            require(type(sources) is list and len(sources) <= 6 and all(public_source(url) for url in sources)
                    and len(set(sources)) == len(sources), "Invalid source URLs.")
        elif kind == "query":
            fields(answer, ("query",))
            string(answer["query"], 180)
            require("\n" not in answer["query"], "Use one search phrase.")
        elif kind in ("playlist", "followup"):
            fields(answer, ("videoIDs",), ("title",))
            if "title" in answer:
                string(answer["title"], 180)
            ids = answer["videoIDs"]
            available = {v["id"] for v in data["candidates"]} - {data.get("videoID")}
            require(type(ids) is list and len(ids) <= len(available), "Invalid selection.")
            require(all(type(i) is str and i in available for i in ids) and len(set(ids)) == len(ids),
                    "An unknown or repeated video was suggested.")
        elif kind == "jump":
            # An empty object explicitly means the captions do not support a jump.
            fields(answer, (), ("cueIndex",))
            if "cueIndex" in answer:
                check_cue(data, answer["cueIndex"])
        else:
            fields(answer, ("points",))
            max_points, max_point_bytes = (3, 500) if kind == "conversation" else (12, 1500)
            require(type(answer["points"]) is list and len(answer["points"]) <= max_points, "Invalid points.")
            for point in answer["points"]:
                fields(point, ("text", "cueIndex"))
                string(point["text"], max_point_bytes)
                check_cue(data, point["cueIndex"])
    except (Problem, UnicodeError):
        raise Problem(502, "invalid_answer", "The assistant returned an answer outside the supplied evidence.")
    return answer


def check_cue(data, index):
    require(type(index) is int and any(c["index"] == index for c in data["cues"]), "Unknown cue.")


def decode(raw):
    def object_from_pairs(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError("duplicate JSON key")
        return result

    def reject_constant(_):
        raise ValueError("non-finite JSON number")

    return json.loads(raw.decode("utf-8"), object_pairs_hook=object_from_pairs, parse_constant=reject_constant)
