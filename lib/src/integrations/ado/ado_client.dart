/// High-level Azure DevOps API client — ports the ADO subset of the Java MCP
/// tools.
///
/// Each method corresponds to a Java `@MCPTool`-annotated method (or a
/// net-new PR tool, for which there is no Java client yet). Transport is
/// delegated to [AdoHttpClient]; this layer only shapes requests and parses
/// JSON into typed results.
library;

import 'dart:convert';

import 'package:dio/dio.dart' show DioException;

import 'ado_http_client.dart';
import 'ado_json.dart';
import 'ado_work_item_client.dart';
import 'ado_work_item_ops.dart';

/// Matches a query that begins with the `SELECT` keyword (any case, leading
/// whitespace allowed). The trailing `\b` keeps fields such as `selection`
/// from matching.
final RegExp _selectStatement = RegExp(r'^\s*select\b', caseSensitive: false);

/// Expands a short WIQL fragment (e.g. `System.State = 'Active'`) into a full
/// statement, matching Java `AzureDevOpsClient.expandWiql`. Full `SELECT`
/// statements, and null/blank input, pass through unchanged.
String? expandWiql(String? wiql) {
  if (wiql == null || wiql.trim().isEmpty) return wiql;
  if (_selectStatement.hasMatch(wiql)) return wiql;
  return 'SELECT [System.Id] FROM WorkItems WHERE $wiql';
}

/// Azure DevOps API methods exposed to the MCP tool runtime.
class AdoClient {
  final AdoHttpClient _http;

  /// Creates a client backed by [_http].
  AdoClient(this._http);

  /// Tracker-agnostic ticket operations (state, assign, field, priority,
  /// link, create-with-parent, field code, attach file).
  late final AdoWorkItemOps workItemOps = AdoWorkItemOps(_http);

  /// `ado_test` — connectivity check via the Profile API
  /// (`app.vssps.visualstudio.com/_apis/profile/profiles/me`).
  ///
  /// Mirrors Java `testConnection`/`getMyProfile`: the org-host
  /// `connection-data` endpoint returns 404 for PATs scoped to work
  /// items, while the Profile API accepts them. A PAT without the
  /// profile-read scope gets 401 from the Profile API (Java fails the
  /// same way). The fallback probes `GET {project}/_apis/wit/workitemtypes`
  /// first (the scope the tools use), then `GET {org}/_apis/projects`. When
  /// both fail, the original profile error is reported. A healthy profile
  /// makes no extra request. Returns `success` plus the user's name/email
  /// when the profile was readable.
  Future<Map<String, dynamic>> testConnection() async {
    try {
      final body = await _http.getProfile('profile/profiles/me');
      final data = jsonDecode(body) as Map<String, dynamic>;
      return {
        'success': true,
        'message': 'Azure DevOps connection successful',
        'user': data['displayName'],
        'email': data['emailAddress'],
      };
    } on Object catch (e) {
      final profileStatus = e is DioException ? e.response?.statusCode : e;
      // 1st fallback: the work-item API for the configured project — the
      // scope the tools actually use. An empty list is not a success.
      if (await _probeWorkItemTypes()) {
        return {
          'success': true,
          'message': 'Azure DevOps connection successful '
              '(profile unreadable: $profileStatus)',
        };
      }
      // 2nd fallback: the organization-scoped projects list.
      try {
        jsonDecode(await _http.getOrg('projects'));
        return {
          'success': true,
          'message': 'Azure DevOps connection successful '
              '(profile unreadable: $profileStatus)',
        };
      } on Object {
        return {
          'success': false,
          'message': 'Azure DevOps connection failed',
          'error': e.toString(),
        };
      }
    }
  }

  /// Returns true when `wit/workitemtypes` for the configured project answers
  /// with a non-empty list. Any transport or decode error counts as false.
  Future<bool> _probeWorkItemTypes() async {
    try {
      final types = await getWorkItemTypes('');
      return types.isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// `ado_get_work_item` — GET `{org}/{project}/_apis/wit/workitems/{id}`.
  Future<Map<String, dynamic>> getWorkItem(int id) async {
    final body = await _http.get('wit/workitems/$id');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_create_work_item` — POST `{org}/{project}/_apis/wit/workitems/$type`.
  ///
  /// The body is a JSON Patch document (ADO's required wire format) that sets
  /// `System.Title`; the `Content-Type` is `application/json-patch+json`.
  Future<Map<String, dynamic>> createWorkItem(String type, String title) async {
    final body = await _http.postPatch(
      'wit/workitems/\$$type',
      body: jsonEncode([
        {'op': 'add', 'path': '/fields/System.Title', 'value': title},
      ]),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_list_prs` — GET `{org}/{project}/_apis/git/pullrequests`.
  ///
  /// [status] defaults to `active` (ADO's default) when omitted, passed as
  /// `searchCriteria.status`.
  Future<List<Map<String, dynamic>>> listPrs([String? status]) async {
    final body = await _http.get(
      'git/pullrequests',
      queryParams: {'searchCriteria.status': status ?? 'active'},
    );
    return _decodeList(body);
  }

  /// `ado_get_pr` — GET `{org}/{project}/_apis/git/pullrequests/{id}`.
  Future<Map<String, dynamic>> getPr(int id) async {
    final body = await _http.get('git/pullrequests/$id');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_update_work_item` — PATCH `wit/workitems/{id}` with one JSON-Patch
  /// `add` op per entry in [fields]. The request uses ADO's
  /// `application/json-patch+json` content type.
  Future<Map<String, dynamic>> updateWorkItem(
    int id,
    Map<String, dynamic> fields,
  ) async {
    final body = await _http.patchPatch(
      'wit/workitems/$id',
      body: jsonEncode([
        for (final entry in fields.entries)
          {'op': 'add', 'path': '/fields/${entry.key}', 'value': entry.value},
      ]),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_work_items` — GET `wit/workitems?ids=1,2,...`.
  Future<List<Map<String, dynamic>>> getWorkItems(
    List<int> ids, {
    List<String>? fields,
  }) async {
    final body = await _http.get(
      'wit/workitems',
      queryParams: {
        'ids': ids.join(','),
        if (fields != null && fields.isNotEmpty)
          'fields': fields.join(',')
        else
          r'$expand': 'relations',
      },
    );
    return _decodeList(body);
  }

  /// `ado_list_work_items` (Java `ado_search_by_wiql`, alias
  /// `tracker_search`) — POST `wit/wiql`, then batch-fetch the full work
  /// items.
  ///
  /// Mirrors Java `searchAndPerform`: the WIQL response carries only
  /// id/url stubs, so the ids are re-fetched via [getWorkItems] in
  /// batches of 200 (the ADO limit).
  Future<List<Map<String, dynamic>>> listWorkItems(
    String wiql, {
    List<String>? fields,
  }) async {
    final body = await _http.post(
      'wit/wiql',
      body: jsonEncode({'query': expandWiql(wiql)}),
    );
    final decoded = jsonDecode(body);
    final ids = decoded is Map ? extractWorkItemIds(decoded) : const <int>[];
    final results = <Map<String, dynamic>>[];
    for (final batch in batchIds(ids)) {
      results.addAll(await getWorkItems(batch, fields: fields));
    }
    return results;
  }

  /// `ado_get_work_item_types` — GET `wit/workitemtypes`.
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<List<Map<String, dynamic>>> getWorkItemTypes(String project) async {
    final body = await _http.get('wit/workitemtypes');
    return _decodeList(body);
  }

  /// `ado_create_repo` — POST `git/repositories` with `{"name": name}`.
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<Map<String, dynamic>> createRepo(String project, String name) async {
    final body = await _http.post(
      'git/repositories',
      body: jsonEncode({'name': name}),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_repos` — GET `git/repositories`.
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<List<Map<String, dynamic>>> getRepos(String project) async {
    final body = await _http.get('git/repositories');
    return _decodeList(body);
  }

  /// `ado_get_builds` — GET `build/builds`, optionally filtered by
  /// [definitions] (a comma-joined `definitions` query parameter).
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<List<Map<String, dynamic>>> getBuilds(
    String project, [
    List<int>? definitions,
  ]) async {
    final queryParams =
        definitions == null ? null : {'definitions': definitions.join(',')};
    final body = await _http.get('build/builds', queryParams: queryParams);
    return _decodeList(body);
  }

  /// `ado_trigger_build` — POST `build/builds` queuing [definitionId].
  Future<Map<String, dynamic>> triggerBuild(int definitionId) async {
    final body = await _http.post(
      'build/builds',
      body: jsonEncode({
        'definition': {'id': definitionId},
      }),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_work_item_revisions` — GET `wit/workitems/{id}/revisions`.
  Future<List<Map<String, dynamic>>> getWorkItemRevisions(int id) async {
    final body = await _http.get('wit/workitems/$id/revisions');
    return _decodeList(body);
  }

  /// `ado_get_teams` — GET `projects/{project}/teams` (org-scoped).
  ///
  /// The path carries the project explicitly, so the request targets the
  /// organization-scoped URL rather than the configured project scope.
  Future<List<Map<String, dynamic>>> getTeams(String project) async {
    final body = await _http.getOrg('projects/$project/teams');
    return _decodeList(body);
  }

  /// `ado_get_team_members` — GET
  /// `projects/{project}/teams/{teamId}/members` (org-scoped).
  Future<List<Map<String, dynamic>>> getTeamMembers(
    String project,
    String teamId,
  ) async {
    final body = await _http.getOrg('projects/$project/teams/$teamId/members');
    return _decodeList(body);
  }

  /// `ado_get_project_properties` — GET `projects/{projectId}/properties`
  /// (org-scoped).
  Future<List<Map<String, dynamic>>> getProjectProperties(
    String projectId,
  ) async {
    final body = await _http.getOrg('projects/$projectId/properties');
    return _decodeList(body);
  }

  /// `ado_get_repo_branches` — GET `git/repositories/{repoId}/stats/branches`.
  Future<List<Map<String, dynamic>>> getRepoBranches(
    String project,
    String repoId,
  ) async {
    final body = await _http.get('git/repositories/$repoId/stats/branches');
    return _decodeList(body);
  }

  /// `ado_get_commits` — POST `git/repositories/{repoId}/commitsbatch` with
  /// [searchCriteria] as the JSON body when criteria are supplied, otherwise
  /// GET `git/repositories/{repoId}/commits`.
  Future<List<Map<String, dynamic>>> getCommits(
    String project,
    String repoId, [
    Map<String, dynamic>? searchCriteria,
  ]) async {
    if (searchCriteria == null) {
      return _decodeList(await _http.get('git/repositories/$repoId/commits'));
    }
    return _decodeList(
      await _http.post(
        'git/repositories/$repoId/commitsbatch',
        body: jsonEncode(searchCriteria),
      ),
    );
  }

  /// `ado_get_pull_request_reviewers` — GET
  /// `git/pullrequests/{prId}/reviewers`.
  Future<List<Map<String, dynamic>>> getPullRequestReviewers(
    String project,
    int prId,
  ) async {
    final body = await _http.get('git/pullrequests/$prId/reviewers');
    return _decodeList(body);
  }

  /// `ado_add_pull_request_reviewer` — PUT
  /// `git/pullrequests/{prId}/reviewers/{reviewerId}`.
  Future<Map<String, dynamic>> addPullRequestReviewer(
    String project,
    int prId,
    String reviewerId,
  ) async {
    final body = await _http.put(
      'git/pullrequests/$prId/reviewers/$reviewerId',
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_update_pull_request` — PATCH `git/pullrequests/{prId}` with the new
  /// [title] and [description] as a plain-JSON body.
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<Map<String, dynamic>> updatePullRequest(
    String project,
    int prId,
    String title,
    String description,
  ) async {
    final body = await _http.patch(
      'git/pullrequests/$prId',
      body: jsonEncode({'title': title, 'description': description}),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_pull_request_commits` — GET `git/pullrequests/{prId}/commits`.
  Future<List<Map<String, dynamic>>> getPullRequestCommits(
    String project,
    int prId,
  ) async {
    final body = await _http.get('git/pullrequests/$prId/commits');
    return _decodeList(body);
  }

  /// `ado_get_pull_request_statuses` — GET `git/pullrequests/{prId}/statuses`.
  Future<List<Map<String, dynamic>>> getPullRequestStatuses(
    String project,
    int prId,
  ) async {
    final body = await _http.get('git/pullrequests/$prId/statuses');
    return _decodeList(body);
  }

  /// `ado_create_pull_request_status` — POST `git/pullrequests/{prId}/statuses`
  /// with [state], [description], and [context] as the status context name.
  Future<Map<String, dynamic>> createPullRequestStatus(
    String project,
    int prId,
    String state,
    String description,
    String context,
  ) async {
    final body = await _http.post(
      'git/pullrequests/$prId/statuses',
      body: jsonEncode({
        'state': state,
        'description': description,
        'context': {'name': context},
      }),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_work_item_comments` — GET `wit/workitems/{id}/comments`.
  Future<List<Map<String, dynamic>>> getWorkItemComments(int id) async {
    final body = await _http.get('wit/workitems/$id/comments');
    return _decodeList(body);
  }

  /// `ado_add_work_item_comment` — POST `wit/workitems/{id}/comments` with
  /// `{"text": text}` (mirrors the Java `postComment` body).
  ///
  /// [format] `markdown` appends `format=markdown` (Java `postComment`);
  /// any other value keeps the previous HTML wire format.
  Future<Map<String, dynamic>> addWorkItemComment(
    int id,
    String text, {
    String? format,
  }) async {
    final body = await _http.post(
      'wit/workitems/$id/comments',
      body: jsonEncode({'text': text}),
      queryParams: isAdoMarkdownFormat(format) ? {'format': 'markdown'} : null,
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_project_details` — GET `projects/{projectId}` (org-scoped).
  ///
  /// Returns the full project object (name, description, state, …). Distinct
  /// from [getProjectProperties], which returns only the key/value property bag.
  Future<Map<String, dynamic>> getProjectDetails(String projectId) async {
    final body = await _http.getOrg('projects/$projectId');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_repo_details` — GET `git/repositories/{repoId}`.
  ///
  /// The [project] argument mirrors the Java tool surface; the request is
  /// scoped to the project configured on this client.
  Future<Map<String, dynamic>> getRepoDetails(
    String project,
    String repoId,
  ) async {
    final body = await _http.get('git/repositories/$repoId');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `ado_get_repo_file` — GET
  /// `git/repositories/{repoId}/items?path={path}&versionDescriptor.version={branch}`.
  ///
  /// Returns the raw file content at [path] on [branch]. ADO resolves a branch
  /// name only when `versionDescriptor.versionType` is `branch`, so that is sent
  /// alongside the version. The [project] argument mirrors the Java tool
  /// surface; the request is scoped to the project configured on this client.
  Future<String> getRepoFile(
    String project,
    String repoId,
    String path,
    String branch,
  ) =>
      _http.get(
        'git/repositories/$repoId/items',
        queryParams: {
          'path': path,
          'versionDescriptor.versionType': 'branch',
          'versionDescriptor.version': branch,
        },
      );

  /// `ado_create_work_item_link` — POST `wit/workitems/{sourceId}/links`.
  ///
  /// Adds a relation of [linkType] (e.g. `System.LinkTypes.Hierarchy-Forward`)
  /// from [sourceId] to [targetId], using ADO's JSON-Patch wire format on the
  /// work-item relations collection. The target relation URL is built from the
  /// project-scoped work-item endpoint.
  Future<Map<String, dynamic>> createWorkItemLink(
    int sourceId,
    int targetId,
    String linkType,
  ) async {
    final body = await _http.postPatch(
      'wit/workitems/$sourceId/links',
      body: jsonEncode([
        {
          'op': 'add',
          'path': '/relations/-',
          'value': {
            'rel': linkType,
            'url': _http.buildUrl('wit/workitems/$targetId'),
          },
        },
      ]),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Decodes a JSON list body into a list of typed maps.
  ///
  /// ADO list endpoints never return bare arrays: paged endpoints wrap
  /// the items as `{count, value: [...]}` and WIQL as
  /// `{queryType, columns, workItems: [...]}` — see [unwrapAdoItems].
  List<Map<String, dynamic>> _decodeList(String body) =>
      unwrapAdoItems(jsonDecode(body));
}
