# Runs INSIDE the TV (its own python3). Times app launches against one clock (this process):
#   python3 bw.py APP_ID [N] [TARGET_URL]
# Serves bench.html on 127.0.0.1:8099; the page reports (as GET beacons) its script start, its first
# animation frame and a small JS benchmark; SAM's foreground app is polled for the launch -> foreground time.
import json, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

APP = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
TARGET = sys.argv[3] if len(sys.argv) > 3 else None
PAGE = open("/tmp/bench/index.html", "rb").read()
beacons = []

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/b":
            q = urllib.parse.parse_qs(u.query)
            beacons.append((time.time(), json.loads(q["d"][0])))
            self.send_response(204); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(PAGE)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 8099), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()

def luna(uri, body):
    return subprocess.run(["luna-send", "-n", "1", uri, json.dumps(body)], stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60).stdout.decode(errors="replace")

def fg():
    try:
        return json.loads(luna("luna://com.webos.applicationManager/getForegroundAppInfo", {})).get("appId")
    except Exception:
        return None

for i in range(1, N + 1):
    luna("luna://com.webos.applicationManager/closeByAppId", {"id": APP})
    time.sleep(6)
    del beacons[:]
    body = {"id": APP}
    if TARGET:
        body["params"] = {"target": TARGET}
    t0 = time.time()
    r = luna("luna://com.webos.applicationManager/launch", body)
    t1 = time.time()
    tfg = None; tff = None; res = None
    while time.time() - t0 < 150:
        if tfg is None and fg() == APP:
            tfg = time.time()
        for t, d in list(beacons):
            if d.get("k") == "ff" and tff is None:
                tff = d["e"] / 1000.0
            if d.get("k") == "res":
                res = d
        if tfg and tff and res:
            break
        time.sleep(0.3)
    f = lambda x: "%.2f" % (x - t0) if x else "none"
    print("run=%d app=%s launch_call_s=%.2f fg_s=%s first_frame_s=%s js=%s launch=%s" % (
        i, APP, t1 - t0, f(tfg), f(tff), json.dumps(res), r.strip()[:120]), flush=True)
srv.shutdown()
