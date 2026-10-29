/// Issue-tracker tool catalog and executor routes — Java `GitHubIssues.java`
/// (dm.ai #543) parity.
///
/// The whole issue family accepts explicit `owner`/`repo`/`number` parts, a
/// composite `key` (`owner/repo#123` or a bare number resolved against the
/// configured `SOURCE_GITHUB_WORKSPACE` / `SOURCE_GITHUB_REPOSITORY`
/// defaults), and the Java `tracker_*` alias set so GitHub can serve as the
/// tracker backend (`DEFAULT_TRACKER=github`).
part of 'github_tools.dart';

/// Comment tool: `github_create_comment`.
List<ToolDefinition> _commentTools() => [
      ToolDefinition(
        name: 'github_create_comment',
        description: 'Create a comment on a GitHub issue or pull request '
            '(PRs are issues upstream).',
        integration: 'github',
        category: 'comments',
        aliases: ['tracker_post_comment'],
        params: [
          _ghOptionalWorkspace(),
          _ghOptionalRepository(),
          _ghOptionalPrId(),
          ToolParam(
            name: 'body',
            description: 'The comment body text',
            required: true,
            aliases: ['text', 'comment'],
          ),
          _ghIssueKeyParam(
            alternative: 'workspace/repository/pullRequestId',
          ),
        ],
      ),
    ];

/// Issue tools: tracker-critical CRUD plus the search/move/assign/reopen
/// tracker layer.
List<ToolDefinition> _issueTools() => [
      ..._issueReadTools(),
      ..._issueMutationTools(),
    ];

/// Issue read/create tools: `github_get_issue`, `github_create_issue`,
/// `github_search_issues`.
List<ToolDefinition> _issueReadTools() => [
      ..._getIssueTool(),
      ..._createIssueTool(),
      ..._searchIssuesTool(),
    ];

/// `github_get_issue` — composite-key aware issue fetch.
List<ToolDefinition> _getIssueTool() => [
      ToolDefinition(
        name: 'github_get_issue',
        aliases: ['source_code_get_issue', 'tracker_get_ticket'],
        description: 'Get details of a GitHub issue including title, '
            'description, state, author, labels, assignees, and comments '
            'count.',
        integration: 'github',
        category: 'issues',
        params: [
          _ghOptionalWorkspace(),
          _ghOptionalRepository(),
          const ToolParam(
            name: 'issueNumber',
            description: 'The issue number',
            required: false,
            aliases: ['number'],
          ),
          const ToolParam(
            name: 'key',
            description: "Composite issue key 'owner/repo#123' (alternative "
                'to workspace/repository/issueNumber)',
            required: false,
          ),
        ],
      ),
    ];

/// `github_create_issue`.
List<ToolDefinition> _createIssueTool() => [
      ToolDefinition(
        name: 'github_create_issue',
        aliases: ['tracker_create_ticket'],
        description: 'Create a GitHub issue',
        integration: 'github',
        category: 'issues',
        params: [
          _ghOptionalOwner(),
          _ghOptionalRepo(),
          ToolParam(
            name: 'title',
            description: 'The title of the new issue',
            required: true,
            aliases: ['summary'],
          ),
          ToolParam(
            name: 'body',
            description: 'The issue description (markdown)',
            required: false,
            aliases: ['description'],
          ),
          const ToolParam(
            name: 'key',
            description: "Composite project key 'owner/repo' (alternative "
                'to owner/repo)',
            required: false,
            aliases: ['project'],
          ),
        ],
      ),
    ];

/// `github_search_issues`.
List<ToolDefinition> _searchIssuesTool() => [
      ToolDefinition(
        name: 'github_search_issues',
        aliases: ['tracker_search'],
        description: 'Search GitHub issues (and pull requests) with a query '
            "string. Returns a JSON object with 'items'.",
        integration: 'github',
        category: 'issues',
        params: [
          const ToolParam(
            name: 'query',
            description: "The GitHub issue search query (e.g. "
                "'repo:owner/name is:open label:bug')",
            required: true,
            aliases: ['jql', 'wiql'],
          ),
          const ToolParam(
            name: 'workspace',
            description: 'The GitHub owner/organization to scope the search '
                'to',
            required: false,
          ),
          const ToolParam(
            name: 'repository',
            description: 'The GitHub repository to scope the search to',
            required: false,
          ),
        ],
      ),
    ];

/// Issue mutation tools: close, reopen, move-to-status, assign, labels.
List<ToolDefinition> _issueMutationTools() => [
      ..._issueStateTools(),
      ..._issueAssignmentTools(),
      ..._issueLabelTools(),
    ];

/// `github_close_issue` + `github_reopen_issue`.
List<ToolDefinition> _issueStateTools() => [
      ToolDefinition(
        name: 'github_close_issue',
        description: 'Close a GitHub issue',
        integration: 'github',
        category: 'issues',
        params: _issueRefParams(),
      ),
      ToolDefinition(
        name: 'github_reopen_issue',
        description: 'Reopen a closed GitHub issue',
        integration: 'github',
        category: 'issues',
        params: _issueRefParams(),
      ),
    ];

/// `github_move_issue_to_status` + `github_assign_issue`.
List<ToolDefinition> _issueAssignmentTools() => [
      ToolDefinition(
        name: 'github_move_issue_to_status',
        aliases: ['tracker_move_to_status'],
        description: 'Move a GitHub issue to a status. '
            "'done'/'closed' close the issue, 'open'/'reopened' reopen it; "
            'any other status is applied as an issue label.',
        integration: 'github',
        category: 'issues',
        params: [
          const ToolParam(
            name: 'statusName',
            description: 'The target status name',
            required: true,
            aliases: ['state', 'status'],
          ),
          ..._issueRefParams(),
        ],
      ),
      ToolDefinition(
        name: 'github_assign_issue',
        aliases: ['tracker_assign_ticket', 'tracker_assign'],
        description: 'Assign a GitHub issue to a user',
        integration: 'github',
        category: 'issues',
        params: [
          const ToolParam(
            name: 'user',
            description: 'The assignee GitHub login',
            required: true,
            aliases: ['accountId', 'assignee', 'userName'],
          ),
          ..._issueRefParams(),
        ],
      ),
    ];

/// `github_add_labels` + `github_remove_label`.
List<ToolDefinition> _issueLabelTools() => [
      ToolDefinition(
        name: 'github_add_labels',
        aliases: ['tracker_add_label'],
        description: 'Add labels to a GitHub issue',
        integration: 'github',
        category: 'issues',
        params: [
          ..._issueRefParams(),
          ToolParam(
            name: 'labels',
            description: 'The label names to add',
            type: 'array',
            required: true,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_remove_label',
        aliases: ['tracker_remove_label'],
        description: 'Remove a label from a GitHub issue',
        integration: 'github',
        category: 'issues',
        params: [
          ..._issueRefParams(),
          const ToolParam(
            name: 'label',
            description: 'The name of the label to remove',
            required: true,
          ),
        ],
      ),
    ];

/// `owner`/`repo`/`number`/`key` parameters shared by the issue mutation
/// tools — all optional (composite-key resolution fills the gaps).
List<ToolParam> _issueRefParams() => [
      _ghOptionalOwner(),
      _ghOptionalRepo(),
      const ToolParam(
        name: 'number',
        description: 'The issue number',
        type: 'number',
        required: false,
      ),
      const ToolParam(
        name: 'key',
        description: "Composite issue key 'owner/repo#123' (alternative to "
            'owner/repo/number)',
        required: false,
      ),
    ];

/// Optional `owner` parameter (Java #543 made the issue-family parts
/// optional).
ToolParam _ghOptionalOwner() => const ToolParam(
      name: 'owner',
      description: 'The repository owner (user or organization)',
      required: false,
    );

/// Optional `repo` parameter.
ToolParam _ghOptionalRepo() => const ToolParam(
      name: 'repo',
      description: 'The repository name',
      required: false,
    );

/// Optional `workspace` parameter.
ToolParam _ghOptionalWorkspace() => const ToolParam(
      name: 'workspace',
      description: 'The GitHub owner/organization name',
      required: false,
    );

/// Optional `repository` parameter.
ToolParam _ghOptionalRepository() => const ToolParam(
      name: 'repository',
      description: 'The GitHub repository name',
      required: false,
    );

/// Optional `pullRequestId` parameter (also accepts `number`).
ToolParam _ghOptionalPrId() => const ToolParam(
      name: 'pullRequestId',
      description: 'The issue or pull request number',
      required: false,
      aliases: ['number', 'issueNumber'],
    );

/// The composite issue `key` parameter for [alternative] parameter names.
ToolParam _ghIssueKeyParam({required String alternative}) => ToolParam(
      name: 'key',
      description: "Composite issue key 'owner/repo#123' (alternative to "
          '$alternative)',
      required: false,
    );

/// Executor routes for the issue-tracker family (Java `GitHubIssues`).
///
/// A function of the client so the [GithubToolExecutor] instance map can
/// merge it (part files cannot see instance fields).
Map<String, Future<dynamic> Function(Map<String, dynamic>)>
    _issueTrackerHandlers(GithubClient client) => {
          ..._issueReadHandlers(client),
          ..._issueMutationHandlers(client),
        };

/// Executor routes for the issue read/create tools.
Map<String, Future<dynamic> Function(Map<String, dynamic>)> _issueReadHandlers(
        GithubClient client) =>
    {
      'github_create_comment': (a) => client.createComment(
            _ghArgStr(a['workspace']),
            _ghArgStr(a['repository']),
            _ghArgStr(a['pullRequestId']),
            _ghArgStr(a['body']) ?? _ghArgStr(a['text']) ?? '',
            key: _ghArgStr(a['key']),
          ),
      'github_get_issue': (a) => client.getIssue(
            _ghArgStr(a['workspace']),
            _ghArgStr(a['repository']),
            _ghArgStr(a['issueNumber']),
            key: _ghArgStr(a['key']),
          ),
      'github_create_issue': (a) => client.createIssue(
            _ghArgStr(a['owner']),
            _ghArgStr(a['repo']),
            _ghArgStr(a['title']) ?? '',
            body: _ghArgStr(a['body']),
            key: _ghArgStr(a['key']),
          ),
      'github_search_issues': (a) => client.searchIssues(
            _ghArgStr(a['query']) ?? '',
            _ghArgStr(a['workspace']),
            _ghArgStr(a['repository']),
          ),
    };

/// Executor routes for the issue mutation tools.
Map<String, Future<dynamic> Function(Map<String, dynamic>)>
    _issueMutationHandlers(GithubClient client) => {
          'github_close_issue': (a) => client.closeIssue(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                key: _ghArgStr(a['key']),
              ),
          'github_reopen_issue': (a) => client.reopenIssue(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                key: _ghArgStr(a['key']),
              ),
          'github_move_issue_to_status': (a) => client.moveIssueToStatus(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                _ghArgStr(a['statusName']) ?? '',
                key: _ghArgStr(a['key']),
              ),
          'github_assign_issue': (a) => client.assignIssue(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                _ghArgStr(a['user']) ?? '',
                key: _ghArgStr(a['key']),
              ),
          'github_add_labels': (a) => client.addLabels(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                (a['labels'] as List).cast<String>(),
                key: _ghArgStr(a['key']),
              ),
          'github_remove_label': (a) => client.removeLabel(
                _ghArgStr(a['owner']),
                _ghArgStr(a['repo']),
                _ghArgInt(a['number']),
                _ghArgStr(a['label']) ?? '',
                key: _ghArgStr(a['key']),
              ),
        };

/// Coerces a loosely-typed executor argument to a string (JS numbers arrive
/// as `num` — Java's `convertParameter` Number→String coercion).
String? _ghArgStr(dynamic value) => value?.toString();

/// Coerces a loosely-typed executor argument to an int.
int? _ghArgInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
