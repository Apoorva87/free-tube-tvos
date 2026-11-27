from pathlib import Path
import json
import tempfile
import unittest

from approved_captions import import_captions, load_captions, parse_track, parse_vtt
from public_captions import public_track


class ApprovedCaptionsTests(unittest.TestCase):
    def test_scoped_import_and_atomic_failed_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source.vtt"
            source.write_text("WEBVTT\n\nfirst\n01:12.500 --> 01:15.250 align:left\n<b>Memory</b> &amp; compute.\n")
            self.assertEqual(import_captions(root, "abcdefghijk", source), 1)
            cues = load_captions(root, "abcdefghijk")
            self.assertEqual(cues[0], dict(index=0, start=72.5, end=75.25, text="Memory & compute."))
            self.assertEqual(load_captions(root, "ABCDEFGHIJK"), [])
            source.write_text("WEBVTT\n\n00:02.000 --> 00:01.000\nInvalid")
            with self.assertRaises(ValueError):
                import_captions(root, "abcdefghijk", source)
            self.assertEqual(load_captions(root, "abcdefghijk"), cues)
            with self.assertRaises(ValueError):
                load_captions(root, "../private")

    def test_segment_timestamps_require_a_video_relative_track(self):
        with self.assertRaises(ValueError):
            parse_vtt(b"WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n")

    def test_transcript_formats_preserve_start_times(self):
        for raw in (b"0:02\nOne sentence.\n0:15\nNext sentence.", b"0:02 One sentence. 0:15 Next sentence.",
                    b"1\n00:00:02,000 --> 00:00:05,000\nOne sentence.\n\n2\n00:00:15,000 --> 00:00:18,000\nNext sentence."):
            cues = parse_track(raw)
            self.assertEqual([(cue["start"], cue["text"]) for cue in cues], [(2, "One sentence."), (15, "Next sentence.")])
        for raw in (b"An untimed description", b"1:02 A\n0:02 B"):
            with self.assertRaises(ValueError):
                parse_track(raw)

    def test_public_source_checks_video_and_track(self):
        video = "abcdefghijk"
        base = "https://www.youtube.com/api/timedtext?v=" + video
        player = {"videoDetails": {"videoId": video}, "playabilityStatus": {"status": "OK"},
                  "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": [
                      {"languageCode": "en", "baseUrl": base}]}}}
        calls = []
        def read(url, limit):
            calls.append(url)
            if len(calls) == 1:
                return ("var ytInitialPlayerResponse = " + json.dumps(player)).encode()
            self.assertEqual(url, base + "&fmt=vtt")
            return b"WEBVTT\n\n00:01.000 --> 00:02.000\nEvidence.\n"
        self.assertEqual(public_track(video, read)[0]["text"], "Evidence.")
        for url in ("https://example.com/api/timedtext?v=" + video, base.replace(video, "ABCDEFGHIJK")):
            calls.clear()
            player["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"][0]["baseUrl"] = url
            self.assertEqual(public_track(video, read), [])
            self.assertEqual(len(calls), 1)
