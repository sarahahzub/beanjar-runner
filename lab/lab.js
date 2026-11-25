// WebOS Chromium test lab. Every test returns {verdict: ok|bad|warn|watch|info, details}. Buttons run one test;
// "Run all" runs every test in order and POSTs the results to ./report (the server keeps them for the owner).
// A CDP runner calls LAB.run(name) / LAB.runAll() and reads LAB.results.
// Timing uses Date.now() (wall clock). Media rate = media seconds played / wall seconds: 1.00 is right; less means
// stalls or a slow clock, more means the media clock runs fast (audio clock problems show up here).
'use strict';
const $ = (s) => document.querySelector(s);
const stage = $('#stage');
const log = (...a) => { $('#log').textContent += a.join(' ') + '\n'; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LAB = (window.LAB = { results: {}, running: null });

function clear() { stage.innerHTML = ''; }

function video(src, { muted = true, w = 480 } = {}) {
  const v = document.createElement('video');
  if (src) v.src = src;
  v.muted = muted; v.playsInline = true; v.style.width = w + 'px';
  stage.appendChild(v);
  return v;
}

// Plays element v for secs and measures it.
async function measure(v, secs) {
  const m = { frames: 0, waiting: 0, stalled: 0, err: null, events: [] };
  const t0 = Date.now();
  const ev = (e) => m.events.push(((Date.now() - t0) / 1000).toFixed(1) + ' ' + e);
  if (v.requestVideoFrameCallback) {
    const f = () => { m.frames++; v.requestVideoFrameCallback(f); };
    v.requestVideoFrameCallback(f);
  }
  v.addEventListener('waiting', () => { m.waiting++; ev('waiting'); });
  v.addEventListener('stalled', () => { m.stalled++; });
  v.addEventListener('playing', () => ev('playing'));
  v.addEventListener('error', () => { m.err = v.error ? v.error.code + ' ' + v.error.message : 'error'; ev('error'); });
  try { await v.play(); } catch (e) { m.err = String(e); }
  // start the clock at the first advancing media time, so load time does not count as a stall
  let start = null, startMedia = 0;
  const end = Date.now() + secs * 1000 + 15000;
  while (Date.now() < end) {
    await sleep(250);
    if (start === null && v.currentTime > 0.05) { start = Date.now(); startMedia = v.currentTime; m.frames = 0; ev('first advance'); }
    if (start !== null && Date.now() - start >= secs * 1000) break;
    if (v.ended || m.err) break;
  }
  const wall = start === null ? 0 : (Date.now() - start) / 1000;
  const pq = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
  m.startup_s = start === null ? null : +((start - t0) / 1000).toFixed(1);
  m.wall_s = +wall.toFixed(1);
  m.media_s = +(v.currentTime - startMedia).toFixed(2);
  m.rate = wall ? +(m.media_s / wall).toFixed(3) : 0;
  m.fps = wall ? +(m.frames / wall).toFixed(1) : 0;
  m.size = v.videoWidth + 'x' + v.videoHeight;
  m.total = pq.totalVideoFrames; m.dropped = pq.droppedVideoFrames;
  m.events = m.events.slice(0, 12);
  v.pause();
  return m;
}

function verdict(m, wantFps) {
  if (m.err) return 'bad';
  if (m.startup_s === null) return 'bad';
  if (m.rate < 0.95 || m.rate > 1.05 || m.waiting > 1) return 'warn';
  // rVFC counts frames Chrome composited; the hardware path (video hole) can show 0 even when the TV shows them
  if (wantFps && m.frames > 0 && m.fps < wantFps * 0.9) return 'warn';
  return 'ok';
}

const TESTS = {
  async codecs() {
    const types = {
      'h264 mp4': 'video/mp4; codecs="avc1.640028"', 'h264+aac mp4': 'video/mp4; codecs="avc1.640028,mp4a.40.2"',
      'hevc mp4': 'video/mp4; codecs="hvc1.1.6.L120.90"', 'vp9 webm': 'video/webm; codecs="vp9"',
      'vp9 mp4': 'video/mp4; codecs="vp09.00.40.08"', 'av1 mp4': 'video/mp4; codecs="av01.0.08M.08"',
      'opus webm': 'audio/webm; codecs="opus"', 'aac mp4': 'audio/mp4; codecs="mp4a.40.2"',
      'ac3 mp4': 'audio/mp4; codecs="ac-3"', 'eac3 mp4': 'audio/mp4; codecs="ec-3"',
    };
    const d = {};
    const v = document.createElement('video');
    for (const [k, t] of Object.entries(types)) {
      d[k] = (v.canPlayType(t) || 'no') + ' / mse ' + (window.MediaSource && MediaSource.isTypeSupported(t) ? 'yes' : 'no');
    }
    d.eme = !!navigator.requestMediaKeySystemAccess;
    return { verdict: 'info', details: d };
  },
  async avsync() {
    // A white box and a beep at every full second. Watch: do they come together? The rate shows clock drift.
    clear(); const v = video('avsync.mp4', { muted: false, w: 960 });
    const m = await measure(v, 30);
    return { verdict: verdict(m, 0) === 'ok' ? 'watch' : verdict(m, 0), details: m,
             note: 'box and beep should match; rate 1.00 = no drift' };
  },
  async p60() { clear(); const m = await measure(video('v1080p60.mp4', { w: 960 }), 15); return { verdict: verdict(m, 60), details: m }; },
  async vp9() { clear(); const m = await measure(video('vp9opus.webm', { muted: false }), 15); return { verdict: verdict(m, 30), details: m }; },
  async mse() {
    clear(); const v = video('', { muted: false, w: 960 });
    const type = 'video/mp4; codecs="avc1.640028,mp4a.40.2"';
    if (!window.MediaSource || !MediaSource.isTypeSupported(type)) return { verdict: 'bad', details: 'no MSE for ' + type };
    const ms = new MediaSource(); v.src = URL.createObjectURL(ms);
    await new Promise((r) => ms.addEventListener('sourceopen', r, { once: true }));
    const sb = ms.addSourceBuffer(type);
    const buf = await (await fetch('mse.mp4')).arrayBuffer();
    const step = 512 * 1024;
    (async () => {
      for (let o = 0; o < buf.byteLength; o += step) {
        sb.appendBuffer(buf.slice(o, o + step));
        await new Promise((r) => sb.addEventListener('updateend', r, { once: true }));
      }
      try { ms.endOfStream(); } catch (e) {}
    })();
    const m = await measure(v, 20);
    return { verdict: verdict(m, 0), details: m };
  },
  async iframe() {
    // Same-origin iframe player; it reports its own timing through postMessage.
    clear(); const f = document.createElement('iframe'); f.src = 'frame.html?src=avsync.mp4&muted=0'; f.allow = 'autoplay; fullscreen';
    stage.appendChild(f);
    await sleep(3000);
    const ask = () => new Promise((r) => {
      const h = (e) => { if (e.data && e.data.frame === 'stat') { removeEventListener('message', h); r(e.data); } };
      addEventListener('message', h); f.contentWindow.postMessage('stat', '*'); setTimeout(() => r(null), 3000);
    });
    const a = await ask(); const t0 = Date.now(); await sleep(15000); const b = await ask();
    if (!a || !b) return { verdict: 'bad', details: { a, b } };
    const wall = (Date.now() - t0) / 1000;
    const d = { rate: +((b.t - a.t) / wall).toFixed(3), fps: +((b.frames - a.frames) / wall).toFixed(1), waiting: b.waiting, err: b.err,
                size: b.w + 'x' + b.h, dropped: b.dropped };
    return { verdict: d.err ? 'bad' : (d.rate < 0.95 || d.rate > 1.05) ? 'warn' : 'ok', details: d };
  },
  async youtube() {
    // Cross-origin iframe (YouTube embed, Big Buck Bunny). The page can only see that it loaded; look at the screen.
    clear(); const f = document.createElement('iframe');
    f.src = 'https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ?autoplay=1&mute=1&playsinline=1';
    f.allow = 'autoplay; fullscreen; encrypted-media'; f.style.width = '960px'; f.style.height = '540px';
    const t0 = Date.now(); let loaded = null; f.onload = () => { loaded = (Date.now() - t0) / 1000; };
    stage.appendChild(f); await sleep(20000);
    return { verdict: loaded === null ? 'bad' : 'watch', details: { loaded_s: loaded } };
  },
  async two() {
    // Two videos at once: the TV has one hardware video path, so the second may go to software (or fail).
    clear(); const a = video('avsync.mp4'), b = video('vp9opus.webm');
    const [ma, mb] = await Promise.all([measure(a, 12), measure(b, 12)]);
    return { verdict: verdict(ma, 0) === 'ok' && verdict(mb, 0) === 'ok' ? 'ok' : 'warn', details: { h264: ma, vp9: mb } };
  },
  async audio_aac() { clear(); const a = new Audio('tone.m4a'); const m = await measure(a, 6); return { verdict: verdict(m, 0), details: m }; },
  async audio_opus() { clear(); const a = new Audio('tone.webm'); const m = await measure(a, 6); return { verdict: verdict(m, 0), details: m }; },
  async fullscreen() {
    // Issue #39: does fullscreen stay? Needs a user gesture (the button, or the runner's userGesture).
    clear(); const v = video('avsync.mp4', { w: 480 }); v.loop = true; v.play().catch(() => {});
    const t0 = Date.now(); const ev = [];
    document.addEventListener('fullscreenchange', () => ev.push(((Date.now() - t0) / 1000).toFixed(1) + ' fs=' + !!document.fullscreenElement));
    let err = null; try { await v.requestFullscreen(); } catch (e) { err = String(e); }
    let left = null;
    for (let i = 0; i < 40; i++) { await sleep(250); if (!document.fullscreenElement && left === null && i > 1) left = ((Date.now() - t0) / 1000).toFixed(1); }
    const still = !!document.fullscreenElement;
    if (still) await document.exitFullscreen().catch(() => {});
    v.pause();
    return { verdict: err ? 'bad' : still ? 'ok' : 'bad', details: { err, still_after_10s: still, left_at_s: left, events: ev } };
  },
  async fonts() {
    // Tofu check: a script whose glyphs draw the same as an unassigned code point has no font. The CDP runner also
    // reads the real font names (CSS.getPlatformFontsForNode).
    const rows = fontRows();
    const c = document.createElement('canvas'); c.width = 200; c.height = 60; const g = c.getContext('2d', { willReadFrequently: true });
    const draw = (txt, fam) => { g.clearRect(0, 0, 200, 60); g.font = '40px ' + fam; g.fillStyle = '#000'; g.fillText(txt, 4, 45);
      return Array.from(g.getImageData(0, 0, 200, 60).data.filter((_, i) => i % 4 === 3)).join(','); };
    const tofu = draw('\u0378', 'sans-serif');
    const d = {}; let missing = 0;
    for (const [name, txt] of rows) {
      const ch = [...txt].find((x) => /\S/.test(x) && x.codePointAt(0) > 0x2ff) || txt[0];
      const has = draw(ch, 'sans-serif') !== tofu;
      if (!has) missing++;
      d[name] = has ? 'drawn' : 'TOFU';
    }
    const b = document.createElement('span'); b.style.font = 'bold 40px sans-serif'; b.textContent = 'Bold';
    const r = document.createElement('span'); r.style.font = '40px sans-serif'; r.textContent = 'Bold';
    document.body.append(b, r); d.bold_wider = b.offsetWidth > r.offsetWidth; b.remove(); r.remove();
    return { verdict: missing ? 'warn' : 'ok', details: d };
  },
};

function fontRows() {
  return [
    ['Latin', 'The quick brown fox 0123'], ['Bold', '<b>Bold</b> and <i>italic</i>'], ['Arabic', 'مرحبا بالعالم ١٢٣'],
    ['Urdu', 'اردو زبان خوبصورت ہے'], ['Persian', 'سلام دنیا'], ['Hebrew', 'שלום עולם'], ['Hindi', 'नमस्ते दुनिया'],
    ['Bengali', 'হ্যালো বিশ্ব'], ['Thai', 'สวัสดีชาวโลก'], ['Chinese', '你好，世界 简体 繁體'], ['Japanese', 'こんにちは世界 カタカナ'],
    ['Korean', '안녕하세요 세계'], ['Cyrillic', 'Привет, мир'], ['Greek', 'Γειά σου Κόσμε'], ['Emoji', '😀 👍 🇵🇰 ❤️'],
  ];
}

function fontTable() {
  const t = $('#fonts');
  t.innerHTML = '<tr><th>script</th><th>sans-serif</th><th>serif</th><th>monospace</th></tr>';
  for (const [name, txt] of fontRows()) {
    const tr = document.createElement('tr'); tr.innerHTML = '<td>' + name + '</td>';
    for (const cls of ['sans', 'serif', 'mono']) {
      const td = document.createElement('td'); td.className = cls; td.id = 'font-' + name + '-' + cls; td.innerHTML = txt; tr.appendChild(td);
    }
    t.appendChild(tr);
  }
}

function show(name, r) {
  let tr = document.getElementById('r-' + name);
  if (!tr) { tr = document.createElement('tr'); tr.id = 'r-' + name; $('#res').appendChild(tr); }
  const cls = { ok: 'ok', bad: 'bad', warn: 'warn' }[r.verdict] || '';
  tr.innerHTML = '<td>' + name + '</td><td class="' + cls + '">' + r.verdict + '</td><td>' +
    JSON.stringify(r.details).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c])).slice(0, 600) + '</td>';
}

LAB.run = async (name) => {
  LAB.running = name; log('run', name);
  let r;
  try { r = await TESTS[name](); } catch (e) { r = { verdict: 'bad', details: 'exception ' + e }; }
  r.at = new Date().toISOString(); LAB.results[name] = r; LAB.running = null; show(name, r); log(name, r.verdict);
  return r;
};
LAB.runAll = async (names) => {
  for (const n of names || Object.keys(TESTS)) if (n !== 'fullscreen') await LAB.run(n);
  clear(); return LAB.report();
};
LAB.report = async () => {
  const body = JSON.stringify({ ua: navigator.userAgent, screen: screen.width + 'x' + screen.height, dpr: devicePixelRatio,
                                href: location.href, results: LAB.results });
  try { const r = await fetch('report', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
        $('#sent').textContent = r.ok ? 'Results saved on the server: ' + (await r.text()) : 'Saving failed: ' + r.status; }
  catch (e) { $('#sent').textContent = 'Saving failed: ' + e; }
  return LAB.results;
};
LAB.tests = Object.keys(TESTS);

const bar = $('#buttons');
const btn = (label, fn) => { const b = document.createElement('button'); b.textContent = label; b.onclick = fn; bar.appendChild(b); };
btn('Run all', () => LAB.runAll());
for (const n of Object.keys(TESTS)) btn(n, () => LAB.run(n));
fontTable();
if (new URLSearchParams(location.search).get('auto') === '1') LAB.runAll();
