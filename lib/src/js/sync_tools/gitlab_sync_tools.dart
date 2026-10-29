/// Synchronous GitLab tool executors for the JS agent bridge.
///
/// One executor per `gitlab_*` MCP tool that agent scripts call through
/// `executeToolViaJava` (js/common/scm.js gitlab provider and the release
/// artefacts scripts). Each executor resolves GitLab connection config from
/// [PropertyReader] (`GITLAB_BASE_PATH` + `GITLAB_TOKEN`), performs blocking
/// HTTP calls via [SyncHttpClient] (curl subprocess), and returns a JSON (or
/// raw text) result string — safe to call inside QuickJS `NativeCallable`
/// callbacks where the Dart event loop is frozen.
///
/// Tool names, argument names, and URL shapes port the Java `GitLab` client
/// (`com.github.istin.dmtools.gitlab.GitLab`, dmtools-core): callers pass
/// `workspace` + `repository` + `pullRequestId`. The legacy `project`/`iid`
/// argument names of the pre-port dispatcher section stay accepted on
/// `gitlab_get_mr`/`gitlab_list_mrs`/`gitlab_create_mr_note` so the wiring
/// swap loses nothing. Auth mirrors the async `GitlabHttpClient`
/// (`PRIVATE-TOKEN` header; the Java client sends the same token as
/// `Authorization: Bearer`, which GitLab accepts interchangeably for PATs).
///
/// The dispatcher merges [GitLabSyncTools.handlers] into its `gitlab_*`
/// routing; the old inline `_GitLabSyncTools` section in
/// `sync_tool_dispatcher.dart` is deleted at wiring time.
library;

import 'dart:convert';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import 'gitlab_release_assets.dart';
import '../sync_http_client.dart';
import 'sync_request_helpers.dart';
import 'sync_required_params.dart';

/// Connection config for the sync GitLab client.
typedef _GitlabConfig = ({String baseUrl, Map<String, String> headers});

/// Internal executor: receives resolved [config] plus the raw tool args.
typedef _GitlabExecutor = String Function(
  _GitlabConfig config,
  Map<String, dynamic> args,
);

/// Synchronous `gitlab_*` tool executors for agent scripts.
///
/// Constructed const; [handlers] resolves config from [PropertyReader] on
/// every call so config overrides apply immediately.
class GitLabSyncTools {
  /// Creates the GitLab sync tool set.
  const GitLabSyncTools();

  /// GitLab tool executors keyed by MCP tool name.
  Map<String, String Function(Map<String, dynamic> args)> get handlers =>
      syncGuardRequired(
        _gitlabHandlers,
        kGitlabRequiredParams,
        kGitlabParamAliases,
        kGitlabAcceptedNames,
      );
}

/// Wraps [fns] so each public handler resolves config (or reports that
/// GitLab is unconfigured) before the executor runs.
Map<String, String Function(Map<String, dynamic>)> _wrapHandlers(
  Map<String, _GitlabExecutor> fns,
) =>
    {
      for (final entry in fns.entries)
        entry.key: (args) {
          final config = _gitlabConfig();
          if (config == null) return syncErr('GitLab not configured');
          return entry.value(config, args);
        },
    };

/// All GitLab sync executors (Java `GitLab` MCP tool surface).
final Map<String, String Function(Map<String, dynamic> args)> _gitlabHandlers =
    _wrapHandlers({
  'gitlab_get_mr': _getMr,
  'gitlab_list_mrs': _listMrs,
  'gitlab_get_mr_pipelines': _getMrPipelines,
  'gitlab_list_issues': _listIssues,
  'gitlab_create_mr_note': _addMrComment,
  'gitlab_add_mr_comment': _addMrComment,
  'gitlab_get_mr_comments': _getMrComments,
  'gitlab_get_mr_diff_text': _getMrDiffText,
  'gitlab_get_mr_diff': _getMrDiff,
  'gitlab_reply_to_mr_thread': _replyToMrThread,
  'gitlab_resolve_mr_thread': _resolveMrThread,
  'gitlab_add_inline_mr_comment': _addInlineMrComment,
  'gitlab_merge_mr': _mergeMr,
  'gitlab_rebase_mr': _rebaseMr,
  'gitlab_approve_mr': _approveMr,
  'gitlab_unapprove_mr': _unapproveMr,
  'gitlab_add_mr_label': _addMrLabel,
  'gitlab_remove_mr_label': _removeMrLabel,
  'gitlab_get_mr_discussions': _getMrDiscussions,
  'gitlab_get_commit_statuses': _getCommitStatuses,
  'gitlab_get_job_logs': _getJobLogs,
  'gitlab_list_pipeline_runs': _listPipelineRuns,
  'gitlab_list_project_jobs': _listProjectJobs,
  'gitlab_get_pipelines': _getPipelines,
  'gitlab_get_pipeline': _getPipeline,
  'gitlab_trigger_pipeline': _triggerPipeline,
  'gitlab_create_mr': _createMr,
  'gitlab_get_or_create_release': _getOrCreateRelease,
  'gitlab_upload_release_asset': _uploadReleaseAsset,
  'gitlab_download_release_asset': _downloadReleaseAsset,
});

/// Builds GitLab config, or `null` when base path / token is missing.
_GitlabConfig? _gitlabConfig() {
  final reader = PropertyReader();
  final basePath = reader.getGitLabBasePath();
  if (basePath == null || basePath.isEmpty) return null;
  final token = reader.getGitLabToken();
  if (token == null || token.isEmpty) return null;
  return (
    baseUrl: '$basePath/api/v4',
    headers: {
      'PRIVATE-TOKEN': token,
      'Content-Type': 'application/json',
    },
  );
}

// ── Merge requests ────────────────────────────────────────────────────────

/// `gitlab_get_mr` — GET `projects/{id}/merge_requests/{iid}`.
///
/// Accepts Java args (`workspace`/`repository`/`pullRequestId`) or the
/// legacy `project`/`iid` pair.
String _getMr(_GitlabConfig config, Map<String, dynamic> args) {
  final url = _mrPath(config, args);
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// The project-scoped API root for [args]: `{base}/projects/{project}`.
String _projectsPath(_GitlabConfig config, Map<String, dynamic> args) =>
    '${config.baseUrl}/projects/${gitlabEncodedProjectArg(args)}';

/// The merge-request path for [args]:
/// `{base}/projects/{project}/merge_requests/{iid}`.
String _mrPath(_GitlabConfig config, Map<String, dynamic> args) =>
    '${_projectsPath(config, args)}/merge_requests/${_prIdArg(args)}';

/// `gitlab_list_mrs` — GET `projects/{id}/merge_requests?state=…`.
///
/// Ports the Java `listMergeRequests`: `open` → `opened`; `closed` → `all`
/// plus a client-side filter keeping only closed/merged MRs. Single page of
/// 100, oldest first (`order_by=created_at&sort=asc` — the Java
/// `checkAllRequests=false` path).
String _listMrs(_GitlabConfig config, Map<String, dynamic> args) {
  final filter = _mrListStateFilter(syncAsStr(args['state']));
  final url = '${_projectsPath(config, args)}/merge_requests'
      '?state=${filter.state}&per_page=100&order_by=created_at&sort=asc';
  final body =
      syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
  if (!filter.closedAndMergedOnly) return body;
  return _closedAndMergedMrsOnly(body);
}

/// `gitlab_get_mr_pipelines` — GET
/// `projects/{id}/merge_requests/{iid}/pipelines` (Java #574, Dart MCP
/// `getMrPipelines`): the CI pipelines for the MR head SHA.
String _getMrPipelines(_GitlabConfig config, Map<String, dynamic> args) {
  final url = '${_mrPath(config, args)}/pipelines';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `gitlab_list_issues` — GET `projects/{id}/issues?state=…&per_page=…`
/// (Java #574, Dart MCP `listIssues`): one page, defaulting to
/// `state=opened`, `per_page=20` like the MCP client.
String _listIssues(_GitlabConfig config, Map<String, dynamic> args) {
  var state = syncAsStr(args['state']);
  if (state.isEmpty || state.toLowerCase() == 'open') state = 'opened';
  final perPage = _parsePositiveInt(syncAsStr(args['perPage']), 20);
  final url = '${_projectsPath(config, args)}/issues'
      '?state=${Uri.encodeQueryComponent(state)}&per_page=$perPage';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// Normalizes the `state` argument: empty/`open` → `opened`; `closed` →
/// `all` with a client-side closed-and-merged filter (Java
/// `listMergeRequests`).
({String state, bool closedAndMergedOnly}) _mrListStateFilter(String raw) {
  if (raw.isEmpty || raw.toLowerCase() == 'open') {
    return (state: 'opened', closedAndMergedOnly: false);
  }
  if (raw.toLowerCase() == 'closed') {
    return (state: 'all', closedAndMergedOnly: true);
  }
  return (state: raw, closedAndMergedOnly: false);
}

/// Filters a `state=all` MR list down to closed/merged MRs; a non-list
/// body passes through verbatim.
String _closedAndMergedMrsOnly(String body) {
  final decoded = syncTryDecode(body);
  if (decoded is! List) return body;
  return jsonEncode([
    for (final mr in decoded)
      if (mr is Map &&
          const ['closed', 'merged']
              .contains((mr['state'] ?? '').toString().toLowerCase()))
        mr,
  ]);
}

/// `gitlab_add_mr_comment` (and legacy `gitlab_create_mr_note`) — POST
/// `projects/{id}/merge_requests/{iid}/notes` with `{body: text}`.
String _addMrComment(_GitlabConfig config, Map<String, dynamic> args) {
  final text = syncAsStr(args['text']);
  final body = syncAsStr(args['body']);
  return syncPostJson(config.headers, '${_mrPath(config, args)}/notes',
      jsonEncode({'body': text.isEmpty ? body : text}));
}

/// `gitlab_get_mr_comments` — GET `…/notes`, non-system notes only.
///
/// Ports the Java `pullRequestComments`: pages of 100 until a short page;
/// notes flagged `system` are dropped.
String _getMrComments(_GitlabConfig config, Map<String, dynamic> args) {
  final notes = gitlabFetchAllPages(
    config.baseUrl,
    config.headers,
    'projects/${gitlabEncodedProjectArg(args)}'
    '/merge_requests/${_prIdArg(args)}/notes',
  );
  return jsonEncode([
    for (final note in notes)
      if (note is Map && note['system'] != true) note,
  ]);
}

/// `gitlab_get_mr_diff_text` — GET `…/changes`, rebuilt as unified diff.
String _getMrDiffText(_GitlabConfig config, Map<String, dynamic> args) {
  final changes = _mrChanges(config, args);
  return changes.decoded == null
      ? changes.body
      : buildGitlabUnifiedDiffText(changes.decoded!);
}

/// `gitlab_get_mr_diff` — GET `…/changes`, summarized as diff stats.
String _getMrDiff(_GitlabConfig config, Map<String, dynamic> args) {
  final changes = _mrChanges(config, args);
  return changes.decoded == null
      ? changes.body
      : jsonEncode(parseGitlabDiffStats(changes.decoded!));
}

/// Fetches the MR `changes` payload: the decoded object when the response
/// is JSON, else the raw body ([decoded] stays `null`).
({String body, Map<String, dynamic>? decoded}) _mrChanges(
  _GitlabConfig config,
  Map<String, dynamic> args,
) {
  final body = syncBodyOrError(SyncHttpClient.get(
      '${_mrPath(config, args)}/changes',
      headers: config.headers));
  final decoded = syncTryDecode(body);
  return (
    body: body,
    decoded: decoded is Map ? Map<String, dynamic>.from(decoded) : null,
  );
}

/// `gitlab_reply_to_mr_thread` — POST
/// `…/discussions/{id}/notes` with `{body: text}`.
String _replyToMrThread(_GitlabConfig config, Map<String, dynamic> args) {
  final url = '${_mrPath(config, args)}'
      '/discussions/${_discussionIdArg(args)}/notes';
  return syncPostJson(
    config.headers,
    url,
    jsonEncode({'body': syncAsStr(args['text'])}),
  );
}

/// `gitlab_resolve_mr_thread` — PUT `…/discussions/{id}` `{resolved: true}`.
String _resolveMrThread(_GitlabConfig config, Map<String, dynamic> args) {
  final url = '${_mrPath(config, args)}/discussions/${_discussionIdArg(args)}';
  return _putBody(config, url, jsonEncode({'resolved': true}));
}

/// `gitlab_add_inline_mr_comment` — POST `…/discussions` with a position.
///
/// Ports the Java `addInlineReviewComment`: `line` must be numeric, and the
/// position carries the MR `diff_refs` SHAs plus the file path on both sides.
String _addInlineMrComment(_GitlabConfig config, Map<String, dynamic> args) {
  final line = int.tryParse(syncAsStr(args['line']));
  if (line == null) {
    return syncErr(
        "Invalid line: expected numeric, got: '${syncAsStr(args['line'])}'");
  }
  final filePath = syncAsStr(args['filePath']);
  final body = jsonEncode({
    'body': syncAsStr(args['text']),
    'position': {
      'position_type': 'text',
      'base_sha': syncAsStr(args['baseSha']),
      'head_sha': syncAsStr(args['headSha']),
      'start_sha': syncAsStr(args['startSha']),
      'new_path': filePath,
      'old_path': filePath,
      'new_line': line,
    },
  });
  final url = '${_mrPath(config, args)}/discussions';
  return syncPostJson(config.headers, url, body);
}

/// `gitlab_merge_mr` — PUT `…/merge` with an optional commit message.
String _mergeMr(_GitlabConfig config, Map<String, dynamic> args) {
  final message = syncAsStr(args['mergeCommitMessage']);
  final body =
      message.isEmpty ? '{}' : jsonEncode({'merge_commit_message': message});
  return _putBody(config, '${_mrPath(config, args)}/merge', body);
}

/// `gitlab_rebase_mr` — PUT `…/rebase` with an empty body.
String _rebaseMr(_GitlabConfig config, Map<String, dynamic> args) =>
    _putBody(config, '${_mrPath(config, args)}/rebase', '{}');

/// `gitlab_approve_mr` — POST `…/approve` with an empty body (Java
/// `GitLab.approveMergeRequest`: `postRequest.setBody("{}")`).
String _approveMr(_GitlabConfig config, Map<String, dynamic> args) =>
    syncPostJson(config.headers, '${_mrPath(config, args)}/approve', '{}');

/// `gitlab_unapprove_mr` — POST `…/unapprove` with an empty body
/// (Dart-extra tool beyond Java; mirrors the async `GitlabHttpClient`).
String _unapproveMr(_GitlabConfig config, Map<String, dynamic> args) =>
    syncPostJson(config.headers, '${_mrPath(config, args)}/unapprove', '{}');

/// `gitlab_add_mr_label` — PUT `…/merge_requests/{iid}` `add_labels`.
String _addMrLabel(_GitlabConfig config, Map<String, dynamic> args) =>
    _updateMrLabels(config, args, 'add_labels');

/// `gitlab_remove_mr_label` — PUT `…/merge_requests/{iid}` `remove_labels`.
String _removeMrLabel(_GitlabConfig config, Map<String, dynamic> args) =>
    _updateMrLabels(config, args, 'remove_labels');

/// PUTs a single-key label update on a merge request (Java
/// `updateMergeRequestLabels`).
String _updateMrLabels(
  _GitlabConfig config,
  Map<String, dynamic> args,
  String field,
) {
  return _putBody(config, _mrPath(config, args),
      jsonEncode({field: syncAsStr(args['label'])}));
}

/// `gitlab_get_mr_discussions` — GET `…/discussions` (all pages).
String _getMrDiscussions(_GitlabConfig config, Map<String, dynamic> args) {
  final discussions = gitlabFetchAllPages(
    config.baseUrl,
    config.headers,
    'projects/${gitlabEncodedProjectArg(args)}'
    '/merge_requests/${_prIdArg(args)}/discussions',
  );
  return jsonEncode(discussions);
}

/// `gitlab_create_mr` — POST `projects/{id}/merge_requests`.
///
/// Ports the Java `createMergeRequest` payload; `description` and
/// `remove_source_branch` are included only when provided.
String _createMr(_GitlabConfig config, Map<String, dynamic> args) {
  final body = <String, dynamic>{
    'source_branch': syncAsStr(args['sourceBranch']),
    'target_branch': syncAsStr(args['targetBranch']),
    'title': syncAsStr(args['title']),
  };
  final description = syncAsStr(args['description']);
  if (description.isNotEmpty) body['description'] = description;
  final removeSourceBranch = syncAsStr(args['removeSourceBranch']);
  if (removeSourceBranch.isNotEmpty) {
    body['remove_source_branch'] = removeSourceBranch.toLowerCase() == 'true';
  }
  return syncPostJson(config.headers,
      '${_projectsPath(config, args)}/merge_requests', jsonEncode(body));
}

// ── CI (jobs, pipelines, commit statuses) ─────────────────────────────────

/// `gitlab_get_commit_statuses` — GET
/// `projects/{id}/repository/commits/{sha}/statuses`, deduped to the latest
/// report per status name (ports the Java `getCommitStatuses`).
String _getCommitStatuses(_GitlabConfig config, Map<String, dynamic> args) {
  final statuses = gitlabFetchAllPages(
    config.baseUrl,
    config.headers,
    'projects/${gitlabEncodedProjectArg(args)}'
    '/repository/commits/${syncAsStr(args['commitSha'])}/statuses',
  );
  return jsonEncode(latestGitlabStatusPerName(statuses));
}

/// `gitlab_get_job_logs` — GET `projects/{id}/jobs/{jobId}/trace` (raw text).
String _getJobLogs(_GitlabConfig config, Map<String, dynamic> args) {
  final url = '${_projectsPath(config, args)}'
      '/jobs/${syncAsInt(args['jobId'])}/trace';
  final body =
      syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
  // The trace endpoint answers plain text; the FFI bridge marshals through
  // JSON, so encode unconditionally (Java parity: JS gets the raw string;
  // agents-side callers try-parse and fall back).
  return jsonEncode(body);
}

/// `gitlab_list_pipeline_runs` — GET `projects/{id}/pipelines`.
///
/// Ports the Java `listPipelineRuns`: `limit` defaults to 50 (clamped
/// positive), `status` is normalized (`failure`→`failed`,
/// `in_progress`→`running`), pages of `min(limit, 100)` follow until the
/// limit is reached or a short page arrives.
String _listPipelineRuns(_GitlabConfig config, Map<String, dynamic> args) {
  final maxResults = _parsePositiveInt(syncAsStr(args['limit']), 50);
  final perPage = maxResults < 100 ? maxResults : 100;
  var path = 'projects/${gitlabEncodedProjectArg(args)}/pipelines?';
  final status = normalizeGitlabPipelineStatus(syncAsStr(args['status']));
  final ref = syncAsStr(args['ref']);
  final filters = [
    if (status.isNotEmpty) 'status=$status',
    if (ref.isNotEmpty) 'ref=${Uri.encodeQueryComponent(ref)}',
  ];
  path += filters.join('&');
  final runs = gitlabFetchAllPages(
    config.baseUrl,
    config.headers,
    path,
    perPage: perPage,
    maxResults: maxResults,
  );
  return jsonEncode(runs);
}

/// `gitlab_list_project_jobs` — GET `projects/{id}/jobs` (gh-380), or
/// GET `projects/{id}/pipelines/{pipelineId}/jobs` when `pipelineId` is
/// given — the pipeline-scoped shape a dispatch-pipeline consumer wants.
///
/// GitLab has no server-side name filter, so `name` narrows the result
/// client-side to exact matches — an empty list is a valid answer, never
/// an error. `scope` (one value, comma list, or array) maps to repeated
/// `scope[]` query params (pre-encoded as `scope%5B%5D` — the curl
/// fallback transport sends the URL verbatim while the isolate bridge
/// percent-encodes via Uri.parse, so the tool must emit the encoded
/// form to keep the wire bytes identical on both transports);
/// `per_page` defaults to 20 (the API default)
/// and is clamped to the 100 maximum; `page` defaults to 1. Returns the
/// bare jobs array (unwrapList-style, like `gitlab_list_pipeline_runs`).
String _listProjectJobs(_GitlabConfig config, Map<String, dynamic> args) {
  final project = gitlabEncodedProjectArg(args);
  final pipelineId = syncAsStr(args['pipelineId']);
  final path = pipelineId.isEmpty
      ? 'projects/$project/jobs'
      : 'projects/$project/pipelines/$pipelineId/jobs';
  final query = <String>[
    'per_page=${_clampPerPage(_perPageArg(args))}',
    'page=${_parsePositiveInt(syncAsStr(args['page']), 1)}',
    for (final scope in _scopeList(args['scope']))
      'scope%5B%5D=${Uri.encodeQueryComponent(scope)}',
  ];
  final body = syncBodyOrError(SyncHttpClient.get(
    '${config.baseUrl}/$path?${query.join('&')}',
    headers: config.headers,
  ));
  final name = syncAsStr(args['name']);
  if (name.isEmpty) return body;
  final decoded = syncTryDecode(body);
  if (decoded is! List) return body;
  return jsonEncode([
    for (final job in decoded)
      if (job is Map && job['name'] == name) job,
  ]);
}

/// Reads the page-size argument: snake `per_page` (the gh-380 tool
/// signature) with the camelCase `perPage` repo spelling as fallback.
String _perPageArg(Map<String, dynamic> args) {
  final raw = syncAsStr(args['per_page']);
  return raw.isEmpty ? syncAsStr(args['perPage']) : raw;
}

/// Clamps the `per_page` argument to GitLab's page-size window:
/// the API default 20 when unset/invalid, 100 maximum (gh-380 AC3).
int _clampPerPage(String raw) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed <= 0) return 20;
  return parsed > 100 ? 100 : parsed;
}

/// Normalizes the `scope` argument into individual status filters — a
/// List, a comma-separated string, and a single value each contribute
/// one `scope[]` query param (gh-380 AC4).
List<String> _scopeList(dynamic scope) {
  final raw = scope is List ? scope : syncAsStr(scope).split(',');
  return [
    for (final entry in raw)
      if (syncAsStr(entry).trim().isNotEmpty) syncAsStr(entry).trim(),
  ];
}

/// `gitlab_get_pipelines` — GET `projects/{id}/pipelines` (gh-380 AC5:
/// the registry tool gains a sync executor, closing the phantom JS
/// wrapper that died with 'Unsupported GitLab tool').
String _getPipelines(_GitlabConfig config, Map<String, dynamic> args) =>
    syncBodyOrError(SyncHttpClient.get(
      '${_projectsPath(config, args)}/pipelines',
      headers: config.headers,
    ));

/// `gitlab_get_pipeline` — GET `projects/{id}/pipelines/{id}` (gh-380
/// AC5, the same coherence closure as [_getPipelines]). Accepts the
/// registry `pipeline_id` spelling alongside the sync-surface
/// `pipelineId`.
String _getPipeline(_GitlabConfig config, Map<String, dynamic> args) {
  final pipelineId = syncAsStr(args['pipelineId']);
  final id = pipelineId.isEmpty ? syncAsStr(args['pipeline_id']) : pipelineId;
  return syncBodyOrError(SyncHttpClient.get(
    '${_projectsPath(config, args)}/pipelines/$id',
    headers: config.headers,
  ));
}

/// `gitlab_trigger_pipeline` — POST `projects/{id}/pipeline`.
String _triggerPipeline(_GitlabConfig config, Map<String, dynamic> args) {
  final body = _pipelineBody(args);
  if (body == null) return syncErr('Invalid variablesJson');
  return syncPostJson(config.headers, '${_projectsPath(config, args)}/pipeline',
      jsonEncode(body));
}

/// Builds the pipeline trigger body (Java `triggerPipeline`): `ref` plus an
/// optional `variables` array; `null` when `variablesJson` does not parse.
Map<String, dynamic>? _pipelineBody(Map<String, dynamic> args) {
  final body = <String, dynamic>{'ref': syncAsStr(args['ref'])};
  final variablesJson = syncAsStr(args['variablesJson']);
  if (variablesJson.isNotEmpty) {
    final vars = syncTryDecode(variablesJson);
    if (vars is! Map) return null;
    body['variables'] = [
      for (final entry in vars.entries)
        {'key': entry.key, 'value': '${entry.value}'},
    ];
  }
  return body;
}

// ── Releases (Generic Package Registry + release asset links) ─────────────
// Implemented in `gitlab_release_assets.dart`; these adapters bridge the
// executor signature to the release library entries.

/// `gitlab_get_or_create_release` — find by tag, else create.
String _getOrCreateRelease(_GitlabConfig config, Map<String, dynamic> args) =>
    gitlabGetOrCreateRelease(
      baseUrl: config.baseUrl,
      headers: config.headers,
      args: args,
    );

/// `gitlab_upload_release_asset` — PUT to the package registry, then link.
String _uploadReleaseAsset(_GitlabConfig config, Map<String, dynamic> args) =>
    gitlabUploadReleaseAsset(
      baseUrl: config.baseUrl,
      headers: config.headers,
      args: args,
    );

/// `gitlab_download_release_asset` — fetch a package registry file.
String _downloadReleaseAsset(_GitlabConfig config, Map<String, dynamic> args) =>
    gitlabDownloadReleaseAsset(
      baseUrl: config.baseUrl,
      headers: config.headers,
      args: args,
    );

// ── Shared helpers ────────────────────────────────────────────────────────

/// Rebuilds a unified diff from a GitLab `changes` response.
///
/// The GitLab API returns each file's diff as a bare hunk body without the
/// `diff --git` / `---` / `+++` header lines; callers that parse unified
/// diff text need them, so they are reconstructed from the per-change
/// metadata (ports the Java `buildUnifiedDiffText`).
String buildGitlabUnifiedDiffText(Map<String, dynamic> response) {
  final changes = response['changes'];
  if (changes is! List) return '';
  final buffer = StringBuffer();
  for (final change in changes) {
    if (change is! Map) continue;
    final newPath = syncAsStr(change['new_path']);
    final oldPath = syncAsStr(change['old_path']);
    final oldOrDefault = oldPath.isEmpty ? newPath : oldPath;
    final newOrDefault = newPath.isEmpty ? oldPath : newPath;
    final diff = syncAsStr(change['diff']);
    buffer
      ..write('diff --git a/$oldOrDefault b/$newOrDefault\n')
      ..write(_diffHeaderLines(change, oldOrDefault, newOrDefault))
      ..write(diff);
    if (!diff.endsWith('\n')) buffer.write('\n');
  }
  return buffer.toString();
}

/// Renders the `new file mode` / `---` / `+++` header lines for one change.
String _diffHeaderLines(Map change, String oldPath, String newPath) {
  if (change['new_file'] == true) {
    return 'new file mode 100644\n--- /dev/null\n+++ b/$newPath\n';
  }
  if (change['deleted_file'] == true) {
    return 'deleted file mode 100644\n--- a/$oldPath\n+++ /dev/null\n';
  }
  return '--- a/$oldPath\n+++ b/$newPath\n';
}

/// Summarizes a GitLab `changes` response as diff stats
/// (`{stats: {total, additions, deletions}, changes: [{filePath}]}`).
Map<String, dynamic> parseGitlabDiffStats(Map<String, dynamic> response) {
  var additions = 0;
  var deletions = 0;
  final files = <String>[];
  final changes = response['changes'];
  if (changes is List) {
    for (final change in changes) {
      if (change is! Map) continue;
      files.add(syncAsStr(change['new_path']));
      final (add, del) = _countDiffLines(syncAsStr(change['diff']));
      additions += add;
      deletions += del;
    }
  }
  return {
    'stats': {
      'total': additions + deletions,
      'additions': additions,
      'deletions': deletions,
    },
    'changes': [
      for (final file in files) {'filePath': file}
    ],
  };
}

/// Counts `+`/`-` body lines of one diff hunk, skipping the `+++`/`---`
/// file-header lines; returns `(additions, deletions)`.
(int, int) _countDiffLines(String diff) {
  var additions = 0;
  var deletions = 0;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+') && !line.startsWith('+++')) {
      additions++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      deletions++;
    }
  }
  return (additions, deletions);
}

/// Keeps only the most recent status report per status name.
///
/// GitLab's commit-statuses endpoint returns the full history per name; a
/// retried CI job yields duplicate names, so the entry with the latest
/// `created_at` (or the last seen) wins (ports the Java
/// `latestStatusPerName`).
List<Map<String, dynamic>> latestGitlabStatusPerName(List<dynamic> statuses) {
  final latestByName = <String, Map<String, dynamic>>{};
  final latestTimestamp = <String, int>{};
  for (final status in statuses) {
    if (status is! Map) continue;
    final key =
        status.containsKey('name') ? syncAsStr(status['name']) : 'unknown';
    final createdAt = _parseTimestamp(syncAsStr(status['created_at']));
    if (createdAt >= (latestTimestamp[key] ?? -1)) {
      latestByName[key] = Map<String, dynamic>.from(status);
      latestTimestamp[key] = createdAt;
    }
  }
  return [for (final status in latestByName.values) status];
}

/// Parses an ISO-8601 instant; `0` when missing or malformed.
int _parseTimestamp(String isoDate) {
  if (isoDate.isEmpty) return 0;
  return DateTime.tryParse(isoDate)?.millisecondsSinceEpoch ?? 0;
}

/// Resolves the MR iid: Java `pullRequestId` or legacy `iid`.
String _prIdArg(Map<String, dynamic> args) =>
    syncAsStr(args['pullRequestId']).isEmpty
        ? syncAsStr(args['iid'])
        : syncAsStr(args['pullRequestId']);

/// Resolves the discussion id: `discussionId` or its `threadId` alias.
String _discussionIdArg(Map<String, dynamic> args) =>
    syncAsStr(args['discussionId']).isEmpty
        ? syncAsStr(args['threadId'])
        : syncAsStr(args['discussionId']);

/// Normalizes a pipeline status filter (Java `normalizePipelineStatus`):
/// `failure` → `failed`, `in_progress` → `running`; anything else passes
/// through unchanged.
String normalizeGitlabPipelineStatus(String status) {
  final lower = status.toLowerCase();
  if (lower == 'failure') return 'failed';
  if (lower == 'in_progress') return 'running';
  return status;
}

/// Parses a positive int, falling back to [defaultValue] (Java
/// `parsePositiveInt`).
int _parsePositiveInt(String raw, int defaultValue) {
  final parsed = int.tryParse(raw.trim());
  return parsed != null && parsed > 0 ? parsed : defaultValue;
}

/// PUTs [body] to [url] and returns the result string.
String _putBody(_GitlabConfig config, String url, String body) =>
    syncBodyOrError(
        SyncHttpClient.put(url, headers: config.headers, body: body));
