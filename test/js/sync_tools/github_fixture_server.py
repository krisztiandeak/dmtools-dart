#!/usr/bin/env python3
"""Scripted GitHub API fixture server for GitHubSyncTools tests.

Dart's HttpServer runs on the event loop, frozen during
`Process.runSync('curl', ...)`; this Python subprocess serves the curl
requests instead (same pattern as test/js/test_echo_server.py).

Serves canned GitHub REST/GraphQL shapes for the multi-request tool
flows (paginated comments, pending-review submit, releases, log-ZIP
redirect + download) and a generic JSON echo for everything else.

Usage:
    python3 github_fixture_server.py [port] [request_log]

Prints the bound port to stdout, appends one `METHOD path` line per
request to the request log, and mirrors the last echoed request JSON to
`<request_log>.last.json` (for asserting the final request of a flow).
"""

import http.server
import io
import json
import sys
import zipfile
from urllib.parse import parse_qs, urlparse

FIXTURE_PR = {
    "number": 42,
    "title": "Add feature",
    "head": {"sha": "abc123def456"},
    "merged_at": None,
}

FIXTURE_PRS = [
    {"number": 1, "title": "A", "merged_at": "2024-01-01T00:00:00Z"},
    {"number": 2, "title": "B", "merged_at": None},
]

INLINE_COMMENTS = [
    {"id": 1, "path": "src/a.txt", "body": "root",
     "created": "2024-01-02T00:00:00Z", "in_reply_to_id": None},
    {"id": 2, "path": "src/a.txt", "body": "reply",
     "created": "2024-01-03T00:00:00Z", "in_reply_to_id": 1},
    {"id": 3, "path": "src/b.txt", "body": "orphan reply",
     "created": "2024-01-04T00:00:00Z", "in_reply_to_id": 99},
]

ISSUE_COMMENTS = [
    {"id": 10, "body": "issue comment",
     "created": "2024-01-01T00:00:00Z", "in_reply_to_id": None},
]

FIXTURE_ISSUE = {
    "number": 50,
    "title": "Route gh-N tracker ops",
    "body": "issue body text",
    "state": "open",
    "labels": [{"name": "agent:review"}, {"name": "status:In Progress"}],
    "assignee": {"login": "octocat"},
    "user": {"login": "octocat"},
}

FIXTURE_ISSUE_CLOSED = {
    "number": 61,
    "title": "Merged work",
    "body": "closed issue body",
    "state": "closed",
    "labels": [{"name": "status:Done"}],
    "user": {"login": "octocat"},
}

FIXTURE_ISSUE_COMMENTS = [
    {"id": 10, "body": "first comment",
     "created_at": "2024-01-01T00:00:00Z",
     "updated_at": "2024-01-01T00:00:00Z", "user": {"login": "octocat"}},
    {"id": 11, "body": "second comment",
     "created_at": "2024-01-02T00:00:00Z",
     "updated_at": "2024-01-02T00:00:00Z", "user": {"login": "hubot"}},
]

# The issues list endpoint also returns PRs — the router must drop them.
# #70 carries no status: label, so its status.name falls back to the state.
FIXTURE_ISSUES_LIST = [
    FIXTURE_ISSUE,
    {"number": 60, "title": "A PR leaking into the issues list",
     "body": "", "state": "open", "labels": [],
     "pull_request": {"url": "https://api.github.com/repos/o/r/pulls/60"},
     "user": {"login": "octocat"}},
    {"number": 70, "title": "Closed without a status label",
     "body": "", "state": "closed", "labels": [],
     "user": {"login": "octocat"}},
]

FIXTURE_RELEASES = [
    {"id": 5, "tag_name": "existing-tag", "name": "Existing Draft",
     "draft": True, "assets": [{"id": 77, "name": "report.txt"}]},
]

DIFF_TEXT = """diff --git a/src/a.txt b/src/a.txt
--- a/src/a.txt
+++ b/src/a.txt
@@ -1 +1,2 @@
-old
+new
+extra
"""


def build_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("job1.txt", "step one log\n")
        zf.writestr("job2.txt", "step two log\n")
        zf.writestr("skip.bin", "not a text entry")
    return buf.getvalue()


def _comment(i):
    return {"id": 1000 + i, "body": "comment %d" % i,
            "created_at": "2024-02-01T00:00:%02dZ" % (i % 60),
            "updated_at": "2024-02-01T00:00:%02dZ" % (i % 60),
            "user": {"login": "octocat"}}


def _paged_issue(n):
    return {"number": n, "title": "Paged issue %d" % n, "body": "",
            "state": "open", "labels": [], "user": {"login": "octocat"}}


# Full first page (100 items) + short second page (1) for the paging
# walk (served for issue 61's comments and the assignee=pager list).
PAGE1_COMMENTS = [_comment(i) for i in range(100)]
PAGE2_COMMENTS = [_comment(100)]
PAGE1_ISSUES = [_paged_issue(200 + i) for i in range(100)]
PAGE2_ISSUES = [_paged_issue(99)]

# CI-tool fixtures (github_ci_sync_tools_test.dart).
BRANCHES_PAGE1 = [
    {"name": "match-a"},     # matches the test regex
    {"name": ""},            # empty name — skipped
    {"name": "nope"},        # regex no-match — skipped
    {"name": "paged"},       # 100+1 commit pages
] + [{"name": "noise-%02d" % i} for i in range(96)]  # 100-item first page
BRANCHES_PAGE2 = [{"name": "match-b"}]

# Per-branch commit pages. match-a/match-b share c2 so the SHA
# de-duplication is observable across branches; match-a also carries a
# null sha (empty key — skipped) and paged/ walks the page loop.
COMMITS_BY_BRANCH = {
    "match-a": [{"sha": "c1"}, {"sha": None}, {"sha": "c2"}],
    "match-b": [{"sha": "c2"}, {"sha": "c3"}],
}


def _paged_commit(i):
    return {"sha": "p%03d" % i, "message": "commit %d" % i}


COMMITS_PAGED_PAGE1 = [_paged_commit(i) for i in range(100)]
COMMITS_PAGED_PAGE2 = [{"sha": "p100"}]

# gh-1457-saga check-runs pagination fixture (live: fa #1457's head
# carried 355 check-runs across 4 CI runs + SM stamps — the default
# 30-run page hid the in_progress placeholder orphans on later pages
# from every SM detector; dmtools-agents#865). Page 1 is full (100),
# page 2 is short (3) and carries the orphan trio.
CHECK_RUNS_PAGE1 = {
    "total_count": 103,
    "check_runs": [
        {"id": 1000 + i, "name": "job-%03d" % i,
         "status": "completed", "conclusion": "success"}
        for i in range(100)
    ],
}
CHECK_RUNS_PAGE2 = {
    "total_count": 103,
    "check_runs": [
        {"id": 2000, "name": "Quality gate",
         "status": "in_progress", "conclusion": None},
        {"id": 2001, "name": "JS engine integration (quickjs-ng)",
         "status": "in_progress", "conclusion": None},
        {"id": 2002, "name": "Binaries smoke gate",
         "status": "in_progress", "conclusion": None},
    ],
}


FILTERED_PRS_PAGE1 = [
    {"number": i, "title": "t%03d" % i, "merged_at": "2024-01-01T00:00:00Z"}
    for i in range(99)
] + [{"number": 999, "title": "t-unmerged", "merged_at": None}]
FILTERED_PRS_PAGE2 = [{"number": 100, "title": "final",
                       "merged_at": "2024-02-01T00:00:00Z"}]


def _query_param(path, name):
    values = parse_qs(urlparse(path).query).get(name, [])
    return values[0] if values else None


class FixtureState(object):
    log_path = None
    last_path = None


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length).decode("utf-8", errors="replace")

    def _respond(self, code, payload, content_type="application/json"):
        if isinstance(payload, bytes):
            encoded = payload
        elif isinstance(payload, str):
            encoded = payload.encode("utf-8")
        else:
            encoded = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _record(self, body):
        if FixtureState.log_path:
            with open(FixtureState.log_path, "a") as fh:
                fh.write("%s %s\n" % (self.command, self.path))
        if FixtureState.last_path:
            with open(FixtureState.last_path, "w") as fh:
                fh.write(json.dumps({
                    "method": self.command,
                    "path": self.path,
                    "headers": {k: v for k, v in self.headers.items()},
                    "body": body,
                }))

    def _serve(self):
        body = ""
        if self.command in ("POST", "PUT", "PATCH"):
            body = self._read_body()
        path = self.path
        # Route matching ignores the query string (pagination params etc.).
        base = path.split("?")[0]
        accept = self.headers.get("Accept", "")

        # Job logs: plain-text body (the real endpoint answers raw logs,
        # not JSON — the bridge must JSON-encode it, live: dmtools-dart
        # rework legs starved on "host callback returned invalid JSON").
        if base.endswith("/actions/jobs/7/logs"):
            self._record(body)
            self._respond(
                200,
                "2026-10-17T08:00:00Z ##[error]method_size: 1 violations\n"
                "plain text, not JSON <<< >>>",
                "text/plain",
            )
            return

        # Job logs for job 302: like the real API, 302 to a signed blob
        # URL — the client must follow it (live: empty job logs).
        if base.endswith("/actions/jobs/302/logs"):
            self._record(body)
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%d/blob/job-302.txt"
                % self.server.server_address[1],
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if base == "/blob/job-302.txt":
            self._record(body)
            self._respond(
                200, "##[error]redirected blob log body\n", "text/plain"
            )
            return

        # Workflow run logs: 302 redirect to the ZIP archive.
        if base.endswith("/actions/runs/55/logs"):
            self._record(body)
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%d/zip" % self.server.server_address[1],
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if base == "/zip":
            self._record(body)
            self._respond(200, build_zip(), "application/zip")
            return

        # gh-388 list pagination: o/pg serves full page 1 + 2-item page
        # 2; o/pgfail fails page 2 (walk keeps page 1).
        if base.startswith("/repos/o/pg/") or base.startswith("/repos/o/pgfail/"):
            self._record(body)
            page = _query_param(path, "page") or "1"
            if page != "1" and base.startswith("/repos/o/pgfail/"):
                self._respond(500, '{"message": "page boom"}')
                return
            items = [{"id": int(page) * 1000 + i, "page": int(page)}
                     for i in range(100 if page == "1" else 2)]
            if base.endswith("/jobs"):
                self._respond(200, {"total_count": 102, "jobs": items})
            else:
                self._respond(200, items)
            return
        if base == "/repos/o/r/commits/pagedsha/check-runs":
            self._record(body)
            if _query_param(path, "page") == "2":
                self._respond(200, CHECK_RUNS_PAGE2)
            else:
                self._respond(200, CHECK_RUNS_PAGE1)
            return
        # PR endpoint answers a diff when asked with the diff accept header.
        is_pr_root = (
            base.startswith("/repos/o/r/pulls/42")
            and "comments" not in path
            and "merge" not in path
            and "reviews" not in path
        )
        if is_pr_root:
            self._record(body)
            if "vnd.github.diff" in accept:
                self._respond(200, DIFF_TEXT, "text/plain")
            else:
                self._respond(200, FIXTURE_PR)
            return

        if base == "/repos/o/r/pulls":
            self._record(body)
            self._respond(200, FIXTURE_PRS)
            return
        if base.endswith("/pulls/42/comments"):
            self._record(body)
            self._respond(200, INLINE_COMMENTS)
            return
        if base.endswith("/pulls/7/comments"):
            self._record(body)
            self._respond(500, '{"message": "boom"}')
            return
        # Plain issue #9: GitHub answers 404 for the review-comments page
        # (only PRs have one) but serves the discussion page normally.
        if base.endswith("/pulls/9/comments"):
            self._record(body)
            self._respond(404, '{"message": "Not Found"}')
            return
        if base.endswith("/issues/9/comments"):
            self._record(body)
            self._respond(
                200,
                [
                    {
                        "id": 21,
                        "body": "plain issue discussion",
                        "created_at": "2026-09-12T10:00:00Z",
                    }
                ],
            )
            return
        # Missing #8: both pages 404 — the error must still surface.
        if base.endswith("/pulls/8/comments"):
            self._record(body)
            self._respond(404, '{"message": "Not Found"}')
            return
        if base.endswith("/issues/8/comments"):
            self._record(body)
            self._respond(404, '{"message": "Not Found"}')
            return
        if base.endswith("/issues/42/comments"):
            self._record(body)
            self._respond(200, ISSUE_COMMENTS)
            return
        if base == "/repos/o/r/issues/42":
            self._record(body)
            self._respond(200, FIXTURE_PR)
            return

        # Tracker-routing fixtures (gh-N keys → GitHub Issues).
        if base == "/repos/o/r/issues/61/comments" and self.command == "GET":
            self._record(body)
            if _query_param(path, "page") == "2":
                self._respond(200, PAGE2_COMMENTS)
            else:
                self._respond(200, PAGE1_COMMENTS)
            return
        if base == "/repos/o/r/issues/999" and self.command == "GET":
            self._record(body)
            self._respond(404, {"message": "Not Found"})
            return
        if base == "/repos/o/r/issues/777" and self.command == "GET":
            self._record(body)
            self._respond(500, {"message": "boom"})
            return
        if base == "/repos/o/r/issues/50/comments" and self.command == "GET":
            self._record(body)
            self._respond(200, FIXTURE_ISSUE_COMMENTS)
            return
        if base == "/repos/o/r/issues/50/comments" and self.command == "POST":
            self._record(body)
            posted = ""
            try:
                posted = json.loads(body or "{}").get("body", "")
            except ValueError:
                posted = ""
            self._respond(201, {
                "id": 12, "body": posted,
                "created_at": "2024-01-03T00:00:00Z",
                "updated_at": "2024-01-03T00:00:00Z",
                "user": {"login": "bot"},
            })
            return
        if base.endswith("/issues/50/labels/missing") and \
                self.command == "DELETE":
            self._record(body)
            self._respond(404, {"message": "Label does not exist"})
            return
        if base == "/repos/o/r/issues/50" and self.command == "GET":
            self._record(body)
            self._respond(200, FIXTURE_ISSUE)
            return
        if base == "/repos/o/r/issues/61" and self.command == "GET":
            self._record(body)
            self._respond(200, FIXTURE_ISSUE_CLOSED)
            return
        if base == "/repos/o/r/issues" and self.command == "GET":
            self._record(body)
            if _query_param(path, "assignee") == "pager":
                if _query_param(path, "page") == "2":
                    self._respond(200, PAGE2_ISSUES)
                else:
                    self._respond(200, PAGE1_ISSUES)
                return
            self._respond(200, FIXTURE_ISSUES_LIST)
            return
        if base.endswith("/pulls/42/reviews"):
            self._record(body)
            self._respond(200, [{"id": 9, "state": "PENDING"}])
            return
        if base.endswith("/releases") and self.command == "GET":
            self._record(body)
            self._respond(200, FIXTURE_RELEASES)
            return
        if base.endswith("/releases/5/assets") and self.command == "GET":
            self._record(body)
            self._respond(200, [{"id": 77, "name": "report.txt"}])
            return

        # Uploads host prefix (custom base path keeps /uploads).
        if base.startswith("/uploads/"):
            self._record(body)
            self._respond(200, {"id": 78, "name": "report.txt",
                                "browser_download_url": "https://dl/x"})
            return

        # ── CI-tool routes (github_ci_sync_tools_test.dart) ─────────────
        # Branch listings: o/r pages 100+1; o/err fails the strict
        # _fetchPages (StateError → error envelope); o/errc succeeds so
        # the commit fetch can fail independently.
        if base == "/repos/o/r/branches":
            self._record(body)
            if _query_param(path, "page") == "2":
                self._respond(200, BRANCHES_PAGE2)
            else:
                self._respond(200, BRANCHES_PAGE1)
            return
        if base == "/repos/o/errc/branches":
            self._record(body)
            self._respond(200, [{"name": "x"}])
            return
        if base == "/repos/o/err/branches":
            self._record(body)
            self._respond(500, '{"message": "branches boom"}')
            return
        if base == "/repos/o/r/commits":
            self._record(body)
            sha = _query_param(path, "sha") or ""
            if sha == "paged":
                if _query_param(path, "page") == "2":
                    self._respond(200, COMMITS_PAGED_PAGE2)
                else:
                    self._respond(200, COMMITS_PAGED_PAGE1)
                return
            self._respond(200, COMMITS_BY_BRANCH.get(sha, []))
            return
        if base == "/repos/o/errc/commits":
            self._record(body)
            self._respond(500, '{"message": "commits boom"}')
            return

        # Filtered PR listings: o/pager walks 100+1; o/err fails a page
        # (error envelope); o/bad answers 200 with a non-List payload.
        if base == "/repos/o/pager/pulls":
            self._record(body)
            if _query_param(path, "page") == "2":
                self._respond(200, FILTERED_PRS_PAGE2)
            else:
                self._respond(200, FILTERED_PRS_PAGE1)
            return
        if base == "/repos/o/err/pulls":
            self._record(body)
            self._respond(500, '{"message": "boom"}')
            return
        if base == "/repos/o/bad/pulls":
            self._record(body)
            self._respond(200, {"message": "not a list"})
            return

        # Non-List 200 for the best-effort comment families (pull 77 —
        # the pull-42 routes above are generic endswith matches).
        if base == "/repos/o/nl/pulls/77/comments":
            self._record(body)
            self._respond(200, {"message": "not a list"})
            return
        if base == "/repos/o/nl/issues/77/comments":
            self._record(body)
            self._respond(200, {"message": "not a list"})
            return
        # Strict reviews-page failure for github_get_pr_activities.
        if base == "/repos/o/err/pulls/77/reviews":
            self._record(body)
            self._respond(500, '{"message": "reviews boom"}')
            return

        # Issue search: canned hit, or a 500 for the boom query.
        if base == "/search/issues":
            self._record(body)
            q = _query_param(path, "q") or ""
            if "boom" in q:
                self._respond(500, '{"message": "search boom"}')
            else:
                self._respond(200, {"total_count": 1, "items": [
                    {"number": 9, "title": "hit"}]})
            return

        self._record(body)
        self._respond(200, {
            "method": self.command,
            "path": path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body,
        })

    do_GET = _serve
    do_POST = _serve
    do_PUT = _serve
    do_DELETE = _serve
    do_PATCH = _serve

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if len(sys.argv) > 2:
        FixtureState.log_path = sys.argv[2]
        FixtureState.last_path = sys.argv[2] + ".last.json"
    server = http.server.HTTPServer(("127.0.0.1", port), FixtureHandler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
