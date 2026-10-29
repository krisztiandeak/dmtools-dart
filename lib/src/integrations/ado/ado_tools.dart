/// MCP tool definitions and dispatcher for the Azure DevOps integration.
///
/// The tool list ports the ADO subset of the Java `@MCPTool` catalog; the
/// executor routes a tool name + arguments to the matching [AdoClient] call.
library;

import 'dart:convert';

import '../../mcp/tool_definition.dart';
import '../../mcp/tool_param.dart';
import 'ado_client.dart';
import 'ado_work_item_client.dart';
part 'ado_pr_tools.dart';
part 'ado_ticket_op_tools.dart';

/// Returns all Azure DevOps MCP tool definitions.
///
/// Tool names and argument schemas mirror the Java `@MCPTool` annotations.
List<ToolDefinition> adoTools() => [
      ..._systemTools(),
      ..._workItemTools(),
      ..._workItemLinkTools(),
      ..._workItemQueryTools(),
      ..._commentTools(),
      ..._ticketOpTools(),
      ..._teamTools(),
      ..._projectTools(),
      ..._pullRequestTools(),
      ..._pullRequestUpdateTools(),
      ..._pullRequestStatusTools(),
      ..._repoTools(),
      ..._repoDetailTools(),
      ..._buildTools(),
      ..._prCommentTools(),
      ..._prThreadTools(),
      ..._prLabelTools(),
      ..._pipelineAgentTools(),
    ];

/// Connectivity-check tool: `ado_test`.
List<ToolDefinition> _systemTools() => [
      ToolDefinition(
        name: 'ado_test',
        description: 'Test Azure DevOps connectivity via the connection-data '
            'endpoint',
        integration: 'ado',
        category: 'system',
        params: [],
      ),
    ];

/// Work-item tools: get/create/update work items and revisions.
List<ToolDefinition> _workItemTools() => [
      ToolDefinition(
        name: 'ado_get_work_item',
        aliases: ['tracker_get_ticket'],
        description: 'Get an Azure DevOps work item by ID',
        integration: 'ado',
        category: 'work_item_management',
        params: [_idParam('The work item ID')],
      ),
      _createWorkItemTool(),
      ToolDefinition(
        name: 'ado_update_work_item',
        description: 'Update an Azure DevOps work item by setting fields',
        integration: 'ado',
        category: 'work_item_management',
        params: [
          _idParam('The work item ID to update'),
          ToolParam(
            name: 'fields',
            description: 'Map of field path to value, e.g. '
                '{"System.Title": "New title"}',
            type: 'object',
          ),
        ],
      ),
      ToolDefinition(
        name: 'ado_get_work_item_revisions',
        description: 'List the revision history of an Azure DevOps work item',
        integration: 'ado',
        category: 'work_item_management',
        params: [_idParam('The work item ID')],
      ),
    ];

/// Work-item link tool: `ado_create_work_item_link`.
///
/// Split out from [_workItemTools] to keep each grouping under the 60-line
/// method-size gate.
List<ToolDefinition> _workItemLinkTools() => [
      ToolDefinition(
        name: 'ado_create_work_item_link',
        description: 'Link two Azure DevOps work items (source → target) with '
            'a relation type',
        integration: 'ado',
        category: 'work_item_management',
        params: [
          _numberParam('sourceId', 'The source work item ID'),
          _numberParam('targetId', 'The target work item ID'),
          ToolParam(
            name: 'linkType',
            description: 'The relation type, e.g. '
                'System.LinkTypes.Hierarchy-Forward',
          ),
        ],
      ),
    ];

/// Work-item query tools: batch fetch, WIQL queries, and work-item types.
List<ToolDefinition> _workItemQueryTools() => [
      ToolDefinition(
        name: 'ado_get_work_items',
        description: 'Get multiple Azure DevOps work items by ID',
        integration: 'ado',
        category: 'work_item_management',
        params: [
          ToolParam(
            name: 'ids',
            description: 'The work item IDs to fetch',
            type: 'array',
          ),
        ],
      ),
      ToolDefinition(
        name: 'ado_list_work_items',
        description: 'Run a WIQL query to list Azure DevOps work items',
        integration: 'ado',
        category: 'work_item_management',
        aliases: ['ado_search_by_wiql', 'tracker_search'],
        params: [
          ToolParam(
            name: 'wiql',
            description: 'The WIQL query string',
            aliases: ['jql', 'searchQueryJQL', 'query'],
          ),
          ToolParam(
            name: 'fields',
            description: 'Optional array of fields to include',
          ),
        ],
      ),
      ToolDefinition(
        name: 'ado_get_work_item_types',
        description: 'List the work item types defined in a project',
        integration: 'ado',
        category: 'work_item_management',
        params: [_projectParam()],
      ),
    ];

/// Work-item comment tools: `ado_get_work_item_comments`,
/// `ado_add_work_item_comment`.
List<ToolDefinition> _commentTools() => [
      ToolDefinition(
        name: 'ado_get_work_item_comments',
        aliases: ['ado_get_comments', 'tracker_get_comments'],
        description: 'List the comments on an Azure DevOps work item',
        integration: 'ado',
        category: 'comment_management',
        params: [_idParam('The work item ID')],
      ),
      ToolDefinition(
        name: 'ado_add_work_item_comment',
        aliases: ['ado_post_comment', 'tracker_post_comment'],
        description: 'Add a comment to an Azure DevOps work item',
        integration: 'ado',
        category: 'comment_management',
        params: [
          _idParam('The work item ID'),
          ToolParam(
            name: 'comment',
            description: 'The comment text',
            aliases: ['text', 'body'],
          ),
          ToolParam(
            name: 'format',
            description: 'Optional comment format: html (default) or markdown',
            required: false,
          ),
        ],
      ),
      ToolDefinition(
        name: 'ado_add_work_item_label',
        aliases: ['tracker_add_label'],
        description:
            'Add a single label (tag) to a work item, keeping existing tags',
        integration: 'ado',
        category: 'work_item_management',
        params: [
          _idParam('The work item ID'),
          ToolParam(name: 'label', description: 'The label to add'),
        ],
      ),
      ToolDefinition(
        name: 'ado_remove_work_item_label',
        aliases: ['tracker_remove_label'],
        description: 'Remove a single label (tag) from a work item, '
            'keeping other tags',
        integration: 'ado',
        category: 'work_item_management',
        params: [
          _idParam('The work item ID'),
          ToolParam(name: 'label', description: 'The label to remove'),
        ],
      ),
    ];

/// Team tools: `ado_get_teams`, `ado_get_team_members`.
List<ToolDefinition> _teamTools() => [
      ToolDefinition(
        name: 'ado_get_teams',
        description: 'List the teams defined in an Azure DevOps project',
        integration: 'ado',
        category: 'teams',
        params: [_projectParam()],
      ),
      ToolDefinition(
        name: 'ado_get_team_members',
        description: 'List the members of an Azure DevOps team',
        integration: 'ado',
        category: 'teams',
        params: [
          _projectParam(),
          ToolParam(name: 'teamId', description: 'The team ID'),
        ],
      ),
    ];

/// Project tools: `ado_get_project_details`, `ado_get_project_properties`.
List<ToolDefinition> _projectTools() => [
      ToolDefinition(
        name: 'ado_get_project_details',
        description: 'Get an Azure DevOps project by ID (name, state, '
            'description)',
        integration: 'ado',
        category: 'projects',
        params: [
          ToolParam(name: 'projectId', description: 'The project ID'),
        ],
      ),
      ToolDefinition(
        name: 'ado_get_project_properties',
        description: 'Get the properties of an Azure DevOps project by ID',
        integration: 'ado',
        category: 'projects',
        params: [
          ToolParam(name: 'projectId', description: 'The project ID'),
        ],
      ),
    ];

/// Executes Azure DevOps MCP tools by dispatching to [AdoClient].
class AdoToolExecutor {
  final AdoClient _client;

  /// Creates an executor bound to [_client].
  AdoToolExecutor(this._client);

  /// Executes [toolName] with [args], returning the tool's result.
  ///
  /// Throws [ArgumentError] for an unknown ADO tool name.
  Future<dynamic> execute(String toolName, Map<String, dynamic> args) {
    final handler = _handlers[toolName];
    if (handler == null) {
      throw ArgumentError('Unknown ADO tool: $toolName');
    }
    return handler(args);
  }

  /// Tool-name → handler dispatch table, mirroring the Java method routing.
  late final Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _handlers = {
    'ado_test': (_) => _client.testConnection(),
    'ado_get_work_item': (a) => _client.getWorkItem(_id(a)),
    ..._ticketOpHandlers(_client.workItemOps),
    'ado_update_work_item': (a) => _client.updateWorkItem(
          _id(a),
          a['fields'] as Map<String, dynamic>,
        ),
    'ado_get_work_item_revisions': (a) => _client.getWorkItemRevisions(_id(a)),
    'ado_get_work_items': (a) => _client.getWorkItems(_intList(a, 'ids')),
    'ado_list_work_items': (a) => _client.listWorkItems(a['wiql'] as String,
        fields: (a['fields'] as List?)?.cast<String>()),
    'ado_get_work_item_types': (a) =>
        _client.getWorkItemTypes(a['project'] as String),
    'ado_get_teams': (a) => _client.getTeams(a['project'] as String),
    'ado_get_team_members': (a) => _client.getTeamMembers(
          a['project'] as String,
          a['teamId'] as String,
        ),
    'ado_get_project_properties': (a) =>
        _client.getProjectProperties(a['projectId'] as String),
    'ado_get_project_details': (a) =>
        _client.getProjectDetails(a['projectId'] as String),
    'ado_create_work_item_link': (a) => _client.createWorkItemLink(
          _num(a, 'sourceId'),
          _num(a, 'targetId'),
          a['linkType'] as String,
        ),
    'ado_list_prs': (a) => _client.listPrs(a['status'] as String?),
    'ado_get_pr': (a) => _client.getPr(_id(a)),
    'ado_get_pull_request_reviewers': (a) => _client.getPullRequestReviewers(
          a['project'] as String,
          _num(a, 'prId'),
        ),
    'ado_add_pull_request_reviewer': (a) => _client.addPullRequestReviewer(
          a['project'] as String,
          _num(a, 'prId'),
          a['reviewerId'] as String,
        ),
    'ado_update_pull_request': (a) => _client.updatePullRequest(
          a['project'] as String,
          _num(a, 'prId'),
          a['title'] as String,
          a['description'] as String,
        ),
    'ado_get_pull_request_commits': (a) => _client.getPullRequestCommits(
          a['project'] as String,
          _num(a, 'prId'),
        ),
    'ado_get_pull_request_statuses': (a) => _client.getPullRequestStatuses(
          a['project'] as String,
          _num(a, 'prId'),
        ),
    'ado_create_pull_request_status': (a) => _client.createPullRequestStatus(
          a['project'] as String,
          _num(a, 'prId'),
          a['state'] as String,
          a['description'] as String,
          a['context'] as String,
        ),
    'ado_get_work_item_comments': (a) => _client.getWorkItemComments(_id(a)),
    'ado_add_work_item_comment': (a) => _client.addWorkItemComment(
          _id(a),
          (a['comment'] ?? a['text']) as String,
          format: a['format'] as String?,
        ),
    'ado_create_repo': (a) => _client.createRepo(
          a['project'] as String,
          a['name'] as String,
        ),
    'ado_get_repos': (a) => _client.getRepos(a['project'] as String),
    'ado_get_repo_details': (a) => _client.getRepoDetails(
          a['project'] as String,
          a['repoId'] as String,
        ),
    'ado_get_repo_file': (a) => _client.getRepoFile(
          a['project'] as String,
          a['repoId'] as String,
          a['path'] as String,
          a['branch'] as String,
        ),
    'ado_get_repo_branches': (a) => _client.getRepoBranches(
          a['project'] as String,
          a['repoId'] as String,
        ),
    'ado_get_commits': (a) => _client.getCommits(
          a['project'] as String,
          a['repoId'] as String,
          a['searchCriteria'] as Map<String, dynamic>?,
        ),
    'ado_get_builds': (a) => _client.getBuilds(
          a['project'] as String,
          a['definitions'] == null ? null : _intList(a, 'definitions'),
        ),
    'ado_trigger_build': (a) => _client.triggerBuild(_num(a, 'definitionId')),
  };
}
