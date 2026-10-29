/// Async Azure DevOps ticket operations (dm.ai #661/#663 parity).
///
/// Ports the tracker-agnostic work-item tools of Java `AzureDevOpsClient`:
/// state/assignment/description/tags/field/priority updates, create with an
/// optional parent link, relationship links, field-code lookup and
/// idempotent file attachment. Mapping logic is shared with the sync JS
/// bridge via `ado_work_item_ops.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'ado_http_client.dart';
import 'ado_work_item_ops.dart';

/// Work-item operations over an [AdoHttpClient].
class AdoWorkItemOps {
  final AdoHttpClient _http;

  /// Creates the operations bound to [_http].
  AdoWorkItemOps(this._http);

  Future<Map<String, dynamic>> _patchItem(int id, String patch) async =>
      jsonDecode(await _http.patchPatch('wit/workitems/$id', body: patch))
          as Map<String, dynamic>;

  /// Sets one [field] (reference name) on work item [id]. With [markdown]
  /// the field's format is also set to Markdown (Java `format` support).
  Future<Map<String, dynamic>> setField(
    int id,
    String field,
    Object? value, {
    bool markdown = false,
  }) =>
      _patchItem(id, adoFieldsPatch({field: value}, markdown: markdown));

  /// `ado_move_to_state` — sets `System.State`.
  Future<Map<String, dynamic>> moveToState(int id, String state) =>
      setField(id, 'System.State', state);

  /// `ado_assign_work_item` — sets `System.AssignedTo`.
  Future<Map<String, dynamic>> assign(int id, String userEmail) =>
      setField(id, 'System.AssignedTo', userEmail);

  /// `ado_update_description` — sets `System.Description`; [format] `markdown`
  /// (see [isAdoMarkdownFormat]) also marks it as Markdown.
  Future<Map<String, dynamic>> updateDescription(
    int id,
    String description, {
    String? format,
  }) =>
      setField(id, 'System.Description', description,
          markdown: isAdoMarkdownFormat(format));

  /// `ado_update_tags` — sets `System.Tags` (semicolon-separated).
  Future<Map<String, dynamic>> updateTags(int id, String tags) =>
      setField(id, 'System.Tags', tags);

  /// `ado_update_field` — sets [field] after [resolveAdoFieldName] mapping;
  /// [format] `markdown` also marks the field's format as Markdown.
  Future<Map<String, dynamic>> updateField(
    int id,
    String field,
    Object? value, {
    String? format,
  }) =>
      setField(id, resolveAdoFieldName(field), value,
          markdown: isAdoMarkdownFormat(format));

  /// `ado_set_priority` — sets the numeric priority.
  ///
  /// Throws [ArgumentError] (Java text) for an unknown priority.
  Future<Map<String, dynamic>> setPriority(int id, String priority) =>
      setField(id, 'Microsoft.VSTS.Common.Priority', mapAdoPriority(priority));

  /// `ado_link_work_items` — adds the [relationship] relation from
  /// [sourceId] to [targetId] (Java `mapRelationshipType` names).
  Future<Map<String, dynamic>> linkWorkItems(
    int sourceId,
    int targetId,
    String relationship,
  ) =>
      _patchItem(
        sourceId,
        adoRelationPatch(
          mapAdoRelationship(relationship),
          _http.buildOrgUrl('wit/workItems/$targetId'),
        ),
      );

  /// `ado_create_work_item` — creates a work item in [project] and, when
  /// [parentId] is given, links it as the parent's child (Hierarchy-Forward
  /// on the parent).
  Future<Map<String, dynamic>> createWorkItem({
    required String project,
    required String workItemType,
    required String title,
    String? description,
    Map<String, dynamic>? fieldsJson,
    String? format,
  }) async {
    // ADO rejects a numeric id in the project slot with TF200016
    // ("project does not exist: 879"); fail early with a clear message.
    if (RegExp(r'^\d+$').hasMatch(project.trim())) {
      throw ArgumentError(
          'ado_create_work_item: "$project" is a numeric id, not a project '
          'name. Pass the ADO project name.');
    }
    return jsonDecode(await _http.postPatch(
      'wit/workitems/\$$workItemType',
      body: adoCreatePatch(title, description, fieldsJson,
          markdown: isAdoMarkdownFormat(format)),
      project: project.isEmpty ? null : project,
    )) as Map<String, dynamic>;
  }

  /// Creates a work item and, when [parentId] is given, links it as the
  /// parent's child (Hierarchy-Forward on the parent).
  Future<Map<String, dynamic>> createWorkItemWithParent({
    required String project,
    required String workItemType,
    required String title,
    String? description,
    Map<String, dynamic>? fieldsJson,
    ({int? parentId, String? format})? opts,
  }) async {
    final created = await createWorkItem(
      project: project,
      workItemType: workItemType,
      title: title,
      description: description,
      fieldsJson: fieldsJson,
      format: opts?.format,
    );
    final parentId = opts?.parentId;
    if (parentId != null) {
      final childId = created['id'];
      if (childId == null) {
        throw StateError('Work item was created but the response carries no '
            'id, cannot link parent $parentId');
      }
      await linkWorkItems(parentId, int.parse('$childId'), 'child');
    }
    return created;
  }

  /// `ado_get_field_code` — the `referenceName` of the field called
  /// [fieldName] (name or reference name, case-insensitive), or `null`.
  Future<String?> getFieldCode(String? project, String fieldName) async {
    if (fieldName.trim().isEmpty) return null;
    final body = (project == null || project.trim().isEmpty)
        ? await _http.get('wit/fields')
        : await _http.getInProject(project.trim(), 'wit/fields');
    return findAdoFieldCode(body, fieldName);
  }

  /// `ado_attach_file` — uploads [filePath] and links it to work item [id];
  /// a same-named attachment (case-insensitive) is not attached twice.
  Future<Map<String, dynamic>> attachFile(
    int id,
    String name,
    String filePath,
  ) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File does not exist', filePath);
    }
    final existing = jsonDecode(await _http
        .get('wit/workitems/$id', queryParams: {r'$expand': 'relations'}));
    if (!adoHasAttachment(existing, name)) {
      final uploaded = jsonDecode(
          await _http.uploadAttachment(name, await file.readAsBytes()));
      final url = uploaded is Map ? uploaded['url'] : null;
      if (url is! String || url.isEmpty) {
        throw StateError('ADO attachment upload returned no url for $name');
      }
      await _patchItem(
        id,
        adoRelationPatch('AttachedFile', url, attributes: {'name': name}),
      );
    }
    return {'status': 'success', 'id': '$id', 'name': name};
  }
}
