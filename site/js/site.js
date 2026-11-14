// Shared helpers: GitHub release lookup, the Home download button, and screenshot slots.
(function () {
  "use strict";

  var REPO = "Edwardrem/analytics-desktop";
  var API = "https://api.github.com/repos/" + REPO + "/releases?per_page=30";
  var CACHE_KEY = "ad-releases-v1";
  var CACHE_MS = 10 * 60 * 1000;

  function readCache() {
    try {
      var raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var c = JSON.parse(raw);
      return Date.now() - c.at < CACHE_MS && Array.isArray(c.data) ? c.data : null;
    } catch (e) { return null; }
  }
  function writeCache(data) {
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data: data })); } catch (e) { /* storage off */ }
  }

  // Resolves to the list of published releases (newest first); rejects on network or API errors.
  function fetchReleases() {
    var cached = readCache();
    if (cached) return Promise.resolve(cached);
    return fetch(API, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("GitHub answered " + r.status);
        return r.json();
      })
      .then(function (list) {
        if (!Array.isArray(list)) throw new Error("Unexpected answer from GitHub");
        var published = list.filter(function (r) { return r && !r.draft; });
        writeCache(published);
        return published;
      });
  }

  function isBeta(rel) {
    return !!rel.prerelease || /-/.test(String(rel.tag_name || ""));
  }

  // The release the Download button offers: the newest stable one, or the newest beta if there is no stable yet.
  function pickLatest(list) {
    var stable = list.filter(function (r) { return !isBeta(r); });
    return stable[0] || list[0] || null;
  }

  function appZip(rel) {
    var assets = (rel && rel.assets) || [];
    var named = assets.filter(function (a) { return /^AnalyticsDesktop-.+\.zip$/.test(a.name); });
    var zips = named.length ? named : assets.filter(function (a) { return /\.zip$/i.test(a.name); });
    return zips[0] || null;
  }

  function formatSize(bytes) {
    var n = Number(bytes) || 0;
    if (n < 1024) return n + " bytes";
    var units = ["KB", "MB", "GB"];
    var i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
    return (n >= 100 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i];
  }

  function versionOf(rel) {
    return String(rel.tag_name || rel.name || "").replace(/^v/, "");
  }

  function wireDownload() {
    var button = document.getElementById("download");
    var meta = document.getElementById("download-meta");
    if (!button) return;
    fetchReleases().then(function (list) {
      var rel = pickLatest(list);
      var zip = appZip(rel);
      if (!rel || !zip || !/^https:\/\//.test(zip.browser_download_url)) return; // keep the Releases fallback link
      button.href = zip.browser_download_url;
      button.textContent = "Download " + versionOf(rel) + (isBeta(rel) ? " beta" : "");
      if (meta) meta.textContent = zip.name + " · " + formatSize(zip.size) + " · macOS 15 or later, Apple silicon";
    }).catch(function () { /* the static link to GitHub Releases stays */ });
  }

  // <figure class="shot" data-src="img/x.png" hidden> shows itself only once the image exists.
  function wireShots() {
    var figures = document.querySelectorAll("figure.shot[data-src]");
    Array.prototype.forEach.call(figures, function (fig) {
      var img = new Image();
      img.alt = fig.getAttribute("data-alt") || "";
      img.onload = function () { fig.insertBefore(img, fig.firstChild); fig.hidden = false; };
      img.src = fig.getAttribute("data-src");
    });
  }

  window.AnalyticsSite = {
    repo: REPO,
    fetchReleases: fetchReleases,
    pickLatest: pickLatest,
    isBeta: isBeta,
    appZip: appZip,
    formatSize: formatSize,
    versionOf: versionOf
  };

  document.addEventListener("DOMContentLoaded", function () { wireDownload(); wireShots(); });
})();
