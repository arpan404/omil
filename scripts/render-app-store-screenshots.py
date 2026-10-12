"""Serve the editable screenshot studio and save the browser's PNG exports.

python3 scripts/render-app-store-screenshots.py
Open http://127.0.0.1:4322/release/app-store/source/ and choose Export all.
"""
import http.server
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCREEN_IDS = {s['id'] for s in json.loads((ROOT / 'release/app-store/source/screens.json').read_text())}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_POST(self):
        parts = self.path.strip('/').split('/')
        if len(parts) != 3 or parts[0] != 'export' or parts[1] not in ('iphone', 'ipad') or parts[2] not in {i + '.png' for i in SCREEN_IDS}:
            self.send_error(400, 'Unknown screenshot destination')
            return
        size = int(self.headers.get('Content-Length', 0))
        if not 8 <= size <= 15_000_000:
            self.send_error(400, 'Invalid PNG size')
            return
        data = self.rfile.read(size)
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):
            self.send_error(400, 'Expected a PNG')
            return
        target = ROOT / 'release/app-store/screenshots' / parts[1] / parts[2]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        result = json.dumps({'path': str(target.relative_to(ROOT)), 'bytes': len(data)}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(result)))
        self.end_headers()
        self.wfile.write(result)


if __name__ == '__main__':
    print('Screenshot studio: http://127.0.0.1:4322/release/app-store/source/', flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', 4322), Handler).serve_forever()
