/// Tracker-agnostic pieces shared by the forge-backed `jira_*` routers
/// ([TrackerGitHubRouter], [TrackerGitLabRouter]): the `gh-<number>` key
/// shape, the Done-ish/Open-ish status vocabulary, the best-effort JQL
/// filter parser, and the Jira-shaped ticket/comment payloads.
library;

/// `gh-<number>` ticket key shape (lowercase, digits only). The `gh-`
/// prefix is the agents' key convention on every forge, not a GitHub tell.
final _ghKeyPattern = RegExp(r'^gh-(\d+)$');

/// Status names that close the issue (normalized lowercase).
const _doneStatuses = {
  'done',
  'closed',
  'resolved',
  'complete',
  'completed',
  'fixed',
  'merged',
};

/// Status names that reopen a closed issue (normalized lowercase).
const _openStatuses = {
  'open',
  'reopened',
  'todo',
  'backlog',
  'new',
  'in progress',
  'in development',
  'ready for development',
  'in review',
  'review',
  'ready for review',
};

/// The issue number digits of a `gh-<number>` ticket key, else `null`.
String? trackerIssueNumber(dynamic key) {
  if (key is! String) return null;
  return _ghKeyPattern.firstMatch(key)?.group(1);
}

/// The issue number of a `gh-<number>` key-clause value, else `null`.
String? ghKeyNumber(String value) =>
    _ghKeyPattern.firstMatch(value.trim().toLowerCase())?.group(1);

/// The issue state a status name implies: `closed` for Done-ish names,
/// `open` for Open-ish names, `null` for every other (label-only) name.
String? targetIssueState(String status) {
  final normalized = status.trim().toLowerCase();
  if (_doneStatuses.contains(normalized)) return 'closed';
  if (_openStatuses.contains(normalized)) return 'open';
  return null;
}

/// The Jira-ish status name of an issue: a `status:<name>` label wins
/// over the raw open/closed state.
String statusNameOf(List<String> labels, {required bool closed}) {
  for (final label in labels) {
    if (label.startsWith('status:')) return label.substring('status:'.length);
  }
  return closed ? 'Done' : 'Open';
}

/// The Jira ticket shape agent scripts consume: `key` plus
/// `fields.summary` / `description` / `labels` / `status.name`.
Map<String, dynamic> jiraTicket({
  required Object? number,
  required Object? title,
  required Object? body,
  required List<String> labels,
  required String statusName,
}) =>
    {
      'key': 'gh-$number',
      'fields': {
        'summary': title ?? '',
        'description': body ?? '',
        'labels': labels,
        'status': {'name': statusName},
        'issuetype': {'name': 'Issue'},
      },
    };

/// The Jira comment shape (`body`, `author.displayName`, `created`,
/// `updated`).
Map<String, dynamic> jiraComment({
  required Object? id,
  required Object? body,
  required Object? author,
  required Object? created,
  required Object? updated,
}) =>
    {
      'id': id?.toString(),
      'body': body ?? '',
      'author': {'displayName': author ?? ''},
      'created': created,
      'updated': updated,
    };

/// Parsed best-effort JQL filters for `jira_search_by_jql`.
class JqlFilters {
  /// `gh-<number>` issue numbers from `key` clauses.
  final List<String> keyNumbers = [];

  /// Matched `labels`/`label` clause values (ANY-of semantics).
  final List<String> labels = [];

  /// Matched `status` clause values (ANY-of semantics).
  final List<String> statuses = [];

  /// Matched `assignee` clause values (ANY-of semantics).
  final List<String> assignees = [];

  /// Whether any clause carried more than one value (not expressible on a
  /// forge's issue-list endpoint, where JQL `in` means ANY).
  bool get hasMultiValue =>
      labels.length > 1 || statuses.length > 1 || assignees.length > 1;

  /// Client-side AND-ed match on a fetched issue: labels, status, and
  /// assignee clauses are ANY-of (JQL `in` semantics), matching
  /// case-insensitively.
  bool matches({
    required List<String> issueLabels,
    required String status,
    required String? assignee,
  }) =>
      (labels.isEmpty || _anyOverlap(issueLabels, labels)) &&
      (statuses.isEmpty || _anyOverlap([status], statuses)) &&
      (assignees.isEmpty || _anyOverlap([assignee], assignees));
}

/// Reason reported when a keyless query carries multi-value clauses.
const multiValueReason = 'multi-value labels/status/assignee '
    'filters are only supported in key-scoped queries';

bool _anyOverlap(List<String?> got, List<String> want) {
  final wanted = {for (final w in want) w.trim().toLowerCase()};
  return got.any((g) => g != null && wanted.contains(g.trim().toLowerCase()));
}

/// The issue numbers when a `key` filter is the *entire* JQL. Combined
/// `key` + filter queries must not short-circuit here — the AND-ed
/// filters would be silently dropped — so they return `null` and go
/// through [parseJqlFilters] (filters applied client-side).
List<String>? keyNumbers(String jql) {
  final single =
      RegExp(r'^key\s*=\s*(\S+)\s*$', caseSensitive: false).firstMatch(jql);
  if (single != null) {
    final number = ghKeyNumber(single.group(1)!);
    return number == null ? null : [number];
  }
  final inClause = RegExp(r'^key\s+in\s*\(([^)]*)\)\s*$', caseSensitive: false)
      .firstMatch(jql);
  if (inClause == null) return null;
  final numbers = <String>[];
  for (final value in _clauseValues(inClause.group(1)!)) {
    final number = ghKeyNumber(value);
    // A non-gh value must not be silently dropped here — fall through
    // to [parseJqlFilters] for the honest unsupported-JQL error.
    if (number == null) return null;
    numbers.add(number);
  }
  return numbers.isEmpty ? null : numbers;
}

/// Parses AND-ed `field = value` / `field in (…)` clauses into issue-list
/// filters. Returns an error message string for anything outside the
/// supported key/labels/status/assignee surface.
Object parseJqlFilters(String jql, {required String forge}) {
  final filters = JqlFilters();
  if (jql.isEmpty) return filters;
  for (final clause in jql.split(RegExp(r'\s+and\s+', caseSensitive: false))) {
    final m =
        RegExp('^\\s*([A-Za-z]+)\\s*(=|in)\\s*(.+?)\\s*\$').firstMatch(clause);
    if (m == null) return unsupportedJql(jql, forge: forge);
    final values = _clauseValues(m.group(3)!);
    final error = _applyClause(filters, m.group(1)!.toLowerCase(), values);
    if (error != null) return unsupportedJql(jql, forge: forge);
  }
  return filters;
}

/// The honest error for a JQL the [forge] routing cannot express.
String unsupportedJql(String jql, {required String forge, String? reason}) {
  final detail = reason ??
      'supported filters: key, labels, status, assignee — = or in, AND-ed';
  return 'unsupported JQL for $forge tracker routing: "$jql" ($detail)';
}

/// Applies one parsed clause to [filters]; returns non-null when the
/// field is outside the supported surface.
String? _applyClause(JqlFilters filters, String field, List<String> values) {
  switch (field) {
    case 'key':
      return _applyKeyNumbers(filters, values);
    case 'labels' || 'label':
      filters.labels.addAll(values);
      return null;
    case 'status':
      filters.statuses.addAll(values);
      return null;
    case 'assignee':
      return _applyAssignee(filters, values);
    default:
      return 'unsupported field: $field';
  }
}

/// Applies a `key` clause; only `gh-<number>` keys route to a forge.
String? _applyKeyNumbers(JqlFilters filters, List<String> values) {
  if (values.isEmpty) return 'unsupported key value: (empty)';
  for (final value in values) {
    final number = ghKeyNumber(value);
    if (number == null) return 'unsupported key value: $value';
    filters.keyNumbers.add(number);
  }
  return null;
}

/// Applies an `assignee` clause; `currentUser()` is unsupported (the
/// token owner is not necessarily the intended assignee).
String? _applyAssignee(JqlFilters filters, List<String> values) {
  if (values.isEmpty || values.contains('currentUser()')) {
    return 'unsupported assignee value';
  }
  filters.assignees.addAll(values);
  return null;
}

/// Splits a clause value (`'a'` or `(a, b)`) into bare values.
List<String> _clauseValues(String raw) {
  var value = raw.trim();
  if (value.startsWith('(') && value.endsWith(')')) {
    value = value.substring(1, value.length - 1);
  }
  return [
    for (final part in value.split(','))
      if (part.trim().isNotEmpty) _unquote(part.trim()),
  ];
}

String _unquote(String value) {
  if (value.length >= 2 &&
      (value.startsWith("'") && value.endsWith("'") ||
          value.startsWith('"') && value.endsWith('"'))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
