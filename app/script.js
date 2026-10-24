/* ==========================================================================
   script.js
   Reads the live deployment metadata published by the server and renders it
   into the "Deployment status" section.

   Endpoints consumed (both are served by Nginx on the Azure VM):
     /health         -> plain text "ok", used as a liveness probe
     /build-info.txt -> key=value metadata written by scripts/deploy.sh

   The file is plain browser JavaScript: no framework, no build step and no
   external dependency, so it can be deployed straight from the repository.
   ========================================================================== */
(function () {
  "use strict";

  var REFRESH_INTERVAL_MS = 30000;
  var REQUEST_TIMEOUT_MS = 8000;

  var el = {
    pill:      document.getElementById("status-pill"),
    url:       document.getElementById("status-url"),
    build:     document.getElementById("status-build"),
    commit:    document.getElementById("status-commit"),
    time:      document.getElementById("status-time"),
    release:   document.getElementById("status-release"),
    by:        document.getElementById("status-by"),
    stamp:     document.getElementById("status-stamp"),
    refresh:   document.getElementById("refresh-btn"),
    navDot:    document.getElementById("nav-dot"),
    navStatus: document.getElementById("nav-status")
  };

  var FALLBACK = "—";

  /* --------------------------------------------------------------------
     Helpers
     -------------------------------------------------------------------- */
  function setText(node, value) {
    if (node) {
      node.textContent = (value === null || value === undefined || value === "") ? FALLBACK : String(value);
    }
  }

  function setPill(state, label) {
    if (!el.pill) { return; }
    el.pill.className = "pill pill--" + state;
    el.pill.textContent = label;
  }

  function setNav(state, label) {
    if (el.navDot) {
      el.navDot.className = "dot" + (state === "ok" ? " dot--ok" : state === "bad" ? " dot--bad" : "");
    }
    setText(el.navStatus, label);
  }

  function formatUtc(isoText) {
    if (!isoText) { return FALLBACK; }
    var parsed = new Date(isoText);
    if (isNaN(parsed.getTime())) { return isoText; }
    return parsed.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
  }

  /* Fetch with a timeout so a hanging server cannot freeze the page. */
  function fetchText(url) {
    if (typeof window.fetch !== "function") {
      return Promise.reject(new Error("fetch is not supported by this browser"));
    }
    if (window.location.protocol === "file:") {
      return Promise.reject(new Error("page opened from the local file system"));
    }

    var controller = (typeof AbortController === "function") ? new AbortController() : null;
    var timer = window.setTimeout(function () {
      if (controller) { controller.abort(); }
    }, REQUEST_TIMEOUT_MS);

    var options = { cache: "no-store", credentials: "same-origin" };
    if (controller) { options.signal = controller.signal; }

    return window.fetch(url, options).then(function (response) {
      window.clearTimeout(timer);
      if (!response.ok) {
        throw new Error(url + " responded with HTTP " + response.status);
      }
      return response.text();
    }, function (error) {
      window.clearTimeout(timer);
      throw error;
    });
  }

  /* Parse the "key=value" lines of build-info.txt into an object. */
  function parseBuildInfo(text) {
    var result = {};
    var lines = (text || "").split("\n");

    for (var i = 0; i < lines.length; i += 1) {
      var line = lines[i].trim();
      if (line === "" || line.charAt(0) === "#") { continue; }

      var separator = line.indexOf("=");
      if (separator === -1) { continue; }

      var key = line.slice(0, separator).trim();
      var value = line.slice(separator + 1).trim();
      result[key] = value;
    }
    return result;
  }

  /* --------------------------------------------------------------------
     Renderers
     -------------------------------------------------------------------- */
  function renderBuildInfo(info) {
    setText(el.build, info.build_tag ? (info.build_tag + " (#" + (info.build_number || "?") + ")") : null);
    setText(el.commit, info.git_commit);
    setText(el.time, formatUtc(info.deployed_at_utc));
    setText(el.release, info.release_id);
    setText(el.by, info.deployed_by);

    if (el.url && window.location.protocol !== "file:") {
      el.url.href = window.location.origin + "/";
      el.url.textContent = window.location.origin + "/";
    }
  }

  function renderError(message) {
    setPill("bad", "Unavailable");
    setNav("bad", "Offline");
    setText(el.stamp, "Last check failed - " + message);
    setText(el.build, null);
    setText(el.commit, null);
    setText(el.time, null);
    setText(el.release, null);
    setText(el.by, null);
  }

  function renderSuccess(info) {
    setPill("ok", "Live");
    setNav("ok", "Live");
    renderBuildInfo(info);
    setText(el.stamp, "Last checked " + new Date().toLocaleTimeString());
  }

  function renderNoBuildInfo() {
    setPill("pending", "No build yet");
    setNav("pending", "Pending");
    setText(el.stamp, "Server is healthy, but no build-info.txt has been published yet.");
  }

  /* --------------------------------------------------------------------
     Main check
     -------------------------------------------------------------------- */
  function checkStatus() {
    if (el.refresh) { el.refresh.disabled = true; }

    return fetchText("health")
      .then(function () {
        return fetchText("build-info.txt").then(function (text) {
          var info = parseBuildInfo(text);
          if (info && Object.keys(info).length > 0) {
            renderSuccess(info);
          } else {
            renderNoBuildInfo();
          }
        }, function () {
          renderNoBuildInfo();
        });
      })
      .catch(function (error) {
        renderError(error && error.message ? error.message : "unknown error");
      })
      .then(function () {
        if (el.refresh) { el.refresh.disabled = false; }
      });
  }

  /* --------------------------------------------------------------------
     Wiring
     -------------------------------------------------------------------- */
  function init() {
    if (el.refresh) {
      el.refresh.addEventListener("click", function () {
        checkStatus();
      });
    }

    checkStatus();
    window.setInterval(checkStatus, REFRESH_INTERVAL_MS);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
