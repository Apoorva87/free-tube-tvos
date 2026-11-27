"""Read a caption track offered by the public watch page for the requested video."""
import json
import re
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from approved_captions import MAX_FILE, VIDEO, parse_vtt


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def fetch(url, limit):
    request = Request(url, headers={"User-Agent": "FreeTube/0.2", "Accept-Language": "en"})
    with build_opener(NoRedirect()).open(request, timeout=8) as response:
        payload = response.read(limit + 1)
        if len(payload) > limit:
            raise ValueError("The caption source was too large.")
        return payload


def public_track(video_id, read=fetch):
    if not VIDEO.fullmatch(video_id):
        raise ValueError("Invalid video ID.")
    try:
        page = read("https://www.youtube.com/watch?v=" + video_id, 4_000_000).decode("utf-8")
        player = re.search(r'\bytInitialPlayerResponse\s*=\s*(?=\{)', page)
        if not player:
            return []
        data = json.JSONDecoder().raw_decode(page[player.end():])[0]
        if (data.get("playabilityStatus", {}).get("status") != "OK" or
                data.get("videoDetails", {}).get("videoId") != video_id):
            return []
        tracks = data.get("captions", {}).get("playerCaptionsTracklistRenderer", {}).get("captionTracks", [])
        # Prefer an English human track, then English auto-captions, then the first offered track.
        tracks = sorted((t for t in tracks if isinstance(t, dict)),
                        key=lambda t: (t.get("languageCode", "").split("-")[0] != "en", t.get("kind") == "asr"))
        for track in tracks:
            url = track.get("baseUrl", "")
            parts = urlsplit(url)
            if (parts.scheme != "https" or parts.netloc not in ("www.youtube.com", "youtube.com") or
                    parts.path != "/api/timedtext" or parse_qs(parts.query).get("v") != [video_id] or parts.fragment):
                continue
            content = read(url + "&fmt=vtt", MAX_FILE)
            return parse_vtt(content) if content.strip() else []
    except (HTTPError, URLError, TimeoutError, ValueError, TypeError, AttributeError):
        return []
    return []
