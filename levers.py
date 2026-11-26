#!/usr/bin/env python3
# levers.py: opens the test pages as tabs in the running browser (CDP on 127.0.0.1:9222) and prints one JSON line
# with each page's load time (navigation start to load event, wall clock of this script).
import json, sys, time
sys.path.insert(0, "/w")
from cdp import Conn, get

PAGES = ["https://en.wikipedia.org/wiki/Television", "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
         "https://www.bbc.com/news"]
b = Conn(get("/json/version")["webSocketDebuggerUrl"])
out = {}
for u in PAGES:
  try:
      t = b.call("Target.createTarget", {"url": "about:blank"}).get("result", {}).get("targetId")
      tgt = next((x for x in get("/json/list") if x.get("id") == t), None)
      if not tgt:
          out[u] = "no target"; continue
      c = Conn(tgt["webSocketDebuggerUrl"]); c.call("Page.enable")
      t0 = time.time(); c.call("Page.navigate", {"url": u}, 60)
      end = t0 + 60; load = None
      while time.time() < end and load is None:
          c.pump(1)
          load = next((round(tt - t0, 1) for tt, m in c.events if m.get("method") == "Page.loadEventFired"), None)
      out[u.split("/")[2]] = load
  except Exception as e:
    out[u.split("/")[2]] = "err " + type(e).__name__
print(json.dumps(out))
