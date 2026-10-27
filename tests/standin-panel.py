#!/usr/bin/env python3
"""A stand-in for the music panel's JSON API and upload routes, for the app's self-test. It follows the
panel's docs/api.md: the same paths, answers and errors, but over a pretend library, queue and log in
folders the test made, with test credentials only (test / test-password).

  standin-panel.py PORT ROOT --lib LIB --queue FILE --log FILE
                   [--drop-after BYTES] [--slow SECONDS] [--needs-look N] [--issues N]

--drop-after   once, cut the connection after that many bytes of a chunk (the app must resume)
--slow         wait that long before answering each chunk (so a test can pause mid-upload)
--needs-look   report this many tracks of an upload as left for review
--issues       pretend that many FLACs break the device's block-size limit (a fix clears them)
--samples      the panel's docs/api-samples.json: its recorded answers are replayed for history, covers, health and the device's added albums and copy history
--corrupt-once flip one byte of the first checksummed file before the check at finish (the app must send it again)
ROOT/stage holds batches, ROOT/inbox the finished folders, ROOT/log.txt every request."""
import base64, hashlib, json, math, os, re, secrets, shutil, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

port, root = int(sys.argv[1]), sys.argv[2]
args = sys.argv[3:]
opt = lambda name, default: type(default)(args[args.index(name) + 1]) if name in args else default
LIB, QUEUE, SYNCLOG = opt('--lib', ''), opt('--queue', ''), opt('--log', '')
DROP_AFTER, SLOW, NEEDS_LOOK, ISSUES = opt('--drop-after', 0), opt('--slow', 0.0), opt('--needs-look', 0), opt('--issues', 0)
CORRUPT_ONCE = '--corrupt-once' in args
SAMPLES_FILE = opt('--samples', '')
DONE = QUEUE[:-4] + '.done.txt' if QUEUE.endswith('.txt') else QUEUE + '.done'
STAGE, INBOX = os.path.join(root, 'stage'), os.path.join(root, 'inbox')
for d in (STAGE, INBOX): os.makedirs(d, exist_ok=True)
AUTH = 'Basic ' + base64.b64encode(b'test:test-password').decode()
AUDIO = ('.flac', '.mp3', '.m4a', '.ogg', '.opus', '.wav', '.aiff', '.wv')
ALLOWED = AUDIO + ('.aif', '.wma', '.ape', '.alac', '.lrc', '.txt', '.jpg', '.jpeg', '.png', '.webp', '.cue', '.log')
PROFILE = {'id': 'hifi-walker-h2', 'name': 'HiFi Walker H2 (Rockbox)', 'formats': ['flac', 'mp3', 'm4a', 'ogg', 'opus', 'wav', 'aiff', 'wv'],
           'max_sample_rate': 192000, 'max_bit_depth': 24, 'max_flac_blocksize': 4608, 'convert_to': None, 'source': None, 'queue': True,
           'protect': ['/.rockbox/', '/Playlists/', '/*.pdf', '/.dap-sync-target', '/System Volume Information/', '/settings.txt', '/update.upt', '/*.upt'],
           'fixes': ['flac_blocksize']}

HEB = ('ניר כנען', 'נקודת תורפה')
NEEDS = [
    {'id': 'imp-aaaa1111-bbbb2222', 'group': 'imports', 'kind': 'import', 'title': 'Mud memory', 'sub': 'Yoavi · auto-import couldn’t match it · 2 tracks', 'age': 1793077765.3, 'later': False, 'open': True, 'cover': '/inbox/art/aaaa1111/bbbb2222', 'fix': None},
    {'id': 'imp-aaaa1111-cccc3333', 'group': 'imports', 'kind': 'import', 'title': HEB[1], 'sub': HEB[0] + ' · still arriving · 1 tracks', 'age': 1793077765.3, 'later': False, 'open': True, 'cover': None, 'fix': None},
    {'id': 'names', 'group': 'health', 'kind': 'names', 'title': '2 names not in Latin letters', 'sub': '1 artist · 1 album title', 'age': None, 'later': False, 'open': True, 'cover': None, 'fix': None},
    {'id': 'covers', 'group': 'health', 'kind': 'covers', 'title': '1 album with no cover', 'sub': 'Mud memory', 'age': None, 'later': False, 'open': True, 'cover': None, 'fix': None},
    {'id': 'fix-split', 'group': 'health', 'kind': 'fix', 'title': '1 album split into several entries in Navidrome', 'sub': 'Test Album', 'age': None, 'later': False, 'open': True, 'cover': None, 'fix': 'split'},
    {'id': 'f-weekly', 'group': 'health', 'kind': 'finding', 'title': '3 · Tracks Navidrome can’t find', 'sub': 'from the weekly health check', 'age': None, 'later': False, 'open': True, 'cover': None, 'fix': None},
    {'id': 'dap', 'group': 'device', 'kind': 'dap', 'title': '17 albums waiting for the DAP', 'sub': 'copies on the next sync from your Mac', 'age': None, 'later': False, 'open': False, 'cover': None, 'fix': None},
]
INBOX_ALBUMS = {
    ('aaaa1111', 'bbbb2222'): {'id': 'imp-aaaa1111-bbbb2222', 'fid': 'aaaa1111', 'gid': 'bbbb2222', 'folder': 'Mixed upload', 'artist': 'Yoavi', 'album': 'Mud memory', 'year': 2026, 'state': 'pending', 'age_minutes': 20, 'n_tracks': 2, 'bytes': 7000000, 'duration': 366.3, 'format': 'FLAC',
        'tracks': [{'n': 1, 'title': 'Background noise', 'duration': 172.6, 'file': 'Background noise - Yoavi.flac'}, {'n': 2, 'title': 'Productive defective', 'duration': 193.7, 'file': 'Productive defective - Yoavi.flac'}],
        'art': '/inbox/art/aaaa1111/bbbb2222', 'needs_asis': [], 'target': 'Yoavi/Mud memory/', 'last_job': None},
    ('aaaa1111', 'cccc3333'): {'id': 'imp-aaaa1111-cccc3333', 'fid': 'aaaa1111', 'gid': 'cccc3333', 'folder': 'Mixed upload', 'artist': HEB[0], 'album': HEB[1], 'year': 2025, 'state': 'arriving', 'age_minutes': 2, 'n_tracks': 1, 'bytes': 3000000, 'duration': 180.0, 'format': 'FLAC',
        'tracks': [{'n': 1, 'title': 'שיר', 'duration': 180.0, 'file': 'שיר.flac'}], 'art': None, 'needs_asis': [{'kind': 'artist', 'name': HEB[0]}, {'kind': 'album', 'name': HEB[1]}], 'target': HEB[0] + '/' + HEB[1] + '/', 'last_job': None},
}


def candidate(gid, query=None):
    heb = gid == 'cccc3333'
    needs = [{'kind': 'artist', 'name': HEB[0], 'suggest': 'Nir Knaan'}, {'kind': 'album', 'name': HEB[1], 'suggest': 'Nekudat Torpa'}] if heb else []
    return {'id': 'rel-' + gid + ('-q' if query else ''), 'score': 0.92 if query else 1.0, 'quality': 'ok' if query else 'good', 'artist': HEB[0] if heb else 'Yoavi', 'album': HEB[1] if heb else 'Mud memory', 'year': 2026, 'country': 'XW', 'media': 'Digital Media', 'label': None,
            'disambig': '', 'url': 'https://musicbrainz.org/release/test', 'tracks_total': 2, 'matched': 2, 'of_files': 2, 'titles_change': 1,
            'tracks': [{'index': 1, 'medium': 1, 'file': 'Background noise - Yoavi.flac', 'title': 'Background noise', 'new_title': 'Background Noise', 'matched': True, 'length': 172.0, 'new_length': 172.6},
                       {'index': 2, 'medium': 1, 'file': 'Productive defective - Yoavi.flac', 'title': 'Productive defective', 'new_title': 'Productive defective', 'matched': True, 'length': 193.0, 'new_length': 193.7}],
            'missing': [], 'extra': [], 'penalties': [{'name': 'year', 'value': 0.02}], 'needs': needs}


SAMPLES = json.load(open(SAMPLES_FILE)) if SAMPLES_FILE else {}


def sample(prefix, default=None):
    k = next((k for k in sorted(SAMPLES) if k.startswith(prefix)), None)
    return SAMPLES[k]['response'] if k else default


lock = threading.Lock()
state = {'ignored': set(), 'lookups': {}, 'english': [], 'corrupted': False, 'dropped': False, 'jobs': {}, 'next_job': 1, 'fixed': set()}


def log(line):
    with lock, open(os.path.join(root, 'log.txt'), 'a') as f: f.write(line + '\n')


# ---- the pretend library ---------------------------------------------------------------------------
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:12]


def library():
    albums, tracks = {}, {}
    if not LIB or not os.path.isdir(LIB): return albums, tracks
    for artist in sorted(os.listdir(LIB)):
        for album in sorted(os.listdir(os.path.join(LIB, artist))) if os.path.isdir(os.path.join(LIB, artist)) else []:
            folder = f'{artist}/{album}'
            files = sorted(os.path.join(r, f) for r, _, fs in os.walk(os.path.join(LIB, folder)) for f in fs if f.lower().endswith(AUDIO))
            if not files: continue
            a = {'id': ident(folder), 'artist': artist, 'album': album, 'year': 2020, 'tracks': len(files), 'folder': folder, 'has_cover': True,
                 'bytes': sum(os.path.getsize(f) for f in files)}
            albums[a['id']] = a
            for n, f in enumerate(files, 1):
                rel = os.path.relpath(f, LIB)
                m = re.match(r'^(\d+)\s*(.*)\.\w+$', os.path.basename(f))
                tracks[ident(rel)] = {'id': ident(rel), 'path': rel, 'album_id': a['id'], 'album': album, 'artist': artist, 'title': (m[2] if m else os.path.splitext(os.path.basename(f))[0]),
                                      'disc': 1, 'track': int(m[1]) if m else n, 'duration': 2.0, 'format': os.path.splitext(f)[1][1:], 'sample_rate': 44100, 'bit_depth': 16,
                                      'bytes': os.path.getsize(f)}
    return albums, tracks


def entry_info(entry):
    path = os.path.join(LIB, entry)
    albums, tracks = library()
    if not os.path.exists(path): return {'entry': entry, 'kind': 'track' if entry.lower().endswith(AUDIO) else 'album', 'album_id': None, 'artist': None, 'album': None, 'bytes': -1, 'tracks': 0, 'gone': True}
    if os.path.isfile(path):
        t = tracks.get(ident(entry), {})
        return {'entry': entry, 'kind': 'track', 'album_id': t.get('album_id'), 'artist': t.get('artist'), 'album': t.get('album'), 'bytes': os.path.getsize(path), 'tracks': 1, 'gone': False}
    a = albums.get(ident(entry))
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs)
    return {'entry': entry, 'kind': 'album', 'album_id': a and a['id'], 'artist': a and a['artist'], 'album': a and a['album'], 'bytes': size, 'tracks': a['tracks'] if a else 0, 'gone': False}


def read_queue():
    try: return [l.rstrip('\n') for l in open(QUEUE, encoding='utf-8') if l.strip()]
    except FileNotFoundError: return []


def write_queue(lines):
    with open(QUEUE, 'w', encoding='utf-8') as f: f.write(''.join(l + '\n' for l in lines))


def fake_issues():
    _, tracks = library()
    flacs = [t for t in list(t for t in tracks.values() if t['format'] == 'flac')[:ISSUES] if t['path'] not in state['fixed']]
    return [{'path': t['path'], 'album_id': t['album_id'], 'bytes': t['bytes'], 'check': 'flac_blocksize', 'value': 16384, 'limit': 4608, 'fixable': True} for t in flacs]


# ---- uploads ---------------------------------------------------------------------------------------
def clean(rel):
    parts = [p for p in re.split(r'[\\/]+', rel or '') if p not in ('', '.')]
    if not parts or any(p == '..' or p.startswith('.') or len(p) > 200 for p in parts) or len(parts) > 6: return None
    return '/'.join(parts) if parts[-1].lower().endswith(ALLOWED) else None


def manifest(b):
    try: return json.load(open(os.path.join(STAGE, b, 'manifest.json'), encoding='utf-8'))
    except (FileNotFoundError, ValueError): return None


def have(b, man):
    r = os.path.join(STAGE, b, 'files')
    return [os.path.getsize(os.path.join(r, f['path'])) if os.path.exists(os.path.join(r, f['path'])) else 0 for f in man['files']]


def wav(seconds=2.0, rate=8000):
    n = int(seconds * rate)
    data = b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(n))
    return b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) + b'data' + struct.pack('<I', len(data)) + data


WAV = wav()
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')


def job_json(jid, j):
    j['polls'] += 1
    running = j['polls'] < 3
    if 'result' in j:
        return {'id': jid, 'kind': j['kind'], 'title': j['kind'], 'status': 'running' if running else 'done', 'result': None if running else j['result'], 'error': None, 'progress': None if running else 1.0,
                'run': None if running else j.get('run'), 'seconds': j['polls'], 'log': ''}
    if j['kind'] in ('import-mb', 'import-asis'):
        result = {'run': j['kind'] + '-test', 'albums': [{'status': 'imported', 'artist': j['artist'], 'album': j['album'], 'path': j['artist'] + '/' + j['album'], 'tracks': 2, 'lyrics_files': 0, 'detail': None, 'verify': {}, 'names_still_non_latin': []}], 'error': None}
        return {'id': jid, 'kind': j['kind'], 'title': 'Import ' + j['album'], 'status': 'running' if running else 'done', 'result': None if running else result, 'error': None, 'progress': None if running else 1.0,
                'run': None if running else j['kind'] + '-test', 'seconds': j['polls'], 'log': 'importing…' if running else ''}
    if j['kind'] == 'names':
        files = 0 if any(r.get('english') == 'Nothing To Do' for r in j['renames']) else 23
        result = {'run': 'names-test', 'names': [{'kind': r['kind'], 'from': r['name'], 'to': r['english'], 'was': None} for r in j['renames']], 'files': files, 'fields': files,
                  'warning': None if files else 'Nothing needed changing: the files already carry the English name. The list this came from is Navidrome’s database, which catches up when it rescans (within the hour).'}
        return {'id': jid, 'kind': 'names', 'title': 'Rename ' + str(len(j['renames'])) + ' names', 'status': 'running' if running else 'done', 'result': None if running else result, 'error': None, 'progress': None, 'run': 'names-test', 'seconds': j['polls'], 'log': ''}
    if j['kind'] == 'upload-import':
        left = min(NEEDS_LOOK, j['tracks'])
        result = {'tracks_total': j['tracks'], 'tracks_imported': j['tracks'] - left, 'tracks_left': left}
    else:
        result = {'run': j['run'], 'found': len(j['paths']), 'fixed': [{'path': p, 'bytes_before': 2, 'bytes_after': 1} for p in j['paths']], 'failed': [], 'folders': []}
        if not running: state['fixed'].update(j['paths'])
    return {'id': jid, 'kind': j['kind'], 'title': j['kind'], 'status': 'running' if running else 'done', 'result': None if running else result, 'error': None,
            'progress': 0.5 if running else 1.0, 'run': j.get('run'), 'seconds': j['polls']}


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass

    def send(self, code, body, ctype='application/json', headers=None):
        data = body if isinstance(body, bytes) else (json.dumps(body) if ctype == 'application/json' else body).encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(data)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        if self.headers.get('Authorization') == AUTH: return True
        self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="music"'); self.send_header('Content-Length', '0'); self.end_headers()
        return False

    def body(self):
        return self.rfile.read(int(self.headers.get('Content-Length') or 0))

    def json_body(self):
        try: return json.loads(self.body() or b'{}')
        except ValueError: return {}

    def route(self):
        u = urlsplit(self.path)
        return u.path, parse_qs(u.query, keep_blank_values=True)

    def do_GET(self):
        if not self.authed(): return
        path, q = self.route()
        log(f'GET {self.path}')
        if path == '/healthz': return self.send(200, {'ok': True})
        if path == '/api/devices': return self.send(200, [PROFILE])
        if path == '/api/needs': return self.send(200, NEEDS)
        if path == '/api/history': return self.send(200, sample('GET /api/history?kind=audio' if 'audio' in (q.get('kind') or []) else 'GET /api/history?limit=3', {'runs': [], 'total': 0, 'next': None}))
        m = re.match(r'^/api/history/([\w.-]+)/undo-preview$', path)
        if m: return self.send(200, sample('GET /api/history/{run}/undo-preview (a tag run)'))
        m = re.match(r'^/api/history/([\w.-]+)$', path)
        if m: return self.send(200, {**sample('GET /api/history/{run} (a tag run)'), 'run': m[1]})
        m = re.match(r'^/api/tracks/(\w+)/lyrics$', path)
        if m:
            _, tracks = library()
            t = tracks.get(m[1])
            return self.send(200, sample('GET /api/tracks/{id}/lyrics (synced)') if t and t['track'] == 1 else sample('GET /api/tracks/{id}/lyrics (none)'))
        if path == '/api/covers':
            albums, _ = library()
            return self.send(200, [{**a, 'has_cover': False, 'queued': False, 'attention': True, 'lyrics': {'synced': 0, 'plain': 0, 'instrumental': 0, 'none': a['tracks']}} for a in list(albums.values())[:1]])
        m = re.match(r'^/api/covers/(\w+)/candidates$', path)
        if m: return self.send(200, sample('GET /api/covers/{album_id}/candidates'))
        m = re.match(r'^/api/health/(split|variants|multi|unknown)$', path)
        if m: return self.send(200, sample('GET /api/health/' + m[1]))
        if path == '/api/health/findings': return self.send(200, sample('GET /api/health/findings'))
        if path == '/api/health/ignored': return self.send(200, [{'id': i, 'kind': i.split(':')[0], 'title': i.split(':', 1)[1], 'since': 1793082427.8} for i in sorted(state['ignored'])])
        m = re.match(r'^/api/devices/([\w-]+)/queue/new$', path)
        if m: return self.send(200, sample('GET /api/devices/{id}/queue/new'))
        m = re.match(r'^/api/devices/([\w-]+)/syncs$', path)
        if m: return self.send(200, sample('GET /api/devices/{id}/syncs'))
        if path == '/api/names':
            return self.send(200, [{'kind': 'artist', 'name': HEB[0], 'suggest': 'Nir Knaan', 'why': 'known name', 'known': True, 'albums': [{'id': 'x1', 'title': HEB[1], 'artist': HEB[0]}], 'folders': [HEB[0] + '/' + HEB[1]]},
                                   {'kind': 'album', 'name': HEB[1], 'suggest': '', 'why': '', 'known': False, 'albums': [{'id': 'x1', 'title': HEB[1], 'artist': HEB[0]}], 'folders': []}])
        m = re.match(r'^/api/needs/imports/(\w+)/(\w+)(/candidates)?$', path)
        if m:
            a = INBOX_ALBUMS.get((m[1], m[2]))
            if not a: return self.send(404, {'error': 'no such album'})
            if not m[3]: return self.send(200, a)
            key = (m[1], m[2])
            n = state['lookups'].get(key, {'polls': 0, 'query': None})
            n['polls'] += 1
            state['lookups'][key] = n
            if n['polls'] < 3: return self.send(200, {'job': 1, 'status': 'queued' if n['polls'] == 1 else 'running', 'error': None, 'recommendation': None, 'candidates': None})
            c = [candidate(m[2])] + ([candidate(m[2], n['query'])] if n['query'] else [])
            return self.send(200, {'job': 1, 'status': 'done', 'error': None, 'recommendation': 'strong', 'candidates': c})
        if path.startswith('/inbox/art/'): return self.send(200, PNG, 'image/png')
        if path == '/api/jobs' and 'recent' in q:
            return self.send(200, [job_json(j, v) for j, v in sorted(state['jobs'].items(), reverse=True)][:int(q['recent'][0])])
        m = re.match(r'^/api/devices/([\w-]+)/queue$', path)
        if m: return self.send(200, [entry_info(e) for e in read_queue()]) if m[1] == PROFILE['id'] else self.send(404, {'error': 'no such device'})
        m = re.match(r'^/api/devices/([\w-]+)/issues$', path)
        if m:
            issues = fake_issues()
            counts = {'flac_blocksize': len(issues)} if issues else {}
            return self.send(200, {'device': m[1], 'scope': (q.get('scope') or ['library'])[0], 'checked': 12, 'total': len(issues), 'counts': counts, 'fixable': len(issues), 'issues': issues})
        m = re.match(r'^/(?:api/)?jobs/(\d+)$', path)
        if m:
            j = state['jobs'].get(int(m[1]))
            return self.send(200, job_json(int(m[1]), j)) if j else self.send(404, {'error': 'no such job'})
        if path == '/api/search':
            albums, tracks = library()
            term = (q.get('q') or [''])[0].lower()
            flt = (q.get('filter') or ['all'])[0]
            queued = set(read_queue())
            rich = [{**a, 'queued': a['folder'] in queued, 'attention': a['artist'] == 'Single Artist', 'lyrics': {'synced': 1, 'plain': 0, 'instrumental': 0, 'none': a['tracks'] - 1}} for a in albums.values()]
            hit = [a for a in rich if (not term or term in a['artist'].lower() or term in a['album'].lower()) and (flt == 'all' or (flt == 'queued' and a['queued']) or (flt == 'attention' and a['attention']) or (flt == 'lyrics_none' and a['lyrics']['synced'] == 0))]
            out = {'albums': hit[:int((q.get('limit') or [50])[0])], 'total': len(hit), 'counts': {'all': len(rich), 'attention': 1, 'nocover': 0, 'lyrics_some': 2, 'lyrics_none': 0, 'queued': len(queued)},
                   'coverage': {'tracks': 12, 'synced': 5, 'plain': 2, 'instrumental': 1, 'none': 4}}
            if term: out['tracks'] = [t for t in tracks.values() if term in t['title'].lower() or term in t['artist'].lower()][:30]
            return self.send(200, out)
        m = re.match(r'^/api/albums/(\w+)$', path)
        if m:
            albums, tracks = library()
            a = albums.get(m[1])
            if not a: return self.send(404, {'error': 'no such album'})
            ts = sorted((t for t in tracks.values() if t['album_id'] == a['id']), key=lambda t: t['track'])
            states = ['synced', 'missing', 'plain', 'instrumental']
            ts = [{**t, 'lyrics': states[i % 4], 'instrumental_marked': states[i % 4] == 'instrumental', 'instrumental_lrclib': False} for i, t in enumerate(ts)]
            return self.send(200, {**a, 'tracks': ts})
        if path == '/api/tracks':
            p = (q.get('path') or [''])[0]
            _, tracks = library()
            t = tracks.get(ident(p))
            return self.send(200, t) if t else self.send(404, {'error': 'no such track'})
        m = re.match(r'^/api/tracks/(\w+)/stream$', path)
        if m:
            _, tracks = library()
            if m[1] not in tracks: return self.send(404, {'error': 'no such track'})
            rng = re.match(r'^bytes=(\d+)-(\d*)$', self.headers.get('Range') or '')
            if rng:
                a, b = int(rng[1]), int(rng[2] or len(WAV) - 1)
                return self.send(206, WAV[a:b + 1], 'audio/wav', {'Content-Range': f'bytes {a}-{b}/{len(WAV)}', 'Accept-Ranges': 'bytes'})
            return self.send(200, WAV, 'audio/wav', {'Accept-Ranges': 'bytes'})
        if path.startswith('/cover/'): return self.send(200, PNG, 'image/png')
        m = re.match(r'^/upload/([0-9a-f]{16})$', path)
        if m:
            man = manifest(m[1])
            return self.send(200, {'batch': m[1], 'files': man['files'], 'have': have(m[1], man), 'name': man['name']}) if man else self.send(404, {'error': 'unknown upload'})
        self.send(404, {'error': 'not found'})

    def do_POST(self):
        if not self.authed(): return
        path, q = self.route()
        log(f'POST {self.path}')
        if path == '/upload/start':
            body = self.json_body()
            files, kept = body.get('files') or [], []
            for f in files:
                p, size = clean(f.get('path')), int(f.get('size') or 0)
                if p and 0 < size <= 4_000_000_000: kept.append({'path': p, 'size': size, 'sha256': f.get('sha256')})
            if not kept: return self.send(400, {'error': 'No music files in what you chose'})
            key = hashlib.sha1(json.dumps(sorted((f['path'], f['size']) for f in kept)).encode()).hexdigest()
            for b in os.listdir(STAGE):
                man = manifest(b)
                if man and man.get('key') == key:
                    log(f'resumed {b}')
                    return self.send(200, {'batch': b, 'files': [{'path': f['path'], 'size': f['size']} for f in man['files']], 'have': have(b, man), 'resumed': True, 'skipped': len(files) - len(kept)})
            name = re.sub(r'[\\/:*?"<>|]+', ' ', (body.get('name') or '').strip()).strip(' .')[:120] or time.strftime('Upload %Y-%m-%d %H%M')
            b = secrets.token_hex(8)
            os.makedirs(os.path.join(STAGE, b, 'files'))
            json.dump({'name': name, 'key': key, 'files': kept, 'created': time.time()}, open(os.path.join(STAGE, b, 'manifest.json'), 'w'))
            return self.send(200, {'batch': b, 'files': [{'path': f['path'], 'size': f['size']} for f in kept], 'have': [0] * len(kept), 'resumed': False, 'skipped': len(files) - len(kept)})
        m = re.match(r'^/upload/([0-9a-f]{16})/finish$', path)
        if m:
            man = manifest(m[1])
            if not man: return self.send(404, {'error': 'That upload is gone.'})
            got = have(m[1], man)
            short = [f['path'] for f, h in zip(man['files'], got) if h != f['size']]
            if short: return self.send(409, {'error': f'{len(short)} file(s) are not complete yet', 'incomplete': short})
            bad = []
            if CORRUPT_ONCE and not state['corrupted']:
                for f in man['files']:
                    if f.get('sha256'):
                        with open(os.path.join(STAGE, m[1], 'files', f['path']), 'r+b') as fh: b0 = fh.read(1); fh.seek(0); fh.write(bytes([b0[0] ^ 0xFF]))
                        state['corrupted'] = True
                        break
            for f in man['files']:
                if f.get('sha256'):
                    digest = hashlib.sha256(open(os.path.join(STAGE, m[1], 'files', f['path']), 'rb').read()).hexdigest()
                    if digest != f['sha256']: bad.append(f['path'])
            if bad:
                for p in bad: os.remove(os.path.join(STAGE, m[1], 'files', p))
                log(f'bad checksum {bad}')
                return self.send(409, {'error': 'a checksum did not match', 'bad': bad})
            name, n = man['name'], 2
            while os.path.exists(os.path.join(INBOX, name)): name = f"{man['name']} {n}"; n += 1
            os.rename(os.path.join(STAGE, m[1], 'files'), os.path.join(INBOX, name))
            shutil.rmtree(os.path.join(STAGE, m[1]), ignore_errors=True)
            tracks = sum(1 for f in man['files'] if f['path'].lower().endswith(('.flac', '.mp3', '.m4a')))
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'kind': 'upload-import', 'polls': 0, 'tracks': tracks, 'name': name}
            log(f'finish {name} job={jid}')
            return self.send(200, {'job': jid})
        m = re.match(r'^/api/devices/([\w-]+)/fix$', path)
        if m:
            body = self.json_body()
            paths = body.get('paths') or [i['path'] for i in fake_issues()]
            jid = state['next_job']; state['next_job'] += 1
            run = 'flacblocks-test-' + secrets.token_hex(2)
            state['jobs'][jid] = {'kind': 'flac-fix', 'polls': 0, 'paths': paths, 'run': run}
            log(f'fix job={jid} paths={len(paths)}')
            return self.send(200, {'job': jid, 'run': run})
        m = re.match(r'^/api/devices/([\w-]+)/queue(/complete)?$', path)
        if m:
            entries = self.json_body().get('entries') or []
            cur = read_queue()
            if m[2]:
                done = [e for e in entries if e in cur]
                with open(DONE, 'a', encoding='utf-8') as f: f.write(''.join(e + '\n' for e in done))
                write_queue([e for e in cur if e not in done])
                return self.send(200, {'completed': done, 'not_in_queue': [e for e in entries if e not in cur], 'left': len(cur) - len(done)})
            add = [e for e in entries if e not in cur and os.path.exists(os.path.join(LIB, e))]
            write_queue(cur + add)
            return self.send(200, {'added': add, 'already': [e for e in entries if e in cur], 'unknown': [e for e in entries if not os.path.exists(os.path.join(LIB, e))]})
        m = re.match(r'^/api/needs/(imp-\w+-\w+|names|covers|dap)/later$', path)
        if m:
            on = bool(self.json_body().get('on'))
            for n in NEEDS:
                if n['id'] == m[1]: n['later'] = on
            return self.send(200, {'id': m[1], 'later': on})
        m = re.match(r'^/api/needs/imports/(\w+)/(\w+)/(search|apply|asis)$', path)
        if m:
            a = INBOX_ALBUMS.get((m[1], m[2]))
            if not a: return self.send(404, {'error': 'no such album'})
            body = self.json_body()
            if m[3] == 'search':
                state['lookups'][(m[1], m[2])] = {'polls': 0, 'query': body.get('query')}
                return self.send(200, {'job': 2, 'status': 'queued', 'error': None, 'recommendation': None, 'candidates': None})
            needs = [n for n in (a['needs_asis'] if m[3] == 'asis' else candidate(m[2])['needs'])]
            eng = body.get('english') or {}
            missing = [{'kind': n['kind'], 'name': n['name']} for n in needs if not (eng.get(n['kind']) or '').strip()]
            if missing: return self.send(400, {'error': 'Fill in the English names first: they decide the folder and what Navidrome shows.', 'needs': missing})
            state['english'].append(eng)
            log(f'{m[3]} {m[1]}/{m[2]} english={json.dumps(eng, ensure_ascii=False)} candidate={body.get("candidate")}')
            jid = state['next_job']; state['next_job'] += 1
            artist, album = (eng.get('artist') or a['artist']), (eng.get('album') or a['album'])
            state['jobs'][jid] = {'kind': 'import-mb' if m[3] == 'apply' else 'import-asis', 'polls': 0, 'artist': artist, 'album': album}
            return self.send(200, {'job': jid} if m[3] == 'apply' else {'job': jid, 'folder': f'{artist}/{album}/', 'queued_for_dap': True})
        if path == '/api/names':
            renames = self.json_body().get('renames') or []
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'kind': 'names', 'polls': 0, 'renames': renames}
            log(f'names {json.dumps(renames, ensure_ascii=False)}')
            return self.send(200, {'job': jid, 'run': 'names-test'})
        m = re.match(r'^/api/history/([\w.-]+)/undo$', path)
        if m:
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'kind': 'undo', 'polls': 0, 'result': {'lines': [f'reverted 7 files (28 fields) as run revert-{m[1]}']}}
            log(f'undo {m[1]} force={self.json_body().get("force")}')
            return self.send(200, {'job': jid})
        m = re.match(r'^/api/(tracks/\w+/lyrics|tracks/\w+/instrumental|albums/\w+/instrumental|albums/\w+/lyrics/lookup|covers/\w+)$', path)
        if m:
            body = self.json_body() if 'json' in (self.headers.get('Content-Type') or '') else {'image_bytes': len(self.body())}
            kind = 'lyrics' if 'lyrics' in m[1] and 'lookup' not in m[1] else 'lyrics-lookup' if 'lookup' in m[1] else 'cover' if m[1].startswith('covers') else 'instrumental'
            result = {'run': 'lyrics-test', 'action': 'paste', 'kind': 'synced', 'lines': 3, 'removed': []} if kind == 'lyrics' else {'found': 2} if kind == 'lyrics-lookup' else {'run': 'cover-test', 'folder': 'x', 'path': 'x/cover.jpg', 'size': [600, 600], 'bytes': 1000, 'replaced': []} if kind == 'cover' else {}
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'kind': kind, 'polls': 0, 'result': result, 'run': result.get('run')}
            log(f'{kind} {m[1]} {json.dumps(body)[:120]}')
            return self.send(200, {'job': jid, **({'tracks': 2} if 'albums' in m[1] and 'instrumental' in m[1] else {})})
        m = re.match(r'^/api/health/(split|variants|multi|unknown)$', path)
        if m:
            body = self.json_body()
            jid = state['next_job']; state['next_job'] += 1
            run = None if m[1] == 'variants' else 'fix-test'
            state['jobs'][jid] = {'kind': 'tag-fix', 'polls': 0, 'result': {'run': run, 'summary': '28 field changes across 7 files'}, 'run': run}
            log(f'health {m[1]} {json.dumps(body, ensure_ascii=False)[:200]}')
            return self.send(200, {'job': jid, 'run': run})
        if path == '/api/health/unignore':
            body = self.json_body()
            log(f'unignore {json.dumps(body)}')
            if body.get('id') not in state['ignored']: return self.send(404, {'error': 'that is not ignored'})
            state['ignored'].discard(body.get('id'))
            return self.send(200, {'id': body.get('id'), 'ignored': False})
        if path == '/api/health/ignore':
            body = self.json_body()
            log(f'ignore {json.dumps(body)}')
            state['ignored'].add(body.get('id') or '')
            return self.send(200, {'id': body.get('id'), 'ignored': True})
        m = re.match(r'^/api/devices/([\w-]+)/queue/new$', path)
        if m: return self.send(200, sample('POST /api/devices/{id}/queue/new'))
        if path == '/api/sync-log':
            body = self.json_body()
            if body.get('result') not in ('finished', 'failed', 'cancelled'): return self.send(400, {'error': 'result must be finished, failed or cancelled'})
            row = {k: body[k] for k in ('ts', 'mode', 'result', 'copied', 'removed', 'seconds', 'mac', 'rsync', 'app', 'detail') if k in body}
            with open(SYNCLOG, 'a', encoding='utf-8') as f: f.write(json.dumps(row, ensure_ascii=False) + '\n')
            return self.send(200, {'ok': True})
        self.send(404, {'error': 'not found'})

    def do_DELETE(self):
        if not self.authed(): return
        path, q = self.route()
        log(f'DELETE {self.path}')
        m = re.match(r'^/upload/([0-9a-f]{16})$', path)
        if m:
            shutil.rmtree(os.path.join(STAGE, m[1]), ignore_errors=True)
            self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers(); return
        m = re.match(r'^/api/tracks/(\w+)/lyrics$', path)
        if m:
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'kind': 'lyrics', 'polls': 0, 'result': {'run': 'lyrics-rm-test', 'action': 'remove', 'removed': ['x.lrc']}, 'run': 'lyrics-rm-test'}
            return self.send(200, {'job': jid})
        m = re.match(r'^/api/devices/([\w-]+)/queue$', path)
        if m:
            entries = q.get('entry') or self.json_body().get('entries') or []
            cur = read_queue()
            write_queue([e for e in cur if e not in entries])
            return self.send(200, {'removed': [e for e in entries if e in cur], 'not_in_queue': [e for e in entries if e not in cur]})
        self.send(404, {'error': 'not found'})

    def do_PUT(self):
        if not self.authed(): return
        path, q = self.route()
        m = re.match(r'^/upload/([0-9a-f]{16})/(\d+)$', path)
        if not m: return self.send(404, {'error': 'not found'})
        b, i, offset = m[1], int(m[2]), int((q.get('offset') or ['0'])[0])
        man = manifest(b)
        n = int(self.headers.get('Content-Length') or 0)
        if not man or not 0 <= i < len(man['files']): self.rfile.read(n); return self.send(404, {'error': 'unknown upload'})
        f = man['files'][i]
        fp = os.path.join(STAGE, b, 'files', f['path'])
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        size = os.path.getsize(fp) if os.path.exists(fp) else 0
        log(f'PUT {b} file={i} offset={offset} bytes={n} have={size}')
        if SLOW: time.sleep(SLOW)
        if offset > size:
            self.rfile.read(n)
            return self.send(409, {'size': size})
        if offset + n > f['size']:
            self.rfile.read(n)
            return self.send(400, {'error': 'more data than the file’s size', 'size': size})
        cut = DROP_AFTER if DROP_AFTER and not state['dropped'] and n > DROP_AFTER else 0
        remaining = cut or n
        with open(fp, 'r+b' if os.path.exists(fp) else 'wb') as out:      # positional, like the panel
            out.seek(offset)
            while remaining > 0:
                part = self.rfile.read(min(65536, remaining))
                if not part: break
                out.write(part); remaining -= len(part)
        if cut:
            state['dropped'] = True
            log('dropped the connection')
            self.close_connection = True
            self.connection.close()
            return
        self.send(200, {'size': os.path.getsize(fp)})


ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
