/// Attachment tool definitions and dispatch — one domain per file.
part of 'jira_tools.dart';

/// Attachment tools: file upload and binary download.
List<ToolDefinition> _attachmentTools() => [
      _jiraTool(
        name: 'jira_attach_file_to_ticket',
        aliases: ['tracker_attach_file'],
        description: 'Attach a file to a Jira ticket via multipart upload',
        params: [
          ToolParam(
            name: 'key',
            description: 'The Jira ticket key (e.g. PROJ-123)',
            required: true,
            aliases: ['ticketKey', 'id'],
          ),
          ToolParam(
            name: 'fileName',
            description: 'The name to give the attached file',
            required: true,
          ),
          ToolParam(
            name: 'filePath',
            description: 'The local file path to upload',
            required: true,
          ),
        ],
      ),
      _jiraTool(
        name: 'jira_download_attachment',
        aliases: ['tracker_download_attachment'],
        description: 'Download a Jira attachment to a local file',
        category: 'system',
        params: [
          ToolParam(
            name: 'url',
            description: 'The full attachment download URL',
            required: true,
          ),
          ToolParam(
            name: 'filePath',
            description: 'The local file path to save to',
            required: true,
          ),
        ],
      ),
    ];

/// Attachment read tool: `jira_get_attachments`.
List<ToolDefinition> _attachmentReadTools() => [
      _jiraTool(
        name: 'jira_get_attachments',
        description: 'Get all attachments for a Jira ticket',
        params: [_keyParam],
      ),
    ];

/// Attachment dispatch entries, provided via a library-private extension so
/// the main [JiraToolExecutor] file stays within the line-count gate.
extension _JiraAttachmentToolExecutor on JiraToolExecutor {
  /// Routes the attachment tool names to their [JiraClient] calls.
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>
      _attachmentHandlers() => {
            'jira_attach_file_to_ticket': (a) => _client.attachFileToTicket(
                  a['key'] as String,
                  a['fileName'] as String,
                  a['filePath'] as String,
                ),
            'jira_download_attachment': (a) => _client.downloadAttachment(
                  a['url'] as String,
                  a['filePath'] as String,
                ),
            'jira_get_attachments': (a) =>
                _client.getAttachments(a['key'] as String),
          };
}
