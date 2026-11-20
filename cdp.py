#!/usr/bin/env python3
# Small Chrome DevTools Protocol client for Brave inside the TV (reached through an SSH -L forward
# to the TV's 127.0.0.1:9222). Needs python3-websocket. Prints JSON.
#   cdp.py version | list
#   cdp.py gpu                      SystemInfo.getInfo (browser target)
#   cdp.py nav URL SECONDS          navigate the first page; load times, requests, blocked-by-client count
#   cdp.py eval EXPR                Runtime.evaluate in the first page (returnByValue)
import json, sys, time, urllib.request
import websocket

BASE = "http://127.0.0.1:9222"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=20) as r:
        return json.loads(r.read())


def page():
    for t in get("/json/list"):
        if t.get("type") == "page":
            return t
    raise SystemExit(json.dumps({"error": "no page target"}))


class Conn:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, timeout=30, suppress_origin=True)
        self.n = 0
        self.events = []

    def call(self, method, params=None, timeout=60):
        self.n += 1
        mid = self.n
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            self.ws.settimeout(max(1, end - time.time()))
            m = json.loads(self.ws.recv())
            if m.get("id") == mid:
                return m
            self.events.append((time.time(), m))
        return {"error": "timeout " + method}

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            self.ws.settimeout(max(0.5, end - time.time()))
            try:
                self.events.append((time.time(), json.loads(self.ws.recv())))
            except websocket.WebSocketTimeoutException:
                break


def evaluate(c, expr):
    r = c.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True}, 60)
    return r.get("result", {}).get("result", {}).get("value", r)


def main():
    cmd = sys.argv[1]
    if cmd == "version":
        print(json.dumps(get("/json/version")))
    elif cmd == "list":
        print(json.dumps([{k: t.get(k) for k in ("type", "title", "url")} for t in get("/json/list")]))
    elif cmd == "gpu":
        c = Conn(get("/json/version")["webSocketDebuggerUrl"])
        r = c.call("SystemInfo.getInfo", timeout=90).get("result", {})
        g = r.get("gpu", {})
        print(json.dumps({"devices": g.get("devices"), "featureStatus": g.get("featureStatus"),
                          "driverBugWorkarounds": (g.get("driverBugWorkarounds") or [])[:20],
                          "auxAttributes": {k: v for k, v in (g.get("auxAttributes") or {}).items()
                                            if k in ("glRenderer", "glVendor", "glVersion", "glImplementationParts",
                                                     "eglVersion", "displayType", "softwareRendering")},
                          "modelName": r.get("modelName"), "commandLine": (r.get("commandLine") or "")[:200]}))
    elif cmd == "nav":
        url, secs = sys.argv[2], float(sys.argv[3])
        c = Conn(page()["webSocketDebuggerUrl"])
        for m in ("Page.enable", "Network.enable"):
            c.call(m)
        t0 = time.time()
        r = c.call("Page.navigate", {"url": url}, 90)
        c.pump(secs)
        ev = c.events
        first = lambda name: next((round(t - t0, 1) for t, m in ev if m.get("method") == name), None)
        reqs = sum(1 for _, m in ev if m.get("method") == "Network.requestWillBeSent")
        failed = [m["params"] for _, m in ev if m.get("method") == "Network.loadingFailed"]
        blocked = [f for f in failed if "BLOCKED_BY_CLIENT" in (f.get("errorText") or "")]
        info = evaluate(c, "JSON.stringify({href:location.href,title:document.title,ready:document.readyState,"
                           "text:(document.body?document.body.innerText:'').slice(0,300)})")
        try:
            info = json.loads(info)
        except Exception:
            pass
        print(json.dumps({"url": url, "navigate": r.get("result", r.get("error")),
                          "domContentEventFired_s": first("Page.domContentEventFired"),
                          "loadEventFired_s": first("Page.loadEventFired"),
                          "requests": reqs, "failed": len(failed), "blocked_by_client": len(blocked),
                          "blocked_sample": [b.get("errorText") for b in blocked[:3]], "page": info}))
    elif cmd == "eval":
        c = Conn(page()["webSocketDebuggerUrl"])
        print(json.dumps(evaluate(c, sys.argv[2])))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
