"""Screenshot test for a dedicated Android emulator. Requires Pillow 11.3.0.

Build test/support/android_bitmap_harness.dart explicitly before running.
Never install the harness APK on a user device or publish it as the app.
"""
import argparse
import http.server, io, json, pathlib, subprocess, threading, time
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
parser.add_argument('--apk', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
if not args.serial.startswith('emulator-'):
    parser.error('Use a dedicated disposable emulator, never a physical phone')
root = pathlib.Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
adb = ['adb', '-s', args.serial]
fixture = (root / 'test/fixtures/subtitles/synthetic-pgs.mkv').read_bytes()
masks = {name: (root / ('test/fixtures/subtitles/expected-PGS-' + name.upper() + '.mask')).read_bytes() for name in ['alpha', 'beta']}
results = []
finished = threading.Event()

def run(*args, **kwargs):
    return subprocess.run(adb + list(args), check=True, **kwargs)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path != '/synthetic-pgs.mkv':
            self.send_error(404); return
        start, end, status = 0, len(fixture) - 1, 200
        header = self.headers.get('Range')
        if header:
            lo, hi = header.removeprefix('bytes=').split('-')
            start, end, status = int(lo), min(int(hi) if hi else end, end), 206
        self.send_response(status)
        self.send_header('Content-Type', 'video/x-matroska')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if status == 206: self.send_header('Content-Range', f'bytes {start}-{end}/{len(fixture)}')
        self.end_headers()
        self.wfile.write(fixture[start:end + 1])
    def do_POST(self):
        if self.headers.get('Transfer-Encoding') == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().strip().split(b';')[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                assert self.rfile.read(2) == b'\r\n'
            body = b''.join(chunks)
        else:
            body = self.rfile.read(int(self.headers['Content-Length']))
        value = json.loads(body)
        status = 200
        terminal = False
        try:
            if value['stage'] in ['complete', 'failed']:
                terminal = True
            else:
                png = run('exec-out', 'screencap', '-p', capture_output=True).stdout
                (out / (value['stage'] + '.png')).write_bytes(png)
                im = Image.open(io.BytesIO(png)).convert('RGB')
                scale = im.width / value['screenWidth']
                assert abs(scale - 1) < .01, (im.size, value)
                x0, y0 = round((im.width - 320) / 2), round((im.height - 180) / 2)
                video = im.crop((x0, y0, x0 + 320, y0 + 180))
                expected = value['expected']
                if expected in masks:
                    mask = masks[expected]
                    errors = 0
                    for y in range(180):
                        for x in range(320):
                            white = 70 <= x < 250 and 140 <= y < 164 and mask[(y - 140) * 180 + x - 70]
                            pixel = video.getpixel((x, y))
                            if (min(pixel) < 230 if white else max(pixel) > 20): errors += 1
                    assert errors == 0, ('pixel mismatch', errors)
                    assert value['visibility'] == 'yes' and not value['text'].strip()
                elif expected == 'off':
                    assert max(video.getextrema()[i][1] for i in range(3)) <= 20
                    assert value['sid'] == 'no' and value['visibility'] == 'no'
                else:
                    # Small Flutter glyphs are antialiased and need not contain solid white pixels.
                    white = sum(min(p) > 64 and max(p) - min(p) < 15 for p in video.getdata())
                    assert white > 20, ('missing Flutter text pixels', white)
                    assert value['visibility'] == 'no' and value['text'].strip() in ['TEXT_CUE', 'EXTERNAL_CUE']
                value['screenshotPixels'] = 'PASSED'
        except Exception as error:
            value['failure'] = str(error)
            status = 500
            terminal = True
        results.append(value)
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        print(json.dumps({key: item for key, item in value.items() if key != 'nativeLogs'}), flush=True)
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()
        if terminal: finished.set()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 38765), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    run('reverse', 'tcp:38765', 'tcp:38765')
    run('shell', 'wm', 'size', '640x360')
    run('shell', 'wm', 'density', '160')
    run('shell', 'settings', 'put', 'secure', 'immersive_mode_confirmations', 'confirmed')
    run('install', '-r', str(args.apk.resolve()))
    run('shell', 'am', 'force-stop', 'com.jsdfhasuh.emoemby')
    component = run('shell', 'cmd', 'package', 'resolve-activity', '--brief', 'com.jsdfhasuh.emoemby', capture_output=True, text=True).stdout.strip().splitlines()[-1]
    assert component.startswith('com.jsdfhasuh.emoemby/')
    run('shell', 'am', 'start', '-n', component)
    if not finished.wait(180): raise RuntimeError('Harness did not finish')
    assert results[-1]['stage'] == 'complete' and len(results) == 33, results[-1]
    print('ANDROID_FLUTTER_TEXTURE_SCREENSHOTS=PASSED frames=32')
finally:
    server.shutdown()
    run('reverse', '--remove', 'tcp:38765')
