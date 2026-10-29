/// Synchronous Azure DevOps tool executors for the JS agent bridge.
///
/// One executor per `ado_*` MCP tool that agent scripts call through
/// `executeToolViaJava` (js/common/scm.js ado provider). Each executor
/// resolves ADO connection config from [PropertyReader] (`ADO_ORGANIZATION`,
/// `ADO_PROJECT`, `ADO_PAT_TOKEN`), performs blocking HTTP calls via
/// [SyncHttpClient] (curl subprocess), and returns a JSON (or raw text)
/// result string — safe to call inside QuickJS `NativeCallable` callbacks
/// where the Dart event loop is frozen.
///
/// Tool names, argument names, and URL shapes port the Java
/// `AzureDevOpsClient` (`com.github.istin.dmtools.microsoft.ado.
/// AzureDevOpsClient`, dmtools-core): PR tools address
/// `{org}/{project}/_apis/git/repositories/{repository}/pullrequests…`,
/// pipeline tools `{org}/{project}/_apis/pipelines…`, and build logs
/// `{org}/{project}/_apis/build/builds…`, every request carrying
/// `api-version=7.0` (Java `API_VERSION`; PR labels use
/// `7.0-preview.1`). Auth mirrors the async `AdoHttpClient`:
/// `Basic base64(':' + PAT)`.
///
/// The dispatcher merges [AdoSyncTools.handlers] into its `ado_*` routing;
/// the old inline `_AdoSyncTools` section in `sync_tool_dispatcher.dart` is
/// deleted at wiring time.
library;

import 'dart:convert';
import 'dart:io';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../../integrations/ado/ado_json.dart';
import '../sync_http_client.dart';
import 'ado_sync_work_item_ops.dart';
import 'sync_request_helpers.dart';

/// Connection config for the sync ADO client.
typedef _AdoConfig = AdoSyncConfig;

/// Internal executor: receives resolved [config] plus the raw tool args.
typedef _AdoExecutor = AdoSyncExecutor;

/// Synchronous `ado_*` tool executors for agent scripts.
///
/// Constructed const; [handlers] resolves config from [PropertyReader] on
/// every call so config overrides apply immediately.
class AdoSyncTools {
  /// Creates the ADO sync tool set.
  const AdoSyncTools();

  /// ADO tool executors keyed by MCP tool name.
  Map<String, String Function(Map<String, dynamic> args)> get handlers =>
      _adoHandlers;
}

/// Wraps [fns] so each public handler resolves config (or reports that ADO
/// is unconfigured) before the executor runs.
Map<String, String Function(Map<String, dynamic>)> _wrapHandlers(
  Map<String, _AdoExecutor> fns,
) =>
    {
      for (final entry in fns.entries)
        entry.key: (args) {
          final config = _adoConfig();
          if (config == null) return syncErr('ADO not configured');
          return entry.value(config, args);
        },
    };

/// All ADO sync executors (Java `AzureDevOpsClient` MCP tool surface).
final Map<String, String Function(Map<String, dynamic> args)> _adoHandlers =
    _wrapHandlers({
  'ado_get_work_item': _getWorkItem,
  'ado_add_work_item_label': _addWorkItemLabel,
  'ado_remove_work_item_label': _removeWorkItemLabel,
  'ado_list_work_items': _listWorkItems,
  'ado_list_prs': _listPrs,
  'ado_get_pr': _getPr,
  'ado_get_pr_comments': _getPrComments,
  'ado_add_pr_comment': _addPrComment,
  'ado_reply_to_pr_thread': _replyToPrThread,
  'ado_resolve_pr_thread': _resolvePrThread,
  'ado_add_inline_comment': _addInlineComment,
  'ado_merge_pr': _mergePr,
  'ado_add_pr_label': _addPrLabel,
  'ado_remove_pr_label': _removePrLabel,
  'ado_get_pr_diff': _getPrDiff,
  'ado_list_pipelines': _listPipelines,
  'ado_list_pipeline_runs': _listPipelineRuns,
  'ado_trigger_pipeline': _triggerPipeline,
  'ado_get_pipeline_logs': _getPipelineLogs,
  ...adoWorkItemOpExecutors,
});

/// Builds ADO config, or `null` when organization / project / PAT is
/// missing. Base URL: `{ADO_BASE_PATH}/{org}/{project}/_apis`.
_AdoConfig? _adoConfig() {
  final reader = PropertyReader();
  final organization = reader.getAdoOrganization();
  if (organization == null || organization.isEmpty) return null;
  final project = reader.getAdoProject();
  if (project == null || project.isEmpty) return null;
  final pat = reader.getAdoPatToken();
  if (pat == null || pat.isEmpty) return null;
  final basic = base64Encode(utf8.encode(':$pat'));
  final basePath = reader.getAdoBasePath();
  return (
    baseUrl: '$basePath/$organization/$project/_apis',
    headers: {
      'Authorization': 'Basic $basic',
      'Content-Type': 'application/json',
    },
  );
}

/// ADO REST API version sent on every request (mirrors Java `API_VERSION`).
const _adoApiVersion = '7.0';

// ── Work items (moved from the dispatcher's inline section) ───────────────

/// `ado_get_work_item` — GET `wit/workitems/{id}?api-version=7.0`.
String _getWorkItem(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${config.baseUrl}/wit/workitems/${syncAsInt(args['id'])}'
      '?api-version=$_adoApiVersion';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `ado_add_work_item_label` — add a single label (tag) to a work item,
/// keeping existing tags (dm.ai #577; Java `addWorkItemLabel` →
/// `addLabelIfNotExists`).
String _addWorkItemLabel(_AdoConfig config, Map<String, dynamic> args) =>
    _updateWorkItemTags(config, args, add: true);

/// `ado_remove_work_item_label` — remove a single label (tag) from a work
/// item, keeping the other tags (dm.ai #577; Java `removeWorkItemLabel` →
/// `deleteLabelInTicket`).
String _removeWorkItemLabel(_AdoConfig config, Map<String, dynamic> args) =>
    _updateWorkItemTags(config, args, add: false);

/// Shared add/remove-single-tag implementation over the ADO `System.Tags`
/// field (a semicolon-delimited string): read the label set, add [label]
/// (a case-insensitive no-op when already present) or remove it, and PATCH
/// the joined set back — mirroring Java's `performTicket` + label helpers.
String _updateWorkItemTags(
  _AdoConfig config,
  Map<String, dynamic> args, {
  required bool add,
}) {
  final label = syncAsStr(args['label']).trim();
  if (label.isEmpty) return syncErr('label is required');
  final url = '${config.baseUrl}/wit/workitems/${syncAsInt(args['id'])}'
      '?api-version=$_adoApiVersion';
  final fetched = syncBodyOrError(
    SyncHttpClient.get(url, headers: config.headers),
  );
  final item = syncTryDecode(fetched);
  if (item is! Map) return fetched;
  final fields = item['fields'];
  final rawTags = fields is Map ? syncAsStr(fields['System.Tags']) : '';
  final tags = rawTags
      .split(';')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  final present = tags.any((t) => t.toLowerCase() == label.toLowerCase());
  if (add == present) {
    // Add-with-existing / remove-with-absent: nothing to change.
    return jsonEncode(<String, dynamic>{'success': true});
  }
  if (add) {
    tags.add(label);
  } else {
    tags.removeWhere((t) => t.toLowerCase() == label.toLowerCase());
  }
  final patch = jsonEncode([
    <String, String>{
      'op': 'add',
      'path': '/fields/System.Tags',
      'value': tags.join('; '),
    },
  ]);
  return syncBodyOrError(
    SyncHttpClient.patch(
      url,
      headers: {
        ...config.headers,
        'Content-Type': 'application/json-patch+json',
      },
      body: patch,
    ),
  );
}

/// `ado_list_work_items` — POST `wit/wiql`, then batch-fetch full items.
///
/// Mirrors the Java `searchAndPerform`: the WIQL response carries only
/// id/url stubs, so the ids are re-fetched via `wit/workitems` in batches
/// of 200 (`fields=...` when given, `$expand=relations` otherwise).
String _listWorkItems(_AdoConfig config, Map<String, dynamic> args) {
  final wiqlUrl = '${config.baseUrl}/wit/wiql?api-version=$_adoApiVersion';
  final wiqlBody = _postBody(
    config,
    wiqlUrl,
    jsonEncode({'query': syncAsStr(args['wiql'])}),
  );
  final wiql = syncTryDecode(wiqlBody);
  // No result list (workItems / workItemRelations) means an error envelope:
  // hand the raw body back so a failed WIQL is not read as an empty match.
  if (wiql is! Map) return wiqlBody;
  if (wiql['workItems'] is! List && wiql['workItemRelations'] is! List) {
    return wiqlBody;
  }
  final ids = extractWorkItemIds(wiql);
  final fields = (args['fields'] as List?)?.cast<String>();
  final items = <Map<String, dynamic>>[];
  for (final batch in batchIds(ids)) {
    final detail = _adoDetailBatch(config, batch, fields);
    if (detail == null) continue;
    items.addAll(detail);
  }
  return jsonEncode(items);
}

/// Fetches one `wit/workitems` id batch, or `null` on an error body.
List<Map<String, dynamic>>? _adoDetailBatch(
  _AdoConfig config,
  List<int> ids,
  List<String>? fields,
) {
  final extra = fields != null && fields.isNotEmpty
      ? 'fields=${Uri.encodeQueryComponent(fields.join(','))}'
      : r'$expand=relations';
  final url = '${config.baseUrl}/wit/workitems'
      '?ids=${ids.join(',')}&$extra&api-version=$_adoApiVersion';
  final body = syncBodyOrError(
    SyncHttpClient.get(url, headers: config.headers),
  );
  final decoded = syncTryDecode(body);
  if (decoded is Map && decoded['error'] != null) return null;
  return unwrapAdoItems(decoded);
}

// ── Pull requests ─────────────────────────────────────────────────────────

/// `ado_list_prs` — GET
/// `git/repositories/{repo}/pullrequests?searchCriteria.status=…`.
///
/// Ports the Java status synonyms: `open`/`opened` → `active`,
/// `closed`/`merged`/`declined` → `completed`.
String _listPrs(_AdoConfig config, Map<String, dynamic> args) {
  var status = syncAsStr(args['status']);
  final lower = status.toLowerCase();
  if (lower == 'open' || lower == 'opened') {
    status = 'active';
  } else if (lower == 'closed' || lower == 'merged' || lower == 'declined') {
    status = 'completed';
  }
  final url = '${_prPath(config, args)}'
      '?searchCriteria.status=$status&api-version=$_adoApiVersion';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `ado_get_pr` — GET `git/repositories/{repo}/pullrequests/{id}`.
String _getPr(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}?api-version=$_adoApiVersion';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `ado_get_pr_comments` — GET `…/pullrequests/{id}/threads`.
String _getPrComments(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}/threads?api-version=$_adoApiVersion';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `ado_add_pr_comment` — POST `…/threads` with a new active thread.
String _addPrComment(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}/threads?api-version=$_adoApiVersion';
  return _postBody(
    config,
    url,
    jsonEncode(
      _newThreadPayload(
        comments: [
          {
            'parentCommentId': 0,
            'content': syncAsStr(args['text']),
            'commentType': 1,
          },
        ],
      ),
    ),
  );
}

/// `ado_reply_to_pr_thread` — POST `…/threads/{id}/comments` with
/// `parentCommentId: 1` (ports the Java `replyToPullRequestThread`).
String _replyToPrThread(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}'
      '/threads/${syncAsStr(args['threadId'])}/comments'
      '?api-version=$_adoApiVersion';
  return _postBody(
    config,
    url,
    jsonEncode({
      'content': syncAsStr(args['text']),
      'parentCommentId': 1,
      'commentType': 1,
    }),
  );
}

/// `ado_resolve_pr_thread` — PATCH `…/threads/{id}` with the numeric status.
///
/// [status] defaults to `fixed`; see [mapAdoThreadStatus] for the accepted
/// names (ports the Java `resolveThread` + `mapThreadStatus`).
String _resolvePrThread(_AdoConfig config, Map<String, dynamic> args) {
  final status = syncAsStr(args['status']);
  final url = '${_prIdPath(config, args)}'
      '/threads/${syncAsStr(args['threadId'])}?api-version=$_adoApiVersion';
  return _patchJson(
    config,
    url,
    jsonEncode({'status': mapAdoThreadStatus(status)}),
  );
}

/// `ado_add_inline_comment` — POST `…/threads` with a file-position context.
///
/// Ports the Java `addInlineComment`: `filePath` gains a leading `/`,
/// `line` must be numeric, `startLine` defaults to `line`, and `side`
/// selects the left (old) or right (new) diff half.
String _addInlineComment(_AdoConfig config, Map<String, dynamic> args) {
  final line = int.tryParse(syncAsStr(args['line']));
  if (line == null) {
    return syncErr(
      "Invalid line: expected a numeric line number, but got: "
      "'${syncAsStr(args['line'])}'",
    );
  }
  var filePath = syncAsStr(args['filePath']);
  if (filePath.isEmpty) filePath = syncAsStr(args['path']);
  if (!filePath.startsWith('/')) filePath = '/$filePath';
  final startLineRaw = syncAsStr(args['startLine']);
  final startLine = startLineRaw.isEmpty ? line : int.tryParse(startLineRaw);
  if (startLine == null) {
    return syncErr(
      "Invalid startLine: expected a numeric line number, but got: "
      "'$startLineRaw'",
    );
  }
  final body = _newThreadPayload(
    comments: [
      {
        'parentCommentId': 0,
        'content': syncAsStr(args['text']),
        'commentType': 1,
      },
    ],
    threadContext: _threadContext(filePath, line, startLine, args),
  );
  final url = '${_prIdPath(config, args)}/threads?api-version=$_adoApiVersion';
  return _postBody(config, url, jsonEncode(body));
}

/// Builds the threadContext position for an inline comment: right (new
/// code, the default) or left (old code) file spans at offset 1.
Map<String, dynamic> _threadContext(
  String filePath,
  int line,
  int startLine,
  Map<String, dynamic> args,
) {
  final isLeft = syncAsStr(args['side']).toLowerCase() == 'left';
  final startKey = isLeft ? 'leftFileStart' : 'rightFileStart';
  final endKey = isLeft ? 'leftFileEnd' : 'rightFileEnd';
  return {
    'filePath': filePath,
    startKey: {'line': startLine, 'offset': 1},
    endKey: {'line': line, 'offset': 1},
  };
}

/// `ado_merge_pr` — complete a PR.
///
/// Ports the Java `completePullRequest`: the PR is fetched first for its
/// `lastMergeSourceCommit` (required by ADO for completion), then PATCHed
/// with `status: completed` and `completionOptions` (`mergeStrategy`
/// defaults to `squash`, `deleteSourceBranch` defaults to true).
String _mergePr(_AdoConfig config, Map<String, dynamic> args) {
  final pr = syncTryDecode(_getPr(config, args));
  final body = _mergePrBody(
    args,
    pr is Map ? pr['lastMergeSourceCommit'] : null,
  );
  final url = '${_prIdPath(config, args)}?api-version=$_adoApiVersion';
  return _patchJson(config, url, jsonEncode(body));
}

/// Builds the PR completion body.
Map<String, dynamic> _mergePrBody(
  Map<String, dynamic> args,
  dynamic lastCommit,
) {
  final mergeStrategy = syncAsStr(args['mergeStrategy']);
  final deleteRaw = syncAsStr(args['deleteSourceBranch']);
  final commitMessage = syncAsStr(args['commitMessage']);
  return {
    'status': 'completed',
    if (lastCommit is Map) 'lastMergeSourceCommit': lastCommit,
    'completionOptions': {
      'mergeStrategy': mergeStrategy.trim().isEmpty ? 'squash' : mergeStrategy,
      'deleteSourceBranch':
          deleteRaw.trim().isEmpty ? true : deleteRaw.toLowerCase() == 'true',
      if (commitMessage.trim().isNotEmpty) 'mergeCommitMessage': commitMessage,
    },
  };
}

/// `ado_add_pr_label` — POST `…/labels` (`api-version=7.0-preview.1`).
String _addPrLabel(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}'
      '/labels?api-version=$_adoApiVersion-preview.1';
  return _postBody(config, url, jsonEncode({'name': syncAsStr(args['label'])}));
}

/// `ado_remove_pr_label` — DELETE `…/labels/{labelId}`
/// (`api-version=7.0-preview.1`).
String _removePrLabel(_AdoConfig config, Map<String, dynamic> args) {
  final url = '${_prIdPath(config, args)}'
      '/labels/${syncAsStr(args['labelId'])}'
      '?api-version=$_adoApiVersion-preview.1';
  return syncBodyOrError(SyncHttpClient.delete(url, headers: config.headers));
}

/// `ado_get_pr_diff` — GET the latest iteration's changes.
///
/// Ports the Java `getPullRequestDiffStat`: iterations are listed first
/// (the latest is the page length), then that iteration's `changes` are
/// fetched. No iterations → `{"changes": []}`.
String _getPrDiff(_AdoConfig config, Map<String, dynamic> args) {
  final iterationsUrl = '${_prIdPath(config, args)}'
      '/iterations?api-version=$_adoApiVersion';
  final iterations = syncTryDecode(
    syncBodyOrError(SyncHttpClient.get(iterationsUrl, headers: config.headers)),
  );
  final list = iterations is Map ? iterations['value'] : null;
  if (list is! List || list.isEmpty) return jsonEncode({'changes': []});
  final changesUrl = '${_prIdPath(config, args)}'
      '/iterations/${list.length}/changes?api-version=$_adoApiVersion';
  return syncBodyOrError(
    SyncHttpClient.get(changesUrl, headers: config.headers),
  );
}

// ── Pipelines ─────────────────────────────────────────────────────────────

/// `ado_list_pipelines` — GET `pipelines`.
String _listPipelines(_AdoConfig config, Map<String, dynamic> args) =>
    syncBodyOrError(
      SyncHttpClient.get(
        '${config.baseUrl}/pipelines?api-version=$_adoApiVersion',
        headers: config.headers,
      ),
    );

/// `ado_list_pipeline_runs` — GET `pipelines/{id}/runs?$top={n}`.
///
/// [top] defaults to 10 (ports the Java `listPipelineRuns`).
String _listPipelineRuns(_AdoConfig config, Map<String, dynamic> args) {
  final top = _asIntOrNull(args['top']);
  final limit = top != null && top > 0 ? top : 10;
  final url =
      '${config.baseUrl}/pipelines/${syncAsInt(args['pipelineId'])}/runs'
      '?\$top=$limit&api-version=$_adoApiVersion';
  return syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));
}

/// `ado_trigger_pipeline` — POST `pipelines/{id}/runs`.
///
/// Ports the Java `triggerPipeline`: `branch` is normalized to a
/// `refs/heads/…` refName and `variables` (a JSON object) is mapped to ADO's
/// `{key: {value, isSecret}}` shape.
String _triggerPipeline(_AdoConfig config, Map<String, dynamic> args) {
  final body = _triggerBody(args);
  if (body == null) return syncErr('Invalid variables');
  final url =
      '${config.baseUrl}/pipelines/${syncAsInt(args['pipelineId'])}/runs'
      '?api-version=$_adoApiVersion';
  return _postBody(config, url, jsonEncode(body));
}

/// Builds the run-trigger body; `null` when `variables` does not parse as a
/// JSON object.
Map<String, dynamic>? _triggerBody(Map<String, dynamic> args) {
  final body = <String, dynamic>{};
  final branch = syncAsStr(args['branch']);
  if (branch.trim().isNotEmpty) {
    var ref = branch.trim();
    if (!ref.startsWith('refs/heads/')) ref = 'refs/heads/$ref';
    body['resources'] = {
      'repositories': {
        'self': {'refName': ref},
      },
    };
  }
  final variablesJson = syncAsStr(args['variables']);
  if (variablesJson.trim().isNotEmpty) {
    final raw = syncTryDecode(variablesJson);
    if (raw is! Map) return null;
    body['variables'] = {
      for (final entry in raw.entries)
        entry.key: {'value': '${entry.value}', 'isSecret': false},
    };
  }
  return body;
}

/// `ado_get_pipeline_logs` — combined logs for all tasks in a build run.
///
/// Ports the Java `getPipelineLogs`: the build timeline supplies the task
/// records, each record's log is fetched and tailed ([tailLines] default
/// 200, `0` = all), `Stage`/`Checkpoint` records are skipped, and
/// [taskName] filters records by case-insensitive substring.
String _getPipelineLogs(_AdoConfig config, Map<String, dynamic> args) {
  final buildId = syncAsInt(args['buildId']);
  final timeline = syncTryDecode(
    syncBodyOrError(
      SyncHttpClient.get(
        '${config.baseUrl}/build/builds/$buildId/timeline'
        '?api-version=$_adoApiVersion',
        headers: config.headers,
      ),
    ),
  );
  final records = timeline is Map ? timeline['records'] : null;
  if (records is! List || records.isEmpty) {
    return jsonEncode('(no timeline records found for build $buildId)');
  }
  final logs = _collectTaskLogs(config, records, buildId, args);
  // Plain-string results (Java parity); JSON-encode for the FFI bridge —
  // raw text fails the host-callback JSON parse (live: github_get_job_logs
  // starved dart #414's rework legs, 2026-10-17).
  return jsonEncode(logs.isEmpty ? '(no logs found for build $buildId)' : logs);
}

/// Fetches and concatenates the log of every matching timeline record.
String _collectTaskLogs(
  _AdoConfig config,
  List records,
  int buildId,
  Map<String, dynamic> args,
) {
  final taskName = syncAsStr(args['taskName']).toLowerCase();
  final tail = _asIntOrNull(args['tailLines']) ?? 200;
  final buffer = StringBuffer();
  for (final record in records) {
    if (!_isLogTaskRecord(record, taskName)) continue;
    final logId = _recordLogId(record);
    if (logId <= 0) continue;
    final content = _fetchLog(config, buildId, logId);
    if (content.isEmpty) continue;
    _appendTaskLog(buffer, record, content, tail);
  }
  return buffer.toString();
}

/// Whether [record] is a task-type record whose name matches [taskName]
/// (empty matches all); `Stage`/`Checkpoint` records never carry logs.
bool _isLogTaskRecord(dynamic record, String taskName) {
  if (record is! Map) return false;
  final type = syncAsStr(record['type']);
  if (type == 'Stage' || type == 'Checkpoint') return false;
  final name = syncAsStr(record['name']);
  return taskName.isEmpty || name.toLowerCase().contains(taskName);
}

/// The build-log id attached to [record], or `0` when it has none.
int _recordLogId(dynamic record) {
  final log = record is Map ? record['log'] : null;
  return log is Map ? syncAsInt(log['id']) : 0;
}

/// Appends one task's log [section] ([type]/[name] header) to [buffer].
void _appendTaskLog(StringBuffer buffer, Map record, String content, int tail) {
  final type = syncAsStr(record['type']);
  final name = syncAsStr(record['name']);
  buffer
    ..write('=== $type: $name ===\n')
    ..write(_tailLogLines(content, tail))
    ..write('\n\n');
}

/// Fetches one raw build log; empty on any failure.
String _fetchLog(_AdoConfig config, int buildId, int logId) {
  final resp = SyncHttpClient.get(
    '${config.baseUrl}/build/builds/$buildId/logs/$logId'
    '?api-version=$_adoApiVersion',
    headers: config.headers,
  );
  if (resp.statusCode == 0 || resp.body.trim().isEmpty) return '';
  return resp.body;
}

/// Keeps the last [tail] lines of [content] (`0` keeps everything).
String _tailLogLines(String content, int tail) {
  if (tail <= 0) return content;
  final lines = content.split('\n');
  if (lines.length <= tail) return content;
  return lines.sublist(lines.length - tail).join('\n');
}

// ── Shared helpers ────────────────────────────────────────────────────────

/// ADO thread status names → numeric codes: 0=unknown, 1=active, 2=fixed,
/// 3=wontFix, 4=closed, 5=byDesign, 6=pending (ports the Java
/// `mapThreadStatus`; unknown names default to `fixed`).
const _adoThreadStatusCodes = <String, int>{
  'active': 1,
  'fixed': 2,
  'resolved': 2,
  'wontfix': 3,
  'wont_fix': 3,
  'closed': 4,
  'bydesign': 5,
  'by_design': 5,
  'pending': 6,
};

/// Maps a thread status name to the ADO numeric code; unknown names
/// default to `fixed` (2).
int mapAdoThreadStatus(String status) =>
    _adoThreadStatusCodes[status.toLowerCase()] ?? 2;

/// Builds the project-scoped PR path for a repository (Java `gitPrPath`):
/// `{base}/git/repositories/{repo}/pullrequests`.
String _prPath(_AdoConfig config, Map<String, dynamic> args) =>
    '${config.baseUrl}/git/repositories/${syncAsStr(args['repository'])}'
    '/pullrequests';

/// The path of one PR: `{prPath}/{pullRequestId}`.
String _prIdPath(_AdoConfig config, Map<String, dynamic> args) =>
    '${_prPath(config, args)}/${syncAsStr(args['pullRequestId'])}';

/// Builds a new-thread payload with optional [comments] and
/// [threadContext]; threads always start `status: 1` (active).
Map<String, dynamic> _newThreadPayload({
  required List<Map<String, dynamic>> comments,
  Map<String, dynamic>? threadContext,
}) =>
    {
      'comments': comments,
      if (threadContext != null) 'threadContext': threadContext,
      'status': 1,
    };

/// PATCHes [body] to [url] with the plain-JSON content type (Java
/// `patchJson` — ADO accepts regular JSON for PR PATCHes, unlike work-item
/// patches which need `application/json-patch+json`). [SyncHttpClient] has
/// no PATCH verb, so this stages the body in a temp file and runs curl
/// directly with the same timeouts and header-file hygiene.
String _patchJson(_AdoConfig config, String url, String body) {
  final dir = Directory.systemTemp.createTempSync('dmtools_ado_patch_');
  try {
    final bodyFile = File('${dir.path}/body')
      ..writeAsStringSync(body, flush: true);
    return syncBodyOrError(
      syncCurlStaged(
        'PATCH',
        url,
        headers: config.headers,
        dataBinaryFile: bodyFile.path,
      ),
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// POSTs [body] to [url] and returns the result string.
String _postBody(_AdoConfig config, String url, String body) => syncBodyOrError(
      SyncHttpClient.post(url, headers: config.headers, body: body),
    );

/// Coerces a loosely-typed JS argument to an int, or `null` when absent.
int? _asIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
