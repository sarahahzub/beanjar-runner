#!/usr/bin/env python3
# CDP helper for MODE=lab (lab.sh): drives the test lab page (lab/ on Oracle, public at /webapp/cnlab/).
#   lab.py run NAME TIMEOUT   LAB.run(NAME) with a user gesture; prints its result
#   lab.py fonts              real font of every cell of the page's font table (CSS.getPlatformFontsForNode)
#   lab.py show SELECTOR      scroll the element into view (for a screenshot)
#   lab.py play               loop the first <video> on the page (screen saver test); prints its state
import json, sys
sys.path.insert(0, "/w")
from cdp import Conn, page, evaluate

c = Conn(page()["webSocketDebuggerUrl"])
cmd = sys.argv[1]
if cmd == "run":
    name, t = sys.argv[2], float(sys.argv[3])
    r = c.call("Runtime.evaluate", {"expression": f"LAB.run({json.dumps(name)}).then(r=>JSON.stringify(r))",
                                    "userGesture": True, "awaitPromise": True, "returnByValue": True}, t)
    v = r.get("result", {}).get("result", {}).get("value")
    print(v if v else json.dumps({"error": r.get("error") or r.get("result")})[:600])
elif cmd == "fonts":
    c.call("DOM.enable"); c.call("CSS.enable")
    root = c.call("DOM.getDocument", {"depth": 1})["result"]["root"]["nodeId"]
    ids = c.call("DOM.querySelectorAll", {"nodeId": root, "selector": "#fonts td[id]"})["result"]["nodeIds"]
    out = {}
    for n in ids:
        a = c.call("DOM.getAttributes", {"nodeId": n})["result"]["attributes"]
        cid = a[a.index("id") + 1].replace("font-", "")
        f = c.call("CSS.getPlatformFontsForNode", {"nodeId": n}).get("result", {}).get("fonts", [])
        out[cid] = ", ".join("%s(%d)" % (x["familyName"], x["glyphCount"]) for x in f)
    print(json.dumps(out, ensure_ascii=False))
elif cmd == "show":
    print(json.dumps(evaluate(c, f"(()=>{{const e=document.querySelector({json.dumps(sys.argv[2])}); if(!e) return 'none';"
                                 "e.scrollIntoView({block:'start'}); return 'ok'})()")))
elif cmd == "play":
    print(json.dumps(evaluate(c, "(()=>{const s=document.getElementById('stage');s.innerHTML='';const v=document.createElement('video');"
                                 "v.src='avsync.mp4';v.loop=true;v.style.width='960px';s.appendChild(v);v.play();"
                                 "return 'started'})()")))
elif cmd == "state":
    print(json.dumps(evaluate(c, "(()=>{const v=document.querySelector('#stage video');return v?{t:+v.currentTime.toFixed(1),"
                                 "paused:v.paused,muted:v.muted}:'no video'})()")))
elif cmd == "pause":
    print(json.dumps(evaluate(c, "(()=>{const v=document.querySelector('#stage video');if(v)v.pause();return 'paused'})()")))
