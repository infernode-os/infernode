#!/usr/bin/env python3
#
# github-analytics.py — capture a daily snapshot of GitHub metrics for
# infernode-os/infernode and regenerate analytics/README.md.
#
# Designed to run from .github/workflows/analytics.yml (daily cron) or
# locally with `GH_TOKEN=$(gh auth token) python3 tools/github-analytics.py`.
# Stdlib only; no pip install. The traffic endpoints require a token
# with push access — the workflow's default GITHUB_TOKEN has it.
#
# Output:
#   analytics/snapshots.jsonl  — append-only, one JSON line per day.
#                                Re-running on the same day overwrites
#                                that day's row.
#   analytics/README.md        — dashboard regenerated every run.
#
# Usage:
#   python3 tools/github-analytics.py

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = "infernode-os/infernode"
API = "https://api.github.com"
ROOT = Path(__file__).resolve().parent.parent
ANALYTICS_DIR = ROOT / "analytics"
SNAPSHOTS = ANALYTICS_DIR / "snapshots.jsonl"
DASHBOARD = ANALYTICS_DIR / "README.md"


def gh(path, params=None):
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("error: set GH_TOKEN or GITHUB_TOKEN (a token with push access for traffic endpoints)")
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "infernode-analytics",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"error: GET {path} -> HTTP {e.code}: {e.read().decode('utf-8', 'replace')}")


def gh_paginated(path, params=None):
    out = []
    params = dict(params or {})
    params["per_page"] = 100
    page = 1
    while True:
        params["page"] = page
        batch = gh(path, params)
        if not batch:
            break
        out.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return out


def search_count(q):
    return gh("/search/issues", {"q": q, "per_page": 1})["total_count"]


def fetch_snapshot():
    repo = gh(f"/repos/{REPO}")
    releases = gh_paginated(f"/repos/{REPO}/releases")
    issues_open = search_count(f"repo:{REPO} is:issue is:open")
    issues_closed = search_count(f"repo:{REPO} is:issue is:closed")
    prs_open = search_count(f"repo:{REPO} is:pr is:open")
    prs_merged = search_count(f"repo:{REPO} is:pr is:merged")
    prs_closed_unmerged = search_count(f"repo:{REPO} is:pr is:closed is:unmerged")
    views = gh(f"/repos/{REPO}/traffic/views")
    clones = gh(f"/repos/{REPO}/traffic/clones")
    referrers = gh(f"/repos/{REPO}/traffic/popular/referrers")
    paths = gh(f"/repos/{REPO}/traffic/popular/paths")

    return {
        "timestamp": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "repo": {
            "stars": repo["stargazers_count"],
            "forks": repo["forks_count"],
            "watchers": repo["watchers_count"],
            "subscribers": repo["subscribers_count"],
            "network": repo.get("network_count", 0),
            "size_kb": repo["size"],
        },
        "issues": {"open": issues_open, "closed": issues_closed},
        "pulls": {
            "open": prs_open,
            "merged": prs_merged,
            "closed_unmerged": prs_closed_unmerged,
        },
        "releases": [
            {
                "tag": r["tag_name"],
                "name": r["name"],
                "draft": r["draft"],
                "prerelease": r["prerelease"],
                "published_at": r.get("published_at"),
                "assets": [
                    {
                        "name": a["name"],
                        "size": a["size"],
                        "downloads": a["download_count"],
                    }
                    for a in r["assets"]
                ],
                "total_downloads": sum(a["download_count"] for a in r["assets"]),
            }
            for r in releases
        ],
        "traffic": {
            "views_14d": views.get("count", 0),
            "views_14d_uniques": views.get("uniques", 0),
            "views_daily": views.get("views", []),
            "clones_14d": clones.get("count", 0),
            "clones_14d_uniques": clones.get("uniques", 0),
            "clones_daily": clones.get("clones", []),
            "referrers": referrers,
            "paths": paths,
        },
    }


def load_history():
    if not SNAPSHOTS.exists():
        return []
    return [
        json.loads(line)
        for line in SNAPSHOTS.read_text().splitlines()
        if line.strip()
    ]


def write_snapshot(snap):
    ANALYTICS_DIR.mkdir(parents=True, exist_ok=True)
    history = load_history()
    today = snap["timestamp"][:10]
    history = [h for h in history if h["timestamp"][:10] != today]
    history.append(snap)
    history.sort(key=lambda h: h["timestamp"])
    SNAPSHOTS.write_text(
        "\n".join(json.dumps(h, separators=(",", ":"), sort_keys=True) for h in history) + "\n"
    )


def lookback(history, today_iso, days):
    target = (datetime.fromisoformat(today_iso + "T00:00:00+00:00") - timedelta(days=days)).date().isoformat()
    candidates = [h for h in history if h["timestamp"][:10] <= target]
    return max(candidates, key=lambda h: h["timestamp"]) if candidates else None


def diff(current, prior, getter):
    if prior is None:
        return "—"
    d = getter(current) - getter(prior)
    return f"+{d}" if d > 0 else str(d)


def published_total_downloads(snap):
    return sum(r["total_downloads"] for r in snap["releases"] if not r["draft"])


def render_dashboard(snap, history):
    today = snap["timestamp"][:10]
    prior7 = lookback(history, today, 7)
    prior30 = lookback(history, today, 30)

    out = []
    out.append("# InferNode analytics")
    out.append("")
    out.append(
        f"Snapshot captured `{snap['timestamp']}`. Updated daily by "
        "[`.github/workflows/analytics.yml`](../.github/workflows/analytics.yml). "
        "Raw time series in [`snapshots.jsonl`](snapshots.jsonl)."
    )
    out.append("")

    out.append("## Engagement")
    out.append("")
    out.append("| Metric | Current | Δ 7d | Δ 30d |")
    out.append("|---|---:|---:|---:|")
    for label, key in [
        ("Stars", "stars"),
        ("Forks", "forks"),
        ("Watchers", "watchers"),
        ("Subscribers", "subscribers"),
    ]:
        getter = lambda s, k=key: s["repo"][k]
        out.append(
            f"| {label} | {snap['repo'][key]} | "
            f"{diff(snap, prior7, getter)} | {diff(snap, prior30, getter)} |"
        )
    out.append("")

    out.append("## Issues & pull requests")
    out.append("")
    out.append("| State | Issues | PRs |")
    out.append("|---|---:|---:|")
    out.append(f"| Open | {snap['issues']['open']} | {snap['pulls']['open']} |")
    out.append(f"| Merged | — | {snap['pulls']['merged']} |")
    out.append(
        f"| Closed (unmerged) | {snap['issues']['closed']} | {snap['pulls']['closed_unmerged']} |"
    )
    out.append("")

    out.append("## Release downloads")
    out.append("")
    total = published_total_downloads(snap)
    d7 = diff(snap, prior7, published_total_downloads)
    d30 = diff(snap, prior30, published_total_downloads)
    out.append(f"Lifetime downloads across published releases: **{total}** (Δ 7d {d7}, Δ 30d {d30}).")
    out.append("")
    out.append("| Release | Published | Downloads |")
    out.append("|---|---|---:|")
    for r in sorted(
        [r for r in snap["releases"] if not r["draft"]],
        key=lambda r: r.get("published_at") or "",
        reverse=True,
    ):
        when = (r.get("published_at") or "")[:10]
        tag = r["tag"] + (" *(pre)*" if r["prerelease"] else "")
        out.append(f"| `{tag}` | {when} | {r['total_downloads']} |")
    out.append("")

    # Top assets across all releases (skip sidecar files like .pem/.sig/SHA256SUMS).
    sidecars = (".pem", ".sig", ".sigstore", "SHA256SUMS.txt")
    top = []
    for r in snap["releases"]:
        if r["draft"]:
            continue
        for a in r["assets"]:
            if a["downloads"] <= 0:
                continue
            if any(a["name"].endswith(s) for s in sidecars):
                continue
            top.append((r["tag"], a["name"], a["downloads"]))
    top.sort(key=lambda x: x[2], reverse=True)
    if top:
        out.append("### Top assets")
        out.append("")
        out.append("| Release | Asset | Downloads |")
        out.append("|---|---|---:|")
        for tag, name, d in top[:10]:
            out.append(f"| `{tag}` | `{name}` | {d} |")
        out.append("")

    out.append("## Traffic (last 14 days)")
    out.append("")
    out.append(
        f"- Views: **{snap['traffic']['views_14d']}** total, "
        f"**{snap['traffic']['views_14d_uniques']}** unique visitors"
    )
    out.append(
        f"- Clones: **{snap['traffic']['clones_14d']}** total, "
        f"**{snap['traffic']['clones_14d_uniques']}** unique cloners"
    )
    out.append("")

    if snap["traffic"]["referrers"]:
        out.append("### Top referrers")
        out.append("")
        out.append("| Referrer | Views | Uniques |")
        out.append("|---|---:|---:|")
        for r in snap["traffic"]["referrers"][:10]:
            out.append(f"| {r['referrer']} | {r['count']} | {r['uniques']} |")
        out.append("")

    if snap["traffic"]["paths"]:
        out.append("### Top paths")
        out.append("")
        out.append("| Path | Views | Uniques |")
        out.append("|---|---:|---:|")
        for p in snap["traffic"]["paths"][:10]:
            out.append(f"| `{p['path']}` | {p['count']} | {p['uniques']} |")
        out.append("")

    DASHBOARD.write_text("\n".join(out))


def main():
    snap = fetch_snapshot()
    write_snapshot(snap)
    render_dashboard(snap, load_history())
    print(f"snapshot captured {snap['timestamp']}")
    print(f"  {SNAPSHOTS.relative_to(ROOT)}")
    print(f"  {DASHBOARD.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
