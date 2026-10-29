#!/usr/bin/env python3
"""Minimal HTTP echo server for SyncHttpClient / SyncToolDispatcher tests.

Dart's HttpServer runs on the event loop, which is frozen during
Process.runSync('curl', ...). This Python server runs in a separate process
and can serve curl requests while the Dart isolate is blocked.

Usage:
    python3 test_echo_server.py [port]

Prints the actual bound port to stdout (first line, flushed), then serves
until killed. Each response echoes the request method, path, headers, and
body as JSON.
"""

import http.server
import json
import sys
import urllib.parse


class EchoHandler(http.server.BaseHTTPRequestHandler):
    """Echoes request details as a JSON response."""

    DELETE_LOG = []
    REQUEST_LOG = []
    FULL_LOG = []
    RETRY_HITS = {}

    def _send(self, encoded, content_type="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _handle(self):
        body = ""
        if self.command in ("POST", "PUT", "PATCH"):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
        if self.command == "DELETE":
            EchoHandler.DELETE_LOG.append(self.path)
        if not self.path.startswith("/__"):
            EchoHandler.REQUEST_LOG.append(self.path)
            EchoHandler.FULL_LOG.append({
                "method": self.command,
                "path": self.path,
                "body": body,
                "headers": {k: v for k, v in self.headers.items()},
            })
        payload = {
            "method": self.command,
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body,
        }
        # Retry-policy fixtures (gh-191 / P6-JSY-18): the first request to a
        # dt-retry path answers 429 with Retry-After: 0, later requests echo
        # normally; dt-retryalways answers 429 forever (attempt-budget
        # guard); dt-retryfail answers 503 with no retry headers.
        if "dt-retryalways" in self.path:
            encoded = b'{"error": "rate limited"}'
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "0")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # gh-356 review fixture: a SUCCESS response (200) whose body merely
        # mentions rate limiting. The retry policy must not re-issue it —
        # the body check only applies to failed requests (Java runs the
        # body check on the exception path only). Hit counts are exposed
        # via /__retry_hits so the test can assert a single request.
        if "dt-200ratelimit" in self.path:
            hits = EchoHandler.RETRY_HITS.get(self.path, 0)
            EchoHandler.RETRY_HITS[self.path] = hits + 1
            encoded = b'{"note": "tickets about rate limit throttling"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if "dt-retryfail" in self.path:
            hits = EchoHandler.RETRY_HITS.get(self.path, 0)
            EchoHandler.RETRY_HITS[self.path] = hits + 1
            if hits == 0:
                encoded = b'{"error": "unavailable"}'
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
        if "dt-retry" in self.path:
            hits = EchoHandler.RETRY_HITS.get(self.path, 0)
            EchoHandler.RETRY_HITS[self.path] = hits + 1
            if hits == 0:
                encoded = b'{"error": "rate limited"}'
                self.send_response(429)
                self.send_header("Content-Type", "application/json")
                self.send_header("Retry-After", "0")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
        # JS source fixture for the URL-jsPath tests: serves an agent script
        # (with the action() contract) as plain text so the loader can eval
        # it — mirrors a raw.githubusercontent.com fetch.
        if self.path.startswith("/script.js"):
            encoded = b'function action(params) { return "from-url"; }'
            self._send(encoded, "text/javascript")
            return
        # Jira 404-HTML fixture: any request under a dt-html base path
        # answers 404 with an HTML body, like a Jira Server that lacks the
        # Cloud-only search route (regression guard: the sync client must
        # surface this as JSON, never raw HTML).
        if "dt-html" in self.path:
            encoded = b"<html><body><h1>404 Not Found</h1></body></html>"
            self.send_response(404)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # Jira move-to-status error-path fixtures (gh-146 review thread 3:
        # transport failures must surface their real reason, never the
        # legacy "No transition found" mask). dt-movefail GET → 500 with
        # an error body (failed transitions fetch); dt-movebadjson GET →
        # 200 with a malformed body; dt-movepostfail POST → 500 (failed
        # transition apply — its GET still echoes a transitions list).
        if "dt-movefail" in self.path and self.command == "GET":
            encoded = b'{"error": "boom"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if "dt-movebadjson" in self.path and self.command == "GET":
            encoded = b"not-json{"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if "dt-movepostfail" in self.path and self.command == "POST":
            encoded = b'{"error": "nope"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # Confluence attachment-upload failure fixture (gh-191 CRAP gate):
        # a multipart POST under /content/dt-fail/... answers 500 so the
        # uploadWithPolicy failure branch runs end to end.
        if "/content/dt-fail/" in self.path and self.command == "POST":
            encoded = b'{"error": "upload rejected"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # Java-parity fixtures for 2xx-with-empty-body responses: a
        # transitions POST (dt-move) and a ticket DELETE (dt-del) answer
        # 204 No Content. The sync layer must hand JS the empty string /
        # "Success" like Java, never an error envelope. The dt-move GET
        # still echoes with a transitions list for the id lookup.
        if "dt-move" in self.path and self.command == "POST":
            self.send_response(204)
            self.end_headers()
            return
        if "dt-del" in self.path and self.command == "DELETE":
            self.send_response(204)
            self.end_headers()
            return
        if "dt-move" in self.path:
            payload["transitions"] = [
                {"id": "31", "name": "Done", "to": {"name": "Done"}}
            ]
        # Recorded request paths, so tests can assert the exact request
        # sequence one dispatch produced against this server instance.
        if self.path == "/__request_log":
            self._send(json.dumps(EchoHandler.REQUEST_LOG).encode("utf-8"))
            return
        # Recorded DELETE paths, so tests can assert which deletions the
        # client performed against this server instance.
        if self.path == "/__full_log":
            self._send(json.dumps(EchoHandler.FULL_LOG).encode("utf-8"))
            return
        if self.path == "/__delete_log":
            self._send(json.dumps(EchoHandler.DELETE_LOG).encode("utf-8"))
            return
        # Recorded request-hit counts per path (gh-356 review: the 200
        # rate-limit fixture must be requested exactly once).
        if self.path == "/__retry_hits":
            self._send(json.dumps(EchoHandler.RETRY_HITS).encode("utf-8"))
            return
        # ADO build-timeline stub for the pipeline-logs tests (build 12):
        # the timeline answers mixed record types (Stage records are skipped
        # by the client; the Test task carries no log id). Other build ids
        # keep the bare echo payload (no records).
        if "/build/builds/12/timeline" in self.path:
            payload["records"] = [
                {"type": "Stage", "name": "Build stage", "log": {"id": 1}},
                {"type": "Task", "name": "Build", "log": {"id": 5}},
                {"type": "Task", "name": "Test", "log": {"id": 0}},
            ]
        # ADO build-log stub: raw text lines (not JSON) like the real
        # /build/builds/{id}/logs/{logId} endpoint.
        elif "/logs/" in self.path:
            self._send(b"log-line-1\nlog-line-2\nlog-line-3", "text/plain")
            return
        # GitLab job trace: raw text (the real /jobs/{id}/trace endpoint
        # answers plain text). The echo payload rides inside as text so
        # tests can still assert method/path after one extra decode.
        elif self.path.endswith("/trace"):
            self._send(
                json.dumps(payload).encode("utf-8"), "text/plain"
            )
            return
        # GitLab MR-list fixture: a state=all listing answers a JSON array
        # so the client-side closed/merged filter runs.
        elif self.command == "GET" and "/merge_requests?state=all" in self.path:
            self._send(json.dumps([
                {"iid": 1, "state": "merged"},
                {"iid": 2, "state": "opened"},
            ]).encode("utf-8"))
            return
        # GitLab release-asset fixtures: the release links and the generic
        # packages listings answer JSON arrays (matching the uploaded asset
        # name / the queried package name+version).
        elif self.command == "GET" and "/assets/links" in self.path:
            self._send(json.dumps([
                {"id": 41, "name": "app.zip"}
            ]).encode("utf-8"))
            return
        elif (self.command == "GET" and "/packages?" in self.path
              and "package_type=generic" in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(json.dumps([
                {
                    "id": 9,
                    "name": query.get("package_name", [""])[0],
                    "version": query.get("package_version", [""])[0],
                }
            ]).encode("utf-8"))
            return
        # Confluence content fixtures: a page GET (777) answers a page
        # object and a child listing (99) answers a results array, both
        # with storage bodies, so the format=markdown conversion runs.
        # Page 555 answers a version object (update-with-history) and its
        # child listing carries a titled child for the downloader.
        elif (self.command == "GET"
              and "/wiki/rest/api/content/777" in self.path
              and "/child/" not in self.path):
            payload.clear()
            payload["id"] = "777"
            payload["title"] = "Hi Page"
            payload["body"] = {
                "storage": {
                    "value": "<p>hi</p>",
                    "representation": "storage",
                }
            }
        elif (self.command == "GET"
              and "/wiki/rest/api/content/666" in self.path
              and "/child/" not in self.path):
            # gh-348: a page whose only attachment always fails with 500 —
            # the downloader must give up (after its transient-retry
            # schedule) and leave no partial file behind.
            payload.clear()
            payload["id"] = "666"
            payload["title"] = "Flaky Page"
            payload["body"] = {
                "storage": {
                    "value": "<p>flaky</p>",
                    "representation": "storage",
                }
            }
        elif (self.command == "GET"
              and "/wiki/rest/api/content/888" in self.path
              and "/child/" not in self.path):
            # gh-347 conversion-fix fixture: a page whose storage holds an
            # excerpt-include of "Source" (space-less ri:page link — must
            # resolve in the page's own space DOCS, carried only via the
            # _expandable link like a real v1 response) and a user mention.
            # The downloader must inline the excerpt body and resolve the
            # mention to @Jane Roe before converting to Markdown.
            payload.clear()
            payload["id"] = "888"
            payload["title"] = "Main Page"
            payload["_expandable"] = {"space": "/rest/api/space/DOCS"}
            payload["body"] = {
                "storage": {
                    "value": (
                        "<p>intro</p>"
                        "<ac:structured-macro ac:name=\"table-excerpt-include\" "
                        "ac:schema-version=\"1\">"
                        "<ac:parameter ac:name=\"page\"><ac:link>"
                        "<ri:page ri:content-title=\"Source\" />"
                        "</ac:link></ac:parameter>"
                        "<ac:parameter ac:name=\"name\">Rules"
                        "</ac:parameter></ac:structured-macro>"
                        "<p>Owner: <ac:link><ri:user "
                        "ri:account-id=\"acc-1\" /></ac:link></p>"
                    ),
                    "representation": "storage",
                }
            }
        elif (self.command == "GET"
              and "/wiki/rest/api/user?" in self.path
              and "accountId=acc-1" in self.path):
            self._send(json.dumps({"displayName": "Jane Roe"}).encode("utf-8"))
            return
        elif (self.command == "GET"
              and "/wiki/rest/api/content/555" in self.path
              and "/child/" not in self.path):
            payload.clear()
            payload["id"] = "555"
            payload["version"] = {"number": 3}
        elif (self.command == "GET"
              and "/wiki/rest/api/content/555/child/page" in self.path):
            # Real Confluence only includes body.storage when the request
            # asks for it via expand (gh-191 review: guards the downloader).
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            wants_body = "body.storage" in query.get("expand", [""])[0]
            payload.clear()
            result = {"id": "902", "title": "Child Page"}
            if wants_body:
                result["body"] = {
                    "storage": {
                        "value": "<p>kid</p>",
                        "representation": "storage",
                    }
                }
            payload["results"] = [result]
        elif self.command == "GET" and "/wiki/rest/api/content/99/child/page" in self.path:
            payload.clear()
            payload["results"] = [
                {
                    "id": "901",
                    "body": {
                        "storage": {
                            "value": "<p>child</p>",
                            "representation": "storage",
                        }
                    },
                }
            ]
        # Confluence title listing (Java content(title, space) →
        # ContentResult): the default-space tools' distinctive expand list
        # answers per the title param — 'Parent' resolves to page 555 (the
        # get_children_by_name parent), 'Nope'/'Ghost' answer empty (not
        # found), anything else answers two results so first-match /
        # applyFormat order is asserted. The plain get_page expand
        # (body.storage only) keeps the bare echo.
        elif (self.command == "GET"
              and "/wiki/rest/api/content?" in self.path
              and "body.storage%2Cbody.export_view" in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            title = query.get("title", [""])[0]
            payload.clear()
            if title in ("Nope", "Ghost"):
                payload["results"] = []
            elif title == "Source":
                # gh-347: excerpt-include target of the 888 page (looked up
                # by title in space DOCS).
                payload["results"] = [{
                    "id": "889",
                    "title": "Source",
                    "space": {"key": "DOCS"},
                    "body": {
                        "storage": {
                            "value": (
                                "<p>source intro</p>"
                                "<ac:structured-macro ac:name="
                                "\"table-excerpt\">"
                                "<ac:parameter ac:name=\"name\">Rules"
                                "</ac:parameter>"
                                "<ac:rich-text-body>"
                                "<table><tbody><tr><th>Key</th></tr>"
                                "<tr><td>included-value</td></tr>"
                                "</tbody></table>"
                                "</ac:rich-text-body>"
                                "</ac:structured-macro>"
                            ),
                            "representation": "storage",
                        }
                    },
                }]
            elif title == "Parent":
                payload["results"] = [{
                    "id": "555",
                    "title": "Parent",
                    "body": {
                        "storage": {
                            "value": "<p>parent</p>",
                            "representation": "storage",
                        }
                    },
                }]
            else:
                payload["results"] = [
                    {
                        "id": "801",
                        "title": "Found Page",
                        "body": {
                            "storage": {
                                "value": "<p>found</p>",
                                "representation": "storage",
                            }
                        },
                    },
                    {
                        "id": "802",
                        "title": "Second Page",
                        "body": {
                            "storage": {
                                "value": "<p>second</p>",
                                "representation": "storage",
                            }
                        },
                    },
                ]
        elif (self.command == "GET"
              and "/wiki/rest/api/content/777/child/page" in self.path):
            # Same expand-gating as the 555 fixture above: no body unless
            # the caller asks for it (the page downloader must request it).
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            wants_body = "body.storage" in query.get("expand", [""])[0]
            payload.clear()
            result = {"id": "902", "title": "Child Page"}
            if wants_body:
                result["body"] = {
                    "storage": {
                        "value": "<p>kid</p>",
                        "representation": "storage",
                    }
                }
            payload["results"] = [result]
        # Confluence v2 REST fixtures (CONFLUENCE_API_VERSION=v2 parity,
        # Java ConfluenceApiV2Test / #592): the granular/scoped-token
        # routes. The spaces resolver answers ENG → numeric id 456 and any
        # other key with an empty listing (spaceIdFromKey must fail).
        elif (self.command == "GET"
              and "/wiki/api/v2/spaces" in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            key = query.get("keys", [""])[0]
            payload.clear()
            if key == "ENG":
                payload["results"] = [{"id": "456", "key": "ENG"}]
            else:
                payload["results"] = []
        # v2 attachment listing: the v1-compatible results envelope (the
        # upload policy and the page downloader run against this too).
        elif (self.command == "GET"
              and "/wiki/api/v2/pages/" in self.path
              and "/attachments" in self.path):
            payload.clear()
            payload["results"] = [
                {"id": "a1", "title": "exists.txt"},
                {
                    "id": "a2",
                    "title": "shot.png",
                    "_links": {
                        "download": "/download/attachments/123/shot.png"
                    },
                },
            ]
        # v2 title lookup: 'Nope' answers empty (not found), 'Parent'
        # resolves to page 555 (the get_children_by_name parent), anything
        # else answers two results so first-match / format order is
        # asserted. Mirrors the v1 title fixture above.
        elif (self.command == "GET"
              and "/wiki/api/v2/pages?" in self.path
              and "title=" in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            title = query.get("title", [""])[0]
            payload.clear()
            if title in ("Nope", "Ghost"):
                payload["results"] = []
            elif title == "Parent":
                payload["results"] = [{
                    "id": "555",
                    "title": "Parent",
                    "body": {
                        "storage": {
                            "value": "<p>parent</p>",
                            "representation": "storage",
                        }
                    },
                }]
            else:
                payload["results"] = [
                    {
                        "id": "801",
                        "title": "Found Page",
                        "body": {
                            "storage": {
                                "value": "<p>found</p>",
                                "representation": "storage",
                            }
                        },
                    },
                    {
                        "id": "802",
                        "title": "Second Page",
                        "body": {
                            "storage": {
                                "value": "<p>second</p>",
                                "representation": "storage",
                            }
                        },
                    },
                ]
        # v2 children listing for the sync-engine parent (empty: every
        # child is created, none is reused or deleted).
        elif (self.command == "GET"
              and "/wiki/api/v2/pages?" in self.path
              and "parent-id=root-page" in self.path):
            payload.clear()
            payload["results"] = []
        elif (self.command == "GET"
              and "/wiki/api/v2/pages/" in self.path
              and "/inline-comments" in self.path):
            payload.clear()
            if "/pages/777/" in self.path:
                payload["results"] = [
                    {
                        "id": "ic-1",
                        "resolutionStatus": "open",
                        "properties": {"inlineOriginalSelection": "hi"},
                        "body": {
                            "storage": {
                                "value": "<p>Needs clarification</p>",
                                "representation": "storage",
                            }
                        },
                    }
                ]
            else:
                payload["results"] = []
        # v2 page object (contentById / updatePage version read / engine
        # getContent): version, ancestors, and a storage body in one shape.
        elif (self.command == "GET"
              and self.path.startswith("/wiki/api/v2/pages/")):
            page_id = self.path[len("/wiki/api/v2/pages/"):]
            page_id = page_id.split("?", 1)[0]
            if page_id in ("42", "123", "root-page"):
                payload.clear()
                payload["id"] = page_id
                payload["title"] = "Fixture Page"
                payload["version"] = {"number": 3}
                payload["ancestors"] = [{"id": "root-parent"}]
                payload["body"] = {
                    "storage": {
                        "value": "<p>fixture</p>",
                        "representation": "storage",
                    }
                }
        # Confluence attachment listing: two fixtures — exists.txt (the
        # skip-existing policy) and shot.png carrying a _links.download
        # path (the page-downloader fetches it below). evil.txt carries an
        # absolute URL on a foreign host (localhost vs 127.0.0.1) — the
        # downloader must fetch it WITHOUT the Confluence credentials, and
        # /download/evil.bin answers CLEAN/LEAKED accordingly.
        elif self.command == "GET" and "/child/attachment" in self.path:
            port = self.server.server_address[1]
            payload.clear()
            if "/content/666/" in self.path:
                # gh-348: one attachment whose download endpoint answers
                # 500 forever (transient-class failure for the retry
                # schedule; the file must never appear on disk).
                payload["results"] = [
                    {
                        "id": "a6",
                        "title": "flaky.png",
                        "_links": {
                            "download": "/download/always500.png"
                        },
                    },
                ]
            else:
                payload["results"] = [
                    {"id": "a1", "title": "exists.txt"},
                    {
                        "id": "a2",
                        "title": "shot.png",
                        "_links": {
                            "download": "/download/attachments/123/shot.png"
                        },
                    },
                    {
                        "id": "a3",
                        "title": "evil.txt",
                        "_links": {
                            "download":
                                "http://localhost:%d/download/evil.bin" % port
                        },
                    },
                ]
        if self.path.startswith("/download/evil.bin"):
            leaked = self.headers.get("Authorization") is not None
            self._send(b"LEAKED" if leaked else b"CLEAN",
                       "application/octet-stream")
            return
        if self.path.startswith("/download/always500.png"):
            # gh-348: a download endpoint that never recovers — answers a
            # bare 500 (a transient-class code for the attachment retry).
            encoded = b'{"error": "boom"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith("/download/attachments/"):
            self._send(b"PNG-fixture-bytes", "application/octet-stream")
            return
        # Jira Cloud attachment 303 redirect fixture (gh-461):
        # /rest/api/2/attachment/content/<id> requires Authorization and
        # responds 303 See Other to a Location (either query ?to=<url> or
        # same-port /media/file/<id>/binary). /media/file/<id>/binary
        # rejects requests that still carry an Authorization header (403),
        # matching api.media.atlassian.com / S3 signed URLs.
        if self.path.startswith("/rest/api/2/attachment/content/"):
            if not self.headers.get("Authorization"):
                encoded = b'{"error": "missing jira auth"}'
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            query = urllib.parse.parse_qs(
                urllib.parse.urlparse(self.path).query
            )
            port = self.server.server_address[1]
            target = query.get(
                "to", ["http://127.0.0.1:%d/media/file/1/binary" % port]
            )[0]
            self.send_response(303)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/media/file/"):
            if self.headers.get("Authorization") or self.headers.get(
                "X-Atlassian-Token"
            ):
                encoded = b'{"error": "foreign auth header rejected by CDN"}'
                self.send_response(403)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            self._send(b"CDN-binary-bytes", "application/octet-stream")
            return
        if self.path.startswith("/same-origin-redir-target"):
            if not self.headers.get("Authorization"):
                encoded = b'{"error": "missing auth on same origin"}'
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            self._send(b"same-origin-bytes", "application/octet-stream")
            return
        # Confluence short-link redirect: /l/... answers a 302 whose
        # Location points back at the 777 page URL (contents_by_urls must
        # resolve it and fetch that page). /l/chain answers a chained hop
        # (→ /dt-redir2 → page URL) so the redirect follower must track the
        # current URL across hops instead of re-GETting the original. The
        # dead short link answers 404 (no Location) — resolvers must
        # degrade to null, not abort the whole call. /dt-redir answers the
        # single-hop redirect for probes that bypass the URL-shape gate.
        if self.path.startswith("/l/chain"):
            port = self.server.server_address[1]
            encoded = b'{"moved": true}'
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%d/wiki/x/AB12" % port,
            )
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith("/wiki/x/"):
            # Second chain hop: a wiki-shaped short link that itself
            # redirects to the canonical page URL (the follower must GET
            # each hop at its own URL).
            port = self.server.server_address[1]
            encoded = b'{"moved": true}'
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%d/wiki/spaces/ENG/pages/777/Hi" % port,
            )
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith("/l/dead"):
            encoded = b'{"gone": true}'
            self.send_response(404)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith("/l/") or self.path.startswith("/dt-redir"):
            port = self.server.server_address[1]
            encoded = b'{"moved": true}'
            self.send_response(302)
            self.send_header(
                "Location",
                "http://127.0.0.1:%d/wiki/spaces/ENG/pages/777/Hi" % port,
            )
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # GitLab jobs fixtures (gh-380): the pipeline-scoped route answers
        # the dispatch-pipeline shape (one ai-teammate job); the
        # project-wide route answers two jobs so the client-side exact-name
        # filter and multi-item handling are both exercised. The
        # pipeline-scoped check comes first — its path also contains
        # "/jobs?".
        elif self.command == "GET" and "/pipelines/9/jobs" in self.path:
            self._send(json.dumps([
                {"id": 501, "name": "ai-teammate", "status": "success",
                 "stage": "dispatch", "pipeline": {"id": 9},
                 "web_url": "http://gl.example/jobs/501"},
            ]).encode("utf-8"))
            return
        elif (self.command == "GET" and "/jobs?" in self.path
              and "/pipelines/" not in self.path):
            self._send(json.dumps([
                {"id": 101, "name": "ai-teammate", "status": "success",
                 "stage": "run", "pipeline": {"id": 7},
                 "web_url": "http://gl.example/jobs/101"},
                {"id": 102, "name": "build", "status": "failed",
                 "stage": "build", "pipeline": {"id": 7},
                 "web_url": "http://gl.example/jobs/102"},
            ]).encode("utf-8"))
            return
        elif (self.command == "GET" and "/pipelines?" in self.path
              and urllib.parse.parse_qs(
                  urllib.parse.urlparse(self.path).query
              ).get("per_page") == ["2"]):
            # GitLab pipelines pagination fixture: full pages of two runs
            # so the client's per_page/maxResults walk is exercised.
            self._send(json.dumps([{"id": 1}, {"id": 2}]).encode("utf-8"))
            return
        # ADO stub shapes for the WIQL two-step regression test: the WIQL
        # POST answers id/url stubs, the ids= detail GET answers full items
        # (mirrors the real dev.azure.com response envelopes).
        if "/wit/wiql" in self.path and "dt-wiql-error" in body:
            # ADO error envelope for a failed WIQL call (auth/bad query):
            # must reach the caller as-is, not look like an empty result.
            payload["message"] = "TF51005: query is invalid"
        elif "/wit/wiql" in self.path:
            payload["workItems"] = [{"id": 7, "url": "stub://7"}]
        elif "/wit/workitems" in self.path and "ids=" in self.path:
            payload["count"] = 1
            payload["value"] = [
                {"id": 7, "fields": {"System.Title": "T"}}
            ]
        elif self.command == "POST" and "/wit/attachments" in self.path:
            # ADO attach-file fixture: the upload answers {id, url}.
            payload["id"] = "att-1"
            payload["url"] = "http://ado.example/_apis/wit/attachments/att-1"
        elif (self.command == "POST"
              and "/wit/workitems/$" in self.path):
            # ADO create fixture: the created work item carries id 321.
            payload["id"] = 321
        elif self.command == "GET" and "/wit/fields" in self.path:
            # ADO field-catalog fixture for ado_get_field_code.
            payload.clear()
            payload["value"] = [
                {"name": "Title", "referenceName": "System.Title"},
                {"name": "Solution Design",
                 "referenceName": "Custom.SolutionDesign"},
            ]
        elif (self.command == "GET"
              and "/wit/workitems/55" in self.path):
            # ADO attach-file fixture: item 55 already has shot.png attached.
            payload.clear()
            payload["id"] = 55
            payload["relations"] = [
                {"rel": "AttachedFile",
                 "attributes": {"name": "Shot.PNG"}},
                {"rel": "System.LinkTypes.Related", "attributes": {}},
            ]
        elif (self.command == "GET"
              and "/wit/workitems/9" in self.path):
            # ADO label-tool fixture (dm.ai #577): a tagged work item for
            # the add/remove-single-label handler tests — the merged or
            # remaining tag set is asserted from the PATCH the handler
            # sends back to the echo server.
            payload.clear()
            payload["id"] = 9
            payload["fields"] = {"System.Tags": "existing; ai_generated"}
        # Jira deployment-detection fixture: /serverInfo answers by marker —
        # dt-server → "Server", dt-cloud → "Cloud", dt-missing → no field,
        # dt-error → 500 (both force the atlassian.net URL fallback).
        if self.path.endswith("/serverInfo"):
            if "dt-error" in self.path:
                encoded = b"<html><body>server error</body></html>"
                self.send_response(500)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            payload.clear()
            if "dt-cloud" in self.path:
                payload["deploymentType"] = "Cloud"
            elif "dt-missing" not in self.path:
                payload["deploymentType"] = "Server"
        # Jira search fixtures: the Cloud endpoint pages by nextPageToken,
        # the legacy Server endpoint pages by startAt (issue keys echo the
        # page's startAt / jql / fields so tests can assert the query).
        # Path prefixes stay Jira-specific so Confluence's
        # /content/search route keeps its bare echo.
        elif (
            self.command == "GET"
            and "/rest/api/latest/search/jql" in self.path
        ):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            token = query.get("nextPageToken", [""])[0]
            if "dt-cloudnull" in self.path:
                self._send(b"null")
                return
            if "dt-cloudhtml" in self.path:
                encoded = b"<html><body>gone</body></html>"
                self.send_response(404)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            payload.clear()
            if "dt-clouderr" in self.path:
                payload["errorMessages"] = ["boom cloud"]
            elif "dt-cloudempty" in self.path:
                # tok2 page is empty but still tokens on: an empty issues
                # page must stop the walk before that token is followed.
                if token == "tok2":
                    payload["issues"] = []
                    payload["nextPageToken"] = "tok3"
                elif token == "tok3":
                    payload["issues"] = [{"key": "CE-3"}]
                else:
                    payload["issues"] = [{"key": "CE-1"}]
                    payload["nextPageToken"] = "tok2"
            elif "dt-cloudnoissues" in self.path:
                # tok2 page omits issues entirely (Java: null tickets).
                if token == "tok2":
                    payload["nextPageToken"] = "tok3"
                elif token == "tok3":
                    payload["issues"] = [{"key": "CI-3"}]
                else:
                    payload["issues"] = [{"key": "CI-1"}]
                    payload["nextPageToken"] = "tok2"
            elif "dt-cloudlast" in self.path:
                if token:
                    payload["issues"] = [{"key": "CL-2"}]
                else:
                    payload["issues"] = [{"key": "CL-1"}]
                    payload["nextPageToken"] = "tok2"
                    payload["isLast"] = True
            elif "dt-cloudpnull" in self.path:
                if token:
                    self._send(b"null")
                    return
                payload["issues"] = [{"key": "CN-1"}]
                payload["nextPageToken"] = "tok2"
            elif "dt-cloudfail" in self.path:
                if token:
                    encoded = b"<html><body>exploded</body></html>"
                    self.send_response(500)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                payload["issues"] = [{"key": "CF-1"}]
                payload["nextPageToken"] = "tok2"
            elif token:
                payload["issues"] = [{"key": "C-2"}]
            else:
                payload["issues"] = [{"key": "C-1"}]
                payload["nextPageToken"] = "tok2"
        elif (
            self.command == "GET"
            and "/rest/api/latest/search?" in self.path
        ):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            payload.clear()
            if "dt-servererr" in self.path:
                payload["errorMessages"] = ["bad jql"]
            elif "dt-servertotal0" in self.path:
                payload["issues"] = []
                payload["maxResults"] = 2
                payload["total"] = 0
            elif "dt-serverrefresh" in self.path:
                # Page 2 halves maxResults (4 -> 2) with total 9: the walk
                # must advance by the refreshed value, so the pages at
                # startAt 6 and 8 are both fetched and included.
                start = int(query.get("startAt", ["0"])[0])
                if start == 0:
                    payload["issues"] = [
                        {"key": k} for k in ("R-0a", "R-0b", "R-0c", "R-0d")
                    ]
                    payload["maxResults"] = 4
                elif start == 4:
                    payload["issues"] = [
                        {"key": k} for k in ("R-4a", "R-4b", "R-4c", "R-4d")
                    ]
                    payload["maxResults"] = 2
                else:
                    payload["issues"] = [{"key": "R-%d" % start}]
                    payload["maxResults"] = 2
                payload["total"] = 9
            elif "dt-serverexact" in self.path:
                # startAt == total is NOT a break in Java: the page at
                # startAt 4 is fetched, and its refreshed total (6) keeps
                # the loop alive so E-4 is still performed.
                start = int(query.get("startAt", ["0"])[0])
                payload["issues"] = [{"key": "E-%d" % start}]
                payload["maxResults"] = 2
                payload["total"] = 6 if start >= 4 else 4
            elif "dt-serveronepage" in self.path:
                start = int(query.get("startAt", ["0"])[0])
                payload["issues"] = [{"key": "O-%d" % start}]
                payload["maxResults"] = 5
                payload["total"] = 3
            elif "dt-serverpnull" in self.path:
                start = int(query.get("startAt", ["0"])[0])
                if start == 0:
                    payload["issues"] = [{"key": "SN-0"}]
                    payload["maxResults"] = 2
                    payload["total"] = 4
                else:
                    self._send(b"null")
                    return
            elif "dt-serverperr" in self.path:
                start = int(query.get("startAt", ["0"])[0])
                if start == 0:
                    payload["issues"] = [{"key": "SF-0"}, {"key": "SF-1"}]
                    payload["maxResults"] = 2
                    payload["total"] = 4
                else:
                    encoded = b"<html><body>boom</body></html>"
                    self.send_response(500)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
            else:
                start = int(query.get("startAt", ["0"])[0])
                keys = ["S-0a", "S-0b"] if start == 0 else ["S-%d" % start]
                payload["issues"] = [
                    {
                        "key": k,
                        "jql": query.get("jql", [""])[0],
                        "fields": query.get("fields", [""])[0],
                    }
                    for k in keys
                ]
                payload["startAt"] = start
                payload["maxResults"] = 2
                payload["total"] = 3
        # Jira label-fetch fixture: a normal ?fields=labels GET answers the
        # ticket's current labels; __jira_fail=1 marks the GET as a transient
        # 5xx (regression guard: a failed fetch must abort, never PUT an
        # empty set).
        elif "fields=labels" in self.path:
            if "__jira_fail" in self.path:
                encoded = b'{"errors": ["transient"]}'
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            payload["fields"] = {"labels": ["existing"]}
        # Figma sync fixtures (gh-173): the layers-batch / svg-content /
        # download handlers need a render (`/images`) map whose URLs point
        # back at this same server. Marker prefixes keep the fixtures clear
        # of every other integration's routes.
        if self.path.startswith("/figsvg/v1/images/"):
            port = self.server.server_address[1]
            payload.clear()
            payload["images"] = {
                "1:2": "http://127.0.0.1:%d/figsvg/body.svg" % port,
                "2:2": "http://127.0.0.1:%d/figsvg/missing.svg" % port,
            }
        elif self.path == "/figsvg/body.svg":
            self._send(
                b'<svg xmlns="http://www.w3.org/2000/svg"></svg>',
                "image/svg+xml",
            )
            return
        elif self.path == "/figsvg/missing.svg":
            encoded = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith("/figdl/v1/images/"):
            port = self.server.server_address[1]
            payload.clear()
            payload["images"] = {
                "1:2": "http://127.0.0.1:%d/figdl/image.png" % port,
                "2:2": "http://127.0.0.1:%d/figdl/missing.png" % port,
            }
        elif self.path == "/figdl/image.png":
            self._send(
                b"\x89PNG\r\n\x1a\nfigdl-fixture-bytes", "image/png"
            )
            return
        elif self.path == "/figdl/missing.png":
            encoded = b"missing"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # Figma layers-batch fixture: the /nodes endpoint answers a document
        # with one child per requested id (keyed by the colon id); id "7:7"
        # carries a null document so the skip branch is exercised.
        if (self.command == "GET"
                and "/figlayers/v1/files/" in self.path
                and "/nodes" in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            nodes = {}
            for raw in query.get("ids", [""])[0].split(","):
                colon = raw.strip().replace("-", ":")
                if colon == "7:7":
                    nodes[colon] = {"document": None}
                else:
                    nodes[colon] = {
                        "document": {
                            "id": colon,
                            "name": "Frame %s" % colon,
                            "type": "FRAME",
                            "children": [
                                {
                                    "id": "%s:1" % colon,
                                    "name": "Child",
                                    "type": "RECTANGLE",
                                    "absoluteBoundingBox": {
                                        "x": 1,
                                        "y": 2,
                                        "width": 3,
                                        "height": 4,
                                    },
                                    "visible": False,
                                }
                            ],
                        }
                    }
            payload.clear()
            payload["nodes"] = nodes
        if (self.command == "GET"
                and "/_apis/wit/workItems/55/comments" in self.path):
            payload["comments"] = [{
                "createdBy": {"displayName": "Ada"},
                "createdDate": "2026-01-01",
                "text": "ADO comment body",
            }]
        response = json.dumps(payload)
        encoded = response.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = http.server.HTTPServer(("127.0.0.1", port), EchoHandler)
    actual_port = server.server_address[1]
    print(actual_port, flush=True)
    server.serve_forever()
