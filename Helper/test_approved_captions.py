from pathlib import Path
import tempfile
import unittest

from approved_captions import import_captions, load_captions, parse_vtt


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
