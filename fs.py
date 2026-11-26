#!/usr/bin/env python3
# Fullscreen check for WebOS Chromium issue #39 (fullscreen ends by itself a few seconds after it starts). Talks CDP
# to the browser through the SSH forward to the TV's 127.0.0.1:9222. Prints one JSON line.
#   fs.py HOW SECONDS
#   HOW: window   Browser.setWindowBounds windowState=fullscreen (what F11 and the menu's fullscreen button do)
#        key      an F11 key press sent to the page (goes through the browser's accelerators if the page skips it)
#        element  document.documentElement.requestFullscreen() with a user gesture (a site's or video's fullscreen)
# Every second: the browser window's state and size (Browser.getWindowBounds) and the page's view (inner size,
# fullscreenElement, visibility, focus), timed by this script's wall clock (page timers are not used).
import json, sys, time
sys.path.insert(0, "/w")
from cdp import Conn, get, page, evaluate

how, secs = sys.argv[1], float(sys.argv[2])
p = page()
pc = Conn(p["webSocketDebuggerUrl"])
bc = Conn(get("/json/version")["webSocketDebuggerUrl"])
w = bc.call("Browser.getWindowForTarget", {"targetId": p["id"]})
wid = w.get("result", {}).get("windowId")

LISTEN = """(()=>{window.FSL=[];const t0=Date.now();const a=(e)=>FSL.push(((Date.now()-t0)/1000).toFixed(1)+' '+e);
document.addEventListener('fullscreenchange',()=>a('fullscreenchange fs='+!!document.fullscreenElement));
document.addEventListener('fullscreenerror',()=>a('fullscreenerror'));
document.addEventListener('visibilitychange',()=>a('visibility '+document.visibilityState));
addEventListener('resize',()=>a('resize '+innerWidth+'x'+innerHeight));
addEventListener('blur',()=>a('blur'));addEventListener('focus',()=>a('focus'));return 'ok'})()"""
VIEW = ("JSON.stringify({i:innerWidth+'x'+innerHeight,fs:!!document.fullscreenElement,v:document.visibilityState,"
        "f:document.hasFocus()})")


def state():
    b = bc.call("Browser.getWindowBounds", {"windowId": wid}, 20).get("result", {}).get("bounds", {})
    try:
        v = json.loads(evaluate(pc, VIEW))
    except Exception:
        v = {}
    return {"win": b.get("windowState"), "size": "%sx%s" % (b.get("width"), b.get("height")), **v}


before = state()
evaluate(pc, LISTEN)
t0 = time.time()
if how == "window":
    r = bc.call("Browser.setWindowBounds", {"windowId": wid, "bounds": {"windowState": "fullscreen"}})
elif how == "key":
    k = {"key": "F11", "code": "F11", "windowsVirtualKeyCode": 122, "nativeVirtualKeyCode": 122}
    r = pc.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", **k})
    pc.call("Input.dispatchKeyEvent", {"type": "keyUp", **k})
elif how == "player":  # YouTube: play, then fullscreen the player element (like its fullscreen button)
    evaluate(pc, "(()=>{const v=document.querySelector('video'); if(v) v.play(); return 1})()")
    time.sleep(3)
    r = pc.call("Runtime.evaluate", {"expression": "(document.querySelector('#movie_player')||document.querySelector('video')||document.documentElement).requestFullscreen().then(()=>'ok',e=>'err '+e)",
                                     "userGesture": True, "awaitPromise": True, "returnByValue": True})
else:
    r = pc.call("Runtime.evaluate", {"expression": "document.documentElement.requestFullscreen().then(()=>'ok',e=>'err '+e)",
                                     "userGesture": True, "awaitPromise": True, "returnByValue": True})
call = r.get("error") or r.get("result", {}).get("result", {}).get("value", "ok")

rows, last = [], None
while time.time() - t0 < secs:
    time.sleep(1)
    s = state()
    key = (s.get("win"), s.get("size"), s.get("i"), s.get("fs"), s.get("v"), s.get("f"))
    if key != last:
        rows.append({"t": round(time.time() - t0, 1), **s})
        last = key
try:
    events = evaluate(pc, "JSON.stringify(window.FSL||[])")
    events = json.loads(events)
except Exception as e:
    events = ["read failed " + type(e).__name__]
went = next((x["t"] for x in rows if x.get("win") == "fullscreen" or x.get("fs")), None)
left = next((x["t"] for x in rows if went is not None and x["t"] > went and x.get("win") != "fullscreen" and not x.get("fs")), None)
print(json.dumps({"how": how, "window_id": wid, "call": call, "before": before, "fullscreen_at_s": went,
                  "left_fullscreen_at_s": left, "end": rows[-1] if rows else None, "changes": rows,
                  "page_events": events}))
