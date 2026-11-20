# beanjar-runner

Smoke tests of [Beanjar](https://github.com/webosbrew/beanjar) (v0.6.0 Debian packages) booting LG webOS
firmware on free GitHub-hosted runners.

- `.github/workflows/beanjar.yml`: manual workflow; each matrix entry downloads one firmware ZIP from LG's own
  download server (`gscs-b2c.lge.com/downloadFile?fileId=...`) at run time, then runs `run.sh` in a
  privileged `debian:trixie` container with `/dev/kvm`.
- `run.sh`: installs the packages, builds epk2extract, `beanjar create`, optional `guest_kernel=x86-64`,
  `beanjar start`, waits for a foreground app, takes screenshots, presses remote keys, opens Settings and the
  browser, and installs a tiny web IPK through Developer Mode.

No LG firmware is stored in this repository or in its artifacts (only screenshots, logs and results).
