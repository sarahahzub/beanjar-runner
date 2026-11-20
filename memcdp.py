#!/usr/bin/env python3
# CDP helper for the memory test (memtest.sh), through the SSH -L forward to the TV's 127.0.0.1:9222. Prints one JSON line.
#   memcdp.py list
#   memcdp.py nav ID|first URL MAXS     navigate; stops 5 s after the load event (or at MAXS). Navigation Timing,
#                                       requests, blocked-by-client count, crash event, page title/text
#   memcdp.py newtab URL MAXS           open a tab (about:blank), then nav in it; prints its "id"
#   memcdp.py video ID SRC SECS         a <video> page (data: URL) playing SRC; state after SECS
#   memcdp.py youtube ID URL SECS       navigate, wait SECS, report video element / bot check (never clicks)
#   memcdp.py tabs                      every page tab: does it answer (20 s), href, title, wasDiscarded
import json, sys, time, urllib.parse, urllib.request
import websocket

BASE = "http://127.0.0.1:9222"


def get(path, method="GET"):
    req = urllib.request.Request(BASE + path, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def pages():
    return [t for t in get("/json/list") if t.get("type") == "page"]


def target(tid):
    ps = pages()
    if not ps:
        raise SystemExit(json.dumps({"error": "no page target"}))
    if tid == "first":
        return ps[0]
    for t in ps:
        if t["id"] == tid:
            return t
    raise SystemExit(json.dumps({"error": "target gone " + tid}))


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
            try:
                m = json.loads(self.ws.recv())
            except websocket.WebSocketTimeoutException:
                break
            if m.get("id") == mid:
                return m
            self.events.append((time.time(), m))
        return {"error": "timeout " + method}

    def pump_until(self, secs, stop):
        end = time.time() + secs
        while time.time() < end:
            self.ws.settimeout(max(0.5, min(2, end - time.time())))
            try:
                self.events.append((time.time(), json.loads(self.ws.recv())))
            except websocket.WebSocketTimeoutException:
                pass
            if stop():
                break


def evaluate(c, expr, timeout=60):
    r = c.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True}, timeout)
    v = r.get("result", {}).get("result", {}).get("value")
    return v if v is not None else {"eval_error": str(r)[:200]}


NAVT = ("(function(){var n=performance.getEntriesByType('navigation')[0]||{};"
        "var t=(document.body?document.body.innerText:'');return JSON.stringify({href:location.href,title:document.title,"
        "ready:document.readyState,loadEventEnd_ms:Math.round(n.loadEventEnd||0),dcl_ms:Math.round(n.domContentLoadedEventEnd||0),"
        "bot:/not a bot|confirm you|unusual traffic/i.test(t),text:t.slice(0,120)})})()")


def jparse(v):
    try:
        return json.loads(v)
    except Exception:
        return v


def nav(t, url, secs):
    c = Conn(t["webSocketDebuggerUrl"])
    for m in ("Page.enable", "Network.enable", "Inspector.enable"):
        c.call(m)
    t0 = time.time()
    r = c.call("Page.navigate", {"url": url}, 90)
    loaded = []

    def stop():
        if not loaded:
            for tt, m in c.events:
                if m.get("method") == "Page.loadEventFired":
                    loaded.append(tt)
                    break
        return (loaded and time.time() > loaded[0] + 5) or any(
            m.get("method") == "Inspector.targetCrashed" for _, m in c.events)
    c.pump_until(secs, stop)
    ev = c.events
    first = lambda name: next((round(tt - t0, 1) for tt, m in ev if m.get("method") == name), None)
    failed = [m["params"] for _, m in ev if m.get("method") == "Network.loadingFailed"]
    crashed = any(m.get("method") == "Inspector.targetCrashed" for _, m in ev)
    info = {} if crashed else jparse(evaluate(c, NAVT, 30))
    return {"id": t["id"], "url": url[:80], "navigate": r.get("result", r.get("error")),
            "loadEventFired_s": first("Page.loadEventFired"), "crashed": crashed,
            "requests": sum(1 for _, m in ev if m.get("method") == "Network.requestWillBeSent"),
            "blocked_by_client": sum(1 for f in failed if "BLOCKED_BY_CLIENT" in (f.get("errorText") or "")),
            "page": info}


def main():
    cmd = sys.argv[1]
    if cmd == "list":
        print(json.dumps([{k: t.get(k) for k in ("id", "type", "title", "url")} for t in get("/json/list")]))
    elif cmd == "nav":
        print(json.dumps(nav(target(sys.argv[2]), sys.argv[3], float(sys.argv[4]))))
    elif cmd == "newtab":
        t = get("/json/new?about:blank", "PUT")
        time.sleep(2)
        print(json.dumps(nav(t, sys.argv[2], float(sys.argv[3]))))
    elif cmd == "video":
        src, secs = sys.argv[3], float(sys.argv[4])
        html = ('<body style="margin:0;background:black"><video id="v" src="%s" autoplay muted loop '
                'style="width:100%%;height:100%%"></video></body>' % src)
        r = nav(target(sys.argv[2]), "data:text/html," + urllib.parse.quote(html), 30)
        c = Conn(target(sys.argv[2])["webSocketDebuggerUrl"])
        time.sleep(secs)
        r["video"] = jparse(evaluate(c, "(function(){var v=document.getElementById('v');if(!v)return '{}';"
                                        "var q=v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():{};return JSON.stringify({"
                                        "paused:v.paused,t:Math.round(v.currentTime*10)/10,rs:v.readyState,w:v.videoWidth,h:v.videoHeight,"
                                        "err:v.error&&v.error.code,dropped:q.droppedVideoFrames,total:q.totalVideoFrames})})()", 30))
        print(json.dumps(r))
    elif cmd == "youtube":
        url, secs = sys.argv[3], float(sys.argv[4])
        r = nav(target(sys.argv[2]), url, secs)
        c = Conn(target(sys.argv[2])["webSocketDebuggerUrl"])
        r["video"] = jparse(evaluate(c, "(function(){var v=document.querySelector('video');var t=(document.body||{}).innerText||'';"
                                        "return JSON.stringify({video:!!v,paused:v&&v.paused,t:v&&v.currentTime,rs:v&&v.readyState,"
                                        "bot:/not a bot|confirm you|unusual traffic/i.test(t),href:location.href})})()", 30))
        print(json.dumps(r))
    elif cmd == "tabs":
        out = []
        for t in pages():
            try:
                c = Conn(t["webSocketDebuggerUrl"])
                v = jparse(evaluate(c, "JSON.stringify({href:location.href.slice(0,60),title:document.title.slice(0,40),"
                                       "discarded:!!document.wasDiscarded})", 20))
                out.append(v if isinstance(v, dict) else {"answer": False, "url": t.get("url", "")[:60], "r": str(v)[:80]})
            except Exception as e:
                out.append({"answer": False, "url": t.get("url", "")[:60], "err": type(e).__name__})
        print(json.dumps({"tabs": len(out), "unresponsive": sum(1 for o in out if o.get("answer") is False),
                          "discarded": sum(1 for o in out if o.get("discarded")), "list": out}))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    print(json.dumps({"error": f"{type(e).__name__}: {e}"[:300]}))
