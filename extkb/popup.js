// Records what happens to the text field, for the test to read through DevTools (window.LOG).
window.LOG = [];
const u = document.getElementById("user");
const log = (s) => window.LOG.push(Math.round(performance.now()) + " " + s);
for (const t of ["focus", "blur", "pointerdown", "keydown", "input"]) {
  u.addEventListener(t, (e) => log(t + (e.key ? ":" + e.key : "") + (e.data ? ":" + e.data : "")));
}
log("loaded");
