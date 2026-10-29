/// Tracker-agnostic ADO ticket-operation tools (dm.ai #661/#663 parity):
/// definitions and executor handlers. Names, params, aliases and
/// descriptions mirror the Java `@MCPTool` annotations.
part of 'ado_tools.dart';

/// Id param with the Java `key` alias.
ToolParam _workItemId() => _idParam('The work item ID');

ToolParam _req(String name, String description,
        {List<String> aliases = const [], String type = 'string'}) =>
    ToolParam(
      name: name,
      description: description,
      aliases: aliases,
      type: type,
    );

ToolDefinition _opTool(
  String name,
  String description,
  List<ToolParam> params, {
  List<String> aliases = const [],
}) =>
    ToolDefinition(
      name: name,
      aliases: aliases,
      description: description,
      integration: 'ado',
      category: 'work_item_management',
      params: params,
    );

/// Optional `format` param (`html` default | `markdown`). A field saved as
/// Markdown cannot go back to HTML (ADO rule).
ToolParam _formatParam() => ToolParam(
      name: 'format',
      description: 'Optional content format: html (default) or markdown. '
          'A field saved as Markdown cannot go back to HTML (ADO rule).',
      required: false,
    );

/// `ado_create_work_item` — Java `createWorkItemWithFieldsJson`.
ToolDefinition _createWorkItemTool() => _opTool(
      'ado_create_work_item',
      'Create a new work item in Azure DevOps',
      [
        _req('project', 'The project name'),
        _req('workItemType', 'The work item type (Bug, Task, User Story, etc.)',
            aliases: ['issueType', 'type']),
        _req('title', 'The work item title', aliases: ['summary']),
        ToolParam(
          name: 'description',
          description: 'The work item description (HTML)',
          required: false,
          aliases: ['body'],
        ),
        ToolParam(
          name: 'fieldsJson',
          description: 'Additional fields as JSON object (e.g., '
              '{"Microsoft.VSTS.Common.Priority": 1})',
          required: false,
          type: 'object',
        ),
        ToolParam(
          name: 'parentId',
          description: 'Optional parent work item ID: the new item is '
              'created as its child (Hierarchy link)',
          required: false,
          aliases: ['parentKey'],
        ),
        _formatParam(),
      ],
      aliases: ['tracker_create_ticket'],
    );

/// Ticket-operation tools added for dm.ai #661.
List<ToolDefinition> _ticketOpTools() => [
      _opTool('ado_move_to_state', 'Move a work item to a specific state', [
        _workItemId(),
        _req('state', 'The target state name',
            aliases: ['statusName', 'status']),
      ], aliases: [
        'tracker_move_to_status'
      ]),
      _opTool('ado_assign_work_item', 'Assign a work item to a user', [
        _workItemId(),
        _req('userEmail', 'The user email or display name',
            aliases: ['accountId']),
      ], aliases: [
        'tracker_assign_ticket',
        'tracker_assign'
      ]),
      _opTool(
          'ado_update_description', 'Update the description of a work item', [
        _workItemId(),
        _req('description', 'The new description (HTML format)'),
        _formatParam(),
      ],
          aliases: [
            'tracker_update_description'
          ]),
      _opTool(
        'ado_update_tags',
        'Update the tags of a work item (semicolon-separated string)',
        [
          _workItemId(),
          _req(
              'tags',
              "Tags as semicolon-separated string (e.g., "
                  "'tag1;tag2;tag3')"),
        ],
      ),
      ..._ticketFieldTools(),
      ..._ticketLinkTools(),
    ];

/// Field-level tools: update-field, set-priority, get-field-code.
List<ToolDefinition> _ticketFieldTools() => [
      _opTool(
          'ado_update_field',
          'Update any field of a work item. The field may be a reference '
              'name (System.Title, Custom.SolutionDesign) or a common human '
              'name (summary, title, description, priority, tags, state, '
              'assignedTo, storyPoints), which is mapped to its reference '
              'name. Unknown names are passed through unchanged.',
          [
            _workItemId(),
            _req('field', 'Field reference name or common name'),
            _req('value', 'The new value'),
            _formatParam(),
          ],
          aliases: [
            'tracker_update_field'
          ]),
      _opTool(
          'ado_set_priority',
          'Set the priority of a work item. Accepts the ADO numbers 1-4 or '
              'Jira-style names (Blocker/Highest/Critical=1, High/Major=2, '
              'Medium/Normal=3, Low/Minor/Lowest/Trivial=4).',
          [
            _workItemId(),
            _req('priority', 'Priority number 1-4 or a priority name'),
          ],
          aliases: [
            'tracker_set_priority'
          ]),
      _opTool(
          'ado_get_field_code',
          'Resolve a human-readable field name to its reference name for the '
              "project (the analogue of jira_get_field_custom_code). Returns "
              "e.g. 'Custom.SolutionDesign' or 'System.Title'; returns null "
              'when no field with that name exists.',
          [
            ToolParam(
              name: 'project',
              description: 'The project name (defaults to the configured '
                  'project)',
              required: false,
            ),
            _req(
                'fieldName',
                "The human-readable field name (e.g. 'Solution Design') or "
                    'reference name'),
          ],
          aliases: [
            'tracker_get_field_code'
          ]),
    ];

/// Link and attachment tools.
List<ToolDefinition> _ticketLinkTools() => [
      _opTool(
          'ado_link_work_items',
          'Link two work items with a relationship (e.g., Parent-Child, '
              'Related, Tested By)',
          [
            _req('sourceId', 'The source work item ID',
                aliases: ['sourceKey'], type: 'number'),
            _req('targetId', 'The target work item ID to link to',
                aliases: ['anotherKey'], type: 'number'),
            _req(
                'relationship',
                "Relationship type (e.g., 'parent', 'child', 'related', "
                    "'tested by', 'tests')"),
          ],
          aliases: [
            'tracker_link_tickets'
          ]),
      _opTool(
          'ado_attach_file',
          'Attach a local file to a work item. Uploads the file and links it '
              'as an attachment; a file with the same name is not attached '
              'twice.',
          [
            _req('id', 'The work item ID',
                aliases: ['ticketKey', 'key'], type: 'number'),
            _req('name', 'The attachment file name'),
            ToolParam(
              name: 'contentType',
              description: 'The content type (defaults to '
                  'application/octet-stream)',
              required: false,
            ),
            _req('filePath', 'Absolute path to the file on disk'),
          ],
          aliases: [
            'tracker_attach_file'
          ]),
    ];

typedef _AdoHandler = Future<dynamic> Function(Map<String, dynamic>);

String _s(Map<String, dynamic> a, String key, [String? alt]) =>
    '${a[key] ?? (alt == null ? '' : a[alt]) ?? ''}';

/// Executor handlers for the ticket-operation tools.
Map<String, _AdoHandler> _ticketOpHandlers(AdoWorkItemOps ops) => {
      'ado_create_work_item': (a) => ops.createWorkItemWithParent(
            project: _s(a, 'project'),
            workItemType: _s(a, 'workItemType', 'type'),
            title: _s(a, 'title'),
            description: a['description'] as String?,
            fieldsJson: _fieldsJsonArg(a['fieldsJson']),
            opts: (
              parentId: _optInt(a['parentId']),
              format: a['format'] as String?
            ),
          ),
      'ado_move_to_state': (a) => ops.moveToState(_id(a), _s(a, 'state')),
      'ado_assign_work_item': (a) => ops.assign(_id(a), _s(a, 'userEmail')),
      'ado_update_description': (a) => ops.updateDescription(
          _id(a), _s(a, 'description'),
          format: a['format'] as String?),
      'ado_update_tags': (a) => ops.updateTags(_id(a), _s(a, 'tags')),
      'ado_update_field': (a) => ops.updateField(
          _id(a), _s(a, 'field'), a['value'],
          format: a['format'] as String?),
      'ado_set_priority': (a) => ops.setPriority(_id(a), _s(a, 'priority')),
      'ado_get_field_code': (a) =>
          ops.getFieldCode(a['project'] as String?, _s(a, 'fieldName')),
      'ado_link_work_items': (a) => ops.linkWorkItems(
            _num(a, 'sourceId'),
            _num(a, 'targetId'),
            _s(a, 'relationship'),
          ),
      'ado_attach_file': (a) =>
          ops.attachFile(_id(a), _s(a, 'name'), _s(a, 'filePath')),
    };

int? _optInt(dynamic v) {
  if (v == null || '$v'.trim().isEmpty) return null;
  return v is int ? v : int.parse('$v'.trim());
}

Map<String, dynamic>? _fieldsJsonArg(dynamic v) {
  if (v == null || v == '') return null;
  final decoded = v is String ? jsonDecode(v) : v;
  return Map<String, dynamic>.from(decoded as Map);
}
