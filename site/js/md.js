// A small, safe Markdown renderer for release notes and status text.
// Every piece of source text is HTML-escaped before any markup is added, and links are kept only
// when they are http(s), so nothing from a release body can inject markup or script.
(function () {
  "use strict";

  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function safeURL(escapedURL) {
    // The URL arrives already escaped; undo only &amp; to test the scheme.
    var raw = escapedURL.replace(/&amp;/g, "&");
    return /^https?:\/\//i.test(raw) ? escapedURL : null;
  }

  // Inline markup on one already-escaped line: code spans first (their contents stay literal),
  // then links, bold, italic.
  function inline(text) {
    var codes = [];
    var s = escapeHTML(text).replace(/`([^`]+)`/g, function (_, c) {
      codes.push("<code>" + c + "</code>");
      return "\u0000" + (codes.length - 1) + "\u0000";
    });
    s = s.replace(/\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)/g, function (all, label, url) {
      var ok = safeURL(url);
      return ok ? '<a href="' + ok + '" rel="noopener">' + label + "</a>" : label;
    });
    s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, function (all, lead, url) {
      return lead + '<a href="' + url + '" rel="noopener">' + url + "</a>";
    });
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*\w])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
    return s.replace(/\u0000(\d+)\u0000/g, function (_, i) { return codes[Number(i)]; });
  }

  function block(md) {
    var lines = String(md || "").replace(/\r\n?/g, "\n").split("\n");
    var html = [];
    var para = [];
    var lists = []; // stack of {type, indent}
    var i = 0;

    function flushPara() {
      if (para.length) { html.push("<p>" + para.map(inline).join(" ") + "</p>"); para = []; }
    }
    function closeLists(toIndent) {
      while (lists.length && lists[lists.length - 1].indent >= toIndent) {
        html.push("</li></" + lists.pop().type + ">");
      }
    }

    while (i < lines.length) {
      var line = lines[i];
      var fence = /^\s*(```|~~~)/.exec(line);
      if (fence) {
        flushPara(); closeLists(0);
        var code = [];
        i++;
        while (i < lines.length && lines[i].trim().indexOf(fence[1]) !== 0) { code.push(lines[i]); i++; }
        html.push("<pre><code>" + escapeHTML(code.join("\n")) + "</code></pre>");
        i++;
        continue;
      }
      var h = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
      var item = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
      if (h) {
        flushPara(); closeLists(0);
        // Release notes sit under the page's own headings, so shift them down two levels.
        var level = Math.min(6, h[1].length + 2);
        html.push("<h" + level + ">" + inline(h[2]) + "</h" + level + ">");
      } else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
        flushPara(); closeLists(0);
        html.push("<hr>");
      } else if (item) {
        flushPara();
        var indent = item[1].replace(/\t/g, "    ").length;
        var type = /\d/.test(item[2]) ? "ol" : "ul";
        var top = lists[lists.length - 1];
        if (top && indent < top.indent) closeLists(indent + 1);
        top = lists[lists.length - 1];
        if (!top || indent > top.indent) {
          lists.push({ type: type, indent: indent });
          html.push("<" + type + "><li>");
        } else {
          if (top.type !== type) {
            html.push("</li></" + lists.pop().type + ">");
            lists.push({ type: type, indent: indent });
            html.push("<" + type + "><li>");
          } else {
            html.push("</li><li>");
          }
        }
        html.push(inline(item[3]));
      } else if (/^\s*>\s?/.test(line)) {
        flushPara(); closeLists(0);
        html.push("<blockquote><p>" + inline(line.replace(/^\s*>\s?/, "")) + "</p></blockquote>");
      } else if (!line.trim()) {
        flushPara();
        // A blank line ends a list unless the next line continues it.
        var next = lines[i + 1] || "";
        if (!/^(\s*)([-*+]|\d+[.)])\s+/.test(next)) closeLists(0);
      } else if (lists.length && /^\s+\S/.test(line)) {
        html.push(" " + inline(line.trim()));
      } else {
        closeLists(0);
        para.push(line.trim());
      }
      i++;
    }
    flushPara(); closeLists(0);
    return html.join("");
  }

  window.MiniMarkdown = { render: block, inline: inline, escape: escapeHTML };
})();
