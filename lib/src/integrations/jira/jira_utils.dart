/// Shared Jira utility functions used by multiple call sites.
library;

import 'dart:convert';

/// Reads the create-tool `labels` argument as `List<String>?`.
///
/// Strict by design (gh-427): `labels` must arrive as a JSON string array.
/// Unlike the read-side `fields` params (which comma-split bare strings), a
/// comma is a legal label character, so any other shape throws a loud
/// [ArgumentError] — the caller sees the rejection instead of the argument
/// being dropped from the create payload.
List<String>? jiraCreateLabelsArg(Map<String, dynamic> args) {
  final value = args['labels'];
  if (value == null) return null;
  if (value is List) {
    for (final entry in value) {
      if (entry is! String) {
        throw ArgumentError(
          'labels must be a list of strings; '
          "got entry '$entry' (${entry.runtimeType})",
        );
      }
    }
    return List<String>.from(value);
  }
  throw ArgumentError(
      'labels must be a list of strings; got ${value.runtimeType}');
}

/// Finds a transition id in [transitions] matching [statusName].
///
/// Matches by transition name or destination status name (case-insensitive).
/// Used by both the async [JiraClient] and the sync [SyncToolDispatcher] so
/// the matching logic is defined in one place.
String? matchTransitionId(
  List<Map<String, dynamic>> transitions,
  String statusName,
) {
  final target = statusName.toLowerCase();
  for (final t in transitions) {
    final name = (t['name'] as String?)?.toLowerCase() ?? '';
    final toStatus = t['to'] as Map<String, dynamic>?;
    final toName = (toStatus?['name'] as String?)?.toLowerCase() ?? '';
    if (name == target || toName == target) return t['id'] as String?;
  }
  return null;
}

/// A field definition candidate from a Jira `field` listing.
///
/// Ports the Java `MultiFieldUpdateStrategy.CustomField` carrier: the pieces
/// [selectBestJiraField] ranks candidates by.
class JiraFieldCandidate {
  /// Field id, e.g. `customfield_10091`.
  final String id;

  /// Human-readable field name.
  final String name;

  /// Schema type string (e.g. `string`, `number`); empty when absent.
  final String schema;

  /// Whether the field is active (defaults to `true`, as in Java).
  final bool active;

  /// Creates a candidate.
  const JiraFieldCandidate(this.id, this.name, this.schema, this.active);
}

/// Extracts the numeric part of a custom-field [fieldId], or `0`.
///
/// Mirrors Java `MultiFieldUpdateStrategy.extractFieldNumber`.
int extractJiraFieldNumber(String fieldId) =>
    int.tryParse(fieldId.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

/// Finds every field in [fieldsJsonResponse] whose name matches [fieldName]
/// (case-insensitive). Malformed/non-array bodies yield an empty list — the
/// Java `findAllFieldsByName` catch-and-log contract.
List<JiraFieldCandidate> findAllJiraFieldsByName(
  String fieldName,
  String fieldsJsonResponse,
) {
  try {
    final decoded = jsonDecodeList(fieldsJsonResponse);
    return decoded
        .map(_asFieldCandidate)
        .where((f) => f.name.toLowerCase() == fieldName.toLowerCase())
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Builds a [JiraFieldCandidate] from a `field` listing entry.
JiraFieldCandidate _asFieldCandidate(Map<String, dynamic> field) {
  final schema = field['schema'];
  return JiraFieldCandidate(
    field['id']?.toString() ?? '',
    field['name']?.toString() ?? '',
    schema is Map ? schema['type']?.toString() ?? '' : '',
    field['active'] is bool ? field['active'] as bool : true,
  );
}

/// Selects the best candidate from [fields] (never mutates the input).
///
/// Mirrors Java `MultiFieldUpdateStrategy.selectBestField`: prefer active
/// fields; for `depend*`/`description*` names prefer text schemas; then the
/// highest `customfield_NNN` number. `null` for an empty list.
JiraFieldCandidate? selectBestJiraField(List<JiraFieldCandidate> fields) {
  if (fields.isEmpty) return null;
  final sorted = [...fields]..sort(_compareFieldCandidates);
  return sorted.first;
}

/// Orders candidates by the Java selection priority (lower sorts first).
int _compareFieldCandidates(JiraFieldCandidate a, JiraFieldCandidate b) {
  if (a.active != b.active) return a.active ? -1 : 1;
  final textOrder = _compareTextFieldPreference(a, b);
  if (textOrder != 0) return textOrder;
  return extractJiraFieldNumber(b.id).compareTo(extractJiraFieldNumber(a.id));
}

/// Text-schema preference order for `depend*`/`description*` names
/// (`0` when equal or not applicable).
int _compareTextFieldPreference(JiraFieldCandidate a, JiraFieldCandidate b) {
  if (!_prefersTextField(a.name)) return 0;
  final aText = _isTextSchema(a.schema);
  final bText = _isTextSchema(b.schema);
  return aText == bText ? 0 : (aText ? -1 : 1);
}

/// Whether [name] activates the Java text-schema preference.
bool _prefersTextField(String name) {
  final lower = name.toLowerCase();
  return lower.contains('depend') || lower.contains('description');
}

/// Whether [schema] is a text-ish schema type.
bool _isTextSchema(String schema) =>
    schema.contains('string') || schema.contains('text');

/// Resolves a relationship name against a Jira `issueLinkType` listing.
///
/// Mirrors Java `JiraClient.getRelationshipByName`: a match on the type name
/// or its inward description maps to `inward`; a match on the outward
/// description maps to `outward`. `null` when nothing matches.
({String direction, String name})? resolveJiraLinkType(
  List<Map<String, dynamic>> linkTypes,
  String relationship,
) {
  final target = relationship.toLowerCase();
  for (final type in linkTypes) {
    final name = type['name']?.toString() ?? '';
    final inward = type['inward']?.toString() ?? '';
    final outward = type['outward']?.toString() ?? '';
    if (target == name.toLowerCase() || target == inward.toLowerCase()) {
      return (direction: 'inward', name: name);
    }
    if (target == outward.toLowerCase()) {
      return (direction: 'outward', name: name);
    }
  }
  return null;
}

/// Decodes a JSON array body, returning `const []` for non-array JSON.
///
/// A JSON *parse* failure rethrows (callers decide the failure contract).
List<Map<String, dynamic>> jsonDecodeList(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return const [];
  return List<Map<String, dynamic>>.from(
    decoded.map((e) => e as Map<String, dynamic>),
  );
}

/// Jira system (non-custom) field names that must never be resolved through
/// the field-name → customfield mapping (Java `JiraClient.SYSTEM_FIELDS`).
const systemJiraFields = {
  'summary',
  'description',
  'status',
  'assignee',
  'reporter',
  'creator',
  'created',
  'updated',
  'resolution',
  'priority',
  'issuetype',
  'project',
  'labels',
  'comment',
  'attachment',
  'worklog',
  'timetracking',
  'aggregatetimeestimate',
  'aggregatetimespent',
  'aggregateprogress',
  'workratio',
  'security',
  'issuerestriction',
  'thumbnail',
  'timespent',
  'timeestimate',
  'duedate',
  'environment',
  'components',
  'versions',
  'fixversions',
  'subtasks',
  'parent',
  'issuelinks',
  'watches',
  'votes',
};

/// Extracts the project key from a ticket key (`PROJ-123` → `PROJ`).
///
/// Mirrors Java `JiraClient.parseJiraProject`.
String jiraProjectKeyOf(String key) => key.split('-').first.toUpperCase();

/// Coerces a loosely-typed field value to the JSON type Jira expects.
///
/// Mirrors Java `JiraClient.coerceFieldValue`: strings equal to
/// `true`/`false` (case-insensitive) become booleans, integer- and
/// double-shaped strings become numbers, and strings that parse entirely
/// as a JSON object/array become that structure (the strict full-string
/// parse keeps wiki macros like `{code:mermaid}…{code}` from being
/// mis-read as `{"code":"mermaid"}`). Non-strings and everything else
/// pass through unchanged.
Object? coerceJiraFieldValue(Object? value) {
  if (value is! String) return value;
  final str = value.trim();
  if (str.isEmpty) return value;
  return _coerceBoolOrNumber(str) ?? _coerceJsonStructure(str) ?? value;
}

/// Bool/int/double forms of [str] (Java `coerceFieldValue` scalar cases),
/// or `null` when the string is neither.
Object? _coerceBoolOrNumber(String str) {
  switch (str.toLowerCase()) {
    case 'true':
      return true;
    case 'false':
      return false;
  }
  return int.tryParse(str) ?? double.tryParse(str);
}

/// The JSON object/array [str] decodes to, or `null` when the string does
/// not have the shape of, or fails to parse entirely as, a JSON structure.
Object? _coerceJsonStructure(String str) {
  if (!_isJsonStructureShape(str)) return null;
  try {
    final decoded = jsonDecode(str);
    if (decoded is Map) return decoded;
    if (decoded is List) return decoded;
  } on FormatException {
    // Fall through: not JSON, keep the original string.
  }
  return null;
}

/// Whether [str] is wrapped like a JSON object or array.
bool _isJsonStructureShape(String str) =>
    (str.startsWith('{') && str.endsWith('}')) ||
    (str.startsWith('[') && str.endsWith(']'));

/// Collects Jira field-update errors from a response body — the joined
/// `errorMessages` and `errors` entries (`Field customfield_X: …` for
/// custom fields, `X: …` otherwise) — or `null` when the body carries no
/// error object. Mirrors Java `checkJiraResponseForErrors`.
String? jiraResponseErrorDetail(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final messages = <String>[];
  final errorMessages = decoded['errorMessages'];
  if (errorMessages is List) {
    messages.addAll(errorMessages.whereType<String>());
  }
  final errors = decoded['errors'];
  if (errors is Map) {
    errors.forEach((field, message) {
      final name = field.toString();
      messages.add(
        name.startsWith('customfield_')
            ? 'Field $name: $message'
            : '$name: $message',
      );
    });
  }
  return messages.isEmpty ? null : messages.join('; ');
}
