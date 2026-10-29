/// Default [ToolRegistry] wiring every integration tool catalog together.
///
/// Mirrors the Java generated `MCPToolRegistry`: the full catalog is built at
/// startup from all integration modules, so `dmtools list` can filter it by
/// the configured integrations and tool dispatch can resolve any tool name.
library;

import '../integrations/ado/ado_tools.dart';
import '../integrations/ai/ai_tools.dart';
import '../integrations/bitrise/bitrise_tools.dart';
import '../integrations/cli/cli_tools.dart';
import '../integrations/env/env_tools.dart';
import '../integrations/confluence/confluence_tools.dart';
import '../integrations/figma/figma_tools.dart';
import '../integrations/file/file_tools.dart';
import '../integrations/github/github_tools.dart';
import '../integrations/gitlab/gitlab_tools.dart';
import '../integrations/jenkins/jenkins_tools.dart';
import '../integrations/jira/jira_tools.dart';
import '../integrations/kb/kb_tools.dart';
import '../integrations/mermaid/mermaid_tools.dart';
import '../integrations/scm/scm_ci_alias_catalog.dart';
import '../integrations/sharepoint/sharepoint_tools.dart';
import '../integrations/teams/teams_tools.dart';
import '../integrations/testrail/testrail_tools.dart';
import '../integrations/xray/xray_tools.dart';
import 'tool_definition.dart';
import 'tool_registry.dart';

/// Static base catalog (all 16 concrete integration modules), constructed
/// once per isolate.
final List<ToolDefinition> _baseToolCatalog = List.unmodifiable([
  ...jiraTools(),
  ...githubTools(),
  ...gitlabTools(),
  ...confluenceTools(),
  ...aiTools(),
  ...fileTools(),
  ...cliTools(),
  ...envTools(),
  ...adoTools(),
  ...testrailTools(),
  ...bitriseTools(),
  ...jenkinsTools(),
  ...figmaTools(),
  ...teamsTools(),
  ...sharepointTools(),
  ...xrayTools(),
  ...kbTools(),
  ...mermaidTools(),
]);

/// Returns every tool definition registered in the default registry.
///
/// Catalog order mirrors the Java `MCPToolRegistry` module list; the registry
/// itself sorts tools by name for `dmtools list`.
///
/// The `scm_*`/`ci_*` alias families (gh-339) are appended when
/// `DEFAULT_SCM`/`DEFAULT_CI` resolve to a known provider — unset means
/// the family is absent from the catalog and `dmtools list` (AC1). The
/// concrete `github_*`/`gitlab_*` tools stay bit-identical either way
/// (AC4).
List<ToolDefinition> defaultToolCatalog() {
  final aliases = scmCiAliasCatalog();
  if (aliases.isEmpty) return _baseToolCatalog;
  return [..._baseToolCatalog, ...aliases];
}

final Map<String, ToolRegistry> _defaultRegistryCache = {};

/// Creates a [ToolRegistry] with every integration catalog registered.
///
/// This is the registry the CLI uses for `dmtools list` and direct tool
/// invocation: all 16 integration catalogs, unfiltered. Callers narrow the
/// output with [ToolRegistry.toolsForIntegrations] based on the resolved
/// `DMTOOLS_INTEGRATIONS` configuration.
ToolRegistry createDefaultToolRegistry() {
  final aliases = scmCiAliasCatalog();
  final key = aliases.map((t) => t.name).join(',');
  return _defaultRegistryCache.putIfAbsent(key, () {
    final registry = ToolRegistry();
    registry.registerAll(
      aliases.isEmpty ? _baseToolCatalog : [..._baseToolCatalog, ...aliases],
    );
    return registry;
  });
}
