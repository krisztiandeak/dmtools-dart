/// The vendor-neutral `scm_*` / `ci_*` alias tool catalog (gh-339).
///
/// Each alias is a first-class normalized tool (its own schema — NOT a
/// passthrough alias on a concrete tool), registered additively next to
/// the untouched `github_*` / `gitlab_*` concrete tools. Dispatch-time
/// translation to the configured provider lives in
/// `ScmCiSyncTools` (`sync_tools/scm_ci_sync_tools.dart`); this file owns
/// the catalog: names, normalized schemas, and env-driven availability.
///
/// Tiering (gh-339): v1 ships the census-derived core subset — the tools
/// the SM loop plus the most-used business calls actually touch (see
/// `tool/scm_alias_census.dart`). Second-tier breadth
/// (create/reopen PRs, files, review threads, branches creation,
/// update-branch) follows in later cards; `scm_update_branch` has no
/// concrete GitHub tool today (the SM shells out to the gh CLI), and
/// zero census call sites, so it stays out of v1.
library;

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../../mcp/tool_definition.dart';
import '../../mcp/tool_param.dart';

/// Registry integration tag of the `scm_*` family.
const String scmIntegration = 'scm';

/// Registry integration tag of the `ci_*` family.
const String ciIntegration = 'ci';

/// `DEFAULT_SCM` values that enable the `scm_*` family → the provider
/// they route to.
const Map<String, String> kScmProviders = {
  'github': 'github',
  'gitlab': 'gitlab',
};

/// `DEFAULT_CI` values that enable the `ci_*` family → the provider they
/// route to. `actions` is GitHub Actions.
const Map<String, String> kCiProviders = {
  'actions': 'github',
  'gitlab-ci': 'gitlab',
};

/// Resolves a `DEFAULT_SCM`-style value to a provider, `null` when
/// unset or unknown (trimmed + lowercased like the tracker env reads).
String? resolveScmProvider(String? raw) => _provider(kScmProviders, raw);

/// Resolves a `DEFAULT_CI`-style value to a provider, `null` when unset
/// or unknown.
String? resolveCiProvider(String? raw) => _provider(kCiProviders, raw);

String? _provider(Map<String, String> table, String? raw) {
  if (raw == null) return null;
  final value = raw.trim().toLowerCase();
  return value.isEmpty ? null : table[value];
}

/// The v1 `scm_*` alias names (census-derived core subset).
const List<String> scmAliasToolNames = [
  'scm_add_labels',
  'scm_add_pr_comment',
  'scm_approve',
  'scm_close_issue',
  'scm_create_comment',
  'scm_get_diff',
  'scm_get_issue',
  'scm_get_pr',
  'scm_get_pr_comments',
  'scm_get_reviews',
  'scm_list_branches',
  'scm_list_prs',
  'scm_merge_pr',
  'scm_remove_label',
  'scm_search_issues',
];

/// The v1 `ci_*` alias names.
const List<String> ciAliasToolNames = [
  'ci_get_merge_state',
  'ci_get_verdict',
  'ci_list_runs',
  'ci_trigger_workflow',
];

/// The `scm_*` tool definitions — normalized data-plane schemas.
List<ToolDefinition> scmAliasTools() => [
      ..._scmPrCoreTools(),
      ..._scmLabelTools(),
      ..._scmIssueTools(),
      ..._scmBranchTools(),
    ];

/// PR lifecycle: list/get/merge/diff.
List<ToolDefinition> _scmPrCoreTools() => [
      _scm(
        'scm_list_prs',
        'List pull requests / merge requests. State filter is the '
            'normalized enum: open (default), closed, merged, all.',
        [
          _workspace(),
          _repository(),
          ToolParam(
            name: 'state',
            description: 'Normalized state filter: open, closed, merged, all',
            required: false,
          ),
        ],
      ),
      _scm(
        'scm_get_pr',
        'Fetch one pull request / merge request (provider PR payload).',
        [_workspace(), _repository(), _pr()],
      ),
      _scm(
        'scm_merge_pr',
        'Merge a pull request / merge request. Merge method per provider '
            'config (GitHub: mergeMethod merge|squash|rebase).',
        [
          _workspace(),
          _repository(),
          _pr(),
          ToolParam(
            name: 'mergeMethod',
            description: 'merge | squash | rebase (GitHub)',
            required: false,
          ),
          ToolParam(
            name: 'commitTitle',
            description: 'Override the merge commit title (GitHub)',
            required: false,
          ),
          ToolParam(
            name: 'commitMessage',
            description: 'Override the merge commit message (GitHub)',
            required: false,
          ),
        ],
      ),
      _scm(
        'scm_get_diff',
        'Raw unified diff text of a pull request / merge request.',
        [_workspace(), _repository(), _pr()],
      ),
    ];

/// Labels + PR comments.
List<ToolDefinition> _scmLabelTools() => [
      _scm(
        'scm_add_labels',
        'Add labels to a PR/MR or issue. Labels are plain strings.',
        [
          _workspace(required: false),
          _repository(required: false),
          _pr(),
          ToolParam(
              name: 'labels', description: 'Labels to add', type: 'array'),
        ],
      ),
      _scm(
        'scm_remove_label',
        'Remove one label from a PR/MR or issue (absent label is a no-op '
            'on GitLab-shaped providers).',
        [
          _workspace(required: false),
          _repository(required: false),
          _pr(),
          ToolParam(name: 'label', description: 'The label to remove'),
        ],
      ),
      _scm(
        'scm_add_pr_comment',
        'Comment on a pull request / merge request.',
        [_workspace(), _repository(), _pr(), _text()],
      ),
      _scm(
        'scm_get_pr_comments',
        'List comments of a pull request / merge request.',
        [_workspace(), _repository(), _pr()],
      ),
    ];

/// The issue area: comment/fetch/search/close.
List<ToolDefinition> _scmIssueTools() => [
      _scm(
        'scm_create_comment',
        'Comment on an issue (the SM issue-carrier channel). GitLab: rides '
            'the MR-note shape — `issue` is the MR iid (the SM state '
            'carrier), not a GitLab issue number (the iid namespaces are '
            'separate).',
        [
          _workspace(required: false),
          _repository(required: false),
          ToolParam(
              name: 'issue', description: 'Issue number (GitLab: MR iid)'),
          ToolParam(name: 'body', description: 'Comment body'),
        ],
      ),
      _scm(
        'scm_get_issue',
        'Fetch one issue by number.',
        [
          _workspace(required: false),
          _repository(required: false),
          ToolParam(name: 'issue', description: 'Issue number'),
        ],
      ),
      _scm(
        'scm_search_issues',
        'Search issues (GitHub search syntax; scoped to the configured '
            'repository when the query has no repo: qualifier).',
        [
          _workspace(required: false),
          _repository(required: false),
          ToolParam(name: 'query', description: 'Search query'),
        ],
      ),
      _scm(
        'scm_close_issue',
        'Close an issue (SM close-on-merge finishing move).',
        [
          _workspace(),
          _repository(),
          ToolParam(name: 'issue', description: 'Issue number'),
        ],
      ),
    ];

/// Branches, reviews and approvals.
List<ToolDefinition> _scmBranchTools() => [
      _scm(
        'scm_list_branches',
        'List repository branches (name + head sha).',
        [_workspace(), _repository()],
      ),
      _scm(
        'scm_get_reviews',
        'List reviews / approvals of a pull request / merge request.',
        [_workspace(), _repository(), _pr()],
      ),
      _scm(
        'scm_approve',
        'Approve a pull request / merge request.',
        [
          _workspace(),
          _repository(),
          _pr(),
          ToolParam(
            name: 'body',
            description: 'Optional approval summary text',
            required: false,
          ),
        ],
      ),
    ];

/// The `ci_*` tool definitions — normalized control-plane schemas with
/// semantic normalization (the verdict / merge-state enums), NOT a
/// passthrough.
List<ToolDefinition> ciAliasTools() => [
      ..._ciRunTools(),
      ..._ciVerdictTools(),
    ];

/// Run handling: trigger + list.
List<ToolDefinition> _ciRunTools() => [
      _ci(
        'ci_trigger_workflow',
        'Trigger a CI run (fire-and-return run handle). `inputs` is a flat '
            'string map (object or JSON string); non-string values are '
            'stringified at the alias boundary.',
        [
          _workspace(),
          _repository(),
          ToolParam(name: 'workflow', description: 'Workflow file / id'),
          ToolParam(
            name: 'ref',
            description: 'Branch or tag ref (default: main)',
            required: false,
          ),
          ToolParam(
            name: 'inputs',
            description: 'Flat string map of run inputs (object or JSON)',
            required: false,
          ),
        ],
      ),
      _ci(
        'ci_list_runs',
        'List CI runs (newest first). Each run: runId, status, verdict '
            '(the 4-value enum), sha, url, startedAt, event.',
        [
          _workspace(),
          _repository(),
          ToolParam(
            name: 'workflow',
            description: 'Workflow file / id filter',
            required: false,
          ),
          ToolParam(
            name: 'ref',
            description: 'Branch or tag ref filter',
            required: false,
          ),
          ToolParam(
            name: 'status',
            description: 'Provider run-status filter',
            required: false,
          ),
          ToolParam(
            name: 'limit',
            description: 'Max runs to return (default 30)',
            required: false,
          ),
        ],
      ),
    ];

/// Semantic reads: verdict + merge state.
List<ToolDefinition> _ciVerdictTools() => [
      _ci(
        'ci_get_verdict',
        'THE CI verdict for a run: pass | fail | pending | none. Call with '
            '`runId`, or probe a head with `sha` (plus optional `workflow` '
            'for the stale-verdict fallback the SM uses).',
        [
          _workspace(),
          _repository(),
          ToolParam(
            name: 'runId',
            description: 'Run handle (from ci_trigger_workflow/ci_list_runs)',
            required: false,
          ),
          ToolParam(
            name: 'sha',
            description: 'Head commit sha to probe',
            required: false,
          ),
          ToolParam(
            name: 'workflow',
            description: 'Workflow file for the sha probe fallback',
            required: false,
          ),
          ToolParam(
            name: 'pr',
            description: 'PR/MR number (GitLab pipelines-of-MR probe)',
            required: false,
          ),
        ],
      ),
      _ci(
        'ci_get_merge_state',
        'Mergeability of a PR/MR in the enum the SM speaks: CLEAN | BEHIND '
            '| DIRTY | BLOCKED | UNKNOWN. Both vendors\' checks-settling '
            'transients return BLOCKED + reason.',
        [_workspace(), _repository(), _pr()],
      ),
    ];

/// The whole alias catalog for the given (or configured) providers.
///
/// The `scm_*` family registers only when [defaultScm] (or
/// `PropertyReader.getDefaultScm`) resolves to a known provider; the
/// `ci_*` family follows [defaultCi] / `DEFAULT_CI` independently.
List<ToolDefinition> scmCiAliasCatalog(
    {String? defaultScm, String? defaultCi}) {
  final reader = PropertyReader();
  final scm = resolveScmProvider(defaultScm ?? reader.getDefaultScm());
  final ci = resolveCiProvider(defaultCi ?? reader.getDefaultCi());
  return [
    if (scm != null) ...scmAliasTools(),
    if (ci != null) ...ciAliasTools(),
  ];
}

ToolDefinition _scm(String name, String description, List<ToolParam> params) =>
    ToolDefinition(
      name: name,
      description: description,
      integration: scmIntegration,
      params: params,
    );

ToolDefinition _ci(String name, String description, List<ToolParam> params) =>
    ToolDefinition(
      name: name,
      description: description,
      integration: ciIntegration,
      params: params,
    );

ToolParam _workspace({bool required = true}) => ToolParam(
      name: 'workspace',
      description: 'Repository owner / namespace (config default when '
          'omitted where the provider supports it)',
      required: required,
    );

ToolParam _repository({bool required = true}) => ToolParam(
      name: 'repository',
      description: 'Repository name (config default when omitted where the '
          'provider supports it)',
      required: required,
    );

ToolParam _pr() => ToolParam(name: 'pr', description: 'PR / MR number');

ToolParam _text() => ToolParam(name: 'text', description: 'Comment text');
