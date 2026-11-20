#!/usr/bin/env python3
# DevTools helper for the extkb mode (browser inside the TV, reached through the SSH -L 9222 forward).
#   extcdp.py targets                 type and url of every target
#   extcdp.py nav MATCH URL          Page.navigate in that target (browser-initiated: data: URLs are allowed)
#   extcdp.py eval MATCH EXPR         Runtime.evaluate in the first target whose url contains MATCH (a page, an
#                                     extension popup or a service worker); prints the value as JSON
import json, sys, urllib.request
import websocket

BASE = "http://127.0.0.1:9222"


def targets():
    with urllib.request.urlopen(BASE + "/json/list", timeout=20) as r:
        return json.loads(r.read())


def call(match, method, params):
    t = next((t for t in targets() if match in t.get("url", "") and t.get("webSocketDebuggerUrl")), None)
    if not t:
        return {"error": "no target matching " + match}
    ws = websocket.create_connection(t["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
    ws.send(json.dumps({"id": 1, "method": method, "params": params}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == 1:
            break
    ws.close()
    return m


def evaluate(match, expr):
    m = call(match, "Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
    if "error" in m and "result" not in m:
        return m
    r = m.get("result", {})
    if r.get("exceptionDetails"):
        return {"error": r["exceptionDetails"].get("text", "exception"),
                "detail": json.dumps(r["exceptionDetails"])[:300]}
    return r.get("result", {}).get("value")


def main():
    try:
        if sys.argv[1] == "targets":
            print(json.dumps([{"type": t.get("type"), "url": t.get("url", "")[:120]} for t in targets()]))
        elif sys.argv[1] == "nav":
            print(json.dumps(call(sys.argv[2], "Page.navigate", {"url": sys.argv[3]}).get("result", {})))
        elif sys.argv[1] == "eval":
            print(json.dumps(evaluate(sys.argv[2], sys.argv[3])))
    except Exception as e:  # never stop the shell script
        print(json.dumps({"error": type(e).__name__ + ": " + str(e)[:200]}))


main()
