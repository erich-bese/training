/* Bridge between the web app and the native shell.
 *
 * Injected at document start, so everything below is in place before the web
 * app's own script runs. The web app itself is never modified — it keeps
 * working unchanged in a plain browser, and in here it simply finds a set of
 * platform features that behave better than the browser's.
 *
 * The placeholders __SEED__ and __VERSION__ are filled in by Bridge.swift.
 */
(function () {
  "use strict";

  var SEED = __SEED__;
  var SHELL_VERSION = "__VERSION__";

  function post(message) {
    try { window.webkit.messageHandlers.native.postMessage(message); }
    catch (e) { /* running outside the shell — nothing to do */ }
  }

  /* ------------------------------------------------------- storage ------- */
  /* The native side owns the data. What lives here is a working copy that is
     seeded on load and flushed back on every change. WebKit may evict its own
     website data at any time; this copy does not care, because it is never the
     thing that has to survive.

     Only the methods the web app actually uses are implemented, plus the rest
     of the Storage surface for good measure. Index access (localStorage[0]) is
     not supported — the web app does not use it, and a Proxy here would be a
     lot of risk for no gain. */
  var data = Object.create(null);
  Object.keys(SEED).forEach(function (k) { data[k] = String(SEED[k]); });

  var pending = false;
  var timer = null;

  function flush() {
    if (timer) { clearTimeout(timer); timer = null; }
    if (!pending) return;
    pending = false;
    var copy = {};
    Object.keys(data).forEach(function (k) { copy[k] = data[k]; });
    post({ cmd: "store", items: copy });
  }

  /* Coalesced, because the web app saves on every tap. A quarter of a second
     is far below the time it takes to leave the app, and every path out of the
     foreground flushes explicitly anyway. */
  function touch() {
    pending = true;
    if (timer) clearTimeout(timer);
    timer = setTimeout(flush, 250);
  }

  var storage = {
    getItem: function (key) {
      key = String(key);
      return Object.prototype.hasOwnProperty.call(data, key) ? data[key] : null;
    },
    setItem: function (key, value) { data[String(key)] = String(value); touch(); },
    removeItem: function (key) { delete data[String(key)]; touch(); },
    clear: function () { data = Object.create(null); touch(); },
    key: function (i) {
      var keys = Object.keys(data);
      i = Number(i);
      return i >= 0 && i < keys.length ? keys[i] : null;
    }
  };
  Object.defineProperty(storage, "length", {
    get: function () { return Object.keys(data).length; }
  });

  try {
    Object.defineProperty(window, "localStorage", { value: storage, configurable: true });
  } catch (e) {
    post({ cmd: "log", text: "localStorage konnte nicht ersetzt werden: " + e });
  }

  /* Every way out of the foreground writes through before the app is frozen. */
  window.addEventListener("pagehide", flush);
  window.addEventListener("beforeunload", flush);
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") flush();
  });
  function snapshot() {
    if (timer) { clearTimeout(timer); timer = null; }
    pending = false;
    var copy = {};
    Object.keys(data).forEach(function (k) { copy[k] = data[k]; });
    return copy;
  }

  /* Called from Swift when the app is about to resign active. */
  window.__training_flush = flush;
  /* Same thing, but handed straight back as the return value instead of going
     through a message. When the app is being put to sleep there is no room for
     a round trip that might not be delivered in time. */
  window.__training_snapshot = snapshot;

  /* ------------------------------------------------------- haptics ------- */
  /* iOS has no navigator.vibrate at all, so the web app's buzz() has always
     been silent on the phone. Mapped onto the taptic engine by duration —
     the web app uses 8 for a tap, 13/14/30 for a confirmation, 45/70 for the
     end of a set or a rest timer running out. */
  try {
    Object.defineProperty(navigator, "vibrate", {
      configurable: true,
      value: function (pattern) {
        var ms = Array.isArray(pattern) ? pattern[0] : pattern;
        post({ cmd: "haptic", ms: Math.max(0, Number(ms) || 0) });
        return true;
      }
    });
  } catch (e) {}

  /* ------------------------------------------------------ wake lock ------ */
  /* Replaces the Screen Wake Lock API with the native idle timer, which is not
     subject to the browser's rules about when a lock may be held. The web app
     only ever calls request("screen") and release(). */
  try {
    Object.defineProperty(navigator, "wakeLock", {
      configurable: true,
      value: {
        request: function () {
          post({ cmd: "awake", on: true });
          var listeners = [];
          var sentinel = {
            type: "screen",
            released: false,
            addEventListener: function (type, fn) {
              if (type === "release" && typeof fn === "function") listeners.push(fn);
            },
            removeEventListener: function (type, fn) {
              var i = listeners.indexOf(fn);
              if (i >= 0) listeners.splice(i, 1);
            },
            release: function () {
              if (!sentinel.released) {
                sentinel.released = true;
                post({ cmd: "awake", on: false });
                listeners.forEach(function (fn) { try { fn({ type: "release" }); } catch (e) {} });
              }
              return Promise.resolve();
            }
          };
          return Promise.resolve(sentinel);
        }
      }
    });
  } catch (e) {}

  /* --------------------------------------------------------- update ------ */
  /* The web app's own update check goes through the service worker, which does
     not exist here — the page is loaded from disk. "Nach Updates suchen" is
     rerouted to the shell, which fetches the current index.html from GitHub
     Pages. Doing it this way keeps the deploy flow of the web app intact:
     git push, and the native app follows on the next start. */
  window.addEventListener("load", function () {
    if (typeof window.checkUpdate === "function") {
      window.checkUpdate = function () { post({ cmd: "update" }); };
    }
    post({ cmd: "ready", version: SHELL_VERSION });
  });

  /* Called from Swift with the result of that check. */
  window.__training_updateResult = function (text) {
    if (typeof window.updMsg === "function") window.updMsg(text);
  };

  /* --------------------------------------------------------- health ------ */
  /* Apple Health, read only. There is no browser API to shim here, so this is
     the one place where the page learns something it could not have known on
     its own — through a global it has to ask for defensively. In a browser the
     global stays null and the page simply does not show the block.

     The shell pushes on its own: once at load, and again every time the app
     comes back to the front. `request` is only for the very first time, when
     iOS still has to put its permission sheet on screen — it must come from a
     tap, not from the page loading. */
  window.__training_health = null;
  window.__training_healthPush = function (data) {
    window.__training_health = data && data.ok ? data : null;
    try {
      window.dispatchEvent(new CustomEvent("training:health", { detail: window.__training_health }));
    } catch (e) {}
  };
  window.__training_healthRequest = function () { post({ cmd: "health", ask: true }); };

  /* Marker for anything that wants to know it is running inside the shell. */
  window.__training_native = SHELL_VERSION;
})();
