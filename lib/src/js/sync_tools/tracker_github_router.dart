/// GitHub Issues backend for tracker-shaped `jira_*` tool calls.
///
/// Routing rule (explicit and opt-in): a tracker call routes to GitHub
/// Issues only when the ticket key matches `gh-<number>` **and** Jira is
/// not configured (no `JIRA_BASE_PATH` or no Jira auth token — the same
/// conditions under which the Jira executors report
/// `{"error": "Jira not configured"}`). Any real Jira config keeps the
/// current Jira behavior — zero regression for Java-parity environments.
/// The keyless `jira_search_by_jql` routes whenever Jira is unconfigured
/// (its only alternative is the config error). One line is logged at
/// dispatch: `tracker: gh-50 → github issues`.
///
/// Routing table (`gh-N` → GitHub Issues on the tracker repo):
///
/// | `jira_*` call            | GitHub routing                                        |
/// |--------------------------|-------------------------------------------------------|
/// | `jira_get_ticket`        | GET issue → Jira-shaped ticket (`key`, `fields.summary`/`description`/`labels`/`status.name`) |
/// | `jira_get_comments`      | GET issue comments → `{comments: [...]}` (Jira shape) |
/// | `jira_post_comment`      | POST issue comment                                    |
/// | `jira_add_label`         | POST issue labels                                     |
/// | `jira_remove_label`      | DELETE issue label (absent label = success)           |
/// | `jira_move_to_status`    | label `status:<name>`; Done-ish names close the issue, Open-ish names reopen it |
/// | `jira_search_by_jql`     | a whole-JQL `key` filter fetches those issues; `key` AND-ed labels/status/assignee filters apply client-side (`in` = ANY, absent issues skipped); keyless queries map single-value filters onto the issues list; an honest "unsupported JQL" error otherwise |
///
/// List endpoints (issues list, comments) walk `per_page=100` pages
/// until a short page — results are never silently capped at 100 items.
/// Key-scoped searches apply their AND-ed filters client-side, where
/// multi-value `in` clauses are correct (ANY semantics); keyless
/// queries support single-value labels/status/assignee filters only
/// (GitHub's list endpoint ANDs comma-joined labels and takes one
/// state/assignee), so multi-value clauses there are an honest
/// unsupported-JQL error rather than a silently narrowed result.
///
/// Status mapping for `jira_move_to_status` (normalized lowercase):
/// Done-ish — done, closed, resolved, complete, completed, fixed, merged —
/// also PATCHes the issue `state: closed`; Open-ish — open, reopened, todo,
/// backlog, new, in progress, in development, ready for development,
/// in review, review, ready for review — PATCHes `state: open` on a closed
/// issue. Every other name is label-only. A `status:<name>` label wins over
/// the open/closed state when `jira_get_ticket` derives `status.name`.
///
/// The tracker repo resolves from `DMTOOLS_TRACKER_REPO`, then
/// `GITHUB_REPOSITORY`, then `SOURCE_GITHUB_REPOSITORY` (`owner/repo`
/// form). Auth and transport reuse the `github_*` sync stack
/// (`SOURCE_GITHUB_TOKEN`, [SyncHttpClient]) — no new auth path.
library;

import 'dart:convert';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../sync_http_client.dart';
import 'jira_markup.dart';
import 'sync_request_helpers.dart';
import 'tracker_routing_common.dart';

/// Tracker-shaped `jira_*` ticket tools eligible for GitHub routing.
const _routableKeyTools = {
  'jira_get_ticket',
  'jira_get_comments',
  'jira_post_comment',
  'jira_add_label',
  'jira_remove_label',
  'jira_move_to_status',
};

/// Connection config for one routed GitHub Issues call.
typedef _GhRouteConfig = ({
  String baseUrl,
  Map<String, String> headers,
  String repoSeg,
});

/// Routes tracker-shaped `jira_*` calls to GitHub Issues when the opt-in
/// rule matches (see the library doc for the routing table).
class TrackerGitHubRouter {
  /// Creates a router; [logger] receives the one-line dispatch log
  /// (defaults to [print]).
  const TrackerGitHubRouter({void Function(String line)? logger})
      : _logger = logger;

  final void Function(String line)? _logger;

  /// The issue number digits of a `gh-<number>` ticket key, else `null`.
  static String? ghIssueNumber(dynamic key) => trackerIssueNumber(key);

  /// Routes [toolName] to GitHub Issues when the opt-in rule matches;
  /// returns `null` to fall through to the normal Jira execution path.
  String? maybeRoute(String toolName, Map<String, dynamic> args) {
    final number = trackerIssueNumber(args['key']);
    final isSearch = toolName == 'jira_search_by_jql';
    if (!isSearch &&
        (number == null || !_routableKeyTools.contains(toolName))) {
      return null;
    }
    final reader = PropertyReader();
    if (_jiraConfigured(reader)) return null;
    _log(number != null
        ? 'tracker: gh-$number → github issues'
        : 'tracker: $toolName → github issues');
    final config = _githubConfig(reader);
    if (config is String) {
      return syncErr('GitHub tracker routing unavailable: $config');
    }
    final gh = config as _GhRouteConfig;
    return isSearch
        ? _searchByJql(gh, args)
        : _routeKeyTool(toolName, number!, gh, args);
  }

  void _log(String line) => (_logger ?? print)(line);

  /// Jira counts as configured exactly when the Jira sync executors would
  /// not report "Jira not configured" (base path plus an auth token).
  bool _jiraConfigured(PropertyReader reader) {
    final basePath = reader.getJiraBasePath();
    if (basePath == null || basePath.isEmpty) return false;
    final token = reader.getJiraLoginPassToken();
    return token != null && token.isNotEmpty;
  }

  /// GitHub config for the routed call, or — as an error-message
  /// `String` — the exact missing piece: `SOURCE_GITHUB_TOKEN is not
  /// configured`, or the tracker-repo failure with the offending value
  /// (`tracker repo … is not configured or malformed: "<value>"`), so
  /// run logs say which env var to fix.
  Object _githubConfig(PropertyReader reader) {
    final token = reader.getGithubToken();
    if (token == null || token.isEmpty) {
      return 'SOURCE_GITHUB_TOKEN is not configured';
    }
    final repo = reader.getValue('DMTOOLS_TRACKER_REPO') ??
        reader.getValue('GITHUB_REPOSITORY') ??
        reader.getGithubRepository();
    final seg = _repoSegment(repo);
    if (seg == null) {
      return 'tracker repo (DMTOOLS_TRACKER_REPO / GITHUB_REPOSITORY, '
          'owner/repo form) is not configured or malformed: "$repo"';
    }
    return (
      baseUrl: reader.getGithubBasePath(),
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': syncJsonContentType,
      },
      repoSeg: seg,
    );
  }

  /// The `owner/repo` segment of a repo env value, or `null` when the
  /// value is not in `owner/repo` form.
  static String? _repoSegment(String? repo) {
    if (repo == null) return null;
    final parts = repo.split('/');
    if (parts.length != 2 || parts.any((p) => p.trim().isEmpty)) return null;
    return '${parts[0].trim()}/${parts[1].trim()}';
  }

  /// Dispatches a routed ticket tool to its GitHub Issues mapping.
  String _routeKeyTool(
    String toolName,
    String number,
    _GhRouteConfig c,
    Map<String, dynamic> args,
  ) =>
      switch (toolName) {
        'jira_get_ticket' =>
          _withIssue(c, number, (i) => jsonEncode(_ticketFromIssue(i))),
        'jira_get_comments' => _getComments(c, number),
        'jira_post_comment' =>
          _postComment(c, number, syncAsStr(args['comment'])),
        'jira_add_label' => _addLabel(c, number, syncAsStr(args['label'])),
        'jira_remove_label' =>
          _removeLabel(c, number, syncAsStr(args['label'])),
        'jira_move_to_status' =>
          _moveToStatus(c, number, syncAsStr(args['statusName'])),
        _ => syncErr('Unsupported tracker tool: $toolName'),
      };

  String _issueUrl(_GhRouteConfig c, String number) =>
      '${c.baseUrl}/repos/${c.repoSeg}/issues/$number';

  /// `jira_get_comments` — issue comments in the Jira `{comments: [...]}`
  /// envelope so scripts reading `comment.comments` work unchanged.
  String _getComments(_GhRouteConfig c, String number) {
    final list = _listPaged(
      c,
      '${_issueUrl(c, number)}/comments',
      'comments for gh-$number',
    );
    if (list is String) return list;
    return jsonEncode({
      'comments': [
        for (final comment in list as List)
          if (comment is Map<String, dynamic>) _commentFromJson(comment),
      ],
    });
  }

  /// `jira_post_comment` — POST an issue comment; returns the created
  /// comment in the Jira comment shape. The body is converted from Jira
  /// wiki markup to Markdown first (gh-125): the agents' post-action
  /// templates hard-code `{code}`/`h3.` syntax that renders as raw noise
  /// on GitHub. The Jira path never sees this code — bodies pass through
  /// unchanged there (Java parity).
  String _postComment(_GhRouteConfig c, String number, String body) {
    final resp = _postJson(c, '${_issueUrl(c, number)}/comments',
        {'body': jiraMarkupToMarkdown(body)});
    if (!resp.isOk) return _respError(resp);
    final created = _tryDecode(resp.body);
    if (created is! Map<String, dynamic>) {
      return syncErr('unexpected GitHub comment payload for gh-$number');
    }
    return jsonEncode(_commentFromJson(created));
  }

  /// `jira_add_label` — POST the labels array; returns the updated labels.
  String _addLabel(_GhRouteConfig c, String number, String label) {
    final resp = _postJson(c, '${_issueUrl(c, number)}/labels', {
      'labels': [label],
    });
    return resp.isOk ? resp.body : _respError(resp);
  }

  /// `jira_remove_label` — DELETE the label; an absent label (404) is a
  /// success, matching Jira's set-based label update semantics.
  String _removeLabel(_GhRouteConfig c, String number, String label) {
    final resp = _deleteLabel(c, number, label);
    if (resp.statusCode == 404) return jsonEncode('');
    return resp.isOk ? jsonEncode('') : _respError(resp);
  }

  /// `jira_move_to_status` — swap the `status:*` label, then close/reopen
  /// the issue for Done-ish/Open-ish names (see the library doc).
  String _moveToStatus(_GhRouteConfig c, String number, String status) =>
      _withIssue(
        c,
        number,
        (issue) => _moveIssue(c, number, status, issue),
      );

  /// Label swap + state sync for [_moveToStatus] once the issue is loaded.
  String _moveIssue(
    _GhRouteConfig c,
    String number,
    String status,
    Map<String, dynamic> issue,
  ) {
    final stale =
        _labelNames(issue['labels']).where((l) => l.startsWith('status:'));
    // Best-effort: a failed stale-label delete must not block the move —
    // the new status label is what matters.
    for (final label in stale) {
      _deleteLabel(c, number, label);
    }
    final added = _postJson(c, '${_issueUrl(c, number)}/labels', {
      'labels': ['status:$status'],
    });
    if (!added.isOk) return _respError(added);
    return _syncIssueState(c, number, status, syncAsStr(issue['state']));
  }

  /// Closes/reopens the issue when [status] is Done-ish/Open-ish; any
  /// other name leaves the issue state untouched.
  String _syncIssueState(
    _GhRouteConfig c,
    String number,
    String status,
    String currentState,
  ) {
    final target = targetIssueState(status);
    if (target == null || target == currentState) return jsonEncode('');
    final resp = SyncHttpClient.patch(
      _issueUrl(c, number),
      headers: c.headers,
      body: jsonEncode({'state': target}),
    );
    return resp.isOk ? jsonEncode('') : _respError(resp);
  }

  /// `jira_search_by_jql` — best-effort GitHub routing. A whole-JQL
  /// `key` filter fetches those issues; `key` AND-ed with supported
  /// filters fetches by number and applies the remaining filters
  /// client-side (`in` = ANY semantics); keyless queries map single-
  /// value labels/status/assignee filters onto the issues list
  /// endpoint. Anything else gets an honest unsupported-JQL error
  /// instead of a silently wrong result.
  String _searchByJql(_GhRouteConfig c, Map<String, dynamic> args) {
    final jql = syncAsStr(args['jql']).trim();
    final numbers = keyNumbers(jql);
    if (numbers != null) {
      return _ticketsByKeyNumbers(c, numbers, JqlFilters());
    }
    final parsed = parseJqlFilters(jql, forge: 'GitHub');
    if (parsed is String) return syncErr(parsed);
    final filters = parsed as JqlFilters;
    return filters.keyNumbers.isNotEmpty
        ? _ticketsByKeyNumbers(c, filters.keyNumbers, filters)
        : _searchIssueList(c, jql, filters);
  }

  /// Key-scoped search: fetches each numbered issue and applies the
  /// AND-ed filters client-side. Issues that do not exist (404) are not
  /// in the result set and are skipped; transport/5xx failures still
  /// surface as error envelopes.
  String _ticketsByKeyNumbers(
    _GhRouteConfig c,
    List<String> numbers,
    JqlFilters filters,
  ) {
    final tickets = <Map<String, dynamic>>[];
    for (final number in numbers) {
      final issue = _issueForSearch(c, number);
      if (issue is String) return issue;
      if (issue == null) continue;
      final map = issue as Map<String, dynamic>;
      if (!_matchesFilters(map, filters)) continue;
      tickets.add(_ticketFromIssue(map));
    }
    return jsonEncode(tickets);
  }

  /// Keyless search: maps single-value filters onto the issues list
  /// endpoint. Multi-value labels/status/assignee filters are honestly
  /// unsupported there — GitHub's list endpoint ANDs comma-joined labels
  /// and takes a single state/assignee, while JQL `in` means ANY.
  String _searchIssueList(_GhRouteConfig c, String jql, JqlFilters filters) {
    if (filters.hasMultiValue) {
      return syncErr(
          unsupportedJql(jql, forge: 'GitHub', reason: multiValueReason));
    }
    final prefix =
        '${c.baseUrl}/repos/${c.repoSeg}/issues?${_issuesListQuery(filters)}';
    final list = _listPaged(c, prefix, 'issues list');
    if (list is String) return list;
    return jsonEncode([
      for (final issue in list as List)
        if (issue is Map<String, dynamic> && issue['pull_request'] == null)
          _ticketFromIssue(issue),
    ]);
  }

  /// The issues-list query for [filters] (labels, state, assignee — no
  /// paging params; those are appended per page).
  static String _issuesListQuery(JqlFilters filters) => [
        if (filters.labels.isNotEmpty)
          'labels=${filters.labels.map(Uri.encodeQueryComponent).join(',')}',
        'state=${filters.statuses.isEmpty ? 'all' : _stateForStatus(filters.statuses.first)}',
        if (filters.assignees.isNotEmpty)
          'assignee=${Uri.encodeQueryComponent(filters.assignees.first)}',
      ].join('&');

  /// Client-side AND-ed filter match on a fetched issue.
  static bool _matchesFilters(Map<String, dynamic> issue, JqlFilters f) =>
      f.matches(
        issueLabels: _labelNames(issue['labels']),
        status: _statusName(issue),
        assignee: (issue['assignee'] as Map?)?['login']?.toString(),
      );

  /// Maps a status filter value to the GitHub issue `state` query.
  static String _stateForStatus(String status) =>
      targetIssueState(status) ?? 'all';

  // ── HTTP helpers ─────────────────────────────────────────────────────

  /// Runs [fn] with the issue map for [number]; an error envelope short-
  /// circuits when the fetch or decode fails.
  String _withIssue(
    _GhRouteConfig c,
    String number,
    String Function(Map<String, dynamic>) fn,
  ) {
    final issue = _issueOrError(c, number);
    return issue is String ? issue : fn(issue as Map<String, dynamic>);
  }

  /// The issue map for [number], or an error-envelope string on failure.
  Object _issueOrError(_GhRouteConfig c, String number) {
    final what = 'issue for gh-$number';
    final result = _getJson(c, _issueUrl(c, number), what);
    if (result is Map<String, dynamic> || result is String) return result;
    return syncErr('unexpected GitHub $what payload');
  }

  /// The issue map for [number] in a search context: `null` when the
  /// issue does not exist (404 — a missing issue is not in the result
  /// set), an error-envelope string on transport/5xx/decode failure.
  Object? _issueForSearch(_GhRouteConfig c, String number) {
    final resp = SyncHttpClient.get(_issueUrl(c, number), headers: c.headers);
    if (resp.statusCode == 404) return null;
    if (!resp.isOk) return _respError(resp);
    final decoded = _tryDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return syncErr('unexpected GitHub issue for gh-$number payload');
  }

  /// The decoded JSON list at [url], or an error-envelope string.
  Object _listOrError(_GhRouteConfig c, String url, String what) {
    final result = _getJson(c, url, what);
    if (result is List || result is String) return result;
    return syncErr('unexpected GitHub $what payload');
  }

  /// Lists [prefix] (URL up to an optional query) across `per_page=100`
  /// pages until a short page — the curl body transport exposes no Link
  /// header, so paging walks `page=` increments.
  Object _listPaged(_GhRouteConfig c, String prefix, String what) {
    final items = <dynamic>[];
    for (var page = 1;; page++) {
      final result = _listOrError(c, _pagedUrl(prefix, page), what);
      if (result is String) return result;
      final list = result as List;
      items.addAll(list);
      if (list.length < 100) return items;
    }
  }

  /// The page-[page] URL of a list [prefix] (page 1 keeps the plain
  /// `per_page=100` form).
  static String _pagedUrl(String prefix, int page) {
    final sep = prefix.contains('?') ? '&' : '?';
    final paging = page == 1 ? 'per_page=100' : 'per_page=100&page=$page';
    return '$prefix$sep$paging';
  }

  /// GETs [url] and decodes the body; transport, non-2xx, and decode
  /// failures surface as an error-envelope string.
  Object _getJson(_GhRouteConfig c, String url, String what) {
    final resp = SyncHttpClient.get(url, headers: c.headers);
    if (!resp.isOk) return _respError(resp);
    return _tryDecode(resp.body) ?? syncErr('unexpected GitHub $what payload');
  }

  /// POSTs a JSON payload to [url].
  SyncHttpResponse _postJson(_GhRouteConfig c, String url, Object payload) =>
      SyncHttpClient.post(url, headers: c.headers, body: jsonEncode(payload));

  /// DELETEs one label from the issue.
  SyncHttpResponse _deleteLabel(
          _GhRouteConfig c, String number, String label) =>
      SyncHttpClient.delete(
        '${_issueUrl(c, number)}/labels/${Uri.encodeComponent(label)}',
        headers: c.headers,
      );

  // ── Payload mapping ──────────────────────────────────────────────────

  /// Maps a GitHub issue to the Jira ticket shape agent scripts consume:
  /// `key` plus `fields.summary` / `fields.description` / `fields.labels`
  /// / `fields.status.name`. A `status:<name>` label wins over the raw
  /// open/closed state for `status.name`.
  static Map<String, dynamic> _ticketFromIssue(Map<String, dynamic> issue) =>
      jiraTicket(
        number: issue['number'],
        title: issue['title'],
        body: issue['body'],
        labels: _labelNames(issue['labels']),
        statusName: _statusName(issue),
      );

  /// The Jira-ish status name of an issue (see [statusNameOf]).
  static String _statusName(Map<String, dynamic> issue) => statusNameOf(
        _labelNames(issue['labels']),
        closed: issue['state'] == 'closed',
      );

  /// Maps a GitHub issue comment to the Jira comment shape.
  static Map<String, dynamic> _commentFromJson(Map<String, dynamic> c) =>
      jiraComment(
        id: c['id'],
        body: c['body'],
        author: (c['user'] as Map?)?['login'],
        created: c['created_at'],
        updated: c['updated_at'],
      );

  /// Label names from a GitHub `labels` payload (string or object entries).
  static List<String> _labelNames(dynamic raw) => [
        for (final label in (raw is List ? raw : const []))
          if (label is String)
            label
          else if (label is Map && label['name'] != null)
            label['name'].toString(),
      ];

  static dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// Failure envelope for a non-2xx (or failed curl) response.
  static String _respError(SyncHttpResponse resp) => resp.statusCode == 0
      ? syncErr('HTTP request failed: ${resp.body}')
      : syncErr('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');

  static String _snippet(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}…';
}
