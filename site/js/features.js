// Renders data/status.json (generated from STATUS.md by tools/status_json.py) on the Features page.
(function () {
  "use strict";

  var KINDS = [
    { key: "Done", cls: "done", label: "done" },
    { key: "Partial", cls: "partial", label: "partial" },
    { key: "Missing", cls: "missing", label: "missing" },
    { key: "N/A", cls: "na", label: "N/A" }
  ];

  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }

  function bar(counts, total) {
    var b = el("div", "bar");
    b.setAttribute("aria-hidden", "true");
    KINDS.forEach(function (k) {
      var n = counts[k.key] || 0;
      if (!n || !total) return;
      var i = el("i", "c-" + k.cls);
      i.style.width = (100 * n / total) + "%";
      b.appendChild(i);
    });
    return b;
  }

  function render(data) {
    var md = window.MiniMarkdown;
    var root = document.getElementById("status");
    root.innerHTML = "";
    if (data.asOf) document.getElementById("as-of").textContent = "Last checked " + data.asOf + ".";

    var t = data.totals;
    var applicable = t.total - t["N/A"];
    var totals = el("div", "totals");
    [
      [t.Done, "done"],
      [t.Partial, "partial"],
      [t.Missing, "missing"],
      [applicable ? Math.round(100 * (t.Done + t.Partial) / applicable) + "%" : "–", "of applicable features work"]
    ].forEach(function (s) {
      var d = el("div", "stat");
      d.appendChild(el("b", null, md.escape(String(s[0]))));
      d.appendChild(el("span", null, md.escape(s[1])));
      totals.appendChild(d);
    });
    root.appendChild(totals);

    var legend = el("div", "legend");
    KINDS.forEach(function (k) { legend.appendChild(el("span", null, '<i class="c-' + k.cls + '"></i>' + k.label)); });
    root.appendChild(legend);

    var filters = el("div", "filters");
    filters.setAttribute("role", "group");
    filters.setAttribute("aria-label", "Show features");
    var current = "all";
    [["all", "All"], ["Done", "Done"], ["Partial", "Partial"], ["Missing", "Missing"]].forEach(function (f) {
      var btn = el("button", null, md.escape(f[1]));
      btn.type = "button";
      btn.setAttribute("aria-pressed", f[0] === current ? "true" : "false");
      btn.addEventListener("click", function () {
        current = f[0];
        Array.prototype.forEach.call(filters.children, function (b) { b.setAttribute("aria-pressed", b === btn ? "true" : "false"); });
        apply();
      });
      filters.appendChild(btn);
    });
    root.appendChild(filters);

    var areas = [];
    data.sections.forEach(function (s) {
      var d = el("details", "area");
      d.id = "area-" + s.number;
      var sum = el("summary");
      sum.appendChild(el("span", "name", md.escape(s.number + ". " + s.title)));
      var parts = KINDS.filter(function (k) { return s.counts[k.key]; })
        .map(function (k) { return s.counts[k.key] + " " + k.label; });
      sum.appendChild(el("span", "counts", md.escape(parts.join(" · "))));
      sum.appendChild(bar(s.counts, s.total));
      d.appendChild(sum);

      if (s.intro && s.intro.length) {
        var intro = el("div", "small muted", md.render(s.intro.join("\n")));
        d.appendChild(intro);
      }
      var list = el("ul", "rows");
      s.rows.forEach(function (r) {
        var kind = KINDS.filter(function (k) { return k.key === r.status; })[0] || KINDS[3];
        var li = el("li");
        li.setAttribute("data-status", r.status);
        var pill = el("span", "pill " + (kind.cls === "na" ? "na" : "c-" + kind.cls), md.escape(r.label));
        li.appendChild(pill);
        li.appendChild(el("span", "feature", md.inline(r.feature)));
        if (r.notes) li.appendChild(el("span", "notes", md.inline(r.notes)));
        list.appendChild(li);
      });
      d.appendChild(list);
      root.appendChild(d);
      areas.push(d);
    });

    function apply() {
      areas.forEach(function (d) {
        var shown = 0;
        Array.prototype.forEach.call(d.querySelectorAll("li[data-status]"), function (li) {
          var on = current === "all" || li.getAttribute("data-status") === current;
          li.hidden = !on;
          if (on) shown++;
        });
        d.hidden = shown === 0;
        if (current !== "all") d.open = true;
      });
    }

    var limits = document.getElementById("known-limits");
    data.knownLimits.forEach(function (k) {
      var li = el("li", null, md.inline(k.text));
      if (k.items.length) {
        var ul = el("ul");
        k.items.forEach(function (x) { ul.appendChild(el("li", null, md.inline(x))); });
        li.appendChild(ul);
      }
      limits.appendChild(li);
    });
    var np = document.getElementById("not-possible");
    data.notPossible.forEach(function (x) { np.appendChild(el("li", null, md.inline(x))); });

    if (location.hash) {
      var target = document.getElementById(location.hash.slice(1));
      if (target && target.tagName === "DETAILS") target.open = true;
      if (target) target.scrollIntoView();
    }
  }

  function fail() {
    var root = document.getElementById("status");
    root.innerHTML = '<p class="muted">The feature list couldn’t be loaded. It is also on GitHub: ' +
      '<a href="https://github.com/Edwardrem/analytics-desktop/blob/main/STATUS.md">STATUS.md</a>.</p>';
  }

  document.addEventListener("DOMContentLoaded", function () {
    fetch("data/status.json", { cache: "no-cache" })
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then(function (data) {
        if (!data || !Array.isArray(data.sections)) throw new Error("bad data");
        render(data);
      })
      .catch(fail);
  });
})();
