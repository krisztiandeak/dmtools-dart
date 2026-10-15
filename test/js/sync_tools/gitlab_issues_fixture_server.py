#!/usr/bin/env python3
"""Scripted GitLab Issues API fixture for TrackerGitLabRouter tests.

Dart's HttpServer runs on the event loop, frozen during
`Process.runSync('curl', ...)`; this subprocess serves the curl requests
(same pattern as github_fixture_server.py).

Usage: python3 gitlab_issues_fixture_server.py [port] [request_log]
Prints the bound port, appends `METHOD path` per request to the log and
mirrors the last request JSON to `<request_log>.last.json`.
"""

import http.server
import json
import re
import sys
from urllib.parse import urlparse

ISSUE = {
    "iid": 4,
    "title": "Smoke test",
    "description": "issue body text",
    "state": "opened",
    "labels": ["agent:dev", "status:In Progress"],
    "assignees": [{"username": "kdeak"}],
}
CLOSED_ISSUE = dict(ISSUE, iid=5, state="closed", labels=["status:Done"])
NOTES = [
    {"id": 1, "body": "first", "system": False, "author": {"username": "kdeak"},
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"},
    {"id": 2, "body": "added ~label", "system": True, "author": {"username": "kdeak"},
     "created_at": "2024-01-02T00:00:00Z", "updated_at": "2024-01-02T00:00:00Z"},
]
ISSUES_PATH = re.compile(r"^/api/v4/projects/o%2Fr/issues(?:/(\d+))?(?:/(notes))?$")
LOG = {"path": None, "last": None}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, body):
        with open(LOG["path"], "a") as fh:
            fh.write("%s %s\n" % (self.command, self.path))
        with open(LOG["last"], "w") as fh:
            json.dump({"method": self.command, "path": self.path, "body": body,
                       "token": self.headers.get("PRIVATE-TOKEN")}, fh)

    def _serve(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        self._record(body)
        match = ISSUES_PATH.match(urlparse(self.path).path)
        if not match:
            return self._reply(404, {"message": "404 Not Found"})
        iid, notes = match.groups()
        if self.command == "GET" and notes:
            return self._reply(200, NOTES)
        if self.command == "POST" and notes:
            created = dict(NOTES[0], id=9, body=json.loads(body)["body"])
            return self._reply(201, created)
        if self.command == "GET" and iid:
            issue = {"4": ISSUE, "5": CLOSED_ISSUE}.get(iid)
            return self._reply(200, issue) if issue else self._reply(404, {"message": "404"})
        if self.command == "PUT" and iid:
            return self._reply(200, dict(ISSUE, **json.loads(body)))
        if self.command == "GET":
            return self._reply(200, [ISSUE])
        return self._reply(405, {"message": "unsupported"})

    do_GET = do_POST = do_PUT = _serve


if __name__ == "__main__":
    LOG["path"] = sys.argv[2]
    LOG["last"] = sys.argv[2] + ".last.json"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
