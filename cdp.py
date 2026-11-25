#!/usr/bin/env python3
# Small Chrome DevTools Protocol client for Brave inside the TV (reached through an SSH -L forward
# to the TV's 127.0.0.1:9222). Needs python3-websocket. Prints JSON.
#   cdp.py version | list
#   cdp.py gpu                      SystemInfo.getInfo (browser target)
#   cdp.py nav URL SECONDS          navigate the first page; load times, requests, blocked-by-client count
#   cdp.py eval EXPR                Runtime.evaluate in the first page (returnByValue); env CDP_MATCH=substring
#                                   picks the first page whose URL contains it
#   cdp.py ae                       focused element (through shadow roots and same-origin iframes) of every page
#                                   target that has focus (else of the visible ones), plus the test page's log
#   cdp.py pages                    page targets (type, url)
#   cdp.py tid                      id of the first tab-like page target (env CDP_TID pins page() to it)
#   cdp.py closepop                 close extension popups / WebUI bubbles
import json, os, sys, time, urllib.request
import websocket

BASE = "http://127.0.0.1:9222"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=20) as r:
        return json.loads(r.read())


def tab_like(t):
    u = t.get("url", "")
    return t.get("type") == "page" and not u.startswith("chrome-extension://") and "top-chrome" not in u


def page():
    m = os.environ.get("CDP_MATCH", "")
    tid = os.environ.get("CDP_TID", "")
    ts = get("/json/list")
    if tid and not m:
        for t in ts:
            if t.get("id") == tid:
                return t
    for t in ts:
        if tab_like(t) and m in t.get("url", ""):
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


AE = r"""(function(){function d(doc){var e=doc.activeElement;while(e&&e.shadowRoot&&e.shadowRoot.activeElement)e=e.shadowRoot.activeElement;
if(e&&e.tagName=='IFRAME'){try{return 'iframe>'+d(e.contentDocument)}catch(x){return 'iframe(cross-origin)'}}
if(!e)return 'null';var t=e.tagName.toLowerCase()+(e.id?'#'+e.id:'');
var l=((e.getAttribute&&(e.getAttribute('aria-label')||e.getAttribute('title')))||e.innerText||e.value||'').toString().replace(/\s+/g,' ').slice(0,30);
return t+(l?' "'+l+'"':'')}
var L=window.LOG||[];var st=document.getElementById('st');
return JSON.stringify({u:location.href.slice(0,60),f:document.hasFocus(),v:document.visibilityState,ae:d(document),sy:Math.round(scrollY),
log:L.slice(-2).join('; '),scr:st&&st.dataset.scr})})()"""


def ae():
    out = []
    for t in get("/json/list"):
        if t.get("type") != "page" or not t.get("webSocketDebuggerUrl"):
            continue
        try:
            c = Conn(t["webSocketDebuggerUrl"])
            c.ws.settimeout(5)
            r = c.call("Runtime.evaluate", {"expression": AE, "returnByValue": True}, 5)
            v = json.loads(r["result"]["result"]["value"])
        except Exception as e:
            v = {"u": t.get("url", "")[:60], "err": type(e).__name__}
        out.append(v)
    foc = [v for v in out if v.get("f")]
    vis = [v for v in out if v.get("v") == "visible" or v.get("err")]
    print(json.dumps({"focused": foc} if foc else {"no_focused_page": vis[:3]}))


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
    elif cmd == "ae":
        ae()
    elif cmd == "tid":
        print(next((t["id"] for t in get("/json/list") if tab_like(t)), ""))
    elif cmd == "closepop":  # close extension popups and WebUI bubbles (test set-up only)
        n = 0
        for t in get("/json/list"):
            if t.get("type") == "page" and not tab_like(t):
                urllib.request.urlopen(BASE + "/json/close/" + t["id"], timeout=10).read()
                n += 1
        print(n)
    elif cmd == "pages":
        print(json.dumps([t.get("url") for t in get("/json/list") if t.get("type") == "page"]))
    elif cmd == "eval":
        c = Conn(page()["webSocketDebuggerUrl"])
        print(json.dumps(evaluate(c, sys.argv[2])))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
