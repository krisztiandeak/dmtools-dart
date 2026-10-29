/// MCP tool definitions and dispatcher for the GitHub integration.
///
/// The tool list ports the GitHub subset of the Java `@MCPTool` catalog; the
/// executor routes a tool name + arguments to the matching [GithubClient] call.
library;

import '../../mcp/tool_args.dart';
import '../../mcp/tool_definition.dart';
import '../../mcp/tool_param.dart';
import 'github_client.dart';
import '../github_pr_review_tools.dart';

part 'github_actions_tools.dart';
part 'github_agent_tools.dart';
part 'github_ci_pr_tools.dart';
part 'github_codeowners_tools.dart';
part 'github_collaborator_tools.dart';
part 'github_issue_tracker_tools.dart';
part 'github_pr_state_tools.dart';
part 'github_pr_update_tools.dart';
part 'github_repository_tools.dart';
part 'github_workflow_catalog_tools.dart';

/// Returns all GitHub MCP tool definitions.
///
/// Tool names and argument schemas mirror the Java `@MCPTool` annotations.
List<ToolDefinition> githubTools() => [
      ..._systemTools(),
      ..._repositoryTools(),
      ..._pullRequestTools(),
      ..._prStateTools(),
      ..._prUpdateTools(),
      ..._reviewTools(),
      ..._commentTools(),
      ..._issueTools(),
      ..._branchTools(),
      ..._fileTools(),
      ..._releaseTools(),
      ..._commitTools(),
      ..._actionsTools(),
      ..._workflowCatalogTools(),
      ..._codeownersTools(),
      ..._collaboratorTools(),
      ..._agentPrTools(),
      ..._agentActionsTools(),
      ..._agentReleaseTools(),
      ...prReviewTools(),
      ..._ciStatusTools(),
      ..._prActivityTools(),
      ..._releaseAssetTools(),
    ];

/// Per-domain catalog functions live in `github_<domain>_tools.dart` part
/// files (repository, PR update, actions, workflow catalog, CODEOWNERS,
/// collaborators) to keep file sizes manageable.

/// Connectivity-check tool: `github_test`.
List<ToolDefinition> _systemTools() => [
      ToolDefinition(
        name: 'github_test',
        aliases: ['tracker_get_my_profile'],
        description: 'Test GitHub connectivity by fetching the current user',
        integration: 'github',
        category: 'system',
        params: [],
      ),
    ];

/// Pull-request tools: `github_get_pr`, `github_list_prs`, `github_create_pr`.
List<ToolDefinition> _pullRequestTools() => [
      ..._prReadTools(),
      _createPrTool(),
    ];

/// PR read tools: `github_get_pr`, `github_list_prs`.
List<ToolDefinition> _prReadTools() => [
      ToolDefinition(
        name: 'github_get_pr',
        description: 'Get details of a GitHub pull request including title, '
            'description, status, author, branches, and merge info.',
        integration: 'github',
        category: 'pull_requests',
        aliases: ['source_code_get_pr'],
        params: [
          _workspaceParam(),
          _repositoryParam(),
          _prIdParam(),
        ],
      ),
      ToolDefinition(
        name: 'github_list_prs',
        description:
            "List pull requests in a GitHub repository by state. State can "
            "be 'open', 'closed', or 'merged'. 'open' returns every "
            "page; 'closed'/'merged' return the first page (up to 100, "
            'most recently updated first) because history can be huge.',
        integration: 'github',
        category: 'pull_requests',
        aliases: ['source_code_list_prs'],
        params: [
          _workspaceParam(),
          _repositoryParam(),
          ToolParam(
            name: 'state',
            description:
                "The state of pull requests to list: 'open', 'closed', or "
                "'merged'. 'opened' is accepted as a synonym for 'open'.",
            required: true,
          ),
        ],
      ),
    ];

/// PR creation tool: `github_create_pr`.
ToolDefinition _createPrTool() => ToolDefinition(
      name: 'github_create_pr',
      description: 'Create a GitHub pull request',
      integration: 'github',
      category: 'pull_requests',
      params: [
        _ownerParam(),
        _repoParam(),
        ToolParam(
          name: 'title',
          description: 'The title of the new pull request',
          required: true,
        ),
        ToolParam(
          name: 'head',
          description: 'The branch containing changes (source)',
          required: true,
        ),
        ToolParam(
          name: 'base',
          description: 'The branch to merge changes into (target)',
          required: true,
        ),
      ],
    );

/// Comment and issue tools live in `github_issue_tracker_tools.dart`
/// (Java `GitHubIssues.java` parity, dm.ai #543).

/// Review tools: `github_create_review`, `github_dismiss_review`.
List<ToolDefinition> _reviewTools() => [
      ToolDefinition(
        name: 'github_create_review',
        description: 'Create a review on a GitHub pull request',
        integration: 'github',
        category: 'reviews',
        params: [
          _ownerParam(),
          _repoParam(),
          _numberParam('The pull request number'),
          ToolParam(
            name: 'body',
            description: 'The review body text',
            required: true,
          ),
          ToolParam(
            name: 'event',
            description: 'Review event: APPROVE, REQUEST_CHANGES, or COMMENT',
            required: true,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_dismiss_review',
        description: 'Dismiss a review on a GitHub pull request',
        integration: 'github',
        category: 'reviews',
        params: [
          _ownerParam(),
          _repoParam(),
          _numberParam('The pull request number'),
          ToolParam(
            name: 'review_id',
            description: 'The id of the review to dismiss',
            type: 'number',
            required: true,
          ),
          ToolParam(
            name: 'message',
            description: 'The dismissal message',
            required: true,
          ),
        ],
      ),
    ];

/// Branch tools: `github_list_branches`, `github_create_branch`,
/// `github_delete_branch`.
List<ToolDefinition> _branchTools() => [
      ToolDefinition(
        name: 'github_list_branches',
        description: 'List branches in a GitHub repository',
        integration: 'github',
        category: 'branches',
        params: [
          _ownerParam(),
          _repoParam(),
        ],
      ),
      ToolDefinition(
        name: 'github_create_branch',
        description: 'Create a new branch from an existing commit SHA',
        integration: 'github',
        category: 'branches',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'branch',
            description: 'The name of the new branch',
            required: true,
          ),
          ToolParam(
            name: 'from_sha',
            description: 'The commit SHA to branch from',
            required: true,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_delete_branch',
        description: 'Delete a branch in a GitHub repository',
        integration: 'github',
        category: 'branches',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'branch',
            description: 'The name of the branch to delete',
            required: true,
          ),
        ],
      ),
    ];

/// File-content tools: `github_get_file_content`, `github_update_file`.
List<ToolDefinition> _fileTools() => [
      ToolDefinition(
        name: 'github_get_file_content',
        description: 'Get the contents of a file in a GitHub repository',
        integration: 'github',
        category: 'files',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'path',
            description: 'The file path within the repository',
            required: true,
          ),
          ToolParam(
            name: 'ref',
            description:
                'Branch, tag, or commit SHA (defaults to default branch)',
            required: false,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_update_file',
        description: 'Create or update a file in a GitHub repository',
        integration: 'github',
        category: 'files',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'path',
            description: 'The file path within the repository',
            required: true,
          ),
          ToolParam(
            name: 'content',
            description: 'The new file content (plain text)',
            required: true,
          ),
          ToolParam(
            name: 'message',
            description: 'The commit message',
            required: true,
          ),
          ToolParam(
            name: 'sha',
            description:
                'The blob SHA of the existing file (required to update)',
            required: true,
          ),
        ],
      ),
    ];

/// Release tools: `github_list_releases`, `github_get_release`,
/// `github_create_release`.
List<ToolDefinition> _releaseTools() => [
      ToolDefinition(
        name: 'github_list_releases',
        description: 'List GitHub releases for a repository',
        integration: 'github',
        category: 'releases',
        params: [
          _ownerParam(),
          _repoParam(),
        ],
      ),
      ToolDefinition(
        name: 'github_get_release',
        description: 'Get a GitHub release by tag name',
        integration: 'github',
        category: 'releases',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'tag',
            description: 'The tag name of the release',
            required: true,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_create_release',
        description: 'Create a GitHub release for a tag',
        integration: 'github',
        category: 'releases',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'tag_name',
            description: 'The name of the tag the release targets',
            required: true,
          ),
          ToolParam(
            name: 'body',
            description: 'The release description (markdown)',
            required: false,
          ),
        ],
      ),
    ];

/// Commit tools: `github_get_commit`, `github_list_commits`.
List<ToolDefinition> _commitTools() => [
      ToolDefinition(
        name: 'github_get_commit',
        description: 'Get a GitHub commit by SHA',
        integration: 'github',
        category: 'commits',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'sha',
            description: 'The commit SHA (or ref) to fetch',
            required: true,
          ),
        ],
      ),
      ToolDefinition(
        name: 'github_list_commits',
        description: 'List commits in a GitHub repository',
        integration: 'github',
        category: 'commits',
        params: [
          _ownerParam(),
          _repoParam(),
          ToolParam(
            name: 'sha',
            description:
                'Branch or commit SHA to list from (defaults to default branch)',
            required: false,
          ),
        ],
      ),
    ];

/// Shared `owner` parameter (repository owner / org).
ToolParam _ownerParam() => ToolParam(
      name: 'owner',
      description: 'The repository owner (user or organization)',
      required: true,
    );

/// Shared `repo` parameter (repository name).
ToolParam _repoParam() => ToolParam(
      name: 'repo',
      description: 'The repository name',
      required: true,
    );

/// Shared numeric `number` parameter with a tool-specific [description].
ToolParam _numberParam(String description) => ToolParam(
      name: 'number',
      description: description,
      type: 'number',
      required: true,
    );

/// Executes GitHub MCP tools by dispatching to [GithubClient].
class GithubToolExecutor {
  final GithubClient _client;

  /// Creates an executor bound to [_client].
  GithubToolExecutor(this._client);

  /// Executes [toolName] with [args], returning the tool's result.
  ///
  /// Throws [ArgumentError] for an unknown GitHub tool name.
  Future<dynamic> execute(String toolName, Map<String, dynamic> args) {
    final handler = _handlers[toolName];
    if (handler == null) {
      throw ArgumentError('Unknown GitHub tool: $toolName');
    }
    return handler(args);
  }

  /// Tool-name → handler dispatch table, mirroring the Java method routing.
  ///
  /// Core PR/repo/actions routes live here; the issue-tracker family routes
  /// (Java `GitHubIssues`) and the CI/PR-activity routes live in their part
  /// files and are merged in.
  late final Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _handlers = {
    ..._baseHandlers,
    ..._issueTrackerHandlers(_client),
    ..._ciPrHandlers(_client),
  };

  /// Core handler routes (everything outside the issue family and the
  /// CI/PR-activity tools).
  late final Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _baseHandlers = {
    'github_test': (_) => _client.testConnection(),
    'github_get_pr': (a) => _client.getPr(
          a['workspace'] as String,
          a['repository'] as String,
          requiredInt(a, 'pullRequestId'),
        ),
    'github_list_prs': (a) => _client.listPrs(
          a['workspace'] as String,
          a['repository'] as String,
          a['state'] as String?,
        ),
    'github_submit_pr_review': (a) => _client.submitPullRequestReview(
          a['workspace'] as String,
          a['repository'] as String,
          a['pullRequestId'].toString(),
          a['event'] as String,
          a['body'] as String?,
        ),
    'github_list_pr_reviews': (a) => _client.listPullRequestReviews(
          a['workspace'] as String,
          a['repository'] as String,
          a['pullRequestId'].toString(),
        ),
    'github_dismiss_pr_review': (a) => _client.dismissPullRequestReview(
          a['workspace'] as String,
          a['repository'] as String,
          a['pullRequestId'].toString(),
          a['reviewId'].toString(),
          a['message'] as String,
        ),
    'github_create_pr': (a) => _client.createPr(
          a['owner'] as String,
          a['repo'] as String,
          a['title'] as String,
          a['head'] as String,
          a['base'] as String,
        ),
    'github_merge_pr': (a) => _client.mergePr(
          a['workspace'] as String,
          a['repository'] as String,
          requiredInt(a, 'pullRequestId'),
        ),
    'github_close_pr': (a) => _client.closePr(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
        ),
    'github_reopen_pr': (a) => _client.reopenPr(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
        ),
    'github_get_pr_diff': (a) => _client.getPrDiff(
          a['workspace'] as String,
          a['repository'] as String,
          requiredInt(a, 'pullRequestID'),
        ),
    'github_get_pr_files': (a) => _client.getPrFiles(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
        ),
    'github_create_review': (a) => _client.createReview(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
          a['body'] as String,
          a['event'] as String,
        ),
    'github_list_branches': (a) => _client.listBranches(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_create_branch': (a) => _client.createBranch(
          a['owner'] as String,
          a['repo'] as String,
          a['branch'] as String,
          a['from_sha'] as String,
        ),
    'github_get_file_content': (a) => _client.getFileContent(
          a['owner'] as String,
          a['repo'] as String,
          a['path'] as String,
          a['ref'] as String?,
        ),
    'github_update_file': (a) => _client.updateFile(
          a['owner'] as String,
          a['repo'] as String,
          a['path'] as String,
          a['content'] as String,
          a['message'] as String,
          a['sha'] as String,
        ),
    'github_delete_branch': (a) => _client.deleteBranch(
          a['owner'] as String,
          a['repo'] as String,
          a['branch'] as String,
        ),
    'github_list_releases': (a) => _client.listReleases(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_get_release': (a) => _client.getRelease(
          a['owner'] as String,
          a['repo'] as String,
          a['tag'] as String,
        ),
    'github_create_release': (a) => _client.createRelease(
          a['owner'] as String,
          a['repo'] as String,
          a['tag_name'] as String,
          a['body'] as String?,
        ),
    'github_get_commit': (a) => _client.getCommit(
          a['owner'] as String,
          a['repo'] as String,
          a['sha'] as String,
        ),
    'github_list_commits': (a) => _client.listCommits(
          a['owner'] as String,
          a['repo'] as String,
          a['sha'] as String?,
        ),
    'github_get_repo': (a) => _client.getRepo(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_update_pr': (a) => _client.updatePullRequest(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
          a['title'] as String?,
          a['body'] as String?,
        ),
    'github_request_reviewers': (a) => _client.requestReviewers(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
          (a['reviewers'] as List).cast<String>(),
        ),
    'github_dismiss_review': (a) => _client.dismissReview(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'number'),
          requiredInt(a, 'review_id'),
          a['message'] as String,
        ),
    'github_get_workflow_runs': (a) => _client.getWorkflowRuns(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_rerun_workflow': (a) => _client.reRunWorkflow(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'run_id'),
        ),
    'github_get_check_runs': (a) => _client.getCheckRuns(
          a['owner'] as String,
          a['repo'] as String,
          a['ref'] as String,
        ),
    'github_get_tree': (a) => _client.getTree(
          a['owner'] as String,
          a['repo'] as String,
          a['ref'] as String,
        ),
    'github_get_workflows': (a) => _client.getWorkflows(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_enable_workflow': (a) => _client.enableWorkflow(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'workflow_id'),
        ),
    'github_disable_workflow': (a) => _client.disableWorkflow(
          a['owner'] as String,
          a['repo'] as String,
          requiredInt(a, 'workflow_id'),
        ),
    'github_get_codeowners': (a) => _client.getCodeowners(
          a['owner'] as String,
          a['repo'] as String,
        ),
    'github_add_collaborator': (a) => _client.addCollaborator(
          a['owner'] as String,
          a['repo'] as String,
          a['username'] as String,
          a['permission'] as String,
        ),
    'github_remove_collaborator': (a) => _client.removeCollaborator(
          a['owner'] as String,
          a['repo'] as String,
          a['username'] as String,
        ),
  };
}
