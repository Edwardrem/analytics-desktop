// Renders GitHub Releases on the Releases page. All text from the API goes through MiniMarkdown,
// which escapes HTML first; only https download links are used.
(function () {
  "use strict";

  var GH_RELEASES = "https://github.com/Edwardrem/analytics-desktop/releases";

  function esc(s) { return window.MiniMarkdown.escape(s == null ? "" : String(s)); }

  function date(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
  }

  function release(rel, latest) {
    var site = window.AnalyticsSite;
    var art = document.createElement("article");
    art.className = "release";
    var tag = String(rel.tag_name || "");
    var anchor = tag.replace(/[^A-Za-z0-9._-]/g, "");
    if (anchor) art.id = anchor;

    var title = rel.name && rel.name.trim() ? rel.name.trim() : tag;
    var head = '<header><h2>' + esc(title) + "</h2>";
    if (site.isBeta(rel)) head += '<span class="tag">Beta</span>';
    if (rel === latest) head += '<span class="tag latest">Latest</span>';
    var when = date(rel.published_at || rel.created_at);
    if (when) head += '<span class="muted small">' + esc(when) + "</span>";
    head += "</header>";

    var notes = rel.body && rel.body.trim()
      ? '<div class="notes">' + window.MiniMarkdown.render(rel.body) + "</div>"
      : '<p class="muted">No release notes.</p>';

    var assets = (rel.assets || []).filter(function (a) { return /^https:\/\//.test(a.browser_download_url || ""); });
    var list = "";
    if (assets.length) {
      list = '<ul class="assets">' + assets.map(function (a) {
        return '<li><a href="' + esc(a.browser_download_url) + '">' + esc(a.name) + '</a><span class="size">' +
          esc(site.formatSize(a.size)) + "</span></li>";
      }).join("") + "</ul>";
    }
    var page = /^https:\/\/github\.com\//.test(rel.html_url || "") ? rel.html_url : GH_RELEASES;
    var more = '<p class="small"><a href="' + esc(page) + '">View on GitHub</a></p>';

    art.innerHTML = head + notes + list + more;
    return art;
  }

  function empty(root, title, text) {
    root.innerHTML = '<div class="empty"><h2>' + esc(title) + "</h2><p>" + esc(text) + '</p><p><a class="button secondary" href="' +
      GH_RELEASES + '">Open GitHub Releases</a></p></div>';
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.getElementById("releases");
    window.AnalyticsSite.fetchReleases().then(function (list) {
      if (!list.length) {
        empty(root, "No releases yet", "The first beta is on its way. Releases will appear here as soon as they are published.");
        return;
      }
      var latest = window.AnalyticsSite.pickLatest(list);
      root.innerHTML = "";
      list.forEach(function (rel) { root.appendChild(release(rel, latest)); });
      if (location.hash) {
        var target = document.getElementById(location.hash.slice(1));
        if (target) target.scrollIntoView();
      }
    }).catch(function () {
      empty(root, "Releases couldn’t be loaded", "GitHub didn’t answer just now, or its hourly limit for this network has been reached. The same list is on GitHub.");
    });
  });
})();
