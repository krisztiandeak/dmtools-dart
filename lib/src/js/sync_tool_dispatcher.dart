/// Dispatches MCP tool calls using synchronous HTTP (curl subprocess).
///
/// This is the `executeToolViaJava` implementation for real agent scripts.
/// Tool calls route by name prefix to the per-integration sync-tools classes
/// in `lib/src/js/sync_tools/` — each owns its config resolver and request
/// builders, mirrors the wire format of the corresponding async client and
/// the Java integration class (spec), and reports errors as JSON:
///
/// - Jira: [JiraSyncTools] — tickets, comments, labels, transitions, links,
///   attachments, ticket creation
/// - GitHub: [GitHubSyncTools] — PRs (comments/labels/threads/diff/merge),
///   workflow runs, draft releases and asset uploads
/// - GitLab: [GitLabSyncTools] — MRs (comments/threads/labels/diff/merge),
///   pipelines, releases and asset transfers
/// - Confluence: [ConfluenceSyncTools] — search/pages/children plus the
///   Markdown→storage directory sync engine
/// - ADO: [AdoSyncTools] — work items, PRs, pipelines
/// - Bitrise: [BitriseSyncTools] — builds and artifacts (write-guarded)
/// - Jenkins: [JenkinsSyncTools] — job info and build logs
/// - AI: [AiSyncTools] — per-provider `<provider>_ai_chat` globals
///
/// File-system (`file_*`) and CLI (`cli_*`) tools are not HTTP-based; they
/// delegate to the host bridge's direct dispatch via [nonHttpHandler].
library;

import '../config/property_reader.dart';
import 'sync_tools/ado_sync_tools.dart';
import 'sync_tools/ai_sync_tools.dart';
import 'sync_tools/bitrise_sync_tools.dart';
import 'sync_tools/confluence_sync_tools.dart';
import 'sync_tools/figma_sync_tools.dart';
import 'sync_tools/github_sync_tools.dart';
import 'sync_tools/gitlab_sync_tools.dart';
import 'sync_tools/jenkins_sync_tools.dart';
import 'sync_tools/jira_sync_tools.dart';
import 'sync_tools/scm_ci_sync_tools.dart';
import '../integrations/env/env_tools.dart';

/// Executor for a non-HTTP (file/CLI) tool call: receives the raw [toolName]
/// and [args], returns the JSON result string.
typedef SyncNonHttpHandler = String Function(
  String toolName,
  Map<String, dynamic> args,
);

/// Per-integration executor resolved by tool-name prefix.
typedef _PrefixDispatch = String Function(
  String toolName,
  Map<String, dynamic> args,
);

/// Routes tool calls to integration clients over synchronous HTTP.
///
/// Non-HTTP tools (file-system, CLI) are delegated to [nonHttpHandler] when
/// provided; otherwise `execute` returns `null` for them.
class SyncToolDispatcher {
  final PropertyReader _reader;
  final SyncNonHttpHandler? _nonHttpHandler;

  /// Creates a dispatcher reading integration config from [reader].
  ///
  /// The optional [nonHttpHandler] receives `file_*` and `cli_*` tool calls
  /// so the dispatcher can serve as a single routing entry point.
  SyncToolDispatcher(this._reader, {SyncNonHttpHandler? nonHttpHandler})
      : _nonHttpHandler = nonHttpHandler;

  /// Confluence tools; built lazily on the first `confluence_*` dispatch.
  late final ConfluenceSyncTools _confluence = ConfluenceSyncTools(_reader);

  /// Bitrise tools; built lazily on the first `bitrise_*` dispatch.
  late final BitriseSyncTools _bitrise = BitriseSyncTools(_reader);

  /// Jenkins tools; built lazily on the first `jenkins_*` dispatch.
  late final JenkinsSyncTools _jenkins = JenkinsSyncTools(_reader);

  /// Figma tools; built lazily on the first `figma_*` dispatch.
  late final FigmaSyncTools _figma = FigmaSyncTools(_reader);

  /// Per-provider AI chat tools; built lazily on first `<provider>_ai_chat`.
  late final AiSyncTools _ai = AiSyncTools(_reader);

  /// The vendor-neutral `scm_*`/`ci_*` alias surface (gh-339). One
  /// instance per dispatcher: the DEFAULT_SCM/DEFAULT_CI routing is
  /// resolved once and frozen for the process (an alias never changes
  /// routing mid-process).
  late final ScmCiSyncTools _scmCi = ScmCiSyncTools(reader: _reader);

  /// Prefix routes to the self-contained sync-tools classes.
  late final List<MapEntry<String, _PrefixDispatch>> _routes = [
    MapEntry('jira_', JiraSyncTools().dispatch),
    MapEntry('github_', _viaHandlers('GitHub', _githubHandlers)),
    MapEntry('gitlab_', _viaHandlers('GitLab', _gitlabHandlers)),
    MapEntry('confluence_', _confluence.dispatch),
    MapEntry('ado_', _viaHandlers('ADO', _adoHandlers)),
    MapEntry('bitrise_', _bitrise.dispatch),
    MapEntry('jenkins_', _jenkins.dispatch),
    MapEntry('figma_', _figma.dispatch),
    MapEntry('scm_', _viaHandlers('scm', _scmCi.handlers)),
    MapEntry('env_', _viaHandlers('env', _envTools.handlers)),
    MapEntry('ci_', _viaHandlers('ci', _scmCi.handlers)),
  ];

  /// Secret-aware configuration reads (`env_get` / `env_list`).
  final EnvTools _envTools = EnvTools();

  /// GitHub executors, mirroring [GitHubSyncTools.handlers].
  late final _githubHandlers = const GitHubSyncTools().handlers;

  /// GitLab executors, mirroring [GitLabSyncTools.handlers].
  late final _gitlabHandlers = const GitLabSyncTools().handlers;

  /// ADO executors, mirroring [AdoSyncTools.handlers].
  late final _adoHandlers = const AdoSyncTools().handlers;

  /// Executes a tool call. Returns a JSON result string, or `null` when no
  /// integration matches the tool name and no [nonHttpHandler] is set.
  String? execute(String toolName, Map<String, dynamic> args) {
    for (final route in _routes) {
      if (toolName.startsWith(route.key)) return route.value(toolName, args);
    }
    // AI chat tools carry provider-name prefixes (gemini_, openai_, …), so
    // they are matched by exact name after the prefix routes.
    final aiFn = _ai.handlers[toolName];
    if (aiFn != null) return aiFn(args);
    // File-system and CLI tools delegate to the host bridge.
    final handler = _nonHttpHandler;
    if (handler != null) return handler(toolName, args);
    return null;
  }

  /// Adapts a handler map into a prefix dispatch that keeps the legacy
  /// `Unsupported <integration> tool` error text.
  _PrefixDispatch _viaHandlers(
    String integration,
    Map<String, String Function(Map<String, dynamic> args)> handlers,
  ) =>
      (toolName, args) {
        final fn = handlers[toolName];
        if (fn == null) {
          return '{"error":"Unsupported $integration tool: $toolName"}';
        }
        return fn(args);
      };
}
