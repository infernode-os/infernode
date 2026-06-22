#!/usr/bin/env python3
"""jira-transition-on-merge.py — move referenced Jira issues to Done on merge.

This is the other half of the "stop stranding finished tickets" fix.  When a
PR merges to master, the squash commit (this repo squash-merges) carries the
PR title + body, which by convention references one or more `INFR-<n>` keys.
This script reads commit-message text, extracts those keys, and transitions
each issue to Done — unless it is already Done — leaving an audit comment that
points at the merge.

Design choices:
  * Stdlib only (urllib) so CI needs no pip install.
  * Idempotent: issues already in a Done status category are skipped.
  * Fail-soft on configuration: if Jira credentials are absent (e.g. a fork
    without secrets), it logs and exits 0 rather than failing the build.
    Genuine API errors with creds present DO exit non-zero so they're visible.
  * --dry-run prints what it would do and changes nothing.

Env:
  JIRA_BASE_URL    e.g. https://nervsystems-team.atlassian.net
  JIRA_EMAIL       Atlassian account email
  JIRA_API_TOKEN   Atlassian API token (https://id.atlassian.com/manage/api-tokens)

Usage:
  git log --format='%B' <before>..<after> | tools/jira-transition-on-merge.py --context "merge abc1234"
  tools/jira-transition-on-merge.py --keys INFR-4 INFR-18 --dry-run
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

KEY_RE = re.compile(r"\bINFR-[0-9]+\b", re.IGNORECASE)
DONE_STATUS_NAME = "Done"


def log(msg):
    print(msg, flush=True)


def extract_keys(text):
    return sorted({m.upper() for m in KEY_RE.findall(text)}, key=lambda k: int(k.split("-")[1]))


class Jira:
    def __init__(self, base_url, email, token):
        self.base = base_url.rstrip("/")
        auth = base64.b64encode(f"{email}:{token}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _req(self, method, path, body=None):
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, headers=self.headers, method=method)
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    def get_status(self, key):
        issue = self._req("GET", f"/rest/api/3/issue/{key}?fields=status")
        st = issue["fields"]["status"]
        return st["name"], st["statusCategory"]["key"]  # e.g. ("In Review", "indeterminate")

    def find_done_transition(self, key):
        data = self._req("GET", f"/rest/api/3/issue/{key}/transitions")
        for t in data.get("transitions", []):
            if t["to"]["name"].lower() == DONE_STATUS_NAME.lower() or \
               t["to"]["statusCategory"]["key"] == "done":
                return t["id"], t["to"]["name"]
        return None, None

    def transition(self, key, transition_id):
        self._req("POST", f"/rest/api/3/issue/{key}/transitions",
                  {"transition": {"id": transition_id}})

    def comment(self, key, text):
        body = {
            "body": {
                "type": "doc", "version": 1,
                "content": [{"type": "paragraph",
                             "content": [{"type": "text", "text": text}]}],
            }
        }
        self._req("POST", f"/rest/api/3/issue/{key}/comment", body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", nargs="*", default=[], help="explicit issue keys")
    ap.add_argument("--context", default="", help="audit string (e.g. 'merge <sha>' or PR URL)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    text = "" if sys.stdin.isatty() else sys.stdin.read()
    keys = sorted(set(args.keys) | set(extract_keys(text)),
                  key=lambda k: int(k.split("-")[1]))

    if not keys:
        log("jira-transition: no INFR-<n> keys found in input; nothing to do.")
        return 0

    log(f"jira-transition: candidate keys: {', '.join(keys)}")

    base_url = os.environ.get("JIRA_BASE_URL", "").strip()
    email = os.environ.get("JIRA_EMAIL", "").strip()
    token = os.environ.get("JIRA_API_TOKEN", "").strip()

    if args.dry_run:
        log(f"jira-transition: DRY RUN — would transition {', '.join(keys)} → {DONE_STATUS_NAME}.")
        return 0

    if not (base_url and email and token):
        # Fork PR / unconfigured environment: do not fail the merge.
        log("jira-transition: JIRA_BASE_URL/JIRA_EMAIL/JIRA_API_TOKEN not all set; "
            "skipping (this is expected on forks). No tickets changed.")
        return 0

    jira = Jira(base_url, email, token)
    ctx = args.context or "a merge to master"
    errors = 0

    for key in keys:
        try:
            name, category = jira.get_status(key)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                log(f"  {key}: not found (skipping).")
                continue
            log(f"  {key}: status lookup failed ({e.code}); skipping.")
            errors += 1
            continue
        except Exception as e:  # noqa: BLE001
            log(f"  {key}: status lookup error: {e}; skipping.")
            errors += 1
            continue

        if category == "done":
            log(f"  {key}: already Done ({name}); skipping.")
            continue

        tid, target = jira.find_done_transition(key)
        if not tid:
            log(f"  {key}: no Done transition available from '{name}'; skipping.")
            continue

        try:
            jira.transition(key, tid)
            jira.comment(
                key,
                f"Auto-transitioned to {target} by jira-transition-on-merge: "
                f"referenced from {ctx}. (Was '{name}'.) If this is premature, reopen.",
            )
            log(f"  {key}: '{name}' → {target}.")
        except Exception as e:  # noqa: BLE001
            log(f"  {key}: transition failed: {e}")
            errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
