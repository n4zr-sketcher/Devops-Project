/* ==========================================================================
   script.js — DevOps CI/CD Project
   Telemetry consumer & interactive UI controllers.
   No external frameworks or libraries.
   Strictly complies with Jenkinsfile static checks.
   ========================================================================== */
(function () {
  "use strict";

  var REFRESH_INTERVAL_MS = 30000;
  var REQUEST_TIMEOUT_MS = 8000;
  var FALLBACK = "—";

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

  /* --------------------------------------------------------------------------
     Pipeline Stages Definition for Interactive Explorer
     -------------------------------------------------------------------------- */
  var PIPELINE_STAGES = [
    {
      title: "Stage: Checkout",
      code: "git rev-parse --short HEAD\ngit rev-parse --abbrev-ref HEAD\n# Pulls latest Git commit from main repository & registers revision hash.",
      desc: "Clones the latest verified source code revision from GitHub and records branch & commit hash for build metadata."
    },
    {
      title: "Stage: Validate",
      code: "test -s app/index.html\ntest -s app/style.css\ntest -s app/script.js\n# Verifies that required web application assets exist and are non-empty.",
      desc: "Confirms presence of all required frontend assets and sanity-checks HTML doctype before performing build steps."
    },
    {
      title: "Stage: Test",
      code: "node --check app/script.js\ngrep -qi \"<!DOCTYPE html>\" app/index.html\n# Verifies CSS brace parity & ensures no debug logging statements exist.",
      desc: "Executes static analysis checks across HTML, CSS syntax integrity, and validates JavaScript AST with Node."
    },
    {
      title: "Stage: Deploy",
      code: "ssh -i ~/.ssh/azure_cicd_vm azureuser@$VM_IP \"mkdir -p /tmp/cicd-build\"\nscp -i ~/.ssh/azure_cicd_vm -r app/ scripts/ azureuser@$VM_IP:/tmp/cicd-build\n# Transfers assets securely over Ed25519-authenticated SSH channel.",
      desc: "Securely transfers staged assets and deploy automation scripts to the Ubuntu target VM over encrypted SSH."
    },
    {
      title: "Stage: Reload",
      code: "sudo bash /tmp/cicd-build/deploy.sh /tmp/cicd-build/app\nsystemctl reload nginx\n# Atomically points /var/www/app symlink to new release & reloads Nginx workers.",
      desc: "Creates timestamped immutable release folder, updates the live symlink with mv -Tf, and gracefully reloads Nginx without dropped connections."
    },
    {
      title: "Stage: Verify",
      code: "curl -fsS --max-time 15 http://localhost:8000/health\ncurl -fsS http://localhost:8000/build-info.txt\n# Probes the live HTTP endpoint to ensure newly published release is active.",
      desc: "Performs synthetic health check against the live web server, ensuring HTTP 200 response and matching build metadata."
    }
  ];

  /* --------------------------------------------------------------------------
     Helpers
     -------------------------------------------------------------------------- */
  function setText(node, value) {
    if (node) {
      node.textContent = (value === null || value === undefined || value === "") ? FALLBACK : String(value);
    }
  }

  function setPill(state, label) {
    if (!el.pill) { return; }
    el.pill.className = "pill pill-" + state;
    el.pill.textContent = label;
  }

  function setNav(state, label) {
    if (el.navDot) {
      el.navDot.className = "status-dot " + (state === "ok" ? "live" : state === "bad" ? "offline" : "pending");
    }
    setText(el.navStatus, label);
  }

  function formatUtc(isoText) {
    if (!isoText) { return FALLBACK; }
    var parsed = new Date(isoText);
    if (isNaN(parsed.getTime())) { return isoText; }
    return parsed.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
  }

  /* Fetch with timeout to prevent hung connection */
  function fetchText(url) {
    if (typeof window.fetch !== "function") {
      return Promise.reject(new Error("fetch API unavailable"));
    }
    if (window.location.protocol === "file:") {
      return Promise.reject(new Error("file-protocol"));
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
        throw new Error(url + " HTTP " + response.status);
      }
      return response.text();
    }, function (error) {
      window.clearTimeout(timer);
      throw error;
    });
  }

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

  /* --------------------------------------------------------------------------
     Telemetry Rendering
     -------------------------------------------------------------------------- */
  function renderBuildInfo(info) {
    setText(el.build, info.build_number ? ("#" + info.build_number + (info.build_tag ? " (" + info.build_tag + ")" : "")) : info.build_tag);
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
    if (message === "file-protocol") {
      setPill("pending", "Local File");
      setNav("pending", "Preview");
      setText(el.stamp, "Local file preview mode — live probe active on http://localhost:8000");
      setText(el.url, "http://localhost:8000/");
      if (el.url) { el.url.href = "http://localhost:8000/"; }
      setText(el.build, "#1 (local-sim)");
      setText(el.commit, "working-tree");
      setText(el.time, new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC");
      setText(el.release, "local-preview");
      setText(el.by, "developer");
      return;
    }
    setPill("bad", "Unavailable");
    setNav("bad", "Offline");
    setText(el.stamp, "Probe failed: " + message);
  }

  function renderSuccess(info) {
    setPill("ok", "Live & Healthy");
    setNav("ok", "Live");
    renderBuildInfo(info);
    var now = new Date();
    setText(el.stamp, "Last verified: " + now.toLocaleTimeString() + " (HTTP 200 OK)");
  }

  function renderNoBuildInfo() {
    setPill("pending", "Active");
    setNav("pending", "Standby");
    setText(el.stamp, "Server healthy, awaiting first build-info.txt release.");
  }

  function checkStatus() {
    var spinner = el.refresh ? el.refresh.querySelector(".refresh-spinner") : null;
    if (spinner) { spinner.classList.add("spinning"); }
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
        renderError(error && error.message ? error.message : "Network error");
      })
      .then(function () {
        window.setTimeout(function () {
          if (spinner) { spinner.classList.remove("spinning"); }
          if (el.refresh) { el.refresh.disabled = false; }
        }, 400);
      });
  }

  /* --------------------------------------------------------------------------
     Interactive Pipeline Stage Stepper
     -------------------------------------------------------------------------- */
  function initStepper() {
    var buttons = document.querySelectorAll("#pipeline-stepper .step-btn");
    var codeEl = document.getElementById("stage-code");
    var titleEl = document.getElementById("stage-file");
    var descEl = document.getElementById("stage-desc");

    if (!buttons.length || !codeEl) { return; }

    for (var i = 0; i < buttons.length; i += 1) {
      buttons[i].addEventListener("click", function () {
        var stageIndex = parseInt(this.getAttribute("data-stage"), 10);
        var stage = PIPELINE_STAGES[stageIndex];
        if (!stage) { return; }

        for (var j = 0; j < buttons.length; j += 1) {
          buttons[j].classList.remove("active");
        }
        this.classList.add("active");

        if (titleEl) { titleEl.textContent = "Jenkinsfile — " + stage.title; }
        if (codeEl) { codeEl.textContent = stage.code; }
        if (descEl) { descEl.innerHTML = "<strong>Stage Objective:</strong> " + stage.desc; }
      });
    }
  }

  /* --------------------------------------------------------------------------
     Copy to Clipboard Controller
     -------------------------------------------------------------------------- */
  function initCopyButtons() {
    var copyBtns = document.querySelectorAll(".copy-btn");
    for (var i = 0; i < copyBtns.length; i += 1) {
      copyBtns[i].addEventListener("click", function () {
        var targetId = this.getAttribute("data-copy-target");
        var targetNode = document.getElementById(targetId);
        if (!targetNode) { return; }

        var textToCopy = targetNode.textContent.trim();
        if (!textToCopy || textToCopy === FALLBACK) { return; }

        var self = this;
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(textToCopy).then(function () {
            self.classList.add("copied");
            window.setTimeout(function () {
              self.classList.remove("copied");
            }, 1800);
          });
        }
      });
    }
  }

  /* --------------------------------------------------------------------------
     Scroll Reveal Controller (IntersectionObserver)
     -------------------------------------------------------------------------- */
  function initScrollReveal() {
    var prefersReduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    var elements = document.querySelectorAll(".feature-card, .tech-card, .telemetry-card, .explainer-card, .flow-node");

    if (prefersReduced || typeof IntersectionObserver !== "function") {
      return;
    }

    var observer = new IntersectionObserver(function (entries) {
      for (var i = 0; i < entries.length; i += 1) {
        if (entries[i].isIntersecting) {
          entries[i].target.classList.add("reveal-visible");
          observer.unobserve(entries[i].target);
        }
      }
    }, { threshold: 0.1 });

    for (var j = 0; j < elements.length; j += 1) {
      elements[j].classList.add("reveal-init");
      observer.observe(elements[j]);
    }
  }

  /* --------------------------------------------------------------------------
     Initialization
     -------------------------------------------------------------------------- */
  function init() {
    if (el.refresh) {
      el.refresh.addEventListener("click", function () {
        checkStatus();
      });
    }

    initStepper();
    initCopyButtons();
    initScrollReveal();

    checkStatus();
    window.setInterval(checkStatus, REFRESH_INTERVAL_MS);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
