/// Synchronous Jira tool executors for the JS tool bridge.
///
/// Public counterpart of the dispatcher-internal `_JiraSyncTools`: pure
/// executor functions that take the JS tool-arguments map and return a JSON
/// result string, resolving Jira config via [PropertyReader] and performing
/// blocking HTTP via [SyncHttpClient] (curl subprocess) — safe to call inside
/// QuickJS [NativeCallable] callbacks where the Dart event loop is frozen.
///
/// Tool names and argument shapes mirror the Java `JiraClient`
/// `@MCPTool`/`@MCPParam` annotations exactly (agents pass e.g.
/// `{sourceKey, anotherKey, relationship}` to `jira_link_issues`); URL
/// shapes mirror the Java request builders (`/rest/api/latest/issueLink`,
/// `issueLinkType`, `issue/{key}/attachments` multipart, …).
library;

import 'dart:convert';
import 'dart:io';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../../integrations/jira/jira_utils.dart';
import '../sync_http_client.dart';
import 'package:dmtools/src/integrations/jira/markdown_to_jira_markup.dart';
import 'tracker_github_router.dart';
import 'tracker_gitlab_router.dart';

part 'jira_sync_http_helpers.dart';
part 'jira_sync_field_update.dart';

/// Executes `jira_*` MCP tool calls synchronously over curl subprocess.
class JiraSyncTools {
  /// Creates Jira tooling; config is resolved per call.
  ///
  /// [trackerRouter] routes `gh-<number>` ticket calls to GitHub Issues
  /// when Jira is unconfigured (see [TrackerGitHubRouter]), and — with
  /// `DEFAULT_TRACKER=gitlab` — to GitLab Issues ([TrackerGitLabRouter]);
  /// tests inject logger-capturing instances.
  const JiraSyncTools({
    TrackerGitHubRouter trackerRouter = _defaultRouter,
    TrackerGitLabRouter gitlabRouter = _defaultGitlabRouter,
  })  : _trackerRouter = trackerRouter,
        _gitlabRouter = gitlabRouter;

  static const _defaultRouter = TrackerGitHubRouter();
  static const _defaultGitlabRouter = TrackerGitLabRouter();

  final TrackerGitHubRouter _trackerRouter;
  final TrackerGitLabRouter _gitlabRouter;

  /// Jira tool executors: canonical `@MCPTool` names plus the dispatch
  /// aliases (`jira_assign`, `jira_create_ticket`, `tracker_*`).
  ///
  /// Each entry is a pure function: arguments map in, JSON result string
  /// out (`{"error": …}` on failure). Config is resolved per invocation via
  /// a fresh [PropertyReader] — the same per-call pattern the dispatcher's
  /// `executeToolViaJava` entry point uses.
  Map<String, String Function(Map<String, dynamic> args)> get handlers => {
        'jira_get_ticket': _getTicket,
        'jira_post_comment': _postComment,
        'jira_search_by_jql': _searchByJql,
        'jira_add_label': _addLabel,
        'jira_remove_label': _removeLabel,
        'jira_move_to_status': _moveToStatus,
        'jira_get_comments': _getComments,
        'jira_update_field': _updateField,
        'jira_update_description': _updateDescription,
        'jira_get_transitions': _getTransitions,
        'jira_get_my_profile': _getMyProfile,
        'jira_delete_ticket': _deleteTicket,
        'jira_create_ticket_basic': _createTicketBasic,
        'jira_create_ticket': _createTicketBasic,
        'jira_assign_ticket_to': _assignTicketTo,
        'jira_assign_to': _assignTicketTo,
        'jira_assign': _assignTicketTo,
        'tracker_assign_ticket': _assignTicketTo,
        'jira_set_priority': _setPriority,
        'jira_create_ticket_with_parent': _createTicketWithParent,
        'jira_create_ticket_with_json': _createTicketWithJson,
        'jira_link_issues': _linkIssues,
        'tracker_link_tickets': _linkIssues,
        'jira_get_field_custom_code': _getFieldCustomCode,
        'jira_attach_file_to_ticket': _attachFileToTicket,
      };

  /// Dispatches a Jira tool call against [handlers].
  ///
  /// Tracker-shaped calls on `gh-<number>` keys route to GitLab Issues
  /// (`DEFAULT_TRACKER=gitlab`) or GitHub Issues first when Jira is
  /// unconfigured ([TrackerGitLabRouter], [TrackerGitHubRouter]); everything
  /// else keeps the Jira path. Mirrors the dispatcher's error contract:
  /// unknown names yield `{"error": "Unsupported Jira tool: …"}`, missing
  /// config yields `{"error": "Jira not configured"}`.
  String dispatch(String toolName, Map<String, dynamic> args) {
    final routed = _gitlabRouter.maybeRoute(toolName, args) ??
        _trackerRouter.maybeRoute(toolName, args);
    if (routed != null) return routed;
    final fn = handlers[toolName];
    if (fn == null) return _err('Unsupported Jira tool: $toolName');
    return fn(args);
  }

  /// `jira_get_ticket` — GET `issue/{key}?fields={fields}`.
  String _getTicket(Map<String, dynamic> args) => _run((config) {
        final url = '${config.baseUrl}/issue/${_asStr(args['key'])}'
            '?fields=${Uri.encodeQueryComponent(_joinFields(args['fields']))}';
        return _bodyOrError(SyncHttpClient.get(url, headers: config.headers));
      });

  /// `jira_post_comment` — POST `issue/{key}/comment`.
  ///
  /// The comment body runs through [markdownToJiraMarkup] first: Java
  /// `JiraClient.postComment` converts whenever
  /// `TrackerClient.TextType == MARKDOWN` (gh-191, P6-JSY-09), and
  /// `BasicJiraClient.getTextType()` always returns MARKDOWN for Jira.
  String _postComment(Map<String, dynamic> args) => _run((config) {
        final body = jsonEncode(
          {'body': markdownToJiraMarkup(_asStr(args['comment']))},
        );
        return _postBody(
          config,
          '${config.baseUrl}/issue/${_asStr(args['key'])}/comment',
          body,
        );
      });

  /// `jira_search_by_jql` — GET `search/jql` (Cloud) or `search` (Server).
  ///
  /// Mirrors Java `searchAndPerform`: Cloud instances page through
  /// `nextPageToken`; Jira Server (which lacks the Cloud-only `search/jql`
  /// route) pages through `startAt`/`maxResults`/`total` like Java's
  /// `legacyServerJiraSearch`. Returns the bare issues array as JSON —
  /// the Java tool returns `List<Ticket>`, so the JS side receives an
  /// array, not the `{issues: …}` envelope.
  String _searchByJql(Map<String, dynamic> args) => _run((config) {
        final jql = Uri.encodeQueryComponent(_asStr(args['jql']));
        final fields = Uri.encodeQueryComponent(_joinFields(args['fields']));
        return _isCloudJira(config)
            ? _cloudSearchPages(config, jql, fields)
            : _serverSearchPages(config, jql, fields);
      });

  /// Cloud pagination: walk `search/jql` pages by `nextPageToken`.
  ///
  /// Mirrors the Java `searchAndPerform` cloud branch: a failed, null, or
  /// error-carrying first page surfaces as an error before the walk; the
  /// walk itself then follows Java's break order per page.
  String _cloudSearchPages(_JiraSyncConfig config, String jql, String fields) {
    final page =
        _fetchSearchPage(config, _searchJqlUrl(config, jql, fields, ''));
    if (page is String) return page;
    final firstError = _firstPageError(page);
    if (firstError != null) return firstError;
    return _cloudWalk(config, jql, fields, page as Map<String, dynamic>);
  }

  /// Walks cloud pages from [firstPage] in Java's loop order: stop on an
  /// empty/absent issues list, then on `isLast`, then on a missing next
  /// token; a failed follow-up fetch surfaces as a pagination error and a
  /// null follow-up page ends the walk.
  String _cloudWalk(
    _JiraSyncConfig config,
    String jql,
    String fields,
    Map<String, dynamic> firstPage,
  ) {
    final issues = <dynamic>[];
    dynamic page = firstPage;
    while (true) {
      final pageIssues = page['issues'] as List?;
      if (pageIssues == null || pageIssues.isEmpty) break;
      issues.addAll(pageIssues);
      // ponytail: Java reads `isLast` off the SearchResult model
      // (optBoolean, absent = false); the raw JSON field carries the same
      // value, so absent/false simply keeps paging like Java.
      if (page['isLast'] == true) break;
      final token = _asStr(page['nextPageToken']);
      if (token.isEmpty) break;
      page = _fetchSearchPage(
        config,
        _searchJqlUrl(config, jql, fields, token),
      );
      if (page is String) {
        return _err('Pagination failed: ${_errorOf(page)}');
      }
      if (page == null) break;
    }
    return jsonEncode(issues);
  }

  /// Server pagination: walk legacy `search` pages by `startAt`.
  ///
  /// Mirrors Java `legacyServerJiraSearch`: a failed or error-carrying
  /// first page surfaces as an error, `total == 0` returns early, and the
  /// walk follows Java's loop conditions with per-page counter refresh.
  String _serverSearchPages(_JiraSyncConfig config, String jql, String fields) {
    final page =
        _fetchSearchPage(config, _legacySearchUrl(config, jql, fields, 0));
    if (page is String) return page;
    final firstError = _firstPageError(page);
    if (firstError != null) return firstError;
    final maxResults = page['maxResults'] as int? ?? 0;
    final total = page['total'] as int? ?? 0;
    if (total == 0) return jsonEncode(const <dynamic>[]);
    return _serverWalk(
      config,
      jql,
      fields,
      page as Map<String, dynamic>,
      maxResults,
      total,
    );
  }

  /// Walks server pages from [firstPage] in Java's loop order: advance
  /// `startAt` by the current page size, collect the current page, break
  /// when `total < maxResults || startAt > total`, otherwise fetch the
  /// next page and refresh the paging counters from it.
  String _serverWalk(
    _JiraSyncConfig config,
    String jql,
    String fields,
    Map<String, dynamic> firstPage,
    int maxResults,
    int total,
  ) {
    final issues = <dynamic>[];
    dynamic page = firstPage;
    var pageSize = maxResults;
    var remaining = total;
    var startAt = 0;
    while (startAt == 0 || startAt < remaining) {
      startAt += pageSize;
      issues.addAll(page['issues'] as List? ?? const []);
      if (remaining < pageSize || startAt > remaining) break;
      page = _fetchSearchPage(
        config,
        _legacySearchUrl(config, jql, fields, startAt),
      );
      if (page is String) return page;
      if (page == null) break;
      pageSize = page['maxResults'] as int? ?? 0;
      remaining = page['total'] as int? ?? 0;
    }
    return jsonEncode(issues);
  }

  /// Validates a first search page like Java's pre-loop checks: a null
  /// page (Java's defensive null `SearchResult`) or a non-empty
  /// `errorMessages` list yields an error result, otherwise `null`.
  String? _firstPageError(dynamic page) {
    if (page == null) return _err('Search returned null results');
    final messages = page['errorMessages'] as List?;
    if (messages != null && messages.isNotEmpty) {
      return _err('Search failed: ${jsonEncode(messages)}');
    }
    return null;
  }

  /// GETs and decodes one search page.
  ///
  /// Returns the page map on success, `null` when the body is JSON `null`
  /// (Java's null `SearchResult`), or the error result string produced by
  /// [_bodyOrError] (curl error, non-2xx status, or a non-JSON body) so
  /// callers can map it to the Java exception paths.
  dynamic _fetchSearchPage(_JiraSyncConfig config, String url) {
    final result =
        _bodyOrError(SyncHttpClient.get(url, headers: config.headers));
    final decoded = _tryDecode(result);
    if (decoded == null) return null;
    return decoded is Map<String, dynamic> && !decoded.containsKey('error')
        ? decoded
        : result;
  }

  /// Builds a `search/jql` URL, omitting an empty [token] like Java.
  String _searchJqlUrl(
    _JiraSyncConfig config,
    String jql,
    String fields,
    String token,
  ) =>
      '${config.baseUrl}/search/jql?jql=$jql&fields=$fields'
      '${token.isEmpty ? '' : '&nextPageToken=${Uri.encodeQueryComponent(token)}'}';

  /// Builds a legacy `search` URL at [startAt].
  String _legacySearchUrl(
    _JiraSyncConfig config,
    String jql,
    String fields,
    int startAt,
  ) =>
      '${config.baseUrl}/search?jql=$jql&fields=$fields&startAt=$startAt';

  /// Deployment-detection cache, keyed by Jira base path.
  ///
  /// Java memoizes via CacheManager for the process lifetime; the key here
  /// is the base path because tests point the client at different servers.
  static final Map<String, bool> _cloudByBasePath = {};

  /// Whether the configured Jira is a Cloud instance.
  ///
  /// Mirrors Java `isCloudJira`: `serverInfo.deploymentType == "Cloud"`
  /// decides; a missing field or a failed probe falls back to the
  /// `atlassian.net` URL pattern.
  bool _isCloudJira(_JiraSyncConfig config) =>
      _cloudByBasePath[config.basePath] ??= _detectCloudJira(config);

  /// Probes `serverInfo` once; falls back to the URL pattern on any doubt.
  bool _detectCloudJira(_JiraSyncConfig config) {
    final info = _getJson(config, '${config.baseUrl}/serverInfo');
    final deploymentType = info?['deploymentType'];
    if (deploymentType != null) {
      return deploymentType.toString().toLowerCase() == 'cloud';
    }
    return config.basePath.contains('atlassian.net');
  }

  /// `jira_add_label` — fetches labels, appends, PUTs the full set.
  ///
  /// The PUT is skipped when the fetch fails: PUTting a set built from an
  /// empty failure result would wipe every existing label on the ticket.
  String _addLabel(Map<String, dynamic> args) => _run((config) {
        final key = _asStr(args['key']);
        final labels = _fetchLabels(config, key);
        if (labels == null) return _err('Failed to fetch labels for $key');
        final label = _asStr(args['label']);
        if (!labels.contains(label)) labels.add(label);
        return _putLabels(config, key, labels);
      });

  /// `jira_remove_label` — fetches labels, removes, PUTs the full set.
  ///
  /// Same failure contract as [_addLabel]: no PUT without a confirmed fetch.
  String _removeLabel(Map<String, dynamic> args) => _run((config) {
        final key = _asStr(args['key']);
        final labels = _fetchLabels(config, key);
        if (labels == null) return _err('Failed to fetch labels for $key');
        labels.remove(_asStr(args['label']));
        return _putLabels(config, key, labels);
      });

  /// `jira_move_to_status` — finds the transition, then POSTs it. Fetch
  /// failures surface as their own error — a transient here used to
  /// masquerade as "No transition found" (nightly 2026-09-17).
  String _moveToStatus(Map<String, dynamic> args) => _run((config) {
        final key = _asStr(args['key']);
        final status = _asStr(args['statusName']);
        final result =
            _getJsonOrError('${config.baseUrl}/issue/$key/transitions', config);
        if (result is String) return _err(result);
        final list =
            (result as Map<String, dynamic>)['transitions'] as List? ?? [];
        final transitions = list.cast<Map<String, dynamic>>();
        final id = matchTransitionId(transitions, status);
        if (id == null) return _err('No transition found for status: $status');
        return _postBody(
          config,
          '${config.baseUrl}/issue/$key/transitions',
          jsonEncode({
            'transition': {'id': id},
          }),
        );
      });

  /// `jira_get_comments` — GET `issue/{key}/comment`.
  String _getComments(Map<String, dynamic> args) => _run((config) {
        final url = '${config.baseUrl}/issue/${_asStr(args['key'])}/comment';
        return _bodyOrError(SyncHttpClient.get(url, headers: config.headers));
      });

  /// `jira_update_field` — the Java `updateField` engine (body in
  /// `jira_sync_field_update.dart`).
  String _updateField(Map<String, dynamic> args) =>
      _run((config) => _updateFieldFor(config, args));

  /// `jira_update_description` — PUT `issue/{key}` with the description.
  String _updateDescription(Map<String, dynamic> args) => _putIssueFields(
        args,
        {'description': _asStr(args['description'])},
      );

  /// `jira_get_transitions` — GET `issue/{key}/transitions`.
  String _getTransitions(Map<String, dynamic> args) => _run((config) {
        final url = '${config.baseUrl}/issue/${_asStr(args['key'])}'
            '/transitions';
        return _bodyOrError(SyncHttpClient.get(url, headers: config.headers));
      });

  /// `jira_get_my_profile` — GET `myself`.
  String _getMyProfile(Map<String, dynamic> args) => _run((config) {
        return _bodyOrError(
          SyncHttpClient.get('${config.baseUrl}/myself',
              headers: config.headers),
        );
      });

  /// `jira_delete_ticket` — DELETE `issue/{key}`.
  ///
  /// Java `deleteTicket`: an empty (204) response reports `"Success"`;
  /// any other body is returned as-is.
  String _deleteTicket(Map<String, dynamic> args) => _run((config) {
        final resp = SyncHttpClient.delete(
          '${config.baseUrl}/issue/${_asStr(args['key'])}',
          headers: config.headers,
        );
        if (resp.isOk && resp.body.isEmpty) return jsonEncode('Success');
        return _bodyOrError(resp);
      });

  /// `jira_create_ticket_basic` (alias `jira_create_ticket`) — POST `issue`.
  ///
  /// Description is included only when provided (Java `createTicketBasic`).
  String _createTicketBasic(Map<String, dynamic> args) =>
      _postIssueCreate(_basicCreateFields(args));

  /// `jira_assign_ticket_to` (aliases `jira_assign_to` / `jira_assign` /
  /// `tracker_assign_ticket`) — PUT `issue/{key}/assignee`.
  String _assignTicketTo(Map<String, dynamic> args) => _run((config) {
        return _putBody(
          config,
          '${config.baseUrl}/issue/${_asStr(args['key'])}/assignee',
          jsonEncode({'accountId': _asStr(args['accountId'])}),
        );
      });

  /// `jira_set_priority` — PUT `issue/{key}` with `priority:{name}`.
  String _setPriority(Map<String, dynamic> args) => _putIssueFields(
        args,
        {
          'priority': {'name': _asStr(args['priority'])},
        },
      );

  /// `jira_create_ticket_with_parent` — POST `issue` with a parent key.
  ///
  /// Java `createTicketInProjectWithParent` signature (`description` is a
  /// declared `@MCPParam`); the parent travels as `{key}` like the async
  /// [JiraClient.createTicketWithParent].
  /// `jira_create_ticket_with_parent` — Java
  /// `createTicketInProjectWithParent`: the parent ticket is fetched first
  /// (`?fields=summary`, failing upfront when it cannot be read) and the
  /// full parent object is embedded in the create payload.
  String _createTicketWithParent(Map<String, dynamic> args) => _run((config) {
        final parentKey = _asStr(args['parentKey']);
        final parent = _getJson(
          config,
          '${config.baseUrl}/issue/$parentKey?fields=summary',
        );
        if (parent == null) {
          return _err('Failed to fetch parent ticket $parentKey');
        }
        return _postIssueCreate({
          ..._basicCreateFields(args),
          'parent': parent,
        });
      });

  /// `jira_create_ticket_with_json` — POST `issue` with merged fields JSON.
  ///
  /// The `fieldsJson` object is merged over the mandatory `project` field
  /// (Java `createTicketInProjectWithJson`).
  String _createTicketWithJson(Map<String, dynamic> args) => _postIssueCreate({
        'project': {'key': _asStr(args['project'])},
        ..._fieldsJsonArg(args['fieldsJson']),
      });

  /// `jira_link_issues` (alias `tracker_link_tickets`) — POST `issueLink`.
  ///
  /// Resolves the relationship against the `issueLinkType` listing (match by
  /// type name, inward, or outward description — case-insensitive) and
  /// places source/another keys on the side the matched direction implies,
  /// mirroring Java `linkIssueWithRelationship`.
  String _linkIssues(Map<String, dynamic> args) => _run((config) {
        final relationship = _asStr(args['relationship']);
        final resolved =
            resolveJiraLinkType(_fetchLinkTypes(config), relationship);
        if (resolved == null) {
          return _err('Unknown relationship type: $relationship');
        }
        final source = {'key': _asStr(args['sourceKey'])};
        final another = {'key': _asStr(args['anotherKey'])};
        final body = resolved.direction == 'inward'
            ? {
                'type': {'name': resolved.name},
                'outwardIssue': source,
                'inwardIssue': another,
              }
            : {
                'type': {'name': resolved.name},
                'inwardIssue': source,
                'outwardIssue': another,
              };
        return _postBody(
          config,
          '${config.baseUrl}/issueLink',
          jsonEncode(body),
        );
      });

  /// `jira_get_field_custom_code` — resolve a display name to a field id.
  ///
  /// Java `getFieldCustomCode`: fetch the `field` listing (createmeta
  /// fallback), find every case-insensitive name match, return the best
  /// candidate's id. Returns JSON `null` when nothing matches (Java returns
  /// `null`).
  String _getFieldCustomCode(Map<String, dynamic> args) => _run((config) {
        final field = _asStr(args['fieldName']);
        final listing = _fieldsListing(config, _asStr(args['project']));
        if (listing.error != null) {
          return _err("Failed to resolve field '$field': ${listing.error}");
        }
        final best = selectBestJiraField(
          findAllJiraFieldsByName(field, listing.body!),
        );
        return best == null ? 'null' : jsonEncode(best.id);
      });

  /// `jira_attach_file_to_ticket` — multipart POST `issue/{key}/attachments`.
  ///
  /// Mirrors Java `attachFileToTicket`: when the ticket already has an
  /// attachment with the same name (case-insensitive) the upload is skipped
  /// and success is still reported; missing local files are an error;
  /// `contentType` defaults to `image/*`.
  String _attachFileToTicket(Map<String, dynamic> args) => _run((config) {
        final ticketKey = _asStr(args['ticketKey']);
        final name = _asStr(args['name']);
        final filePath = _asStr(args['filePath']);
        final file = File(filePath);
        if (!file.existsSync()) return _err('File does not exist: $filePath');
        if (_attachmentExists(config, ticketKey, name)) {
          return _attachSuccess(ticketKey, name);
        }
        final contentType = _asStr(args['contentType']);
        final effectiveContentType =
            contentType.isEmpty ? 'image/*' : contentType;
        return _uploadAttachment(
          config,
          ticketKey,
          name,
          effectiveContentType,
          filePath,
        );
      });

  /// Builds the Java `attachFileToTicket` success result.
  String _attachSuccess(String ticketKey, String name) => jsonEncode({
        'status': 'success',
        'message': "File '$name' attached to ticket $ticketKey",
        'ticket': ticketKey,
        'fileName': name,
      });

  /// Whether [ticketKey] already has an attachment named [name].
  bool _attachmentExists(
      _JiraSyncConfig config, String ticketKey, String name) {
    final decoded = _getJson(
      config,
      '${config.baseUrl}/issue/$ticketKey?fields=attachment,summary',
    );
    if (decoded == null) return false;
    final fields = decoded['fields'] as Map<String, dynamic>? ?? {};
    final attachments = fields['attachment'] as List? ?? [];
    return attachments.any(
      (a) => (a as Map)['name']?.toString().toLowerCase() == name.toLowerCase(),
    );
  }

  /// Uploads a file via `curl -F`, returning the final tool result.
  String _uploadAttachment(
    _JiraSyncConfig config,
    String ticketKey,
    String name,
    String contentType,
    String filePath,
  ) {
    final resp = _curlMultipart(
      '${config.baseUrl}/issue/$ticketKey/attachments',
      headers: _multipartHeaders(config.headers),
      form: 'file=@$filePath;filename=$name;type=$contentType',
    );
    if (resp.statusCode == 0) return _err('HTTP request failed: ${resp.body}');
    if (!resp.isOk) {
      return _err('Attach failed (${resp.statusCode}): ${resp.body}');
    }
    return _attachSuccess(ticketKey, name);
  }

  /// Runs a multipart POST through curl, staging headers in a 0700 temp dir
  /// (auth stays out of `ps`; `Content-Type` is left to curl so the
  /// multipart boundary is generated).
  SyncHttpResponse _curlMultipart(
    String url, {
    required Map<String, String> headers,
    required String form,
  }) {
    final dir = Directory.systemTemp.createTempSync('dmtools_attach_');
    try {
      final headerFile = File('${dir.path}/headers')
        ..writeAsStringSync(SyncHttpClient.renderHeaderFile(headers),
            flush: true);
      final result = Process.runSync(
          'curl',
          [
            '-s',
            '-w',
            '\n%{http_code}',
            '--connect-timeout',
            '${SyncHttpClient.connectTimeoutSeconds}',
            '--max-time',
            '${SyncHttpClient.maxTimeSeconds}',
            '-H',
            '@${headerFile.path}',
            '-F',
            form,
            url,
          ],
          stdoutEncoding: utf8);
      return SyncHttpClient.parseResponse(result);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// Drops `Content-Type` from [headers] for multipart requests.
  Map<String, String> _multipartHeaders(Map<String, String> headers) => {
        for (final e in headers.entries)
          if (e.key.toLowerCase() != 'content-type') e.key: e.value,
      };

  /// Coerces a `fieldsJson` argument (object or JSON string) to a map.
  Map<String, dynamic> _fieldsJsonArg(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is String) {
      final decoded = _tryDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return {};
  }

  /// Fetches the `issueLinkType` listing; empty list on failure.
  List<Map<String, dynamic>> _fetchLinkTypes(_JiraSyncConfig config) {
    final decoded = _getJson(config, '${config.baseUrl}/issueLinkType');
    if (decoded == null) return [];
    return (decoded['issueLinkTypes'] as List? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// Fetches the current labels list for [key]; `null` when the fetch fails
  /// (non-2xx, malformed JSON, curl error). Callers must abort rather than
  /// PUT an empty set — the failure path is what protects existing labels.
  List<String>? _fetchLabels(_JiraSyncConfig config, String key) {
    final decoded =
        _getJson(config, '${config.baseUrl}/issue/$key?fields=labels');
    if (decoded == null) return null;
    final fields = decoded['fields'] as Map<String, dynamic>? ?? {};
    return List<String>.from(fields['labels'] as List? ?? []);
  }

  /// PUTs the full labels set via `update.labels[].set`.
  String _putLabels(_JiraSyncConfig config, String key, List<String> labels) {
    final body = jsonEncode({
      'update': {
        'labels': [
          {'set': labels},
        ],
      },
    });
    return _putBody(config, '${config.baseUrl}/issue/$key', body);
  }

  /// Resolves the Jira connection config, or `null` when incomplete.
  _JiraSyncConfig? _config() {
    final reader = PropertyReader();
    final basePath = reader.getJiraBasePath();
    if (basePath == null || basePath.isEmpty) return null;
    final token = reader.getJiraLoginPassToken();
    if (token == null || token.isEmpty) return null;
    final authType = reader.getJiraAuthType() ?? 'Basic';
    return (
      basePath: basePath,
      baseUrl: '$basePath/rest/api/latest',
      headers: {
        'Authorization': '$authType $token',
        'X-Atlassian-Token': 'nocheck',
        'Content-Type': _jsonContentType,
      },
    );
  }

  /// Runs [fn] with resolved config, or reports the missing config.
  String _run(String Function(_JiraSyncConfig config) fn) {
    final config = _config();
    if (config == null) return _err('Jira not configured');
    return fn(config);
  }

  /// PUTs `issue/{key}` with a `fields` update payload.
  String _putIssueFields(
          Map<String, dynamic> args, Map<String, dynamic> fields) =>
      _run((config) => _putBody(
            config,
            '${config.baseUrl}/issue/${_asStr(args['key'])}',
            jsonEncode({'fields': fields}),
          ));

  /// POSTs a create payload (`{fields: …}`) to `issue`.
  String _postIssueCreate(Map<String, dynamic> fields) =>
      _run((config) => _postBody(
            config,
            '${config.baseUrl}/issue',
            jsonEncode({'fields': fields}),
          ));

  /// The shared create fields (project/issuetype/summary, plus description
  /// when given) — the Java `createTicketBasic` payload base.
  Map<String, dynamic> _basicCreateFields(Map<String, dynamic> args) {
    final fields = <String, dynamic>{
      'project': {'key': _asStr(args['project'])},
      'issuetype': {'name': _asStr(args['issueType'])},
      'summary': _asStr(args['summary']),
    };
    final description = _asStr(args['description']);
    if (description.isNotEmpty) fields['description'] = description;
    return fields;
  }
}
