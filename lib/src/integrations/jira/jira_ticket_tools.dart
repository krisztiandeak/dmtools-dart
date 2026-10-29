/// Core ticket-management tools — part of the Jira MCP tool catalog.
///
/// Ports the ticket `@MCPTool` definitions (read, search, comment, label,
/// status, assign, field mutation, create, transitions, delete, links).
/// Parameter names mirror the Java `Jira.java` `@MCPParam` annotations.
part of 'jira_tools.dart';

/// Connectivity-check tool: `jira_test`.
List<ToolDefinition> _systemTools() => [
      _jiraTool(
        name: 'jira_test',
        description:
            'Test Jira connectivity by fetching the current user profile',
        category: 'system',
      ),
    ];

/// Ticket-read tool: `jira_get_ticket`.
List<ToolDefinition> _ticketTools() => [
      _jiraTool(
        name: 'jira_get_ticket',
        description: 'Get a Jira ticket by key',
        aliases: ['tracker_get_ticket'],
        params: [
          _keyParam,
          _fieldsListParam,
        ],
      ),
    ];

/// JQL search tool: `jira_search_by_jql`.
List<ToolDefinition> _searchTools() => [
      _jiraTool(
        name: 'jira_search_by_jql',
        aliases: ['tracker_search'],
        description: 'Search Jira issues by JQL query',
        category: 'search',
        params: _jqlSearchParams,
      ),
    ];

/// Comment tool: `jira_post_comment`.
List<ToolDefinition> _commentTools() => [
      _jiraTool(
        name: 'jira_post_comment',
        aliases: ['tracker_post_comment'],
        description: 'Post a comment on a Jira ticket',
        params: [
          _keyParam,
          _commentTextParam,
        ],
      ),
    ];

/// Label-mutation tools: `jira_add_label` / `jira_remove_label`.
List<ToolDefinition> _labelTools() => [
      _jiraTool(
        name: 'jira_add_label',
        description: 'Add a label to a Jira ticket',
        aliases: ['tracker_add_label'],
        params: [
          _keyParam,
          ToolParam(
            name: 'label',
            description: 'The label to add',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_remove_label',
        description: 'Remove a label from a Jira ticket',
        aliases: ['tracker_remove_label'],
        params: [
          _keyParam,
          ToolParam(
            name: 'label',
            description: 'The label to remove',
            required: true,
          ),
        ],
      ),
    ];

/// Workflow-transition tool: `jira_move_to_status`.
List<ToolDefinition> _statusTools() => [
      _jiraTool(
        name: 'jira_move_to_status',
        aliases: ['tracker_move_to_status'],
        description: 'Transition a Jira ticket to a target status',
        category: 'workflow',
        params: [
          _keyParam,
          ToolParam(
            name: 'statusName',
            description: 'The target status name',
            required: true,
            aliases: ['state', 'status'],
          ),
        ],
      ),
    ];

/// Reads an optional string-array argument as `List<String>?`.
List<String>? _optionalStringList(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is List) return value.cast<String>();
  if (value is String) return value.split(',');
  return null;
}

/// Comment-read tool: `jira_get_comments`.
List<ToolDefinition> _commentReadTools() => [
      _jiraTool(
        name: 'jira_get_comments',
        aliases: ['tracker_get_comments'],
        description: 'Get all comments on a Jira ticket',
        params: [_keyParam],
      ),
    ];

/// Assignment tool: `jira_assign_ticket_to` (Java `assignTo`).
///
/// Canonical name and the `tracker_assign_ticket` alias mirror the Java
/// `@MCPTool`; `jira_assign` / `jira_assign_to` are kept callable for the
/// existing dispatcher entry points.
List<ToolDefinition> _assignTools() => [
      _jiraTool(
        name: 'jira_assign_ticket_to',
        description: 'Assigns a Jira ticket to user',
        aliases: ['tracker_assign_ticket', 'tracker_assign'],
        params: [
          _keyParam,
          ToolParam(
            name: 'accountId',
            description: 'The Jira account ID to assign to. If you know email'
                ' use first jira_get_account_by_email tools to get account ID',
            required: true,
          ),
        ],
      ),
    ];

/// Field-mutation tools: `jira_update_field` / `jira_clear_field`.
List<ToolDefinition> _fieldTools() => [
      _jiraTool(
        name: 'jira_update_field',
        aliases: ['tracker_update_field'],
        description: "Update field(s) in a Jira ticket. When using field "
            "names (e.g., 'Dependencies'), updates ALL fields with that "
            "name. When using custom field IDs (e.g., 'customfield_10091'), "
            "updates only that specific field.",
        params: [
          _keyParam,
          _fieldUpdateParam,
          ToolParam(
            name: 'value',
            description: 'The new value for the field(s)',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_clear_field',
        description: 'Clear (set to null) a single field on a Jira ticket',
        params: [
          _keyParam,
          ToolParam(
            name: 'field',
            description: 'The field name to clear',
            required: true,
          ),
        ],
      ),
    ];

/// Create tools: `jira_create_ticket_basic` + `jira_create_ticket_with_json`.
///
/// `jira_create_ticket_basic` is the Java canonical `@MCPTool` name (alias
/// `tracker_create_ticket`); `jira_create_ticket` stays callable for the
/// existing dispatcher entry points.
List<ToolDefinition> _createTools() => [
      _jiraTool(
        name: 'jira_create_ticket_basic',
        aliases: ['tracker_create_ticket'],
        description:
            'Create a new Jira ticket with basic fields (project, issue '
            'type, summary, description)',
        params: [
          _projectParam,
          _issueTypeParam,
          _summaryParam,
          ToolParam(
            name: 'description',
            description: 'The ticket description',
            required: false,
          ),
          _labelsParam,
        ],
      ),
      _jiraTool(
        name: 'jira_create_ticket_with_json',
        description: 'Create a new Jira ticket with custom fields using JSON '
            'configuration',
        params: [
          _projectParam,
          ToolParam(
            name: 'fieldsJson',
            description: 'JSON object containing ticket fields in Jira format',
            type: 'object',
            required: true,
          ),
        ],
      ),
    ];

/// Transition-read tool: `jira_get_transitions`.
List<ToolDefinition> _transitionReadTools() => [
      _jiraTool(
        name: 'jira_get_transitions',
        description: 'Get available workflow transitions for a Jira ticket',
        category: 'workflow',
        params: [_keyParam],
      ),
    ];

/// Delete tool: `jira_delete_ticket`.
List<ToolDefinition> _deleteTools() => [
      _jiraTool(
        name: 'jira_delete_ticket',
        description: 'Delete a Jira ticket',
        params: [_keyParam],
      ),
    ];

/// Project-metadata read tools: issue types, fields, components, versions.
List<ToolDefinition> _projectMetaTools() => [
      _jiraTool(
        name: 'jira_get_issue_types',
        description: 'Get available issue types for a Jira project',
        category: 'project_management',
        params: [_projectParam],
      ),
      _jiraTool(
        name: 'jira_get_fields',
        description: 'Get available fields for a Jira project',
        category: 'project_management',
        params: [_projectParam],
      ),
      _jiraTool(
        name: 'jira_get_components',
        description: 'Get all components for a Jira project',
        category: 'project_management',
        params: [_projectParam],
      ),
      _jiraTool(
        name: 'jira_get_fix_versions',
        description: 'Get all fix versions for a Jira project',
        category: 'project_management',
        params: [_projectParam],
      ),
    ];

/// Ticket field-mutation tools: fix version, priority, description.
List<ToolDefinition> _ticketWriteTools() => [
      _jiraTool(
        name: 'jira_set_fix_version',
        description: 'Set the fix version on a Jira ticket',
        params: [
          _keyParam,
          ToolParam(
            name: 'fixVersion',
            description: 'The fix version name to set',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_set_priority',
        aliases: ['tracker_set_priority'],
        description: 'Set the priority on a Jira ticket',
        params: [
          _keyParam,
          ToolParam(
            name: 'priority',
            description: 'The priority name to set',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_update_description',
        aliases: ['tracker_update_description'],
        description: 'Update the description of a Jira ticket',
        params: [
          _keyParam,
          ToolParam(
            name: 'description',
            description: 'The new description text',
            required: true,
          ),
        ],
      ),
    ];

/// Subtask read tool: `jira_get_subtasks`.
List<ToolDefinition> _subtaskTools() => [
      _jiraTool(
        name: 'jira_get_subtasks',
        description: 'Get all subtasks of a Jira ticket',
        params: [_keyParam],
      ),
    ];

/// Create-with-parent tool: `jira_create_ticket_with_parent`.
List<ToolDefinition> _createWithParentTools() => [
      _jiraTool(
        name: 'jira_create_ticket_with_parent',
        description: 'Create a new Jira ticket with a parent relationship',
        params: [
          _projectParam,
          _issueTypeParam,
          _summaryParam,
          ToolParam(
            name: 'description',
            description: 'The ticket description',
            required: true,
          ),
          ToolParam(
            name: 'parentKey',
            description: 'The key of the parent ticket',
            required: true,
          ),
          _labelsParam,
        ],
      ),
    ];

/// Comment-if-not-exists tool: `jira_post_comment_if_not_exists`.
List<ToolDefinition> _commentIfExistsTools() => [
      _jiraTool(
        name: 'jira_post_comment_if_not_exists',
        description: 'Post a comment only if it does not already exist',
        params: [
          _keyParam,
          _commentTextParam,
        ],
      ),
    ];

/// ADF field update tool: `jira_update_field_as_adf`.
List<ToolDefinition> _adfFieldTools() => [
      _jiraTool(
        name: 'jira_update_field_as_adf',
        description: 'Update a Jira ticket field with an ADF document',
        params: [
          _keyParam,
          _fieldUpdateParam,
          ToolParam(
            name: 'value',
            description: 'The ADF document to set as the field value',
            type: 'object',
            required: true,
          ),
        ],
      ),
    ];

/// Field-by-name tools: search field definitions by display name and update
/// every matching field on a ticket.
List<ToolDefinition> _fieldsByNameTools() => [
      _jiraTool(
        name: 'jira_get_all_fields_with_name',
        description: 'Find all Jira field definitions matching a display name',
        category: 'project_management',
        params: [
          _projectParam,
          ToolParam(
            name: 'fieldName',
            description: 'The display name to search for',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_get_field_custom_code',
        aliases: ['tracker_get_field_code'],
        description: 'Get the custom field code for a human friendly field '
            'name in a Jira project',
        category: 'project_management',
        params: [
          _projectParam,
          ToolParam(
            name: 'fieldName',
            description: 'The human-readable field name',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_update_all_fields_with_name',
        description: 'Update every field matching a display name on a ticket',
        params: [
          _keyParam,
          ToolParam(
            name: 'fieldName',
            description: 'The display name of the fields to update',
            required: true,
          ),
          ToolParam(
            name: 'value',
            description: 'The new value for the fields',
            required: true,
          ),
        ],
      ),
    ];

/// Raw update tools: `jira_update_ticket` + `jira_update_ticket_parent`.
List<ToolDefinition> _rawUpdateTools() => [
      _jiraTool(
        name: 'jira_update_ticket',
        description: 'Update a Jira ticket with raw JSON parameters',
        params: [
          _keyParam,
          ToolParam(
            name: 'jsonParams',
            description: 'Raw JSON object to send as the update body',
            type: 'object',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_update_ticket_parent',
        description: 'Update the parent of a Jira ticket. Can be used for '
            'setting up epic relationships and parent-child relationships '
            'for subtasks',
        params: [
          _keyParam,
          ToolParam(
            name: 'parentKey',
            description: 'The key of the new parent ticket',
            required: true,
          ),
        ],
      ),
    ];

/// Issue link tools: create link + list link types.
///
/// `jira_link_issues` mirrors the Java `linkIssueWithRelationship` signature:
/// `sourceKey` / `anotherKey` / `relationship`, with the
/// `tracker_link_tickets` alias.
List<ToolDefinition> _linkTools() => [
      _jiraTool(
        name: 'jira_link_issues',
        description: 'Link two Jira issues with a specific relationship type',
        aliases: ['tracker_link_tickets'],
        params: [
          ToolParam(
            name: 'sourceKey',
            description: 'The source issue key',
            required: true,
            aliases: ['sourceId'],
          ),
          ToolParam(
            name: 'anotherKey',
            description: 'The target issue key',
            required: true,
            aliases: ['targetId'],
          ),
          ToolParam(
            name: 'relationship',
            description: 'The relationship type name',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_get_issue_link_types',
        description: 'Get all available Jira issue link types',
        category: 'project_management',
      ),
    ];

/// Generic request tool: `jira_execute_request`.
List<ToolDefinition> _genericRequestTools() => [
      _jiraTool(
        name: 'jira_execute_request',
        description:
            'Execute a GET request against an arbitrary Jira REST path',
        category: 'system',
        params: [
          ToolParam(
            name: 'url',
            description: 'The REST path relative to /rest/api/latest/',
            required: true,
          ),
        ],
      ),
    ];

/// Reusable parameter: the comment text to post.
const _commentTextParam = ToolParam(
  name: 'comment',
  description: 'The comment text to post',
  required: true,
  aliases: ['text', 'body'],
);

/// Reusable parameter: the field name to update.
const _fieldUpdateParam = ToolParam(
  name: 'field',
  description: 'The field name to update',
  required: true,
);

/// Reusable parameter: optional label list on the create tools (gh-427).
///
/// Deliberate Dart-side divergence: the Java upstream create tools declare
/// no `labels` param (see `test/fixtures/java_mcp_param_drift.txt`).
const _labelsParam = ToolParam(
  name: 'labels',
  description: 'Optional list of Jira labels to set on the created ticket',
  type: 'array',
  required: false,
);

/// Reusable parameter: issue type for ticket creation.
const _issueTypeParam = ToolParam(
  name: 'issueType',
  description: 'The type of issue to create (e.g., Bug, Story, Task)',
  required: true,
  aliases: ['workItemType'],
);

/// Reusable parameter: the ticket summary/title.
const _summaryParam = ToolParam(
  name: 'summary',
  description: 'The ticket summary/title',
  required: true,
  aliases: ['title'],
);
