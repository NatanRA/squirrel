"""Offline tests for the playlist and quality-target logic in ytdl_bridge.

A fake extractor serves canned info dicts, so yt-dlp's real playlist
processing (flat extraction, playlistend, format selection) runs without the
network. Needs yt-dlp importable: the version the apps pin, e.g. from a
desktop runtime (SQUIRREL_RUNTIME=desktop/build/runtime-macos-arm64) or a venv.

    python3 -m unittest discover shared/pybridge/tests
"""
from __future__ import annotations

import copy
import json
import os
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
if os.environ.get('SQUIRREL_RUNTIME'):
    sys.path.insert(0, os.path.join(os.environ['SQUIRREL_RUNTIME'], 'lib'))

# The bridge loads yt-dlp through the over-the-air updater at import; use the installed one.
sys.modules['ytdl_updater'] = types.SimpleNamespace(
    load_ytdlp=lambda: None, load_state={'source': 'bundled', 'error': None},
    bundled_version=lambda: None, installed_update_version=lambda: None)

import yt_dlp  # noqa: E402
from yt_dlp.extractor.common import InfoExtractor  # noqa: E402

import ytdl_bridge  # noqa: E402

FIXTURES: dict[str, dict] = {}


class FakeIE(InfoExtractor):
    _VALID_URL = r'fake://(?P<id>.+)'
    IE_NAME = 'fake'

    def _real_extract(self, url):
        if url not in FIXTURES:
            raise yt_dlp.utils.ExtractorError(f'No fixture for {url}', expected=True)
        info = copy.deepcopy(FIXTURES[url])
        if info.pop('_lazy', False):  # like YouTube's pages of results: no total up front
            info['entries'] = (e for e in info['entries'])
        return info


class FakeYoutubeDL(yt_dlp.YoutubeDL):
    """yt-dlp with FakeIE tried first, and downloads that just write a small file."""

    def __init__(self, params=None, auto_init=True):
        super().__init__(params, auto_init)
        self.add_info_extractor(FakeIE())
        self._ies = {'Fake': self._ies.pop('Fake'), **self._ies}

    def dl(self, name, info, subtitle=False, test=False):
        with open(name, 'wb') as f:
            f.write(b'WEBVTT\n' if subtitle else info['format_id'].encode())
        for hook in self._progress_hooks:
            hook({'status': 'finished', 'filename': name, 'info_dict': info})
        return True, True


def video(video_id, heights=(1080, 720, 360), vcodec='avc1.640028', audio=True, url=None, title=None,
          subtitles=None, captions=None):
    formats = [{'format_id': f'v{h}', 'url': f'https://example.invalid/{video_id}/{h}.mp4', 'ext': 'mp4',
                'vcodec': vcodec, 'acodec': 'none', 'width': h * 16 // 9, 'height': h, 'fps': 30, 'tbr': h}
               for h in heights]
    if audio:
        formats.append({'format_id': 'a', 'url': f'https://example.invalid/{video_id}/a.m4a', 'ext': 'm4a',
                        'vcodec': 'none', 'acodec': 'mp4a.40.2', 'abr': 128})
    info = {'id': video_id, 'title': title or f'Video {video_id}', 'formats': formats}
    for field, languages in (('subtitles', subtitles), ('automatic_captions', captions)):
        if languages:
            info[field] = {k: [{'ext': 'vtt', 'url': f'https://example.invalid/{video_id}/{k}.vtt', 'name': name}]
                           for k, name in languages.items()}
    if url:
        info['webpage_url'] = url
    return info


def flat(video_id, **extra):
    return {'_type': 'url', 'ie_key': 'Fake', 'id': video_id, 'url': f'fake://video/{video_id}',
            'title': f'Video {video_id}', 'duration': 60, **extra}


def call(function, **params):
    return json.loads(getattr(ytdl_bridge, function)(json.dumps(params)))


class BridgeTestCase(unittest.TestCase):
    def setUp(self):
        FIXTURES.clear()
        self.cache = tempfile.TemporaryDirectory()
        ytdl_bridge.configure(json.dumps({'cache_dir': self.cache.name, 'av1_decode': False, 'vp9_decode': False}))
        patcher = mock.patch.object(yt_dlp, 'YoutubeDL', FakeYoutubeDL)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.cache.cleanup)

    def add_videos(self, *ids, **kwargs):
        for video_id in ids:
            FIXTURES[f'fake://video/{video_id}'] = video(video_id, **kwargs)


class ResolveTargetTests(unittest.TestCase):
    @staticmethod
    def choices(*videos, audio=True):
        out = [{'id': f'v{h}', 'kind': 'video', 'height': h, 'playable': playable, 'format_ids': [f'v{h}']}
               for h, playable in videos]
        if audio:
            out.append({'id': 'audio', 'kind': 'audio', 'height': 0, 'playable': True, 'format_ids': ['a']})
        return out

    def test_best_prefers_playable(self):
        choices = self.choices((2160, False), (1080, True), (720, True))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'video'})['id'], 'v1080')

    def test_cap(self):
        choices = self.choices((1080, True), (720, True), (480, True))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'video', 'max_height': 720})['id'], 'v720')

    def test_cap_below_smallest_takes_smallest(self):
        choices = self.choices((1080, True), (720, True))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'video', 'max_height': 360})['id'], 'v720')

    def test_only_unplayable(self):
        choices = self.choices((2160, False), (1440, False))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'video'})['id'], 'v2160')

    def test_audio(self):
        choices = self.choices((1080, True))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'audio'})['id'], 'audio')

    def test_mp3(self):
        choices = self.choices((1080, True)) + [
            {'id': 'mp3', 'kind': 'audio', 'height': 0, 'playable': True, 'format_ids': ['a'], 'convert': 'mp3'}]
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'audio', 'convert': 'mp3'})['id'], 'mp3')
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'audio'})['id'], 'audio')

    def test_mp3_when_the_audio_already_is(self):
        choices = self.choices((1080, True))
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'audio', 'convert': 'mp3'})['id'], 'audio')

    def test_audio_without_audio_stream_takes_smallest_video(self):
        choices = self.choices((1080, True), (360, True), audio=False)
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'audio'})['id'], 'v360')

    def test_generic_best(self):
        choices = [{'id': 'best', 'kind': 'video', 'height': 0, 'playable': True, 'format_ids': ['best']}]
        self.assertEqual(ytdl_bridge._resolve_target(choices, {'kind': 'video', 'max_height': 720})['id'], 'best')

    def test_nothing(self):
        with self.assertRaises(ValueError):
            ytdl_bridge._resolve_target([], {'kind': 'video'})


class SubtitleTests(unittest.TestCase):
    info = {'subtitles': {'en-GB': [], 'pt': [], 'live_chat': []},
            'automatic_captions': {'de': [], 'de-orig': [], 'fr': [], 'en': []}}

    def test_people_written_first(self):
        self.assertEqual(ytdl_bridge._subtitle_tracks(self.info, ['en-US', 'pt-PT'], auto=True), ['en-GB', 'pt'])

    def test_automatic_only_in_the_videos_language(self):
        self.assertEqual(ytdl_bridge._subtitle_tracks(self.info, ['de', 'fr'], auto=True), ['de-orig'])
        self.assertEqual(ytdl_bridge._subtitle_tracks(self.info, ['de'], auto=False), [])

    def test_old_language_codes(self):
        info = {'subtitles': {'iw': [], 'in': []}}
        self.assertEqual(ytdl_bridge._subtitle_tracks(info, ['he-IL', 'id'], auto=False), ['iw', 'in'])

    def test_summary(self):
        self.assertEqual(ytdl_bridge._subtitle_summary(self.info), {'languages': ['en', 'pt'], 'auto': ['de']})


class PlaylistHintTests(unittest.TestCase):
    def test_watch_with_list(self):
        self.assertEqual(ytdl_bridge._playlist_hint('https://www.youtube.com/watch?v=abc&list=PL123'),
                         'https://www.youtube.com/playlist?list=PL123')

    def test_short_link(self):
        self.assertEqual(ytdl_bridge._playlist_hint('https://youtu.be/abc?list=PL123'),
                         'https://www.youtube.com/playlist?list=PL123')

    def test_music(self):
        self.assertEqual(ytdl_bridge._playlist_hint('https://music.youtube.com/watch?v=abc&list=OLAK5uy'),
                         'https://music.youtube.com/playlist?list=OLAK5uy')

    def test_mix_is_ignored(self):
        self.assertIsNone(ytdl_bridge._playlist_hint('https://www.youtube.com/watch?v=abc&list=RDabc'))

    def test_playlist_page_and_other_sites(self):
        self.assertIsNone(ytdl_bridge._playlist_hint('https://www.youtube.com/playlist?list=PL123'))
        self.assertIsNone(ytdl_bridge._playlist_hint('https://example.com/watch?v=abc&list=PL123'))
        self.assertIsNone(ytdl_bridge._playlist_hint('https://www.youtube.com/watch?v=abc'))


class ExtractTests(BridgeTestCase):
    def playlist(self, entries, url='fake://playlist/1', **extra):
        FIXTURES[url] = {'_type': 'playlist', 'id': 'PL1', 'title': 'My list', 'uploader': 'Someone',
                         'entries': entries, **extra}
        return url

    def test_video(self):
        self.add_videos('a')
        result = call('extract', url='fake://video/a', playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['type'], 'video')
        self.assertEqual(result['key'], 'fake a')
        self.assertEqual([c['id'] for c in result['choices']], ['v1080', 'v720', 'v360', 'audio', 'mp3'])
        self.assertEqual(result['choices'][-1]['convert'], 'mp3')

    def test_playlist_items(self):
        self.add_videos('a', 'b', 'c')
        url = self.playlist([flat('a'), flat('b', availability='private'), flat('c', live_status='is_upcoming'),
                             flat('d', title='[Deleted video]')], playlist_count=4)
        result = call('extract', url=url, playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['type'], 'playlist')
        self.assertEqual((result['title'], result['folder'], result['count'], result['truncated']),
                         ('My list', 'My list', 4, False))
        entries = result['entries']
        self.assertEqual([e['index'] for e in entries], [1, 2, 3, 4])
        self.assertEqual([e['key'] for e in entries], ['fake a', 'fake b', 'fake c', 'fake d'])
        self.assertEqual(entries[0]['url'], 'fake://video/a')
        self.assertIsNone(entries[0]['pick'])
        self.assertEqual([e['unavailable'] for e in entries], [False, True, False, True])
        self.assertEqual([e['live'] for e in entries], [False, False, True, False])

    def test_without_playlists_takes_the_first_video(self):
        self.add_videos('a', 'b')
        url = self.playlist([flat('a'), flat('b')])
        result = call('extract', url=url)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['type'], result['id']), ('video', 'a'))

    def test_truncated(self):
        url = self.playlist([flat(str(i)) for i in range(8)], playlist_count=8)
        with mock.patch.object(ytdl_bridge, 'PLAYLIST_CAP', 5):
            result = call('extract', url=url, playlists=True)
        self.assertTrue(result['truncated'])
        self.assertEqual(len(result['entries']), 5)
        self.assertEqual(result['count'], 8)

    def test_truncated_without_a_total(self):
        url = self.playlist([flat(str(i)) for i in range(8)], _lazy=True)
        with mock.patch.object(ytdl_bridge, 'PLAYLIST_CAP', 5):
            result = call('extract', url=url, playlists=True)
        self.assertTrue(result['truncated'])
        self.assertIsNone(result['count'])

    def test_one_item_is_a_video(self):
        self.add_videos('a')
        result = call('extract', url=self.playlist([flat('a')]), playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['type'], result['id']), ('video', 'a'))

    def test_empty(self):
        result = call('extract', url=self.playlist([]), playlists=True)
        self.assertFalse(result['ok'])

    def test_channel_tabs(self):
        tab = {'_type': 'playlist', 'id': 'UC1', 'extractor': 'fake', 'extractor_key': 'Fake'}
        videos = {**tab, 'title': 'Chan - Videos', 'webpage_url': 'https://www.youtube.com/@chan/videos',
                  'entries': [flat('a'), flat('b')]}
        shorts = {**tab, 'title': 'Chan - Shorts', 'webpage_url': 'https://www.youtube.com/@chan/shorts',
                  'entries': [flat('s')]}
        url = self.playlist([videos, shorts], title='Chan')
        result = call('extract', url=url, playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['sections'], ['Videos', 'Shorts'])
        self.assertEqual([(e['section'], e['index']) for e in result['entries']],
                         [('Videos', 1), ('Videos', 2), ('Shorts', 3)])

    def test_cap_covers_all_sections(self):
        tab = {'_type': 'playlist', 'id': 'UC1', 'extractor': 'fake', 'extractor_key': 'Fake'}
        videos = {**tab, 'webpage_url': 'https://www.youtube.com/@chan/videos', 'entries': [flat(f'v{i}') for i in range(4)]}
        shorts = {**tab, 'webpage_url': 'https://www.youtube.com/@chan/shorts', 'entries': [flat(f's{i}') for i in range(4)]}
        url = self.playlist([videos, shorts], title='Chan')
        with mock.patch.object(ytdl_bridge, 'PLAYLIST_CAP', 5):
            result = call('extract', url=url, playlists=True)
        self.assertTrue(result['truncated'])
        self.assertEqual([e['section'] for e in result['entries']], ['Videos'] * 4 + ['Shorts'])

    def test_videos_next_to_a_nested_playlist(self):
        tab = {'_type': 'playlist', 'id': 'sub', 'title': 'Extras', 'extractor': 'fake', 'extractor_key': 'Fake',
               'entries': [flat('x')]}
        result = call('extract', url=self.playlist([flat('a'), tab, flat('b')]), playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual([(e['key'], e['section']) for e in result['entries']],
                         [('fake a', None), ('fake b', None), ('fake x', 'Extras')])

    def test_post_with_several_videos(self):
        post = 'fake://post/1'
        FIXTURES[post] = {'_type': 'multi_video', 'id': 'post1', 'title': 'Post', 'webpage_url': post,
                          'entries': [video('m1', url=post), video('m2', url=post)]}
        result = call('extract', url=post, playlists=True)
        self.assertTrue(result['ok'], result)
        self.assertIsNone(result['folder'])
        self.assertEqual([(e['url'], e['pick']) for e in result['entries']], [(post, 1), (post, 2)])


class DownloadTests(BridgeTestCase):
    def download(self, **params):
        out = tempfile.mkdtemp(dir=self.cache.name)
        return call('download', out_dir=out, job_id='job', **params), out

    def test_format_ids(self):
        self.add_videos('a')
        result, _ = self.download(url='fake://video/a', format_ids=['v720', 'a'])
        self.assertTrue(result['ok'], result)
        self.assertEqual(len(result['files']), 2)
        self.assertIsNone(result['choice'])
        self.assertEqual(result['key'], 'fake a')

    def test_target(self):
        self.add_videos('a', heights=(2160, 1080, 720))
        result, _ = self.download(url='fake://video/a', target={'kind': 'video', 'max_height': 1080})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['choice']['id'], 'v1080')
        self.assertEqual(sorted(os.path.basename(f).rsplit('.f', 1)[1] for f in result['files']),
                         ['a.m4a', 'v1080.mp4'])

    def test_subtitles(self):
        FIXTURES['fake://video/a'] = video('a', subtitles={'en': 'English', 'es': 'Spanish'},
                                           captions={'fr': 'French', 'fr-orig': 'French (Original)'})
        result, _ = self.download(url='fake://video/a', format_ids=['v720', 'a'],
                                  subtitles={'languages': ['en', 'fr'], 'auto': True})
        self.assertTrue(result['ok'], result)
        self.assertEqual([(t['lang'], t['name']) for t in result['subtitles']],
                         [('eng', 'English'), ('fra', 'French (auto-generated)')])
        self.assertTrue(all(os.path.exists(t['path']) for t in result['subtitles']))
        self.assertEqual(len(result['files']), 2)  # the subtitles aren't media parts

    def test_no_subtitles_for_audio(self):
        FIXTURES['fake://video/a'] = video('a', subtitles={'en': 'English'})
        result, _ = self.download(url='fake://video/a', target={'kind': 'audio'},
                                  subtitles={'languages': ['en'], 'auto': False})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['subtitles'], [])

    def test_audio_target(self):
        self.add_videos('a')
        result, _ = self.download(url='fake://video/a', target={'kind': 'audio'})
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['choice']['kind'], len(result['files'])), ('audio', 1))

    def test_pick_from_post(self):
        post = 'fake://post/1'
        FIXTURES[post] = {'_type': 'multi_video', 'id': 'post1', 'title': 'Post', 'webpage_url': post,
                          'entries': [video('m1', url=post), video('m2', url=post, heights=(480,))]}
        result, _ = self.download(url=post, playlist_index=2, target={'kind': 'video'})
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['id'], result['choice']['id']), ('m2', 'v480'))

    def test_cancel_before_start(self):
        self.add_videos('a')
        ytdl_bridge.cancel(json.dumps({'job_id': 'job'}))
        result, out = self.download(url='fake://video/a', format_ids=['v720'])
        self.assertTrue(result.get('cancelled'), result)
        self.assertEqual(os.listdir(out), [])
        # A retry with the same id isn't cancelled again
        result, _ = self.download(url='fake://video/a', format_ids=['v720'])
        self.assertTrue(result['ok'], result)

    def test_nested_playlist_is_refused(self):
        tab = {'_type': 'playlist', 'id': 'tab', 'extractor': 'fake', 'extractor_key': 'Fake', 'entries': [flat('a')]}
        FIXTURES['fake://channel'] = {'_type': 'playlist', 'id': 'chan', 'entries': [tab]}
        result, out = self.download(url='fake://channel', target={'kind': 'video'})
        self.assertFalse(result['ok'])
        self.assertIn('playlist', result['error'])
        self.assertEqual(os.listdir(out), [])


class ConversionTests(unittest.TestCase):
    """Videos the iOS app converts to HEVC for Photos (``hevc``), which takes neither AV1 nor VP9."""

    def setUp(self):
        ytdl_bridge.configure(json.dumps({'av1_decode': False, 'vp9_decode': False}))

    @staticmethod
    def dash(*videos):
        """Video-only formats at 1080p, one per codec, and AAC audio."""
        formats = [{'format_id': fid, 'url': f'https://example.invalid/{fid}.mp4', 'ext': 'mp4', 'vcodec': codec,
                    'acodec': 'none', 'width': 1080, 'height': 1920, 'fps': 30} for fid, codec in videos]
        formats.append({'format_id': 'a', 'url': 'https://example.invalid/a.m4a', 'ext': 'm4a',
                        'vcodec': 'none', 'acodec': 'mp4a.40.2', 'abr': 128})
        return {'formats': formats}

    def test_converted_choices_say_so(self):
        choice = ytdl_bridge._presets(self.dash(('vp9', 'vp09.00.40.08')), hevc=['VP9'])[0]
        self.assertEqual((choice['convert'], choice['playable']), ('hevc', True))
        self.assertIn('Converted for Photos', choice['detail'])

    def test_without_conversion_vp9_plays_in_vlc(self):
        choice = ytdl_bridge._presets(self.dash(('vp9', 'vp09.00.40.08')))[0]
        self.assertNotIn('convert', choice)
        self.assertFalse(choice['playable'])
        self.assertIn('Plays in VLC', choice['detail'])

    def test_av1_that_plays_is_still_converted(self):
        ytdl_bridge.configure(json.dumps({'av1_decode': True}))
        self.addCleanup(ytdl_bridge.configure, json.dumps({'av1_decode': False}))
        choice = ytdl_bridge._presets(self.dash(('av1', 'av01.0.08M.08')), hevc=['AV1', 'VP9'])[0]
        self.assertEqual(choice['convert'], 'hevc')

    def test_convertible_beats_unconvertible(self):
        # No AV1 decoding, so only the VP9 one can reach Photos
        info = self.dash(('av1', 'av01.0.08M.08'), ('vp9', 'vp09.00.40.08'))
        self.assertEqual(ytdl_bridge._presets(info, hevc=['VP9'])[0]['format_ids'], ['vp9', 'a'])

    def test_h264_beats_converting(self):
        info = self.dash(('vp9', 'vp09.00.40.08'), ('h264', 'avc1.640028'))
        choice = ytdl_bridge._presets(info, hevc=['VP9'])[0]
        self.assertEqual(choice['format_ids'], ['h264', 'a'])
        self.assertNotIn('convert', choice)

    def test_best_target_takes_converted_1080p(self):
        info = self.dash(('vp9', 'vp09.00.40.08'))
        info['formats'].append({'format_id': 'v720', 'url': 'https://example.invalid/v720.mp4', 'ext': 'mp4',
                                'vcodec': 'avc1.64001f', 'acodec': 'none', 'width': 720, 'height': 1280})
        choice = ytdl_bridge._resolve_target(ytdl_bridge._presets(info, hevc=['VP9']), {'kind': 'video'})
        self.assertEqual(choice['id'], 'v1080')


def box(kind, *children, payload=b''):
    body = payload + b''.join(children)
    return struct.pack('>I4s', 8 + len(body), kind) + body


def mp4_start(width, height, padding=0):
    """The start of a faststart MP4 like Facebook's: its moov box (sound track first, then H.264
    video) before the media. ``padding`` makes the moov box longer than one read."""
    def trak(handler, entry, size=(0, 0)):
        tkhd = box(b'tkhd', payload=bytes(76) + struct.pack('>II', size[0] << 16, size[1] << 16))
        hdlr = box(b'hdlr', payload=bytes(8) + handler + bytes(12))
        stsd = box(b'stsd', payload=struct.pack('>II', 0, 1) + box(entry, payload=bytes(8)))
        return box(b'trak', tkhd, box(b'mdia', hdlr, box(b'minf', box(b'stbl', stsd))))
    moov = box(b'moov', box(b'mvhd', payload=bytes(100)), trak(b'soun', b'mp4a'),
               trak(b'vide', b'avc1', (width, height)), box(b'free', payload=bytes(padding)))
    return box(b'ftyp', payload=b'isom' + bytes(4)) + moov + box(b'mdat', payload=bytes(1000))


class FakeFetcher:
    """Stands in for YoutubeDL.urlopen, serving byte ranges of canned files."""

    def __init__(self, files):
        self.files = files
        self.requests = []

    def urlopen(self, request):
        first, last = map(int, request.headers['Range'].removeprefix('bytes=').split('-'))
        self.requests.append((request.url, first, last))
        data = self.files[request.url]
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.headers = {'Content-Range': f'bytes {first}-{last}/{len(data)}'}
        response.read.side_effect = lambda size: data[first:first + size]
        return response


class ProbeTests(unittest.TestCase):
    URL = 'https://example.invalid/hd.mp4'

    def setUp(self):
        ytdl_bridge.configure(json.dumps({'av1_decode': True, 'vp9_decode': False}))
        self.addCleanup(ytdl_bridge.configure, json.dumps({'av1_decode': False}))

    def info(self):
        """Like Facebook: AV1-only DASH video, and its own direct file listing no size or codecs."""
        return {'formats': [
            {'format_id': 'hd', 'url': self.URL, 'ext': 'mp4', 'protocol': 'https'},
            {'format_id': 'v1080', 'url': 'https://example.invalid/v1080.mp4', 'ext': 'mp4', 'protocol': 'https',
             'vcodec': 'av01.0.08M.08', 'acodec': 'none', 'width': 1080, 'height': 1920},
            {'format_id': 'a', 'url': 'https://example.invalid/a.m4a', 'ext': 'm4a', 'protocol': 'https',
             'vcodec': 'none', 'acodec': 'mp4a.40.5', 'abr': 74},
        ]}

    def direct_choice(self, fetcher):
        choices = ytdl_bridge._presets(self.info(), fetcher, hevc=['AV1', 'VP9'])
        return next((c for c in choices if c['format_ids'] == ['hd']), None)

    def test_direct_file_is_offered(self):
        data = mp4_start(720, 1280)
        choice = self.direct_choice(FakeFetcher({self.URL: data}))
        self.assertEqual((choice['label'], choice['playable']), ('720p', True))
        self.assertNotIn('convert', choice)
        self.assertIn('H.264', choice['detail'])
        self.assertIn(ytdl_bridge._human(len(data)), choice['detail'])

    def test_long_moov_box_is_read_to_its_end(self):
        fetcher = FakeFetcher({self.URL: mp4_start(720, 1280, padding=100_000)})
        self.assertEqual(self.direct_choice(fetcher)['label'], '720p')
        self.assertEqual(len(fetcher.requests), 2)

    def test_unreadable_file_is_left_out(self):
        self.assertIsNone(self.direct_choice(FakeFetcher({self.URL: b'<html>' * 100})))

    def test_nothing_is_fetched_without_ydl(self):
        choices = ytdl_bridge._presets(self.info())
        self.assertNotIn(['hd'], [c['format_ids'] for c in choices])


if __name__ == '__main__':
    unittest.main()
