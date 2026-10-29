/// Teammate job — Dart port of Java `Teammate` (`teammate/Teammate.java`),
/// ticket-driven mode only: the job selects tickets by `inputJql`, prepares
/// the `input/<ticketKey>/` context folder, and delegates each ticket to
/// [CliAgent] under the hood.
///
/// Scope note (port decision): Java Teammate's internal AI-processing branch
/// (`ContextOrchestrator` + `RequestDecompositionAgent` + LLM providers) is
/// intentionally not ported — the dmtools-agents Teammate configs run with
/// `skipAIProcessing: true` and let the CLI agent do the AI work via
/// `cliCommands`. Everything the configs actually use is ported:
/// ticket selection, the CI-run trace comment, and the full CliAgent
/// lifecycle (preJSAction → input folder → preCliJSAction → cliCommands →
/// postJSAction → reset).
library;

import '../config/property_reader.dart';
import '../js/job_runner.dart';
import '../js/sync_tool_dispatcher.dart';
import 'dart:convert';
import 'dart:io';

import 'cli_agent.dart';
import 'github_ticket_source.dart';
import 'github_tracker_client.dart';
import 'cli_agent_params.dart';
import 'input_context_config.dart';
import 'ticket_smart_sources.dart';

/// Fetches the hydrated tickets for [inputJql]: each ticket is a raw tracker
/// JSON map with at least `key` and `fields` (comments included).
typedef TeammateTicketSource = Future<List<Map<String, dynamic>>> Function(
    String inputJql);

/// Posts a trace/status comment to [key] (Jira comment parity).
typedef TeammateCommentPoster = Future<void> Function(String key, String body);

/// Ticket-driven Teammate job.
///
/// Runs one [CliAgent] per ticket resolved from `params.inputJql`:
/// - empty/missing `inputJql` → no-op success (Java: "skipping ticket
///   processing");
/// - each ticket becomes the [CliAgentParams] context id, so the input
///   folder is `input/<ticketKey>/`;
/// - `ciRunUrl` + enabled comments post the Java trace comment
///   (`[<agentId>] Processing started. CI Run: <url>`).
class TeammateJob {
  /// Creates the job from the raw `params` block of a Teammate config.
  ///
  /// - [ticketSource] — ticket lookup; defaults to the Jira sync tools
  ///   (search → get_ticket → get_comments hydration).
  /// - [commentPoster] — comment sink for the CI-run trace comment; defaults
  ///   to `jira_post_comment`.
  TeammateJob({
    required this.params,
    this.workingDirectory,
    this.ticketSource,
    this.commentPoster,
    this.propertyReader,
    this.jsRunner,
  });

  /// Raw params from the job config (the `params` block).
  final Map<String, dynamic> params;

  /// Working-directory override forwarded to each [CliAgent].
  final String? workingDirectory;

  /// Ticket lookup override (tests inject fakes; default: Jira sync tools).
  final TeammateTicketSource? ticketSource;

  /// Comment sink override (tests inject fakes; default: `jira_post_comment`).
  final TeammateCommentPoster? commentPoster;

  /// Property reader forwarded to each [CliAgent].
  final PropertyReader? propertyReader;

  /// JS runner forwarded to each [CliAgent].
  final JsJobRunner? jsRunner;

  /// Runs the job and returns `{'success': …, 'results': […]}` where each
  /// result item carries `ticket`, plus the [CliAgent] result fields.
  Future<Map<String, dynamic>> run() async {
    final inputConfig = InputContextConfig.fromJson(params);
    final inputJql =
        ((params['inputJql'] as String?) ?? inputConfig.jql ?? '').trim();
    if (inputJql.isEmpty) {
      final explicitKey = inputConfig.ticket;
      if (explicitKey != null && explicitKey.isNotEmpty) {
        final fetched = TicketSmartSources(propertyReader ?? PropertyReader())
            .fetchTicketByKey(explicitKey);
        return _runTickets([
          {'key': explicitKey, 'fields': <String, dynamic>{}, ...?fetched},
        ]);
      }
      // Issues-driven pass-through: the caller prepared `input/ticket.md`
      // (e.g. the ai-teammate workflow wrote the issue body). Run
      // the config AS-IS through one [CliAgent] with a synthetic ticket —
      // the canonical `input/<contextId>/` context is built from it.
      // Without a prepared input this is Java parity: "skipping ticket
      // processing" → empty result list.
      final prepared = _preparedInputTicket();
      if (prepared == null) {
        return const {'success': true, 'results': []};
      }
      _consumePreparedInput();
      return _runSingle(prepared);
    }
    _sourceIsGithub = looksLikeGithubQuery(inputJql);
    final source = ticketSource ??
        (_sourceIsGithub ? githubIssueTicketSource : jiraTicketSource);
    final tickets = await source(inputJql);
    return _runTickets(tickets);
  }

  /// Runs every resolved ticket through a loud [CliAgent], then applies
  /// the Java Teammate end-of-run hard stop (epam/dm.ai#580): all matched
  /// tickets are attempted, but if any `preCliJSAction` threw an uncaught
  /// exception the overall job fails so the CI step actually goes red.
  Future<Map<String, dynamic>> _runTickets(
      List<Map<String, dynamic>> tickets) async {
    final results = <Map<String, dynamic>>[];
    final unexpectedSetupFailures = <String>[];
    for (final ticket in tickets) {
      final outcome = await _runTicket(ticket);
      if (outcome.postJsError != null) {
        // #585 parity: Java's RuntimeException propagates out of
        // runJobImpl — the job fails immediately and the remaining
        // tickets are never attempted.
        results.add(outcome.result);
        return {
          'success': false,
          'error': outcome.postJsError,
          'results': results,
        };
      }
      if (outcome.key != null && outcome.setupThrew) {
        unexpectedSetupFailures.add(outcome.key!);
      }
      results.add(outcome.result);
    }
    if (unexpectedSetupFailures.isNotEmpty) {
      return {
        'success': false,
        'error': _abortMessage(unexpectedSetupFailures),
        'results': results,
      };
    }
    final ok = results.isNotEmpty && results.every((r) => r['success'] == true);
    return {'success': ok, 'results': results};
  }

  /// Runs one ticket: trace comment, then a loud [CliAgent] (Java
  /// Teammate epam/dm.ai#580/#585 parity — uncaught JS-action exceptions
  /// fail the job visibly instead of being swallowed into warnings).
  Future<_TicketOutcome> _runTicket(Map<String, dynamic> ticket) async {
    final key = _ticketKey(ticket);
    if (key == null || key.isEmpty) {
      return _TicketOutcome.resultOnly({
        'ticket': null,
        'success': false,
        'error': 'search result without a ticket key',
      });
    }
    await _postTraceComment(key);
    final agent = CliAgent(
      params: _paramsForTicket(key),
      workingDirectory: workingDirectory,
      ticketData: ticket,
      propertyReader: propertyReader,
      jsRunner: jsRunner,
      failOnJsActionErrors: true,
    );
    final result = await agent.run();
    return _TicketOutcome(
      key: key,
      result: {'ticket': key, 'success': result['success'] == true, ...result},
      setupThrew: result['unexpectedSetupFailure'] == true,
      postJsError: result['postJsActionUncaught'] == true
          ? result['error'] as String?
          : null,
    );
  }

  /// Runs one [CliAgent] against a single prepared [ticket] (no per-ticket
  /// contextId override and no Jira trace comment — there is no tracker).
  Future<Map<String, dynamic>> _runSingle(Map<String, dynamic> ticket) async {
    final agent = CliAgent(
      params: CliAgentParams.fromJson(params),
      workingDirectory: workingDirectory,
      ticketData: ticket,
      propertyReader: propertyReader,
      jsRunner: jsRunner,
      failOnJsActionErrors: true,
    );
    final result = await agent.run();
    final key = _ticketKey(ticket);
    if (result['postJsActionUncaught'] == true) {
      return {'success': false, 'error': result['error'], 'results': []};
    }
    if (result['unexpectedSetupFailure'] == true) {
      // Java Teammate #580 parity: a swallowed uncaught setup exception
      // fails the job — the CI step must go red.
      return {
        'success': false,
        'error': _abortMessage([key ?? 'unknown']),
        'results': [],
      };
    }
    return {
      'success': result['success'] == true,
      'results': [
        {'ticket': key, 'success': result['success'] == true, ...result}
      ],
    };
  }

  /// Java Teammate end-of-run hard-stop message (epam/dm.ai#580), listing
  /// every ticket whose `preCliJSAction` threw an uncaught exception.
  String _abortMessage(List<String> tickets) =>
      'Teammate job aborted: preCliJSAction threw an unexpected error '
      '(e.g. a git command failure) for ticket(s) $tickets — see the '
      'warnings logged above for the underlying error(s).';

  /// The caller-provided ticket at `<workDir>/input/ticket.md`, mapped to
  /// the raw-tracker shape [CliAgent] understands (first line → summary,
  /// the rest → description), or null when absent/blank.
  Map<String, dynamic>? _preparedInputTicket() {
    final base = workingDirectory ?? Directory.current.path;
    final file = File('$base/input/ticket.md');
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync().trim();
    if (content.isEmpty) return null;
    final newline = content.indexOf('\n');
    final summary =
        newline < 0 ? content : content.substring(0, newline).trim();
    final description =
        newline < 0 ? '' : content.substring(newline + 1).trim();
    return {
      'key': _contextId(),
      'fields': {'summary': summary, 'description': description},
    };
  }

  /// Deletes the consumed bootstrap `input/ticket.md`.
  ///
  /// The ticket now lives in memory and the canonical `input/<contextId>/`
  /// context is built from it by [CliAgent]; the root copy must not
  /// survive the consumption — left in the tree it (a) duplicates the
  /// ticket body next to the canonical context and (b) leaks an
  /// uncommitted runtime file into the agent's git flow: the branch-setup
  /// stash pops it onto the tracked version with conflict markers that
  /// the agent's final `git add -A` then commits (seen on fa gh-671:
  /// `input/ticket.md` and `input/gh-671/ticket.md` both carried
  /// `<<<<<<< Updated upstream` blocks). Best-effort — a locked file
  /// must not fail the job.
  void _consumePreparedInput() {
    final base = workingDirectory ?? Directory.current.path;
    final file = File('$base/input/ticket.md');
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } catch (_) {
      // Best-effort: never fail the job over cleanup.
    }
  }

  /// The config's `metadata.contextId`, falling back to CliAgent's own
  /// `'cli-agent'` default.
  String _contextId() {
    final md = params['metadata'];
    if (md is Map) {
      final contextId = md['contextId'];
      if (contextId is String && contextId.isNotEmpty) return contextId;
    }
    return 'cli-agent';
  }

  /// Per-ticket [CliAgentParams]: the shared config with `metadata.contextId`
  /// pinned to the ticket key (Java Teammate's input folder is
  /// `input/<ticketKey>/`).
  CliAgentParams _paramsForTicket(String key) {
    final p = CliAgentParams.fromJson(params);
    p.metadata = {...?p.metadata, 'contextId': key};
    return p;
  }

  /// Posts the CI-run trace comment when `ciRunUrl` is set and comments are
  /// enabled (`alwaysPostComments` or non-`none` `outputType`).
  ///
  /// The default sink follows the ticket source: GitHub-sourced tickets
  /// post through [GithubTrackerClient] (Java `trackerClient.postComment`
  /// with `DEFAULT_TRACKER=github`), everything else through
  /// `jira_post_comment`. A failed trace comment never fails the job —
  /// Java catches, warns, and continues.
  Future<void> _postTraceComment(String key) async {
    final ciRunUrl = (params['ciRunUrl'] as String?)?.trim() ?? '';
    if (ciRunUrl.isEmpty || !_shouldPostComments) return;
    final poster = commentPoster ??
        (_sourceIsGithub ? _githubCommentPoster : _jiraCommentPoster);
    try {
      await poster(
          key,
          '${_agentNamePrefix()}'
          'Processing started. CI Run: $ciRunUrl');
    } catch (_) {
      // Advisory comment only — processing continues (Java parity).
    }
  }

  /// Java `AbstractJob.shouldPostComments`: `alwaysPostComments` wins, else
  /// comments are on when `outputType` is not `none`.
  bool get _shouldPostComments {
    if (params['alwaysPostComments'] == true) return true;
    final outputType = (params['outputType'] as String?)?.trim().toLowerCase();
    return outputType != null && outputType.isNotEmpty && outputType != 'none';
  }

  /// Whether the resolved ticket source is the GitHub-issues one — trace
  /// comments are Jira-specific and are skipped in that mode.
  bool _sourceIsGithub = false;

  /// Java `AbstractJob.agentNamePrefix`: `[<contextId>|<agentId>] ` or `''`.
  String _agentNamePrefix() {
    final md = params['metadata'];
    if (md is Map) {
      final contextId = md['contextId'];
      if (contextId is String && contextId.isNotEmpty) return '[$contextId] ';
      final agentId = md['agentId'];
      if (agentId is String && agentId.isNotEmpty) return '[$agentId] ';
    }
    return '';
  }

  /// Extracts the ticket key from a raw search/get result map.
  String? _ticketKey(Map<String, dynamic> ticket) {
    final key = ticket['key'];
    return key is String ? key : null;
  }
}

/// Default [TeammateTicketSource]: Jira sync tools — `jira_search_by_jql`
/// for the keys, then `jira_get_ticket` + `jira_get_comments` hydration so
/// the input folder carries the full ticket text and comments
/// (Java `TicketContext.prepareContext` parity).
Future<List<Map<String, dynamic>>> jiraTicketSource(
  String inputJql, {
  String? Function(String toolName, Map<String, dynamic> args)? execute,
}) async {
  final exec = execute ?? SyncToolDispatcher(PropertyReader()).execute;
  final raw = exec('jira_search_by_jql', {
    'jql': inputJql,
    'fields': ['summary', 'status', 'priority', 'labels'],
  });
  final keys = extractTicketKeys(raw);
  return [
    for (final key in keys)
      hydrateTicket(
        rawTicket: exec('jira_get_ticket', {
          'key': key,
          'fields': ['*navigable', 'attachment'],
        }),
        rawComments: exec('jira_get_comments', {'key': key}),
        key: key,
      ),
  ];
}

Future<void> _jiraCommentPoster(String key, String body) async {
  final dispatcher = SyncToolDispatcher(PropertyReader());
  dispatcher.execute('jira_post_comment', {'key': key, 'comment': body});
}

/// Default comment sink for GitHub-sourced tickets: the write-side
/// GitHub issues tracker client (Java `GitHubTrackerClient.postComment`).
Future<void> _githubCommentPoster(String key, String body) async {
  GithubTrackerClient().postComment(key, body);
}

/// Merges a raw ticket payload and a raw comments payload into one ticket
/// map whose `fields.comments` carries the comments (the shape
/// `TicketInputContextBuilder` consumes). Falls back to `{'key': key}`
/// when [rawTicket] does not decode.
Map<String, dynamic> hydrateTicket({
  String? rawTicket,
  String? rawComments,
  required String key,
}) {
  final ticket = _decodeMap(rawTicket) ?? {'key': key};
  final comments = decodeCommentsPayload(rawComments);
  if (comments == null && ticket['fields'] is! Map) return ticket;
  final fields = Map<String, dynamic>.from(
    ticket['fields'] as Map<String, dynamic>? ?? const {},
  );
  if (comments != null) fields['comment'] = {'comments': comments};
  ticket['fields'] = fields;
  return ticket;
}

/// Decodes a search-result payload into ticket keys. Accepts both a bare
/// issues array (`[{key, …}, …]`) and the paged map (`{issues: […]}`) —
/// the two shapes Jira search returns across API versions.
List<String> extractTicketKeys(String? raw) {
  final decoded = decodeJsonPayload(raw);
  if (decoded is List) {
    return decoded.map(_mapKey).whereType<String>().toList();
  }
  if (decoded is Map) {
    final issues = decoded['issues'];
    if (issues is List) return issues.map(_mapKey).whereType<String>().toList();
  }
  return const [];
}

/// Returns the `key` of [value] when it is a map with a string key.
String? _mapKey(dynamic value) {
  if (value is Map<String, dynamic>) return value['key'] as String?;
  if (value is Map) return value['key'] as String?;
  return null;
}

/// Decodes a comments payload: either `{comments: […]}` (the raw Jira
/// issue-comment response) or a bare array.
List<dynamic>? decodeCommentsPayload(String? raw) {
  final decoded = decodeJsonPayload(raw);
  if (decoded is Map && decoded['comments'] is List) {
    return decoded['comments'] as List;
  }
  if (decoded is List) return decoded;
  return null;
}

/// Decodes a JSON payload string, returning `null` for empty or malformed
/// input (network bodies are best-effort — Java treats undecodable bodies
/// the same way by failing the search, which the dispatcher surfaces).
dynamic decodeJsonPayload(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

Map<String, dynamic>? _decodeMap(String? raw) {
  final decoded = decodeJsonPayload(raw);
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return decoded.cast<String, dynamic>();
  return null;
}

/// Per-ticket outcome of [_runTicket] — the result item plus the two
/// loud-mode failure signals Teammate's job-level semantics act on
/// (epam/dm.ai#580 unexpected setup failure, #585 postJSAction uncaught).
class _TicketOutcome {
  _TicketOutcome({
    required this.result,
    this.key,
    this.setupThrew = false,
    this.postJsError,
  });

  _TicketOutcome.resultOnly(this.result)
      : key = null,
        setupThrew = false,
        postJsError = null;

  /// The per-ticket result item merged into the job's `results` list.
  final Map<String, dynamic> result;

  /// The ticket key, or null for a keyless search result.
  final String? key;

  /// The ticket's `preCliJSAction` crashed with an uncaught exception.
  final bool setupThrew;

  /// The ticket's `postJSAction` crashed with an uncaught exception —
  /// the job must fail immediately (Java's RuntimeException parity).
  final String? postJsError;
}
