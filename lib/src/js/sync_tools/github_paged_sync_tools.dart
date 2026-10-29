/// Paginated GitHub list executors (gh-388): every list tool that used
/// to read a single page walks `per_page=100` pages through one shared
/// walker.
///
/// Shared semantics (Java port identical): start at `page=1`; stop on a
/// page with fewer than 100 items (or an empty/undecodable one);
/// null/empty/non-JSON/error bodies on page 1 pass through untouched; a
/// later-page failure returns the pages already collected; a short first
/// page is exactly one request with its body unchanged.
part of 'github_sync_tools.dart';

/// GitHub's maximum page size — the pagination stop threshold.
const int _ghPageSize = 100;

/// Extracts a page's items, or `null` when the page has the wrong shape.
typedef _PageItems = List<dynamic>? Function(dynamic decoded);

/// Items of a bare JSON-array page.
List<dynamic>? _arrayItems(dynamic decoded) => decoded is List ? decoded : null;

/// Items under [key] of an envelope page (`{total_count, <key>: [...]}`).
_PageItems _envelopeItems(String key) => (decoded) =>
    decoded is Map && decoded[key] is List ? decoded[key] as List : null;

/// Appends every page after the first (full) [firstPage] of [base]
/// (which already carries `?...per_page=100`); a short, failed, or
/// undecodable page ends the walk.
List<dynamic> _walkPages(
  GhSyncConfig c,
  String base,
  List<dynamic> firstPage,
  _PageItems items,
) {
  final all = <dynamic>[...firstPage];
  for (var page = 2;; page++) {
    final next = items(_getJson(c, '$base&page=$page'));
    if (next == null) break;
    all.addAll(next);
    if (next.length < _ghPageSize) break;
  }
  return all;
}

/// Walks a bare-array endpoint; [first] is its successful page-1 reply.
String _walkArrayFrom(GhSyncConfig c, String base, SyncHttpResponse first) {
  final firstPage = _arrayItems(syncTryDecode(first.body));
  if (firstPage == null || firstPage.length < _ghPageSize) return first.body;
  return jsonEncode(_walkPages(c, base, firstPage, _arrayItems));
}

/// GETs every page of the bare-array endpoint [base].
String _getAllArrayPages(GhSyncConfig c, String base) {
  final first = SyncHttpClient.get('$base&page=1', headers: c.headers);
  if (!first.isOk) return syncBodyOrError(first);
  return _walkArrayFrom(c, base, first);
}

/// GETs every page of the envelope endpoint [base], merging the [key]
/// arrays and keeping page 1's `total_count`.
String _getAllEnvelopePages(GhSyncConfig c, String base, String key) {
  final first = SyncHttpClient.get('$base&page=1', headers: c.headers);
  if (!first.isOk) return syncBodyOrError(first);
  final decoded = syncTryDecode(first.body);
  final pageItems = _envelopeItems(key);
  final firstPage = pageItems(decoded);
  if (firstPage == null || firstPage.length < _ghPageSize) return first.body;
  return jsonEncode({
    'total_count': (decoded as Map)['total_count'],
    key: _walkPages(c, base, firstPage, pageItems),
  });
}

/// `github_list_branches` — every page of `repos/{w}/{r}/branches`
/// (Java `listBranches` parity; REST shape `[{name, commit: {sha}}]`).
/// The SM provider reads the default-branch HEAD from it to compute
/// behind/CLEAN deterministically (REST `mergeable_state` lazily
/// recomputes to `unknown` right after a base push).
String _listBranches(GhSyncConfig c, Map<String, dynamic> a) =>
    _getAllArrayPages(c, '${c.baseUrl}/${_repoSeg(a)}/branches?per_page=100');

/// `github_list_prs` — `repos/{w}/{r}/pulls`, newest-updated first.
///
/// Java `listPullRequests`/`pullRequests`: state synonyms are normalized
/// (`opened`→`open`, `declined`/`merged`→`closed`) and `state=merged`
/// keeps only PRs with a `merged_at` timestamp. `open` walks every page
/// (open counts are bounded; SM sweeps need completeness); closed/merged
/// return the first page (up to 100) only — history can be huge.
String _listPrs(GhSyncConfig c, Map<String, dynamic> a) {
  final requested = syncAsStr(a['state']).trim().toLowerCase();
  final normalized = switch (requested) {
    'opened' => 'open',
    'declined' || 'merged' => 'closed',
    _ => requested,
  };
  final base = '${c.baseUrl}/${_repoSeg(a)}/pulls'
      '?state=$normalized&sort=updated&direction=desc&per_page=100';
  if (normalized == 'open') return _getAllArrayPages(c, base);
  final resp = SyncHttpClient.get('$base&page=1', headers: c.headers);
  final body = syncBodyOrError(resp);
  if (requested != 'merged' || !resp.isOk) return body;
  return _filterMergedPrs(body);
}

/// Filters the decoded PR list to entries with a non-null `merged_at`
/// (the `state=merged` emulation for GitHub's REST pulls endpoint).
String _filterMergedPrs(String body) {
  final decoded = syncTryDecode(body);
  final prs = decoded is List ? decoded : const [];
  final merged =
      prs.where((pr) => pr is Map && pr['merged_at'] != null).toList();
  return jsonEncode(merged);
}

/// `github_list_pr_reviews` — every page of `pulls/{id}/reviews`
/// (Java #495). An empty response comes back as `[]` (Java parity).
String _listPrReviews(GhSyncConfig c, Map<String, dynamic> a) {
  final base = '${_prUrl(c, a)}/reviews?per_page=100';
  final first = SyncHttpClient.get('$base&page=1', headers: c.headers);
  if (!first.isOk) return syncBodyOrError(first);
  if (first.body.trim().isEmpty) return '[]';
  return _walkArrayFrom(c, base, first);
}

/// `github_get_commit_check_runs` — GET `commits/{sha}/check-runs`,
/// walking every page (per_page=100). Heads accumulate check-runs
/// across CI re-runs and SM bridge-free stamps (live: fa #1457's head
/// carried 355 — the default 30-run page hid the in_progress
/// placeholder orphans from every SM detector; dmtools-agents#865).
/// Non-paged shapes (echo stubs, error bodies) pass through untouched.
String _getCommitCheckRuns(GhSyncConfig c, Map<String, dynamic> a) =>
    _getAllEnvelopePages(
      c,
      '${c.baseUrl}/${_repoSeg(a)}'
          '/commits/${syncAsStr(a['commitSha'])}/check-runs?per_page=100',
      'check_runs',
    );

/// `github_get_workflow_run_jobs` — GET `actions/runs/{id}/jobs`, every
/// page merged into one `{total_count, jobs}` envelope.
String _getWorkflowRunJobs(GhSyncConfig c, Map<String, dynamic> a) =>
    _getAllEnvelopePages(
      c,
      '${c.baseUrl}/${_repoSeg(a)}'
          '/actions/runs/${syncAsStr(a['runId'])}/jobs?per_page=100',
      'jobs',
    );
