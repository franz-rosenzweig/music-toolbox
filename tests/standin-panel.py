#!/usr/bin/env python3
"""A stand-in for the music panel's /upload routes (app/routes/upload.py), for the app's self-test.
Same chunk protocol, same answers, a job card shaped like the panel's, test credentials only.

  standin-panel.py PORT ROOT [--drop-after BYTES] [--slow SECONDS] [--needs-look N]

--drop-after   once, cut the connection after that many bytes of a chunk (the app must resume)
--slow         wait that long before answering each chunk (so a test can pause mid-upload)
--needs-look   report this many tracks as left for review
The test login is test / test-password. ROOT/stage holds batches, ROOT/inbox the finished folders,
ROOT/log.txt every request."""
import base64, hashlib, json, os, re, secrets, shutil, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, root = int(sys.argv[1]), sys.argv[2]
args = sys.argv[3:]
opt = lambda name, default: type(default)(args[args.index(name) + 1]) if name in args else default
DROP_AFTER, SLOW, NEEDS_LOOK = opt('--drop-after', 0), opt('--slow', 0.0), opt('--needs-look', 0)
STAGE, INBOX = os.path.join(root, 'stage'), os.path.join(root, 'inbox')
for d in (STAGE, INBOX): os.makedirs(d, exist_ok=True)
AUTH = 'Basic ' + base64.b64encode(b'test:test-password').decode()
ALLOWED = ('.flac', '.mp3', '.m4a', '.ogg', '.opus', '.wav', '.aiff', '.aif', '.wma', '.ape', '.wv', '.alac',
           '.lrc', '.txt', '.jpg', '.jpeg', '.png', '.webp', '.cue', '.log')
lock = threading.Lock()
state = {'dropped': False, 'jobs': {}, 'next_job': 1}


def log(line):
    with lock, open(os.path.join(root, 'log.txt'), 'a') as f: f.write(line + '\n')


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


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass

    def send(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else (json.dumps(body) if ctype == 'application/json' else body).encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(data))); self.end_headers()
        self.wfile.write(data)

    def authed(self):
        if self.headers.get('Authorization') == AUTH: return True
        self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="music"'); self.send_header('Content-Length', '0'); self.end_headers()
        return False

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n)

    def do_GET(self):
        if not self.authed(): return
        log(f'GET {self.path}')
        if self.path == '/healthz': return self.send(200, {'ok': True})
        m = re.match(r'^/upload/([0-9a-f]{16})$', self.path)
        if m:
            man = manifest(m[1])
            return self.send(200, {'batch': m[1], 'files': man['files'], 'have': have(m[1], man), 'name': man['name']}) if man else self.send(404, {'error': 'unknown upload'})
        m = re.match(r'^/jobs/(\d+)$', self.path)
        if m:
            j = state['jobs'].get(int(m[1]))
            if not j: return self.send(404, 'No such job', 'text/plain')
            j['polls'] += 1
            return self.send(200, card(int(m[1]), j), 'text/html')
        self.send(404, {'error': 'not found'})

    def do_POST(self):
        if not self.authed(): return
        log(f'POST {self.path}')
        if self.path == '/upload/start':
            body = json.loads(self.body() or b'{}')
            files, kept = body.get('files') or [], []
            for f in files:
                p, size = clean(f.get('path')), int(f.get('size') or 0)
                if p and 0 < size <= 4_000_000_000: kept.append({'path': p, 'size': size})
            if not kept: return self.send(400, {'error': 'No music files in what you chose'})
            key = hashlib.sha1(json.dumps(sorted((f['path'], f['size']) for f in kept)).encode()).hexdigest()
            for b in os.listdir(STAGE):
                man = manifest(b)
                if man and man.get('key') == key:
                    log(f'resumed {b}')
                    return self.send(200, {'batch': b, 'files': man['files'], 'have': have(b, man), 'resumed': True, 'skipped': len(files) - len(kept)})
            name = re.sub(r'[\\/:*?"<>|]+', ' ', (body.get('name') or '').strip()).strip(' .')[:120] or time.strftime('Upload %Y-%m-%d %H%M')
            b = secrets.token_hex(8)
            os.makedirs(os.path.join(STAGE, b, 'files'))
            json.dump({'name': name, 'key': key, 'files': kept, 'created': time.time()}, open(os.path.join(STAGE, b, 'manifest.json'), 'w'))
            return self.send(200, {'batch': b, 'files': kept, 'have': [0] * len(kept), 'resumed': False, 'skipped': len(files) - len(kept)})
        m = re.match(r'^/upload/([0-9a-f]{16})/finish$', self.path)
        if m:
            man = manifest(m[1])
            if not man: return self.send(200, '<div class="callout red">That upload is gone.</div>', 'text/html')
            short = [f['path'] for f, h in zip(man['files'], have(m[1], man)) if h != f['size']]
            if short: return self.send(200, f'<div class="callout red">{len(short)} file(s) aren’t complete yet.</div>', 'text/html')
            name, n = man['name'], 2
            while os.path.exists(os.path.join(INBOX, name)): name = f"{man['name']} {n}"; n += 1
            os.rename(os.path.join(STAGE, m[1], 'files'), os.path.join(INBOX, name))
            shutil.rmtree(os.path.join(STAGE, m[1]), ignore_errors=True)
            tracks = sum(1 for f in man['files'] if f['path'].lower().endswith(('.flac', '.mp3', '.m4a')))
            jid = state['next_job']; state['next_job'] += 1
            state['jobs'][jid] = {'polls': 0, 'tracks': tracks, 'name': name}
            log(f'finish {name} job={jid}')
            return self.send(200, card(jid, state['jobs'][jid]), 'text/html')
        self.send(404, {'error': 'not found'})

    def do_PUT(self):
        if not self.authed(): return
        m = re.match(r'^/upload/([0-9a-f]{16})/(\d+)\?offset=(\d+)$', self.path)
        if not m: return self.send(404, {'error': 'not found'})
        b, i, offset = m[1], int(m[2]), int(m[3])
        man = manifest(b)
        if not man or not 0 <= i < len(man['files']): self.body(); return self.send(404, {'error': 'unknown upload'})
        f = man['files'][i]
        path = os.path.join(STAGE, b, 'files', f['path'])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        n = int(self.headers.get('Content-Length') or 0)
        log(f'PUT {b} file={i} offset={offset} bytes={n} have={size}')
        if SLOW: time.sleep(SLOW)
        if offset != size:
            self.rfile.read(n)
            return self.send(409, {'size': size})
        cut = DROP_AFTER if DROP_AFTER and not state['dropped'] and n > DROP_AFTER else 0
        remaining = cut or n
        with open(path, 'ab') as out:
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
        self.send(200, {'size': os.path.getsize(path)})

    def do_DELETE(self):
        if not self.authed(): return
        m = re.match(r'^/upload/([0-9a-f]{16})$', self.path)
        if m: shutil.rmtree(os.path.join(STAGE, m[1]), ignore_errors=True)
        log(f'DELETE {self.path}')
        self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers()


def card(jid, j):
    if j['polls'] < 2:
        return f'<div class="job" id="job-{jid}" hx-get="/jobs/{jid}" hx-trigger="load delay:1s" hx-swap="outerHTML"><div class="jt">Import</div></div>'
    left = min(NEEDS_LOOK, j['tracks'])
    if left:
        text = f'{j["tracks"] - left} of {j["tracks"]} tracks matched MusicBrainz and are in the library. {left} track{"s" if left != 1 else ""} need a look: <a href="/">review them</a>.'
        return f'<div class="job ok" id="job-{jid}"><div class="callout amber">{text}</div></div>'
    return f'<div class="job ok" id="job-{jid}"><div class="callout green">All {j["tracks"]} tracks matched MusicBrainz and are in the library, queued for the DAP.</div></div>'


ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
