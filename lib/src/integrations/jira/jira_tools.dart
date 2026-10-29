/// MCP tool definitions and dispatcher for the Jira integration.
///
/// The tool list ports the Jira subset of the Java `@MCPTool` catalog; the
/// executor routes a tool name + arguments to the matching [JiraClient] call.
library;

import '../../mcp/tool_definition.dart';
import '../../mcp/tool_param.dart';
import 'jira_client.dart';
import 'jira_utils.dart';

part 'jira_agile_tools.dart';
part 'jira_attachment_tools.dart';
part 'jira_export_tools.dart';
part 'jira_fix_version_tools.dart';
part 'jira_ticket_tools.dart';
part 'jira_issue_type_tools.dart';
part 'jira_metadata_tools.dart';
part 'jira_project_tools.dart';
part 'jira_scheme_tools.dart';
part 'jira_search_tools.dart';
part 'jira_transition_tools.dart';
part 'jira_user_tools.dart';
part 'jira_watcher_tools.dart';
part 'jira_workflow_tools.dart';
part 'jira_worklog_tools.dart';

/// Reusable parameter: Jira ticket key.
const _keyParam = ToolParam(
  name: 'key',
  description: 'The Jira ticket key (e.g. PROJ-123)',
  required: true,
);

/// Reusable parameter: Jira project key.
const _projectParam = ToolParam(
  name: 'project',
  description: 'The project key (e.g. PROJ)',
  required: true,
);

/// Reusable parameter: optional comma-separated field list.
const _fieldsListParam = ToolParam(
  name: 'fields',
  description: 'Comma-separated field names to return',
  type: 'array',
  required: false,
);

/// Reusable parameters: JQL query string plus optional field list.
const _jqlSearchParams = [
  ToolParam(
    name: 'jql',
    description: 'The JQL query string',
    required: true,
    aliases: ['wiql', 'query', 'searchQueryJQL'],
  ),
  _fieldsListParam,
];

/// Builds a Jira tool definition with standard defaults.
///
/// [category] defaults to `'ticket_management'`; override for tools that
/// belong to a different group.
ToolDefinition _jiraTool({
  required String name,
  required String description,
  String category = 'ticket_management',
  List<String> aliases = const [],
  List<ToolParam> params = const [],
}) =>
    ToolDefinition(
      name: name,
      description: description,
      integration: 'jira',
      category: category,
      aliases: aliases,
      params: params,
    );

/// Returns all Jira MCP tool definitions.
///
/// Tool names and argument schemas mirror the Java `@MCPTool` annotations.
List<ToolDefinition> jiraTools() => [
      ..._systemTools(),
      ..._ticketTools(),
      ..._searchTools(),
      ..._commentTools(),
      ..._labelTools(),
      ..._statusTools(),
      ..._commentReadTools(),
      ..._assignTools(),
      ..._fieldTools(),
      ..._createTools(),
      ..._transitionReadTools(),
      ..._deleteTools(),
      ..._projectMetaTools(),
      ..._ticketWriteTools(),
      ..._subtaskTools(),
      ..._createWithParentTools(),
      ..._commentIfExistsTools(),
      ..._adfFieldTools(),
      ..._fieldsByNameTools(),
      ..._rawUpdateTools(),
      ..._linkTools(),
      ..._genericRequestTools(),
      ..._projectDetailTools(),
      ..._transitionTools(),
      ..._userTools(),
      ..._attachmentTools(),
      ..._projectLifecycleTools(),
      ..._workflowTools(),
      ..._projectStructureTools(),
      ..._boardConfigTools(),
      ..._schemeTools(),
      ..._issueTypeTools(),
      ..._fixVersionTools(),
      ..._myProfileTools(),
      ..._searchPageTools(),
      ..._attachmentReadTools(),
      ..._worklogTools(),
      ..._watcherTools(),
      ..._metadataTools(),
      ..._exportTools(),
      ..._agileTools(),
    ];

/// Executes Jira MCP tools by dispatching to [JiraClient].
class JiraToolExecutor {
  final JiraClient _client;

  /// Creates an executor bound to [_client].
  JiraToolExecutor(this._client);

  /// Executes [toolName] with [args], returning the tool's result.
  ///
  /// Throws [ArgumentError] for an unknown Jira tool name.
  Future<dynamic> execute(String toolName, Map<String, dynamic> args) {
    final handler = _handlers[toolName];
    if (handler == null) {
      throw ArgumentError('Unknown Jira tool: $toolName');
    }
    return handler(args);
  }

  /// Tool-name → handler dispatch table, mirroring the Java method routing.
  late final Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _handlers = {
    ..._coreHandlers(),
    ..._assignCreateHandlers(),
    ..._projectMetaHandlers(),
    ..._ticketWriteHandlers(),
    ..._commentIfExistsHandlers(),
    ..._adfFieldHandlers(),
    ..._fieldsByNameHandlers(),
    ..._rawUpdateHandlers(),
    ..._linkHandlers(),
    ..._genericRequestHandlers(),
    ..._projectHandlers(),
    ..._transitionHandlers(),
    ..._userHandlers(),
    ..._attachmentHandlers(),
    ..._workflowHandlers(),
    ..._schemeHandlers(),
    ..._issueTypeHandlers(),
    ..._fixVersionHandlers(),
    ..._searchPageHandlers(),
    ..._worklogHandlers(),
    ..._watcherHandlers(),
    ..._metadataHandlers(),
    ..._exportHandlers(),
    ..._agileHandlers(),
  };

  /// Dispatch entries for the core Jira ticket tools.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)> _coreHandlers() =>
      {
        'jira_test': (_) => _client.testConnection(),
        'jira_get_ticket': (a) => _client.getTicket(
              a['key'] as String,
              _optionalStringList(a, 'fields'),
            ),
        'jira_search_by_jql': (a) => _client.searchByJql(
              a['jql'] as String,
              _optionalStringList(a, 'fields'),
            ),
        'jira_post_comment': (a) => _client.postComment(
              a['key'] as String,
              a['comment'] as String,
            ),
        'jira_add_label': (a) => _client.addLabel(
              a['key'] as String,
              a['label'] as String,
            ),
        'jira_remove_label': (a) => _client.removeLabel(
              a['key'] as String,
              a['label'] as String,
            ),
        'jira_move_to_status': (a) => _client.moveToStatus(
              a['key'] as String,
              a['statusName'] as String,
            ),
        'jira_get_comments': (a) => _client.getComments(a['key'] as String),
        'jira_update_field': (a) => _client.updateField(
              a['key'] as String,
              a['field'] as String,
              a['value'],
            ),
        'jira_get_transitions': (a) =>
            _client.getTransitions(a['key'] as String),
        'jira_delete_ticket': (a) => _client.deleteTicket(a['key'] as String),
        'jira_clear_field': (a) => _client.clearField(
              a['key'] as String,
              a['field'] as String,
            ),
      };

  /// Dispatch entries for the assign and create tools — the canonical Java
  /// names plus the legacy short keys the dispatcher routes.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _assignCreateHandlers() => {
            'jira_assign_ticket_to': _assignTo,
            'jira_assign_to': _assignTo,
            'jira_assign': _assignTo,
            'jira_create_ticket_basic': _createTicketBasic,
            'jira_create_ticket': _createTicketBasic,
            'jira_create_ticket_with_json': (a) {
              // gh-427 E5: no third labels path — steer callers to fieldsJson.
              if (a.containsKey('labels')) {
                throw ArgumentError(
                  'labels is not a top-level argument of '
                  'jira_create_ticket_with_json; pass it inside fieldsJson, '
                  'e.g. {"fieldsJson": {"labels": ["a", "b"]}}',
                );
              }
              return _client.createTicketWithJson(
                a['project'] as String,
                a['fieldsJson'] as Map<String, dynamic>,
              );
            },
          };

  /// `jira_assign_ticket_to` — assign [key] to [accountId].
  Future<void> _assignTo(Map<String, dynamic> a) => _client.assignTo(
        a['key'] as String,
        a['accountId'] as String,
      );

  /// `jira_create_ticket_basic` — create with basic fields.
  Future<Map<String, dynamic>> _createTicketBasic(Map<String, dynamic> a) =>
      _client.createTicketBasic(
        a['project'] as String,
        a['issueType'] as String,
        a['summary'] as String,
        a['description'] as String?,
        jiraCreateLabelsArg(a),
      );

  /// Dispatch entries for the project-metadata read tools.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _projectMetaHandlers() => {
            'jira_get_issue_types': (a) =>
                _client.getIssueTypes(a['project'] as String),
            'jira_get_fields': (a) => _client.getFields(a['project'] as String),
            'jira_get_components': (a) =>
                _client.getComponents(a['project'] as String),
            'jira_get_fix_versions': (a) =>
                _client.getFixVersions(a['project'] as String),
          };

  /// Dispatch entries for the ticket write, subtask, and create-with-parent
  /// tools.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _ticketWriteHandlers() => {
            'jira_set_fix_version': (a) => _client.setFixVersion(
                  a['key'] as String,
                  a['fixVersion'] as String,
                ),
            'jira_set_priority': (a) => _client.setPriority(
                  a['key'] as String,
                  a['priority'] as String,
                ),
            'jira_get_subtasks': (a) => _client.getSubtasks(a['key'] as String),
            'jira_update_description': (a) => _client.updateDescription(
                  a['key'] as String,
                  a['description'] as String,
                ),
            'jira_create_ticket_with_parent': (a) =>
                _client.createTicketWithParent(
                  a['project'] as String,
                  a['issueType'] as String,
                  a['summary'] as String,
                  a['parentKey'] as String,
                  a['description'] as String?,
                  jiraCreateLabelsArg(a),
                ),
          };

  /// Dispatch entries for the comment-if-not-exists tool.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _commentIfExistsHandlers() => {
            'jira_post_comment_if_not_exists': (a) =>
                _client.postCommentIfNotExists(
                  a['key'] as String,
                  a['comment'] as String,
                ),
          };

  /// Dispatch entries for the ADF field-update tool.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _adfFieldHandlers() => {
            'jira_update_field_as_adf': (a) => _client.updateFieldAsAdf(
                  a['key'] as String,
                  a['field'] as String,
                  a['value'] as Map<String, dynamic>,
                ),
          };

  /// Dispatch entries for the field-by-name tools.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _fieldsByNameHandlers() => {
            'jira_get_all_fields_with_name': (a) =>
                _client.getAllFieldsWithName(
                  a['project'] as String,
                  a['fieldName'] as String,
                ),
            'jira_get_field_custom_code': (a) => _client.getFieldCustomCode(
                  a['project'] as String,
                  a['fieldName'] as String,
                ),
            'jira_update_all_fields_with_name': (a) =>
                _client.updateAllFieldsWithName(
                  a['key'] as String,
                  a['fieldName'] as String,
                  a['value'],
                ),
          };

  /// Dispatch entries for the raw-update tool.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _rawUpdateHandlers() => {
            'jira_update_ticket': (a) => _client.updateTicket(
                  a['key'] as String,
                  a['jsonParams'] as Map<String, dynamic>,
                ),
            'jira_update_ticket_parent': (a) => _client.updateTicketParent(
                  a['key'] as String,
                  a['parentKey'] as String,
                ),
          };

  /// Dispatch entries for the issue-link tools (Java
  /// `linkIssueWithRelationship` signature: source/another/relationship).
  Map<String, Future<dynamic> Function(Map<String, dynamic>)> _linkHandlers() =>
      {
        'jira_link_issues': (a) => _client.linkIssues(
              a['sourceKey'] as String,
              a['anotherKey'] as String,
              a['relationship'] as String,
            ),
        'jira_get_issue_link_types': (_) => _client.getIssueLinkTypes(),
      };

  /// Dispatch entries for the generic request tool.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _genericRequestHandlers() => {
            'jira_execute_request': (a) =>
                _client.executeRequest(a['url'] as String),
          };
}
