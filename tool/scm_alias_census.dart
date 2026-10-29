/// Builds the `scm_*`/`ci_*` alias usage census (gh-339 AC2).
///
/// Scans the dmtools-agents JS tree (`agents/js`) for call sites of the
/// `github_*` tools covered by the v1 core alias subset and emits one
/// fixture line per site: `<github_tool> <alias> <path>:<line>`.
///
/// The gate test (`test/scm_ci_gates_test.dart`) recomputes the census
/// live from `agents/js` and asserts every census tool is covered by a
/// registered alias — no committed snapshot (agents/ floats on main).
///
/// The scan is a plain call-shaped regex (`\bgithub_[a-z_]+\s*\(`) over
/// `agents/js/**.js` excluding `js/unit-tests/` (harness stubs, not
/// production call sites). Comment *mentions* without a call shape do
/// not count; string-embedded worker sources do (they execute).
library;

import 'dart:io';

/// The v1 core mapping: `github_*` tool → covering `scm_*`/`ci_*` alias.
///
/// Derived from the gh-339 capability table intersected with the real
/// call-site census over `agents/js` — tools with zero call sites
/// (create/reopen/update PR, PR files, branch creation, update-branch)
/// stay out of v1, as do second-tier surfaces (threads, releases, logs).
const Map<String, String> kCensusToolAlias = {
  'github_add_labels': 'scm_add_labels',
  'github_add_pr_comment': 'scm_add_pr_comment',
  'github_close_issue': 'scm_close_issue',
  'github_create_comment': 'scm_create_comment',
  'github_get_commit_check_runs': 'ci_get_verdict',
  'github_get_issue': 'scm_get_issue',
  'github_get_pr': 'scm_get_pr',
  'github_get_pr_comments': 'scm_get_pr_comments',
  'github_get_pr_diff_text': 'scm_get_diff',
  'github_list_branches': 'scm_list_branches',
  'github_list_pr_reviews': 'scm_get_reviews',
  'github_list_prs': 'scm_list_prs',
  'github_list_workflow_runs': 'ci_list_runs',
  'github_merge_pr': 'scm_merge_pr',
  'github_merge_pull_request': 'scm_merge_pr',
  'github_remove_label': 'scm_remove_label',
  'github_search_issues': 'scm_search_issues',
  'github_submit_pr_review': 'scm_approve',
  'github_trigger_workflow': 'ci_trigger_workflow',
};

/// Call-shaped site pattern (identifier followed by an opening paren).
final RegExp callSitePattern = RegExp(r'\b(github_[a-z_]+)\s*\(');

/// Computes the census lines for [root] (default: `agents/js`), sorted,
/// paths repo-relative.
List<String> computeCensus({String root = 'agents/js'}) {
  final lines = <String>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return lines;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.js')) continue;
    final normalized = entity.path.replaceAll('\\', '/');
    if (normalized.contains('js/unit-tests/')) continue;
    var lineNo = 0;
    for (final line in entity.readAsLinesSync()) {
      lineNo++;
      for (final match in callSitePattern.allMatches(line)) {
        final tool = match.group(1)!;
        final alias = kCensusToolAlias[tool];
        if (alias == null) continue;
        lines.add('$tool $alias $normalized:$lineNo');
      }
    }
  }
  return lines..sort();
}
