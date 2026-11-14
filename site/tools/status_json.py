#!/usr/bin/env python3
"""Turn STATUS.md into site/data/status.json for the Features page.

Usage: python3 site/tools/status_json.py STATUS.md site/data/status.json

Standard library only. Counts per area come from the feature rows themselves, so the page can
never disagree with the tables; a summary row that differs is reported as a warning.
"""
import json
import re
import sys

STATUSES = ("Done", "Partial", "Missing", "N/A")
SECTION = re.compile(r"^##\s+(\d+)\.\s+(.+?)\s*$")
HEADING = re.compile(r"^##\s+(.+?)\s*$")
NUMBERED = re.compile(r"^(\d+)\.\s+(.*)$")
AS_OF = re.compile(r"as of (\d{1,2} \w+ \d{4})")


def cells(line):
    """Split a Markdown table row into trimmed cells, or None if it isn't one."""
    line = line.strip()
    if not (line.startswith("|") and line.endswith("|")):
        return None
    return [c.strip() for c in line[1:-1].split("|")]


def is_separator(row):
    return all(re.fullmatch(r":?-{3,}:?", c) for c in row)


def status_key(text):
    """'Partial (extra)' -> 'Partial'; anything unknown -> None."""
    for s in STATUSES:
        if text == s or text.startswith(s + " "):
            return s
    return None


def parse(md):
    lines = md.splitlines()
    out = {"asOf": None, "sections": [], "notPossible": [], "knownLimits": [], "warnings": []}
    m = AS_OF.search(md)
    if m:
        out["asOf"] = m.group(1)

    summary = {}
    current = None   # the section dict being filled, or a string naming a prose block
    for raw in lines:
        sec = SECTION.match(raw)
        head = HEADING.match(raw)
        if sec:
            current = {"number": int(sec.group(1)), "title": sec.group(2), "rows": [], "intro": []}
            out["sections"].append(current)
            continue
        if head:
            current = head.group(1).strip().lower()
            continue

        row = cells(raw)
        if current == "summary" and row and not is_separator(row) and row[0] != "Section":
            name = row[0].replace("*", "").strip()
            nums = [int(c.replace("*", "")) for c in row[1:6] if c.replace("*", "").isdigit()]
            if len(nums) == 5:
                summary[name] = nums
        elif isinstance(current, dict):
            if row:
                if is_separator(row) or row[:2] == ["Feature", "Status"]:
                    continue
                if len(row) >= 3:
                    key = status_key(row[1])
                    if key is None:
                        out["warnings"].append(f"Unknown status '{row[1]}' in §{current['number']}")
                        continue
                    current["rows"].append({"feature": row[0], "status": key,
                                            "label": row[1], "notes": " | ".join(row[2:])})
            elif raw.strip():
                current["intro"].append(raw.strip())
        elif current == "not possible here":
            if raw.startswith("- "):
                out["notPossible"].append(raw[2:].strip())
        elif current == "known limits":
            num = NUMBERED.match(raw)
            if num:
                out["knownLimits"].append({"text": num.group(2).strip(), "items": []})
            elif raw.lstrip().startswith("- ") and out["knownLimits"]:
                out["knownLimits"][-1]["items"].append(raw.lstrip()[2:].strip())

    totals = dict.fromkeys(STATUSES, 0)
    for s in out["sections"]:
        counts = dict.fromkeys(STATUSES, 0)
        for r in s["rows"]:
            counts[r["status"]] += 1
        s["counts"] = counts
        s["total"] = len(s["rows"])
        for k in STATUSES:
            totals[k] += counts[k]
        label = f"{s['number']}. {s['title']}"
        listed = summary.get(label)
        mine = [counts[k] for k in STATUSES] + [s["total"]]
        if listed is not None and listed != mine:
            out["warnings"].append(f"Summary row for '{label}' says {listed}, the table has {mine}")
    out["totals"] = dict(totals, total=sum(totals.values()))
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        data = parse(f.read())
    if not data["sections"]:
        print("No feature sections found in " + argv[1], file=sys.stderr)
        return 1
    for w in data["warnings"]:
        print("warning: " + w, file=sys.stderr)
    with open(argv[2], "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    t = data["totals"]
    print(f"Wrote {argv[2]}: {len(data['sections'])} areas, {t['total']} features "
          f"({t['Done']} done, {t['Partial']} partial, {t['Missing']} missing, {t['N/A']} N/A)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
