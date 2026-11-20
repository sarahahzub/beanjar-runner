# mkipk.py APPDIR OUT.ipk : a minimal webOS IPK (ar: debian-binary, control.tar.gz, data.tar.gz)
import io, json, os, sys, tarfile, time

src, out = sys.argv[1], sys.argv[2]
info = json.load(open(os.path.join(src, "appinfo.json")))
app = info["id"]

def tgz(entries):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:gz", format=tarfile.GNU_FORMAT) as t:
        for name, data in entries:
            if data is None:
                ti = tarfile.TarInfo(name); ti.type = tarfile.DIRTYPE; ti.mode = 0o755
                ti.mtime = int(time.time()); t.addfile(ti)
            else:
                ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = 0o644; ti.mtime = int(time.time())
                t.addfile(ti, io.BytesIO(data))
    return b.getvalue()

files = [(f, open(os.path.join(src, f), "rb").read()) for f in sorted(os.listdir(src))]
base = "./usr/palm/applications/" + app
dirs = ["./usr", "./usr/palm", "./usr/palm/applications", base]
data = tgz([(d, None) for d in dirs] + [(base + "/" + f, d) for f, d in files])
size = sum(len(d) for _, d in files)
control = ("Package: %s\nVersion: %s\nSection: misc\nPriority: optional\nArchitecture: all\n"
           "Installed-Size: %d\nMaintainer: bean\nDescription: %s\nwebOS-Package-Format-Version: 2\n"
           "webOS-Packager-Version: x.y.x\n" % (app, info["version"], size, info["title"])).encode()
ctrl = tgz([("./control", control)])

def member(name, data):
    h = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, int(time.time()), 0, 0, "100644", len(data))
    return h.encode() + data + (b"\n" if len(data) % 2 else b"")

with open(out, "wb") as f:
    f.write(b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", ctrl)
            + member("data.tar.gz", data))
print(out, os.path.getsize(out))
