/// High-level Xray API client — ports the Xray test-management MCP tools.
///
/// Xray authenticates with OAuth2 client credentials: [authenticate] POSTs to
/// `/api/v2/authenticate`, receives a JWT, and stores it as a Bearer token for
/// all subsequent API calls. Transport is delegated to [XrayHttpClient].
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../base_http_client.dart';
import '../jira/jira_client.dart';
import '../jira/jira_http_client.dart';

/// Low-level Xray HTTP transport used by [XrayClient].
///
/// Stores the Bearer token obtained from [XrayClient.authenticate] and injects
/// it into every request via [authHeaders]. Before authentication the token is
/// empty and [authHeaders] omits the `Authorization` header so the
/// `/api/v2/authenticate` call can succeed.
class XrayHttpClient extends BaseHttpClient {
  /// Xray OAuth2 client ID from `XRAY_CLIENT_ID`.
  final String clientId;

  /// Xray OAuth2 client secret from `XRAY_CLIENT_SECRET`.
  final String clientSecret;

  String _token;

  /// Creates a client from [reader]'s Xray configuration.
  ///
  /// Pass [dio] to inject a custom HTTP transport (tests); production code
  /// omits it and gets a default [Dio] with 60-second timeouts.
  ///
  /// Throws [StateError] when `XRAY_BASE_PATH`, `XRAY_CLIENT_ID`, or
  /// `XRAY_CLIENT_SECRET` is missing or empty.
  factory XrayHttpClient(PropertyReader reader, {Dio? dio}) {
    final basePath = reader.getXrayBasePath();
    final clientId = reader.getXrayClientId();
    final clientSecret = reader.getXrayClientSecret();
    if (basePath == null || basePath.isEmpty) {
      throw StateError('XRAY_BASE_PATH is not configured');
    }
    if (clientId == null || clientId.isEmpty) {
      throw StateError('XRAY_CLIENT_ID is not configured');
    }
    if (clientSecret == null || clientSecret.isEmpty) {
      throw StateError('XRAY_CLIENT_SECRET is not configured');
    }
    return XrayHttpClient._(
      dio: dio ?? BaseHttpClient.createDefaultDio(),
      basePath: basePath,
      clientId: clientId,
      clientSecret: clientSecret,
    );
  }

  XrayHttpClient._({
    required super.dio,
    required super.basePath,
    required this.clientId,
    required this.clientSecret,
  }) : _token = '';

  /// Stores the Bearer [token] obtained from the authenticate endpoint.
  void setToken(String token) => _token = token;

  /// Whether a Bearer token has been stored via [setToken].
  bool get isAuthenticated => _token.isNotEmpty;

  @override
  Map<String, String> get authHeaders =>
      _token.isEmpty ? const {} : {'Authorization': 'Bearer $_token'};

  @override
  String buildUrl(String path) => '$basePath/api/v2/$path';
}

/// Xray API methods exposed to the MCP tool runtime.
///
/// Auto-authenticates (using the configured client credentials) on the first
/// API call that requires a Bearer token, so callers can invoke [getTests],
/// [getTestExecutions], [getTestSteps], [getTestPlan], or
/// [createTestExecution] without a manual [authenticate] call.
class XrayClient {
  final XrayHttpClient _http;
  final Duration _syncDelay;
  JiraClient? _jira;

  /// Creates a client backed by [_http].
  ///
  /// Pass [jira] to inject the Jira-side transport used by the tools that
  /// create or search Jira issues (tests); production code omits it and a
  /// [JiraClient] is built lazily from the Jira configuration on first use,
  /// mirroring the Java dual Jira/Xray configuration.
  XrayClient(
    this._http, {
    JiraClient? jira,
    Duration syncDelay = const Duration(seconds: 2),
  })  : _jira = jira,
        _syncDelay = syncDelay;

  /// The lazily-created Jira client backing Jira-side tool calls.
  JiraClient get _jiraClient =>
      _jira ??= JiraClient(JiraHttpClient(PropertyReader()));

  /// Authenticates with Xray OAuth2 and stores the Bearer token.
  ///
  /// POSTs `{"client_id", "client_secret"}` to `/api/v2/authenticate`.
  /// The response body is a JSON-quoted JWT string; the decoded value is
  /// stored as the Bearer token for all subsequent requests.
  Future<void> authenticate(String clientId, String clientSecret) async {
    final body = await _http.post(
      'authenticate',
      body: jsonEncode({
        'client_id': clientId,
        'client_secret': clientSecret,
      }),
    );
    final token = jsonDecode(body);
    if (token is String) _http.setToken(token);
  }

  /// Authenticates using the configured credentials when not already done.
  Future<void> _ensureAuthenticated() async {
    if (!_http.isAuthenticated) {
      await authenticate(_http.clientId, _http.clientSecret);
    }
  }

  /// `jira_xray_test` — connectivity check via OAuth2 authentication.
  ///
  /// Returns `success: true` on successful authentication, or `success: false`
  /// with the error message on failure.
  Future<Map<String, dynamic>> testConnection() async {
    try {
      await authenticate(_http.clientId, _http.clientSecret);
      return {'success': true, 'message': 'Xray connection successful'};
    } on Object catch (e) {
      return {
        'success': false,
        'message': 'Xray connection failed',
        'error': e.toString(),
      };
    }
  }

  /// `jira_xray_get_tests` — POST `/api/v2/tests`.
  ///
  /// Returns the decoded list of test objects matching [testKeys], or an
  /// empty list when the response body is not a JSON array.
  Future<List<Map<String, dynamic>>> getTests(List<String> testKeys) async {
    await _ensureAuthenticated();
    final body =
        await _http.post('tests', body: jsonEncode({'keys': testKeys}));
    return _decodeList(body);
  }

  /// Gets test executions that contain [testKey] — GET
  /// `/api/v2/test/{testKey}/testexecutions`.
  ///
  /// Returns the decoded list of test-execution objects, or an empty list
  /// when the response body is not a JSON array.
  Future<List<Map<String, dynamic>>> getTestExecutions(String testKey) async {
    await _ensureAuthenticated();
    final body = await _http.get('test/$testKey/testexecutions');
    return _decodeList(body);
  }

  /// `jira_xray_get_test_runs` — GET `/api/v2/testrun?testKey={testKey}`.
  ///
  /// Returns the decoded list of test-run objects for [testKey], or an empty
  /// list when the response body is not a JSON array.
  Future<List<Map<String, dynamic>>> getTestRuns(String testKey) async {
    await _ensureAuthenticated();
    final body = await _http.get('testrun', queryParams: {'testKey': testKey});
    return _decodeList(body);
  }

  /// `jira_xray_get_test_steps` — GET `/api/v2/test/{testKey}/steps`.
  ///
  /// Returns the decoded list of test-step objects, or an empty list when
  /// the response body is not a JSON array.
  Future<List<Map<String, dynamic>>> getTestSteps(String testKey) async {
    await _ensureAuthenticated();
    final body = await _http.get('test/$testKey/steps');
    return _decodeList(body);
  }

  /// `jira_xray_get_test_plan` — GET `/api/v2/testplan/{testPlanKey}`.
  ///
  /// Returns the decoded test-plan object, or an empty map when the body is
  /// not a JSON object.
  Future<Map<String, dynamic>> getTestPlan(String testPlanKey) async {
    await _ensureAuthenticated();
    final body = await _http.get('testplan/$testPlanKey');
    return _decodeMap(body) ?? {};
  }

  /// `jira_xray_create_test_execution` — POST `/api/v2/import/execution`.
  ///
  /// Merges [projectKey] into [testExecJson] and imports the execution.
  /// Returns the decoded response object, or an empty map when the body is
  /// not a JSON object.
  Future<Map<String, dynamic>> createTestExecution(
    String projectKey,
    Map<String, dynamic> testExecJson,
  ) async {
    await _ensureAuthenticated();
    final payload = {...testExecJson, 'projectKey': projectKey};
    final body = await _http.post(
      'import/execution',
      body: jsonEncode(payload),
    );
    return _decodeMap(body) ?? {};
  }

  /// `jira_xray_update_test_execution` — POST `/api/v2/testexec/{executionId}`.
  ///
  /// Updates the status of test execution [executionId]. Returns the decoded
  /// response object, or an empty map when the body is not a JSON object.
  Future<Map<String, dynamic>> updateTestExecution(
    String executionId,
    String status,
  ) async {
    await _ensureAuthenticated();
    final body = await _http.post(
      'testexec/$executionId',
      body: jsonEncode({'status': status}),
    );
    return _decodeMap(body) ?? {};
  }

  /// `jira_xray_get_test_details` — GraphQL `getTests(jql: "key={testKey}")`.
  ///
  /// Returns the first matching Test/Precondition object with its steps,
  /// preconditions, test type, gherkin, and dataset, or `null` when the key
  /// is not found or the response reports GraphQL errors.
  Future<Map<String, dynamic>?> getTestDetails(String testKey) async {
    final data = _graphqlData(
      await _executeGraphQL(_testDetailsQuery('key=$testKey', 1)),
    );
    return _firstResult(data?['getTests']);
  }

  /// `jira_xray_get_preconditions` — preconditions of [testKey] via the
  /// GraphQL test-details query.
  ///
  /// Returns the `preconditions.results` list, or an empty list when the
  /// test has no preconditions.
  Future<List<Map<String, dynamic>>> getPreconditions(String testKey) async {
    final details = await getTestDetails(testKey);
    final preconditions = details?['preconditions'];
    final results =
        preconditions is Map<String, dynamic> ? preconditions['results'] : null;
    if (results is List) {
      return [for (final e in results) Map<String, dynamic>.from(e as Map)];
    }
    return const [];
  }

  /// `jira_xray_get_precondition_details` — GraphQL `getTests` restricted to
  /// Precondition issues.
  ///
  /// Returns the first matching result including its `definition`, or
  /// `null` when not found or the response reports GraphQL errors.
  Future<Map<String, dynamic>?> getPreconditionDetails(
    String preconditionKey,
  ) async {
    final data = _graphqlData(
      await _executeGraphQL(_preconditionDetailsQuery(preconditionKey)),
    );
    return _firstResult(data?['getTests']);
  }

  /// `jira_xray_add_test_step` — GraphQL `addTestStep` mutation.
  ///
  /// Throws when the response reports GraphQL errors; otherwise returns the
  /// created step (`id`, `action`, `data`, `result`), or `null` when absent.
  Future<Map<String, dynamic>?> addTestStep(
    String issueId,
    String action, [
    String? data,
    String? result,
  ]) async {
    final mutation =
        'mutation { addTestStep( issueId: "${_gqlEscape(issueId)}", '
        'step: { action: "${_gqlEscape(action)}", '
        'data: "${_gqlEscape(data ?? '')}", '
        'result: "${_gqlEscape(result ?? '')}" } ) { id action data result } }';
    return _mutationResult(await _executeGraphQL(mutation), 'addTestStep');
  }

  /// `jira_xray_add_test_steps` — adds each step via [addTestStep].
  ///
  /// Steps that fail are skipped; when every step fails, the first error is
  /// rethrown so callers can fall back to issue IDs (Java parity).
  Future<List<Map<String, dynamic>>> addTestSteps(
    String issueId,
    List<Map<String, dynamic>> steps,
  ) async {
    final created = <Map<String, dynamic>>[];
    Object? firstError;
    for (final step in steps) {
      try {
        final result = await addTestStep(
          issueId,
          (step['action'] ?? '') as String,
          step['data'] as String?,
          step['result'] as String?,
        );
        if (result != null) created.add(result);
      } on Object catch (e) {
        firstError ??= e;
      }
    }
    if (created.isEmpty && firstError != null) throw firstError;
    return created;
  }

  /// `jira_xray_add_precondition_to_test` — GraphQL
  /// `addPreconditionsToTest` mutation with a single ID.
  ///
  /// Throws when the response reports GraphQL errors; otherwise returns the
  /// mutation result, or `null` when absent.
  Future<Map<String, dynamic>?> addPreconditionToTest(
    String testIssueId,
    String preconditionIssueId,
  ) async {
    if (testIssueId.isEmpty || preconditionIssueId.isEmpty) return null;
    final mutation =
        'mutation { addPreconditionsToTest( issueId: "$testIssueId", '
        'preconditionIssueIds: ["$preconditionIssueId"] ) { __typename } }';
    return _mutationResult(
      await _executeGraphQL(mutation),
      'addPreconditionsToTest',
    );
  }

  /// `jira_xray_add_preconditions_to_test` — adds each precondition via
  /// [addPreconditionToTest], skipping individual failures (Java parity).
  Future<List<Map<String, dynamic>>> addPreconditionsToTest(
    String testIssueId,
    List<String> preconditionIssueIds,
  ) async {
    final results = <Map<String, dynamic>>[];
    for (final id in preconditionIssueIds) {
      try {
        final result = await addPreconditionToTest(testIssueId, id);
        if (result != null) results.add(result);
      } on Object {
        // continue with the remaining preconditions
      }
    }
    return results;
  }

  /// `jira_xray_create_precondition` — creates the Jira Precondition issue,
  /// then converts [steps] to a definition via the Xray GraphQL API.
  ///
  /// Returns the created ticket key. Failures after the Jira creation are
  /// swallowed so the tool still reports the key (Java parity).
  Future<String> createPrecondition(
    String project,
    String summary, {
    String? description,
    List<Map<String, dynamic>>? steps,
  }) async {
    final response = await _jiraClient.createTicketBasic(
      project,
      'Precondition',
      summary,
      description ?? '',
    );
    final key = response['key'] as String;
    if (steps != null && steps.isNotEmpty) {
      try {
        await _setPreconditionDefinition(key, steps);
      } on Object {
        // the ticket exists; an X-ray sync failure must not fail the tool
      }
    }
    return key;
  }

  /// `jira_xray_search_tickets` — Jira JQL search plus X-ray enrichment.
  ///
  /// `issuetype` is always requested so Test/Precondition issues can be
  /// identified; matching tickets get `xrayTestSteps`, `xrayTestType`,
  /// `xrayGherkin`, `xrayDataset`, and `xrayPreconditions` merged into
  /// their `fields`.
  Future<List<Map<String, dynamic>>> searchTickets(
    String searchQueryJQL, [
    List<String>? fields,
  ]) async {
    final issues = await _jiraClient.searchByJql(
      searchQueryJQL,
      _ensureIssueType(fields),
    );
    if (issues.isNotEmpty) {
      await _enrichWithXrayData(issues, searchQueryJQL);
    }
    return issues;
  }

  /// Runs [query] against `/api/v2/graphql` with the Xray Bearer token.
  Future<String> _executeGraphQL(String query) async {
    await _ensureAuthenticated();
    return _http.post('graphql', body: jsonEncode({'query': query}));
  }

  /// Decodes a GraphQL response body to its `data` object.
  ///
  /// Returns `null` for non-object bodies, GraphQL `errors` responses, or a
  /// missing `data` member (the GraphQL query methods return null there).
  Map<String, dynamic>? _graphqlData(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['errors'] != null) return null;
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : null;
  }

  /// Extracts `data.[field]` from a mutation response.
  ///
  /// Throws when the response reports GraphQL errors, mirroring the Java
  /// mutations that surface GraphQL errors as failures.
  Map<String, dynamic>? _mutationResult(String body, String field) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message =
          first is Map ? first['message'] ?? 'Unknown GraphQL error' : null;
      throw StateError('GraphQL mutation failed: $message');
    }
    final data = decoded['data'];
    final result = data is Map<String, dynamic> ? data[field] : null;
    return result is Map<String, dynamic> ? result : null;
  }

  /// First entry of a GraphQL `getTests` result wrapper, or `null`.
  Map<String, dynamic>? _firstResult(dynamic getTests) {
    final results =
        getTests is Map<String, dynamic> ? getTests['results'] : null;
    if (results is List && results.isNotEmpty) {
      return Map<String, dynamic>.from(results.first as Map);
    }
    return null;
  }

  /// Adds `issuetype` to [fields] (case-insensitive check) so X-ray
  /// enrichment can detect Test/Precondition issues.
  List<String> _ensureIssueType(List<String>? fields) {
    final list = fields ?? const [];
    if (list.isEmpty) return ['issuetype'];
    if (list.any((f) => f.toLowerCase() == 'issuetype')) return list;
    return [...list, 'issuetype'];
  }

  /// Enriches Test/Precondition [issues] with the X-ray data for [jql].
  Future<void> _enrichWithXrayData(
    List<Map<String, dynamic>> issues,
    String jql,
  ) async {
    final xrayData = await _testsByJql(jql);
    if (xrayData.isEmpty) return;
    final byKey = <String, Map<String, dynamic>>{};
    for (final test in xrayData) {
      final key = _jiraKeyOf(test);
      if (key != null && key.isNotEmpty) byKey[key] = test;
    }
    final summaries = await _preconditionSummaries(xrayData);
    for (final issue in issues) {
      final key = issue['key'] as String?;
      final data = key == null ? null : byKey[key];
      if (data != null) _attachXrayData(issue, data, summaries);
    }
  }

  /// All tests matching [jql] via GraphQL, paginated by `key > lastKey`
  /// cursors with `ORDER BY key ASC` (Java `getTestsByJQLGraphQL`).
  Future<List<Map<String, dynamic>>> _testsByJql(String jql) async {
    final all = <Map<String, dynamic>>[];
    var current = jql;
    while (true) {
      final page = await _fetchJqlPage(current);
      if (page == null || page.isEmpty) break;
      all.addAll([for (final e in page) Map<String, dynamic>.from(e as Map)]);
      final lastKey = _maxKeyOf(page);
      if (page.length < 100 || lastKey == null) break;
      current = '$jql AND key > "$lastKey"';
    }
    return all;
  }

  /// One GraphQL `getTests` results page for [jql] (`ORDER BY key ASC`,
  /// limit 100), or `null` when the response carries no results.
  Future<List?> _fetchJqlPage(String jql) async {
    final data = _graphqlData(
      await _executeGraphQL(_testDetailsQuery('$jql ORDER BY key ASC', 100)),
    );
    final getTests = data?['getTests'];
    final results =
        getTests is Map<String, dynamic> ? getTests['results'] : null;
    return results is List ? results : null;
  }

  /// Fetches Jira `summary`/`description` for every precondition key found
  /// in [xrayData] (Java's precondition batch fetch).
  Future<Map<String, Map<String, String>>> _preconditionSummaries(
    List<Map<String, dynamic>> xrayData,
  ) async {
    final summaries = <String, Map<String, String>>{};
    for (final test in xrayData) {
      final preconditions = test['preconditions'];
      final results = preconditions is Map<String, dynamic>
          ? preconditions['results']
          : null;
      if (results is! List) continue;
      for (final entry in results) {
        final key = entry is Map ? _jiraKeyOf(entry) : null;
        if (key == null || summaries.containsKey(key)) continue;
        summaries[key] = await _jiraSummary(key);
      }
    }
    return summaries;
  }

  /// `GET issue/{key}?fields=summary,description` collapsed to a flat map.
  Future<Map<String, String>> _jiraSummary(String key) async {
    try {
      final ticket =
          await _jiraClient.getTicket(key, ['summary', 'description']);
      final fields = ticket?['fields'];
      if (fields is Map<String, dynamic>) {
        return {
          if (fields['summary'] is String)
            'summary': fields['summary'] as String,
          if (fields['description'] is String)
            'description': fields['description'] as String,
        };
      }
    } on Object {
      // skip preconditions Jira cannot serve (Java parity)
    }
    return const {};
  }

  /// Merges X-ray [data] into `issue.fields` as `xray*` keys, adding the
  /// Jira [summaries] to each precondition entry.
  void _attachXrayData(
    Map<String, dynamic> issue,
    Map<String, dynamic> data,
    Map<String, Map<String, String>> summaries,
  ) {
    final fields = issue['fields'];
    if (fields is! Map<String, dynamic>) return;
    _attachXrayFields(fields, data);
    _attachXrayPreconditions(fields, data, summaries);
  }

  /// Copies the scalar X-ray facets (steps, test type, gherkin, dataset)
  /// into `fields` under their `xray*` keys.
  void _attachXrayFields(
    Map<String, dynamic> fields,
    Map<String, dynamic> data,
  ) {
    final steps = data['steps'];
    if (steps is List && steps.isNotEmpty) fields['xrayTestSteps'] = steps;
    if (data['testType'] is Map) fields['xrayTestType'] = data['testType'];
    _attachString(fields, 'xrayGherkin', data['gherkin']);
    final dataset = data['dataset'];
    if (dataset is Map && dataset.isNotEmpty) fields['xrayDataset'] = dataset;
  }

  /// Attaches [value] under [key] when it is a non-empty string.
  void _attachString(Map<String, dynamic> fields, String key, Object? value) {
    if (value is String && value.isNotEmpty) fields[key] = value;
  }

  /// Attaches `xrayPreconditions` to `fields`, enriching each entry with
  /// its Jira [summaries] entry.
  void _attachXrayPreconditions(
    Map<String, dynamic> fields,
    Map<String, dynamic> data,
    Map<String, Map<String, String>> summaries,
  ) {
    final preconditions = data['preconditions'];
    final results =
        preconditions is Map<String, dynamic> ? preconditions['results'] : null;
    if (results is! List) return;
    for (final entry in results) {
      final summary = entry is Map ? summaries[_jiraKeyOf(entry)] : null;
      if (summary != null) entry.addAll(summary);
    }
    fields['xrayPreconditions'] = results;
  }

  /// The `jira.key` of a GraphQL test/precondition entry, or `null`.
  String? _jiraKeyOf(dynamic entry) {
    final jira = entry is Map ? entry['jira'] : null;
    final key = jira is Map ? jira['key'] : null;
    return key is String ? key : null;
  }

  /// Lexicographically greatest `jira.key` in a results page, used as the
  /// next pagination cursor regardless of the page's sort order.
  String? _maxKeyOf(List page) {
    String? max;
    for (final entry in page) {
      final key = _jiraKeyOf(entry);
      if (key != null && (max == null || key.compareTo(max) > 0)) max = key;
    }
    return max;
  }

  /// Waits for X-ray to index the newly created [ticketKey].
  ///
  /// Polls the GraphQL test-details query up to three times, two seconds
  /// apart (Java `waitForXraySync`), returning the Xray issue ID or `null`
  /// when the ticket never shows up.
  Future<String?> _waitForXraySync(String ticketKey) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final details = await getTestDetails(ticketKey);
        final issueId = details?['issueId'];
        if (issueId is String && issueId.isNotEmpty) return issueId;
        if (details != null) return null; // synced, but no issueId
      } on Object {
        // not yet indexed — retry after the delay
      }
      if (attempt < 2) {
        await Future<void>.delayed(_syncDelay);
      }
    }
    return null;
  }

  /// Sets the definition of the freshly created precondition via the Xray
  /// GraphQL `updatePrecondition` mutation (Java `setPreconditionDefinition`).
  Future<void> _setPreconditionDefinition(
    String ticketKey,
    List<Map<String, dynamic>> steps,
  ) async {
    final issueId =
        await _waitForXraySync(ticketKey) ?? await _jiraIssueId(ticketKey);
    if (issueId == null || issueId.isEmpty) {
      throw StateError('Cannot get issue ID for precondition $ticketKey');
    }
    final definition = _stepsToDefinition(steps);
    final mutation = 'mutation { updatePrecondition( issueId: "$issueId", '
        'precondition: { definition: "${_gqlEscape(definition)}" } ) '
        '{ issueId } }';
    _mutationResult(await _executeGraphQL(mutation), 'updatePrecondition');
  }

  /// Resolves the Jira issue ID for [ticketKey] (`GET issue/{key}?fields=id`).
  Future<String?> _jiraIssueId(String ticketKey) async {
    final ticket = await _jiraClient.getTicket(ticketKey, ['id']);
    final id = ticket?['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// Converts [steps] to the precondition definition text.
  ///
  /// Format: `Step 1: action -> data -> result` lines joined by newlines,
  /// with the Java `step`/`expectedResult` field-name fallbacks.
  String _stepsToDefinition(List<Map<String, dynamic>> steps) {
    final lines = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final action = (steps[i]['action'] ?? steps[i]['step'] ?? '') as String;
      final data = (steps[i]['data'] ?? '') as String;
      final result =
          (steps[i]['result'] ?? steps[i]['expectedResult'] ?? '') as String;
      final parts = [
        if (action.isNotEmpty) action,
        if (data.isNotEmpty) data,
        if (result.isNotEmpty) result,
      ];
      lines.add('Step ${i + 1}: ${parts.join(' -> ')}');
    }
    return lines.join('\n');
  }

  /// Decodes a JSON array of objects, tolerating non-array bodies.
  List<Map<String, dynamic>> _decodeList(String body) {
    final decoded = jsonDecode(body);
    return decoded is List
        ? [for (final e in decoded) Map<String, dynamic>.from(e as Map)]
        : const [];
  }

  /// Decodes a JSON body to a map, or `null` when not an object.
  Map<String, dynamic>? _decodeMap(String body) {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}

/// GraphQL `getTests` query with the Java field list (steps with attachments
/// and custom fields, test type, folder, gherkin, dataset, preconditions).
String _testDetailsQuery(String jql, int limit) =>
    'query { getTests(jql: "${jql.replaceAll('"', r'\"')}", limit: $limit) '
    '{ results { issueId projectId '
    'jira(fields: ["key", "summary", "description"]) testType { name } '
    'folder { path } steps { id action data result '
    'attachments { id filename downloadLink } customFields { id name value } } '
    'scenarioType gherkin unstructured '
    'dataset { parameters { name type listValues } rows { order Values } } '
    'preconditions(limit: 10) { total results { issueId definition '
    'jira(fields: ["key", "summary"]) } } } } }';

/// GraphQL query for Precondition issues including `definition` via an
/// inline fragment (Java `getPreconditionDetailsGraphQL`).
String _preconditionDetailsQuery(String preconditionKey) =>
    'query { getTests(jql: "key=${preconditionKey.replaceAll('"', r'\"')} '
    'AND issueType = Precondition", limit: 1) { results { issueId projectId '
    'jira(fields: ["key", "summary", "description"]) testType { name } '
    '... on Precondition { definition } } } }';

/// Escapes a string for a GraphQL literal: backslash, double quote,
/// newline, and carriage return (Java parity).
String _gqlEscape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');
