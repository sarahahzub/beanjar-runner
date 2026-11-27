#!/usr/bin/env python3
# Session restore checks for WebOS Chromium issue #42 (CDP on 127.0.0.1:9222):
#   sess.py setpref        On startup = "Continue where you left off" (session.restore_on_startup = 1), read back
#   sess.py open           opens Wikipedia and BBC News as two more tabs
#   sess.py tabs           the page tabs' URLs
#   sess.py close          Chrome's own exit (Browser.close, as the menu's Exit)
import json, sys, time
sys.path.insert(0, "/w")
from cdp import Conn, get, page, evaluate

cmd = sys.argv[1]
if cmd == "setpref":
    c = Conn(page()["webSocketDebuggerUrl"]); c.call("Page.enable")
    c.call("Page.navigate", {"url": "chrome://settings/onStartup"}); c.pump(6)
    print(evaluate(c, "new Promise(r=>chrome.settingsPrivate.setPref('session.restore_on_startup',1,'',ok=>"
                      "chrome.settingsPrivate.getPref('session.restore_on_startup',p=>r('set '+ok+' now '+p.value))))"))
elif cmd == "open":
    b = Conn(get("/json/version")["webSocketDebuggerUrl"])
    for u in ["https://en.wikipedia.org/wiki/Television", "https://www.bbc.com/news"]:
        b.call("Target.createTarget", {"url": u}); time.sleep(12)
    print("opened")
elif cmd == "tabs":
    print(json.dumps([t.get("url", "")[:60] for t in get("/json/list") if t.get("type") == "page"
                      and not t.get("url", "").startswith("chrome-extension://")]))
elif cmd == "close":
    b = Conn(get("/json/version")["webSocketDebuggerUrl"])
    print(json.dumps(b.call("Browser.close", timeout=20))[:100])
