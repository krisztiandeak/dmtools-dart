/// Dispatch-time translation of the normalized `scm_*` / `ci_*` alias
/// calls onto the configured provider's concrete tools (gh-339).
///
/// Routing: `DEFAULT_SCM` (`github` | `gitlab`) picks the data-plane
/// carrier, `DEFAULT_CI` (`actions` | `gitlab-ci`) the control-plane
/// carrier — resolved once per instance, so an alias never changes
/// routing mid-process. The provider handlers are the existing sync
/// surfaces (`GitHubSyncTools` / `GitLabSyncTools`), injectable for
/// tests; unconfigured creds therefore surface the provider's own auth
/// error through the alias (E1), never tool-not-found.
///
/// Contracts pinned here:
/// - Data plane (`scm_*`): parameter-shape translation plus the
///   normalized `state` enum; the provider response returns
///   byte-identical (contract-fixture requirement).
/// - Control plane (`ci_*`): semantic normalization — `ci_get_verdict`
///   speaks ONLY the 4-value verdict enum, `ci_get_merge_state` ONLY the
///   SM's 5-value merge-state enum (see `ci_normalization.dart`).
/// - `inputs` are a flat string map; non-string values are stringified
///   at this boundary (pinned fact).
/// - `scm_search_issues`/`scm_get_issue`/`scm_list_branches`/
///   `scm_get_reviews` have no GitLab sync surface in v1 — an honest
///   error naming the gap (the documented-degradation rule).
library;

import 'dart:convert';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../../integrations/scm/ci_normalization.dart';
import '../../integrations/scm/scm_ci_alias_catalog.dart'
    show resolveCiProvider, resolveScmProvider;
import 'github_sync_tools.dart';
import 'gitlab_sync_tools.dart';
import 'sync_request_helpers.dart' show syncTryDecode;

/// One translated tool executor.
typedef Handler = String Function(Map<String, dynamic> args);

/// The normalized `state` enum accepted by `scm_list_prs` (E2: this is
/// the only accepted shape — a raw provider spelling is rejected).
const String kScmStateEnum = 'open, closed, merged, all';

/// GitHub provider id (dispatch key + the `provider` field the bridge
/// rewrites to).
const String providerGithub = 'github';

/// GitLab provider id (dispatch key + the `provider` field the bridge
/// rewrites to).
const String providerGitlab = 'gitlab';

/// Slack for the post-dispatch `created_at` comparison: the cutoff is a
/// locally captured clock, GitHub's `created_at` is server-side.
const Duration _runLookupSkew = Duration(minutes: 2);

/// Translates `scm_*`/`ci_*` calls to the configured provider.
class ScmCiSyncTools {
  final PropertyReader _reader;

  final Map<String, Handler>? _githubHandlers;
  final Map<String, Handler>? _gitlabHandlers;
  final String? _scmOverride;
  final String? _ciOverride;

  /// Creates the alias surface.
  ///
  /// [scmProvider]/[ciProvider] pin the routing explicitly (tests);
  /// otherwise the `DEFAULT_SCM`/`DEFAULT_CI` property chain decides.
  /// The handler maps default to the real provider sync surfaces.
  ScmCiSyncTools({
    PropertyReader? reader,
    Map<String, Handler>? githubHandlers,
    Map<String, Handler>? gitlabHandlers,
    String? scmProvider,
    String? ciProvider,
  })  : _reader = reader ?? PropertyReader(),
        _githubHandlers = githubHandlers,
        _gitlabHandlers = gitlabHandlers,
        _scmOverride = scmProvider,
        _ciOverride = ciProvider;

  late final String? _scm =
      _scmOverride ?? resolveScmProvider(_reader.getDefaultScm());
  late final String? _ci =
      _ciOverride ?? resolveCiProvider(_reader.getDefaultCi());

  /// The concrete GitHub handlers (real or injected).
  Map<String, Handler> get _gh =>
      _githubHandlers ?? const GitHubSyncTools().handlers;

  /// The concrete GitLab handlers (real or injected).
  Map<String, Handler> get _gl =>
      _gitlabHandlers ?? const GitLabSyncTools().handlers;

  /// Every alias executor for the configured providers, keyed by alias
  /// name. Empty when the corresponding axis is unconfigured — the
  /// registry then does not carry the family either (tool-not-found).
  Map<String, Handler> get handlers => {
        if (_scm != null) ..._scmRoute(),
        if (_ci != null) ..._ciRoute(),
      };

  Map<String, Handler> _scmRoute() =>
      _scm == providerGitlab ? _scmGitlab() : _scmGithub();

  Map<String, Handler> _ciRoute() =>
      _ci == providerGitlab ? _ciGitlab() : _ciGithub();

  // ── scm_* → github ────────────────────────────────────────────────────

  Map<String, Handler> _scmGithub() => {
        ..._scmGithubPrs(),
        ..._scmGithubIssues(),
      };

  /// `scm_*` PR aliases routed to the GitHub tools.
  Map<String, Handler> _scmGithubPrs() => {
        'scm_list_prs': (a) => _stateValidated(
            a, (state) => _ghCall('github_list_prs', {'state': state}, a)),
        'scm_get_pr': (a) =>
            _ghCall('github_get_pr', {'pullRequestId': a['pr']}, a),
        'scm_merge_pr': (a) => _ghCall(
            'github_merge_pr',
            {
              'pullRequestId': a['pr'],
              if (a['mergeMethod'] != null) 'mergeMethod': a['mergeMethod'],
              if (a['commitTitle'] != null) 'commitTitle': a['commitTitle'],
              if (a['commitMessage'] != null)
                'commitMessage': a['commitMessage'],
            },
            a),
        'scm_get_diff': (a) =>
            _ghCall('github_get_pr_diff_text', {'pullRequestId': a['pr']}, a),
        'scm_add_labels': (a) => _ghCall(
            'github_add_labels', {'number': a['pr'], 'labels': a['labels']}, a),
        'scm_remove_label': (a) => _ghCall(
            'github_remove_label', {'number': a['pr'], 'label': a['label']}, a),
        'scm_add_pr_comment': (a) => _ghCall('github_add_pr_comment',
            {'pullRequestId': a['pr'], 'text': a['text']}, a),
        'scm_get_pr_comments': (a) =>
            _ghCall('github_get_pr_comments', {'pullRequestId': a['pr']}, a),
      };

  /// `scm_*` issue/branch/review aliases routed to the GitHub tools.
  Map<String, Handler> _scmGithubIssues() => {
        'scm_create_comment': (a) => _ghCall('github_create_comment',
            {'number': a['issue'], 'body': a['body']}, a),
        'scm_get_issue': (a) =>
            _ghCall('github_get_issue', {'issueNumber': a['issue']}, a),
        'scm_search_issues': (a) =>
            _ghCall('github_search_issues', {'query': a['query']}, a),
        'scm_list_branches': (a) =>
            _ghCall('github_list_branches', const {}, a),
        'scm_get_reviews': (a) =>
            _ghCall('github_list_pr_reviews', {'pullRequestId': a['pr']}, a),
        'scm_approve': (a) => _ghCall(
            'github_submit_pr_review',
            {
              'pullRequestId': a['pr'],
              'event': 'APPROVE',
              if (a['body'] != null) 'body': a['body'],
            },
            a),
        'scm_close_issue': (a) =>
            _ghCall('github_close_issue', {'number': a['issue']}, a),
      };

  // ── scm_* → gitlab ────────────────────────────────────────────────────

  Map<String, Handler> _scmGitlab() => {
        'scm_list_prs': (a) => _stateValidated(
            a,
            (state) =>
                _glCall('gitlab_list_mrs', {'state': _glState(state)}, a)),
        'scm_get_pr': (a) =>
            _glCall('gitlab_get_mr', {'pullRequestId': '${a['pr']}'}, a),
        'scm_merge_pr': (a) =>
            _glCall('gitlab_merge_mr', {'pullRequestId': '${a['pr']}'}, a),
        'scm_get_diff': (a) => _glCall(
            'gitlab_get_mr_diff_text', {'pullRequestId': '${a['pr']}'}, a),
        'scm_add_labels': (a) => _glAddLabels(a),
        'scm_remove_label': (a) => _glCall('gitlab_remove_mr_label',
            {'pullRequestId': '${a['pr']}', 'label': a['label']}, a),
        'scm_add_pr_comment': (a) => _glCall('gitlab_add_mr_comment',
            {'pullRequestId': '${a['pr']}', 'text': a['text']}, a),
        'scm_get_pr_comments': (a) => _glCall(
            'gitlab_get_mr_comments', {'pullRequestId': '${a['pr']}'}, a),
        // Issue notes ride the MR-note shape (smProvider twin precedent:
        // projects using MRs as the state carrier get exact behavior).
        'scm_create_comment': (a) => _glCall('gitlab_create_mr_note',
            {'pullRequestId': '${a['issue']}', 'text': a['body']}, a),
        'scm_get_issue': (a) => _glGap('scm_get_issue'),
        'scm_search_issues': (a) => _glGap('scm_search_issues'),
        'scm_list_branches': (a) => _glGap('scm_list_branches'),
        'scm_get_reviews': (a) => _glGap('scm_get_reviews'),
        'scm_approve': (a) =>
            _glCall('gitlab_approve_mr', {'pullRequestId': '${a['pr']}'}, a),
        // Documented v1 gap, matching the smProvider gitlab twin: no
        // close-issue tool — the issue stays open.
        'scm_close_issue': (a) => _glGap('scm_close_issue'),
      };

  String _glAddLabels(Map<String, dynamic> a) {
    final labels = a['labels'];
    if (labels is! List || labels.isEmpty) {
      return _err('scm_add_labels requires a non-empty labels array');
    }
    var last = '';
    for (final label in labels) {
      last = _glCall('gitlab_add_mr_label',
          {'pullRequestId': '${a['pr']}', 'label': '$label'}, a);
      if (_isErr(last)) return last;
    }
    return last;
  }

  // ── ci_* → github actions ─────────────────────────────────────────────

  Map<String, Handler> _ciGithub() => {
        'ci_trigger_workflow': _ghTrigger,
        'ci_list_runs': _ghListRuns,
        'ci_get_verdict': _ghVerdict,
        'ci_get_merge_state': (a) => _verdictJson(
              _ghCall('github_get_pr', {'pullRequestId': a['pr']}, a),
              (body) => ghMergeState(
                mergeable: body['mergeable'],
                mergeableState: body['mergeable_state'] as String?,
                mergeStateStatus: body['mergeStateStatus'] as String?,
              ),
              extra: {'provider': providerGithub},
            ),
      };

  String _ghTrigger(Map<String, dynamic> a) {
    final inputs = _stringifiedInputs(a);
    if (inputs == null) return _err('ci_trigger_workflow: invalid inputs JSON');
    // Captured before the trigger call: a run created during the listing
    // is ours (the skew slack covers local-vs-server clock drift).
    final dispatchedAt = DateTime.now().toUtc();
    final raw = _ghCall(
        'github_trigger_workflow',
        {
          'workflowId': a['workflow'],
          if (a['ref'] != null) 'ref': a['ref'],
          if (inputs.isNotEmpty) 'inputs': inputs,
        },
        a);
    if (_isErr(raw)) return raw;
    return _triggerResult(providerGithub,
        _ghRunIdLookup(a, a['ref'] ?? 'main', dispatchedAt), raw);
  }

  /// Best-effort run handle after a GitHub dispatch (the API returns no
  /// id): the newest `workflow_dispatch` run of the workflow on the
  /// dispatched ref, created at/after the dispatch moment.
  ///
  /// The listing lags the dispatch by seconds — until the fresh run
  /// appears, the newest match would be the PREVIOUS run (an older head
  /// sha), and `ci_get_verdict` by runId never re-checks the sha, so a
  /// plausible-but-wrong handle would surface a stale verdict as
  /// authoritative (the fa #762 failure class). A push to the same ref
  /// is never ours either. No provably-fresh run → the honest null
  /// handle (`runId: null`); the SM's race-safe path is the sha probe.
  dynamic _ghRunIdLookup(
    Map<String, dynamic> a,
    String ref,
    DateTime dispatchedAt,
  ) {
    final cutoff = dispatchedAt.subtract(_runLookupSkew);
    try {
      final raw = _ghCall('github_list_workflow_runs',
          {'workflowId': a['workflow'], 'perPage': '5'}, a);
      final runs = (_decode(raw)['workflow_runs'] as List? ?? const [])
          .whereType<Map>()
          .where((r) => r['head_branch'] == ref)
          .where((r) => r['event'] == 'workflow_dispatch')
          .where((r) {
        final at = DateTime.tryParse('${r['created_at']}');
        return at != null && !at.isBefore(cutoff);
      });
      return runs.isEmpty ? null : runs.first['id'];
    } catch (_) {
      // Best-effort by contract: an unparsable or unavailable listing
      // must never fail an accepted trigger — the handle is null.
      return null;
    }
  }

  String _ghListRuns(Map<String, dynamic> a) {
    final raw = _ghCall(
        'github_list_workflow_runs',
        {
          if (a['workflow'] != null) 'workflowId': a['workflow'],
          if (a['status'] != null) 'status': a['status'],
          if (a['limit'] != null) 'perPage': a['limit'],
        },
        a);
    // E1: a provider error envelope passes through — an unconfigured or
    // failing provider must not read as a repo with no CI runs.
    if (_isErr(raw)) return raw;
    // The concrete tool has no server-side ref filter: answering with
    // unfiltered runs *labeled* as ref-filtered would make a wrong-branch
    // run look legitimate to the SM, so the alias filters client-side
    // (the same head_branch match `_ghRunIdLookup` uses).
    final ref = a['ref'];
    final runs = (_decode(raw)['workflow_runs'] as List? ?? const [])
        .whereType<Map>()
        .where((r) => ref == null || r['head_branch'] == ref);
    return jsonEncode({
      'runs': [
        for (final r in runs.whereType<Map>())
          {
            'runId': r['id'],
            'status': r['status'],
            'verdict': ghRunVerdict(
                r['status'] as String?, r['conclusion'] as String?),
            'sha': r['head_sha'],
            'url': r['html_url'],
            'startedAt': r['created_at'],
            'event': r['event'],
            'path': r['path'],
            'name': r['name'],
          },
      ],
    });
  }

  String _ghVerdict(Map<String, dynamic> a) {
    final runId = a['runId'];
    final sha = a['sha'];
    if (runId != null) {
      final raw = _ghCall('github_get_workflow_run', {'runId': runId}, a);
      final body = _decode(raw);
      if (body['error'] != null)
        return _runMismatch(raw, providerGithub, runId);
      return jsonEncode({
        'provider': providerGithub,
        'verdict': ghRunVerdict(
            body['status'] as String?, body['conclusion'] as String?),
      });
    }
    if (sha != null) return _ghShaVerdict(a, sha);
    return _err('ci_get_verdict requires runId, or sha (+ optional '
        'workflow) for the head probe');
  }

  /// The `(sha[, workflow])` probe: check-run rollup first; when the
  /// head carries no check runs, the workflow-runs fallback matched on
  /// head_sha (the SM's stale-verdict probe, live fa #762). Provider
  /// error envelopes pass through (E1) — they never read as "no check
  /// runs" / `none`.
  String _ghShaVerdict(Map<String, dynamic> a, String sha) {
    final crRaw =
        _ghCall('github_get_commit_check_runs', {'commitSha': sha}, a);
    if (_isErr(crRaw)) return crRaw;
    final runs = _decode(crRaw)['check_runs'] as List? ?? const [];
    if (runs.isNotEmpty) {
      return jsonEncode(
          {'provider': providerGithub, 'verdict': ghCheckRunsVerdict(runs)});
    }
    final wf = a['workflow'];
    if (wf == null) {
      return jsonEncode({'provider': providerGithub, 'verdict': verdictNone});
    }
    final raw = _ghCall(
        'github_list_workflow_runs', {'workflowId': wf, 'perPage': '30'}, a);
    if (_isErr(raw)) return raw;
    final mine = (_decode(raw)['workflow_runs'] as List? ?? const [])
        .whereType<Map>()
        .where((r) => r['head_sha'] == sha);
    if (mine.isEmpty) {
      return jsonEncode({'provider': providerGithub, 'verdict': verdictNone});
    }
    final top = mine.first;
    return jsonEncode({
      'provider': providerGithub,
      'verdict':
          ghRunVerdict(top['status'] as String?, top['conclusion'] as String?),
    });
  }

  // ── ci_* → gitlab ci ──────────────────────────────────────────────────

  Map<String, Handler> _ciGitlab() => {
        // GitLab pipelines are file-driven; the workflow selector has no
        // GitLab counterpart and rides along as a plain variable-free
        // trigger (smProvider twin precedent).
        'ci_trigger_workflow': (a) {
          final inputs = _stringifiedInputs(a);
          if (inputs == null) {
            return _err('ci_trigger_workflow: invalid inputs JSON');
          }
          final raw = _glCall(
              'gitlab_trigger_pipeline',
              {
                'ref': a['ref'] ?? 'main',
                if (inputs.isNotEmpty) 'variablesJson': inputs,
              },
              a);
          if (_isErr(raw)) return raw;
          return _triggerResult(providerGitlab, _decode(raw)['id'], raw);
        },
        'ci_list_runs': (a) {
          final raw = _glCall(
              'gitlab_list_pipeline_runs',
              {
                if (a['ref'] != null) 'ref': a['ref'],
                if (a['status'] != null) 'status': a['status'],
                if (a['limit'] != null) 'limit': a['limit'],
              },
              a);
          // E1 + the List type-cast guard: an error envelope is a map,
          // and `map as List?` would crash the alias with a TypeError
          // instead of the provider's message.
          if (_isErr(raw)) return raw;
          final runs = _decode(raw) as List? ?? const [];
          return jsonEncode({
            'runs': [
              for (final r in runs.whereType<Map>())
                {
                  'runId': r['id'],
                  'status': r['status'],
                  'verdict': gitlabStatusVerdict(r['status'] as String?),
                  'sha': r['sha'],
                  'url': r['web_url'],
                  'startedAt': r['created_at'],
                },
            ],
          });
        },
        'ci_get_verdict': _glVerdict,
        'ci_get_merge_state': (a) => _verdictJson(
              _glCall('gitlab_get_mr', {'pullRequestId': '${a['pr']}'}, a),
              (body) => gitlabMergeState(
                mergeStatus: body['merge_status'] as String?,
                detailedMergeStatus: body['detailed_merge_status'] as String?,
                hasConflicts: body['has_conflicts'],
              ),
              extra: {'provider': providerGitlab},
            ),
      };

  String _glVerdict(Map<String, dynamic> a) {
    final runId = a['runId'];
    if (runId != null) return _glRunVerdict(runId, a);
    if (a['pr'] != null) {
      final raw = _glCall(
          'gitlab_get_mr_pipelines', {'pullRequestId': '${a['pr']}'}, a);
      // E1 + the List type-cast guard (see ci_list_runs).
      if (_isErr(raw)) return raw;
      return jsonEncode({
        'provider': providerGitlab,
        'verdict': gitlabStatusListVerdict(_decode(raw) as List? ?? const []),
      });
    }
    if (a['sha'] != null) {
      final raw =
          _glCall('gitlab_get_commit_statuses', {'commitSha': a['sha']}, a);
      if (_isErr(raw)) return raw;
      return jsonEncode({
        'provider': providerGitlab,
        'verdict': gitlabStatusListVerdict(_decode(raw) as List? ?? const []),
      });
    }
    return _err('ci_get_verdict requires runId, pr, or sha (+ optional '
        'workflow) for the head probe');
  }

  /// `ci_get_verdict` by GitLab pipeline [runId].
  String _glRunVerdict(dynamic runId, Map<String, dynamic> a) {
    final jobsHandler = _gl['gitlab_get_pipeline_jobs'];
    if (jobsHandler == null) {
      // The concrete pipeline-jobs tool has no sync surface yet (it is
      // still in the Java-parity gap list) — an honest gap error beats
      // a null-check crash on the primary runId form. The pr/sha
      // probes below are fully served.
      return _err('ci_get_verdict by runId is not available on the '
          'GitLab route in v1 — the concrete gitlab_get_pipeline_jobs '
          'tool has no GitLab sync surface yet; poll via the pr or sha '
          'probe form instead');
    }
    final raw = jobsHandler(_withRepo({'pipelineId': runId}, a));
    final body = _decode(raw);
    if (body['error'] != null) return _runMismatch(raw, providerGitlab, runId);
    final jobs = body['jobs'] as List? ?? const [];
    final statuses = [
      for (final j in jobs.whereType<Map>()) {'status': j['status']},
    ];
    return jsonEncode({
      'provider': providerGitlab,
      'verdict': gitlabStatusListVerdict(statuses),
    });
  }

  // ── shared helpers ────────────────────────────────────────────────────

  /// Calls a GitHub handler with `workspace`/`repository` carried over
  /// from the alias args plus [specific].
  String _ghCall(
    String tool,
    Map<String, dynamic> specific,
    Map<String, dynamic> a,
  ) =>
      (_gh[tool]!)(_withRepo(specific, a));

  /// Calls a GitLab handler with `workspace`/`repository` carried over.
  String _glCall(
    String tool,
    Map<String, dynamic> specific,
    Map<String, dynamic> a,
  ) =>
      (_gl[tool]!)(_withRepo(specific, a));

  Map<String, dynamic> _withRepo(
    Map<String, dynamic> specific,
    Map<String, dynamic> a,
  ) =>
      {
        ...specific,
        if (a['workspace'] != null) 'workspace': a['workspace'],
        if (a['repository'] != null) 'repository': a['repository'],
      };

  /// Validates the normalized state enum, then hands the normalized
  /// value to [call] (E2: raw provider spellings are rejected).
  String _stateValidated(Map<String, dynamic> a, String Function(String) call) {
    final raw = a['state']?.toString().trim().toLowerCase() ?? 'open';
    if (raw.isEmpty) return call('open');
    const allowed = {'open', 'closed', 'merged', 'all'};
    if (!allowed.contains(raw)) {
      return _err('scm_list_prs: state must be one of: $kScmStateEnum '
          "(got '$raw') — the normalized enum is the only accepted shape");
    }
    return call(raw);
  }

  /// GitLab's MR-list spelling of the normalized state.
  String _glState(String state) => state == 'open' ? 'opened' : state;

  /// The normalized inputs contract: a flat string map (object or JSON
  /// string); non-string values stringified at this boundary. `null`
  /// marks an unparsable JSON-string payload.
  String? _stringifiedInputs(Map<String, dynamic> a) {
    final inputs = a['inputs'];
    if (inputs == null) return '';
    if (inputs is String) {
      final trimmed = inputs.trim();
      if (trimmed.isEmpty) return '';
      final decoded = _tryDecode(trimmed);
      if (decoded == null) return null;
      return jsonEncode(_stringifiedMap(decoded));
    }
    if (inputs is Map) return jsonEncode(_stringifiedMap(inputs));
    return jsonEncode({'input': '$inputs'});
  }

  Map<String, dynamic> _stringifiedMap(dynamic decoded) => {
        for (final entry in (decoded as Map).entries)
          '${entry.key}':
              entry.value is String ? entry.value : '${entry.value}',
      };

  /// The trigger response: provider + best-effort run handle + the
  /// provider's own success message (kept verbatim; the GitHub trigger
  /// message arrives JSON-quoted).
  String _triggerResult(String provider, dynamic runId, String raw) {
    final decoded = _decode(raw);
    final message = decoded is Map
        ? decoded['message'] ?? _unwrapQuoted(raw)
        : _unwrapQuoted(raw);
    return jsonEncode({
      'provider': provider,
      'runId': runId,
      'message': message,
    });
  }

  String _unwrapQuoted(String raw) {
    final v = _tryDecode(raw);
    return v is String ? v : raw;
  }

  /// E3: a run handle that the routed provider does not know must name
  /// the mismatch, not just the transport failure.
  String _runMismatch(String raw, String provider, dynamic runId) {
    final body = _decode(raw);
    if (body['error'] == null) return raw;
    return _err('${body['error']} (runId $runId not found on '
        '$provider — was it created by a different provider?)');
  }

  /// Normalizes a provider body through [map] and merges [extra]. An
  /// error envelope passes through unchanged (E1): `UNKNOWN`/`none` are
  /// semantically meaningful answers for the SM, so a provider failure
  /// must never be normalized into one.
  String _verdictJson(
    String raw,
    MergeState Function(Map<String, dynamic> body) map, {
    Map<String, dynamic> extra = const {},
  }) {
    if (_isErr(raw)) return raw;
    final out = map(_decode(raw)).toJson();
    return jsonEncode({...out, ...extra});
  }

  /// The honest v1 gap error for a tool without a GitLab sync surface.
  String _glGap(String tool) =>
      _err('$tool is not available on the GitLab route in v1 (no GitLab sync '
          'surface for it yet) — see the gh-339 tiering notes');

  String _err(String message) => '{"error":${jsonEncode(message)}}';
}

/// Decodes a provider response; non-map JSON wraps under `value` shape
/// is avoided — the alias only decodes where a map/array is expected.
dynamic _decode(String raw) => syncTryDecode(raw) ?? <String, dynamic>{};

/// The decoded error-envelope check — the one error convention in this
/// class. Never a substring sniff (`raw.contains('"error"')`): a success
/// payload may legitimately contain the literal `"error"` token, and the
/// envelope spelling is the provider's contract, not a text shape.
bool _isErr(String raw) {
  final body = _decode(raw);
  return body is Map && body['error'] != null;
}

/// Best-effort JSON decode (null when the payload is not JSON).
dynamic _tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
