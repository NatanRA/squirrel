"""Tests for the desktop host's file naming (no FFmpeg needed).

    python3 -m unittest discover desktop/host/tests
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import remux  # noqa: E402


class SafeNameTests(unittest.TestCase):
    def test_illegal_characters(self):
        self.assertEqual(remux.safe_name('AC/DC: Live? "Best" <of>'), 'AC DC Live Best of')

    def test_reserved_windows_names(self):
        self.assertEqual(remux.safe_name('CON'), 'CON _')
        self.assertEqual(remux.safe_name('nul.txt'), 'nul.txt _')
        self.assertEqual(remux.safe_name('Console'), 'Console')

    def test_trailing_dots_and_empty(self):
        self.assertEqual(remux.safe_name('Wait...'), 'Wait')
        self.assertEqual(remux.safe_name('///', fallback='Playlist'), 'Playlist')

    def test_limit(self):
        self.assertEqual(len(remux.safe_name('x' * 200, limit=80)), 80)


class UniquePathTests(unittest.TestCase):
    def test_reserves_each_name(self):
        with tempfile.TemporaryDirectory() as folder:
            first = remux.unique_path(folder, 'Intro', 'mp4')
            second = remux.unique_path(folder, 'Intro', 'mp4')
            self.assertEqual(os.path.basename(first), 'Intro.mp4')
            self.assertEqual(os.path.basename(second), 'Intro (2).mp4')
            self.assertTrue(os.path.exists(first) and os.path.exists(second))


if __name__ == '__main__':
    unittest.main()
