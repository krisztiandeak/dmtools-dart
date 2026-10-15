/// GitLab Issues backend for tracker-shaped `jira_*` tool calls.
///
/// Routing rule (explicit and opt-in): a tracker call routes to GitLab
/// Issues only when `DEFAULT_TRACKER=gitlab`, the ticket key matches
/// `gh-<number>` (the agents' key convention on every forge — the number is
/// the issue `iid`) **and** Jira is not configured. The keyless
/// `jira_search_by_jql` routes whenever those two conditions hold. One line
/// is logged at dispatch: `tracker: gh-4 → gitlab issues`.
///
/// Routing table (`gh-N` → GitLab Issues on the tracker project):
///
/// | `jira_*` call            | GitLab routing                                        |
/// |--------------------------|-------------------------------------------------------|
/// | `jira_get_ticket`        | GET issue → Jira-shaped ticket                        |
/// | `jira_get_comments`      | GET issue notes (user notes only, oldest first)       |
/// | `jira_post_comment`      | POST issue note                                       |
/// | `jira_add_label`         | PUT issue `add_labels`                                |
/// | `jira_remove_label`      | PUT issue `remove_labels` (absent label = success)    |
/// | `jira_move_to_status`    | label `status:<name>`; Done-ish closes, Open-ish reopens (`state_event`) |
/// | `jira_search_by_jql`     | same JQL surface as [TrackerGitHubRouter]             |
///
/// The tracker project resolves from `DMTOOLS_TRACKER_REPO`, then
/// `GITLAB_WORKSPACE` + `GITLAB_REPOSITORY` (`owner/repo`). Auth and
/// transport reuse the `gitlab_*` sync stack (`GITLAB_BASE_PATH`,
/// `GITLAB_TOKEN`, [SyncHttpClient]).
library;

import 'dart:convert';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../sync_http_client.dart';
import 'jira_markup.dart';
import 'sync_request_helpers.dart';
import 'tracker_routing_common.dart';

/// Tracker-shaped `jira_*` ticket tools eligible for GitLab routing.
const _routableKeyTools = {
  'jira_get_ticket',
  'jira_get_comments',
  'jira_post_comment',
  'jira_add_label',
  'jira_remove_label',
  'jira_move_to_status',
};

/// Connection config for one routed GitLab Issues call.
typedef _GlRouteConfig = ({
  String issuesUrl,
  Map<String, String> headers,
});

/// Routes tracker-shaped `jira_*` calls to GitLab Issues when the opt-in
/// rule matches (see the library doc for the routing table).
class TrackerGitLabRouter {
  /// Creates a router; [logger] receives the one-line dispatch log
  /// (defaults to [print]).
  const TrackerGitLabRouter({void Function(String line)? logger})
      : _logger = logger;

  final void Function(String line)? _logger;

  /// Routes [toolName] to GitLab Issues when the opt-in rule matches;
  /// returns `null` to fall through to the next backend.
  String? maybeRoute(String toolName, Map<String, dynamic> args) {
    final number = trackerIssueNumber(args['key']);
    final isSearch = toolName == 'jira_search_by_jql';
    if (!isSearch &&
        (number == null || !_routableKeyTools.contains(toolName))) {
      return null;
    }
    final reader = PropertyReader();
    if (reader.getDefaultTracker()?.toLowerCase() != 'gitlab' ||
        _jiraConfigured(reader)) {
      return null;
    }
    (_logger ?? print)(number != null
        ? 'tracker: gh-$number → gitlab issues'
        : 'tracker: $toolName → gitlab issues');
    final config = _config(reader);
    if (config is String) {
      return syncErr('GitLab tracker routing unavailable: $config');
    }
    final gl = config as _GlRouteConfig;
    return isSearch
        ? _searchByJql(gl, args)
        : _routeKeyTool(toolName, number!, gl, args);
  }

  /// Jira counts as configured exactly when the Jira sync executors would
  /// not report "Jira not configured" (base path plus an auth token).
  bool _jiraConfigured(PropertyReader reader) {
    final basePath = reader.getJiraBasePath();
    if (basePath == null || basePath.isEmpty) return false;
    final token = reader.getJiraLoginPassToken();
    return token != null && token.isNotEmpty;
  }

  /// GitLab config for the routed call, or — as an error-message `String` —
  /// the exact missing piece, so run logs say which env var to fix.
  Object _config(PropertyReader reader) {
    final basePath = reader.getGitLabBasePath();
    final token = reader.getGitLabToken();
    if (basePath == null || basePath.isEmpty) {
      return 'GITLAB_BASE_PATH is not configured';
    }
    if (token == null || token.isEmpty) return 'GITLAB_TOKEN is not configured';
    final project = reader.getValue('DMTOOLS_TRACKER_REPO') ??
        _workspaceRepo(
            reader.getGitLabWorkspace(), reader.getGitLabRepository());
    if (project == null || !RegExp(r'^[^/\s]+(/[^/\s]+)+$').hasMatch(project)) {
      return 'tracker project (DMTOOLS_TRACKER_REPO / GITLAB_WORKSPACE + '
          'GITLAB_REPOSITORY, owner/repo form) is not configured or '
          'malformed: "$project"';
    }
    return (
      issuesUrl: '$basePath/api/v4/projects/'
          '${Uri.encodeComponent(project)}/issues',
      headers: {'PRIVATE-TOKEN': token, 'Content-Type': syncJsonContentType},
    );
  }

  static String? _workspaceRepo(String? workspace, String? repository) =>
      (workspace == null || repository == null)
          ? null
          : '$workspace/$repository';

  String _routeKeyTool(
    String toolName,
    String number,
    _GlRouteConfig c,
    Map<String, dynamic> args,
  ) =>
      switch (toolName) {
        'jira_get_ticket' =>
          _withIssue(c, number, (i) => jsonEncode(_ticketFromIssue(i))),
        'jira_get_comments' => _getComments(c, number),
        'jira_post_comment' => _postNote(c, number, syncAsStr(args['comment'])),
        'jira_add_label' =>
          _putIssue(c, number, {'add_labels': syncAsStr(args['label'])}),
        'jira_remove_label' =>
          _putIssue(c, number, {'remove_labels': syncAsStr(args['label'])}),
        'jira_move_to_status' =>
          _moveToStatus(c, number, syncAsStr(args['statusName'])),
        _ => syncErr('Unsupported tracker tool: $toolName'),
      };

  String _issueUrl(_GlRouteConfig c, String number) => '${c.issuesUrl}/$number';

  /// `jira_get_comments` — user notes in the Jira `{comments: [...]}`
  /// envelope (system notes — label/state changes — are not comments).
  String _getComments(_GlRouteConfig c, String number) {
    final notes = _listPaged(
      c,
      '${_issueUrl(c, number)}/notes?sort=asc&order_by=created_at',
      'notes for gh-$number',
    );
    if (notes is String) return notes;
    return jsonEncode({
      'comments': [
        for (final note in notes as List)
          if (note is Map<String, dynamic> && note['system'] != true)
            _commentFromNote(note),
      ],
    });
  }

  /// `jira_post_comment` — POST an issue note, converted from Jira wiki
  /// markup to Markdown first (same as the GitHub route, gh-125).
  String _postNote(_GlRouteConfig c, String number, String body) {
    final resp = SyncHttpClient.post(
      '${_issueUrl(c, number)}/notes',
      headers: c.headers,
      body: jsonEncode({'body': jiraMarkupToMarkdown(body)}),
    );
    if (!resp.isOk) return _respError(resp);
    final created = _tryDecode(resp.body);
    return created is Map<String, dynamic>
        ? jsonEncode(_commentFromNote(created))
        : syncErr('unexpected GitLab note payload for gh-$number');
  }

  /// PUTs [fields] onto the issue; an absent label on remove is a no-op in
  /// GitLab, matching Jira's set-based label update semantics.
  String _putIssue(
      _GlRouteConfig c, String number, Map<String, String> fields) {
    final resp = SyncHttpClient.put(
      _issueUrl(c, number),
      headers: c.headers,
      body: jsonEncode(fields),
    );
    return resp.isOk ? jsonEncode('') : _respError(resp);
  }

  /// `jira_move_to_status` — swap the `status:*` label and close/reopen the
  /// issue for Done-ish/Open-ish names, in one PUT.
  String _moveToStatus(_GlRouteConfig c, String number, String status) =>
      _withIssue(c, number, (issue) {
        final stale =
            _labelNames(issue).where((l) => l.startsWith('status:')).join(',');
        final target = targetIssueState(status);
        final current = issue['state'] == 'closed' ? 'closed' : 'open';
        return _putIssue(c, number, {
          'add_labels': 'status:$status',
          if (stale.isNotEmpty) 'remove_labels': stale,
          if (target != null && target != current)
            'state_event': target == 'closed' ? 'close' : 'reopen',
        });
      });

  /// `jira_search_by_jql` — best-effort GitLab routing with the same JQL
  /// surface as the GitHub route (see [parseJqlFilters]).
  String _searchByJql(_GlRouteConfig c, Map<String, dynamic> args) {
    final jql = syncAsStr(args['jql']).trim();
    final numbers = keyNumbers(jql);
    if (numbers != null) return _ticketsByNumbers(c, numbers, JqlFilters());
    final parsed = parseJqlFilters(jql, forge: 'GitLab');
    if (parsed is String) return syncErr(parsed);
    final filters = parsed as JqlFilters;
    return filters.keyNumbers.isNotEmpty
        ? _ticketsByNumbers(c, filters.keyNumbers, filters)
        : _searchIssueList(c, jql, filters);
  }

  /// Key-scoped search: fetches each numbered issue and applies the AND-ed
  /// filters client-side; missing issues (404) are skipped.
  String _ticketsByNumbers(
    _GlRouteConfig c,
    List<String> numbers,
    JqlFilters filters,
  ) {
    final tickets = <Map<String, dynamic>>[];
    for (final number in numbers) {
      final resp = SyncHttpClient.get(_issueUrl(c, number), headers: c.headers);
      if (resp.statusCode == 404) continue;
      if (!resp.isOk) return _respError(resp);
      final issue = _tryDecode(resp.body);
      if (issue is! Map<String, dynamic>) {
        return syncErr('unexpected GitLab issue for gh-$number payload');
      }
      if (_matches(issue, filters)) tickets.add(_ticketFromIssue(issue));
    }
    return jsonEncode(tickets);
  }

  /// Keyless search: single-value filters map onto the issues list
  /// endpoint; multi-value clauses are an honest unsupported-JQL error.
  String _searchIssueList(_GlRouteConfig c, String jql, JqlFilters filters) {
    if (filters.hasMultiValue) {
      return syncErr(
          unsupportedJql(jql, forge: 'GitLab', reason: multiValueReason));
    }
    final list = _listPaged(
        c, '${c.issuesUrl}?${_issuesListQuery(filters)}', 'issues list');
    if (list is String) return list;
    return jsonEncode([
      for (final issue in list as List)
        if (issue is Map<String, dynamic>) _ticketFromIssue(issue),
    ]);
  }

  static String _issuesListQuery(JqlFilters f) => [
        if (f.labels.isNotEmpty)
          'labels=${Uri.encodeQueryComponent(f.labels.first)}',
        'state=${_stateForStatus(f.statuses)}',
        if (f.assignees.isNotEmpty)
          'assignee_username=${Uri.encodeQueryComponent(f.assignees.first)}',
      ].join('&');

  static String _stateForStatus(List<String> statuses) =>
      switch (statuses.isEmpty ? null : targetIssueState(statuses.first)) {
        'closed' => 'closed',
        'open' => 'opened',
        _ => 'all',
      };

  static bool _matches(Map<String, dynamic> issue, JqlFilters f) => f.matches(
        issueLabels: _labelNames(issue),
        status: _statusName(issue),
        assignee: _assigneeLogin(issue),
      );

  static String? _assigneeLogin(Map<String, dynamic> issue) =>
      (issue['assignees'] is List && (issue['assignees'] as List).isNotEmpty
              ? (issue['assignees'] as List).first
              : issue['assignee'])?['username']
          ?.toString();

  // ── HTTP helpers ─────────────────────────────────────────────────────

  /// Runs [fn] with the issue map for [number]; an error envelope
  /// short-circuits when the fetch or decode fails.
  String _withIssue(
    _GlRouteConfig c,
    String number,
    String Function(Map<String, dynamic>) fn,
  ) {
    final resp = SyncHttpClient.get(_issueUrl(c, number), headers: c.headers);
    if (!resp.isOk) return _respError(resp);
    final issue = _tryDecode(resp.body);
    return issue is Map<String, dynamic>
        ? fn(issue)
        : syncErr('unexpected GitLab issue for gh-$number payload');
  }

  /// Lists [prefix] across `per_page=100` pages until a short page.
  Object _listPaged(_GlRouteConfig c, String prefix, String what) {
    final items = <dynamic>[];
    final sep = prefix.contains('?') ? '&' : '?';
    for (var page = 1;; page++) {
      final resp = SyncHttpClient.get('$prefix${sep}per_page=100&page=$page',
          headers: c.headers);
      if (!resp.isOk) return _respError(resp);
      final list = _tryDecode(resp.body);
      if (list is! List) return syncErr('unexpected GitLab $what payload');
      items.addAll(list);
      if (list.length < 100) return items;
    }
  }

  // ── Payload mapping ──────────────────────────────────────────────────

  static Map<String, dynamic> _ticketFromIssue(Map<String, dynamic> issue) =>
      jiraTicket(
        number: issue['iid'],
        title: issue['title'],
        body: issue['description'],
        labels: _labelNames(issue),
        statusName: _statusName(issue),
      );

  static String _statusName(Map<String, dynamic> issue) =>
      statusNameOf(_labelNames(issue), closed: issue['state'] == 'closed');

  static Map<String, dynamic> _commentFromNote(Map<String, dynamic> n) =>
      jiraComment(
        id: n['id'],
        body: n['body'],
        author: (n['author'] as Map?)?['username'],
        created: n['created_at'],
        updated: n['updated_at'],
      );

  /// GitLab issues carry labels as plain strings.
  static List<String> _labelNames(Map<String, dynamic> issue) => [
        for (final label in (issue['labels'] is List ? issue['labels'] : []))
          label.toString(),
      ];

  static dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  static String _respError(SyncHttpResponse resp) => resp.statusCode == 0
      ? syncErr('HTTP request failed: ${resp.body}')
      : syncErr('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');

  static String _snippet(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}…';
}
