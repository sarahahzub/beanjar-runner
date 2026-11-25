#!/usr/bin/env python3
# Static server for the WebOS Chromium test lab, with HTTP Range (video seeking) and POST /report (a TV without CDP
# saves its results; at most 64 KB each and 500 files, in ./reports). Binds 127.0.0.1 only; Caddy + Tailscale Funnel
# publish it at /webapp/cnlab/.   python3 serve.py PORT
import http.server, json, os, re, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
REP = os.path.join(ROOT, "reports")
TYPES = {".mp4": "video/mp4", ".webm": "video/webm", ".m4a": "audio/mp4", ".html": "text/html; charset=utf-8",
         ".js": "text/javascript; charset=utf-8", ".json": "application/json", ".css": "text/css"}


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def guess_type(self, path):
        return TYPES.get(os.path.splitext(path)[1], super().guess_type(path))

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def do_GET(self):
        path = self.translate_path(self.path.split("?")[0])
        if "/reports" in self.path or os.path.basename(path) in ("serve.py", "gen.sh"):
            return self.send_error(404)
        m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if not m or not os.path.isfile(path):
            return super().do_GET()
        size = os.path.getsize(path)
        a = int(m.group(1)) if m.group(1) else max(0, size - int(m.group(2) or 0))
        b = int(m.group(2)) if m.group(1) and m.group(2) else size - 1
        if a >= size:
            self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
        b = min(b, size - 1)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {a}-{b}/{size}")
        self.send_header("Content-Length", str(b - a + 1))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(a); left = b - a + 1
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)

    def do_POST(self):
        if self.path.split("?")[0] != "/report":
            return self.send_error(404)
        n = int(self.headers.get("Content-Length") or 0)
        os.makedirs(REP, exist_ok=True)
        if n > 65536 or len(os.listdir(REP)) >= 500:
            return self.send_error(413)
        body = self.rfile.read(n)
        try:
            json.loads(body)
        except Exception:
            return self.send_error(400)
        name = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}-{time.time_ns() % 1000000}.json"
        with open(os.path.join(REP, name), "wb") as f:
            f.write(body)
        self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers()
        self.wfile.write(name.encode())

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % a))


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
