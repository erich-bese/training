/* Offline-Cache der App-Shell.
 *
 * Zwei Strategien, bewusst getrennt:
 *
 * Das HTML-Dokument laeuft "network first". Mit Netz kommt immer die aktuelle
 * Version, ohne Netz die letzte gecachte. Nur so sieht ein Update sofort und
 * nicht erst beim zweiten Start. Die frueher benutzte "cache first"-Variante
 * lieferte hartnaeckig die alte App aus, auch wenn online schon die neue lag.
 *
 * Alles andere (Icons, Manifest) laeuft "cache first" mit stiller Erneuerung
 * im Hintergrund. Das sind statische Dateien, da ist Tempo wichtiger.
 */
const CACHE = "training-v4";
const FILES = [
  "./", "./index.html", "./manifest.webmanifest",
  "./apple-touch-icon.png", "./icon-192.png", "./icon-512.png"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE)
      /* reload: umgeht den HTTP-Cache, sonst landen beim Update alte Kopien im neuen Cache */
      .then(c => c.addAll(FILES.map(f => new Request(f, {cache:"reload"}))))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

/* Anfragen, bei denen Aktualitaet vor Tempo geht: die Seite selbst. */
function isDocument(req){
  if (req.mode === "navigate") return true;
  const dest = req.destination;
  if (dest === "document") return true;
  return /\/(index\.html)?(\?.*)?$/.test(new URL(req.url).pathname + (new URL(req.url).search || ""));
}

/* Das Dokument bewusst am HTTP-Cache vorbei holen: GitHub Pages liefert
 * max-age=600, sonst koennte der Browser bis zu zehn Minuten nach einem
 * Deployment weiter die alte Datei ausgeben.
 *
 * Mit Zeitlimit, damit ein lahmes Netz den Start nicht blockiert. Laeuft es ab,
 * greift der Cache-Fallback und die neue Version kommt beim naechsten Start.
 */
const DOC_TIMEOUT = 2500;
function freshDocument(req){
  let ctrl = null, timer = null;
  try { ctrl = new AbortController(); } catch(e){}
  const opts = {cache:"no-store"};
  if (ctrl) {
    opts.signal = ctrl.signal;
    timer = setTimeout(() => { try { ctrl.abort(); } catch(e){} }, DOC_TIMEOUT);
  }
  const clear = () => { if (timer) clearTimeout(timer); };
  return fetch(req.url, opts).then(res => { clear(); return res; },
                                   err => { clear(); throw err; });
}

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  if (new URL(req.url).origin !== self.location.origin) return;

  if (isDocument(req)) {
    e.respondWith(
      freshDocument(req)
        .then(res => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then(c => c.put("./index.html", copy)).catch(() => {});
          }
          return res;
        })
        .catch(() => caches.match("./index.html").then(hit => hit || caches.match("./")))
    );
    return;
  }

  e.respondWith(
    caches.match(req).then(hit => {
      if (hit) {
        fetch(req).then(res => {
          if (res && res.ok) caches.open(CACHE).then(c => c.put(req, res.clone())).catch(() => {});
        }).catch(() => {});
        return hit;
      }
      return fetch(req).then(res => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        }
        return res;
      }).catch(() => caches.match("./index.html"));
    })
  );
});

/* Erlaubt der Seite, ein Update aktiv anzustossen (Mehr > Auf Update pruefen). */
self.addEventListener("message", e => {
  if (e.data === "skipWaiting") self.skipWaiting();
});
