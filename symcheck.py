#!/usr/bin/env python3
# symcheck.py APPDIR GUESTROOT : an ldd-like check without running anything.
# For the app's browser/chrome and lib/*.so: is every NEEDED library in APPDIR/lib or the guest copy, and is every
# strong undefined dynamic symbol (with its version) defined by one of them? GUESTROOT holds copies of the guest's
# libraries (lib/, usr/lib/). Uses binutils readelf. Prints one line per finding and a summary.
import glob, os, re, subprocess, sys

app, groot = sys.argv[1], sys.argv[2]
SEARCH = [os.path.join(app, "lib"), os.path.join(groot, "lib"), os.path.join(groot, "usr/lib")]


def readelf(args, path):
    return subprocess.run(["readelf", "-W"] + args + [path], capture_output=True, text=True).stdout


def needed(path):
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", readelf(["-d"], path))


def syms(path):
    defined, undef = set(), set()
    for line in readelf(["--dyn-syms"], path).splitlines():
        p = line.split()
        if len(p) < 8 or not p[0].endswith(":"):
            continue
        typ, bind, ndx, name = p[3], p[4], p[6], p[7]
        base, _, ver = name.replace("@@", "@").partition("@")
        ver = re.sub(r"\s*\(\d+\)$", "", ver)
        if ndx == "UND":
            if bind != "WEAK" and base:
                undef.add((base, ver))
        elif bind in ("GLOBAL", "WEAK") and base:
            defined.add((base, ver))
            defined.add((base, ""))
    return defined, undef


def find(lib):
    for d in SEARCH:
        p = os.path.join(d, lib)
        if os.path.exists(p):
            return p
    return None


objs = [os.path.join(app, "browser/chrome")] + sorted(glob.glob(os.path.join(app, "lib/*.so")))
cache, missing_libs, missing_syms = {}, set(), []
for o in objs:
    providers, todo, seen = [], list(needed(o)), set()
    while todo:  # the object's NEEDED closure
        n = todo.pop(0)
        if n in seen:
            continue
        seen.add(n)
        p = find(n)
        if not p:
            missing_libs.add(f"{os.path.basename(o)} needs {n}: not in app lib/ or the guest")
            continue
        providers.append(p)
        todo += needed(p)
    have = set()
    for p in providers:
        if p not in cache:
            cache[p] = syms(p)[0]
        have |= cache[p]
    _, und = syms(o)
    for base, ver in sorted(und):
        if (base, ver) not in have and not (ver == "" and (base, "") in have):
            missing_syms.append(f"{os.path.basename(o)}: {base}{'@' + ver if ver else ''}")

libc = find("libc.so.6")
vers = sorted(set(re.findall(r"GLIBC_2\.\d+", readelf(["-V"], libc))) if libc else [], key=lambda v: int(v.split(".")[1]))
need = sorted(set(re.findall(r"GLIBC_2\.\d+", readelf(["-V"], objs[0]))), key=lambda v: int(v.split(".")[1]))
print(f"guest libc newest version node: {vers[-1] if vers else '?'}; chrome needs up to {need[-1] if need else '?'}")
for m in sorted(missing_libs):
    print("MISSING_LIB", m)
for m in missing_syms[:80]:
    print("MISSING_SYM", m)
print(f"summary: {len(objs)} objects, {len(missing_libs)} missing libraries, {len(missing_syms)} unresolved strong symbols")
