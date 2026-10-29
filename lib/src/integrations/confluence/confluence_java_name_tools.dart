part of 'confluence_tools.dart';

/// Boilerplate-free `ToolDefinition` for the Java-named tools: the
/// integration is always `confluence` (duplication gate).
ToolDefinition _javaTool({
  required String name,
  required String description,
  required String category,
  required List<ToolParam> params,
}) =>
    ToolDefinition(
      name: name,
      description: description,
      integration: 'confluence',
      category: category,
      params: params,
    );

/// Boilerplate-free `ToolParam` (duplication gate): name + description
/// with `required` defaulting to true like the Java `@MCPParam`s.
ToolParam _param(String name, String description, {bool required = true}) =>
    ToolParam(name: name, description: description, required: required);

/// The gh-191 Java-named tools (frozen gap snapshot, `Confluence.java`
/// `@MCPTool` annotations), grouped per the file's list-function pattern.

/// All Java-named tool definitions in Java catalog order.
List<ToolDefinition> javaNameConfluenceTools() => [
      ..._javaNameContentByTitleTools(),
      ..._javaNameUrlFetchTools(),
      ..._javaNameFindTools(),
      ..._javaNameFindOrCreateTools(),
      ..._javaNameAttachmentListTools(),
      ..._javaNameInlineCommentTools(),
      ..._javaNameProfileAndSearchTools(),
      ..._javaNameHistoryUpdateTools(),
      ..._javaNameUploadTools(),
    ];

/// Default-space title content: `confluence_content_by_title` / `confluence_content_by_title_and_space`.
List<ToolDefinition> _javaNameContentByTitleTools() => [
      _javaTool(
        name: 'confluence_content_by_title',
        description: 'Get Confluence content by title in the default space. '
            'Returns content result with metadata and body information. Use '
            'format=md to convert body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('title', 'Title of the Confluence page to get'),
          _formatParam(),
        ],
      ),
      _javaTool(
        name: 'confluence_content_by_title_and_space',
        description: 'Get Confluence content by title and space key. Returns '
            'content result with metadata and body information. Use format=md '
            'to convert body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('title', 'The title of the Confluence page'),
          _param('space', 'The space key where the content is located'),
          _formatParam(),
        ],
      ),
    ];

/// URL fetch + recursive page download: `confluence_contents_by_urls` / `confluence_download_pages`.
List<ToolDefinition> _javaNameUrlFetchTools() => [
      _javaTool(
        name: 'confluence_contents_by_urls',
        description: 'Get Confluence content by multiple URLs. Returns a list '
            'of content objects for each valid URL. Use format=md to convert '
            'body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('urlStrings',
              'Array of Confluence URLs to retrieve content from'),
          _formatParam(),
        ],
      ),
      _javaTool(
        name: 'confluence_download_pages',
        description: 'Download Confluence pages and their attachments to a '
            'local folder. Follows child pages down to the given depth.',
        category: 'content_management',
        params: [
          _param('urlStrings', 'Array of Confluence page URLs to download'),
          ToolParam(
            name: 'outputPath',
            description:
                'Local folder path where pages and attachments will be saved',
            required: true,
          ),
          ToolParam(
            name: 'depth',
            description:
                'How many levels of child pages to follow. Default is 1.',
            required: false,
          ),
          ToolParam(
            name: 'downloadAttachments',
            description:
                'Whether to download page attachments. Default is true.',
            required: false,
          ),
        ],
      ),
    ];

/// Find-by-title family: `confluence_find_content` / `confluence_find_content_by_title_and_space`.
List<ToolDefinition> _javaNameFindTools() => [
      _javaTool(
        name: 'confluence_find_content',
        description: 'Find a Confluence page by title in the default space. '
            "Returns the page content if found. Use format=md to convert "
            'body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('title', 'Title of the Confluence page to find'),
          _formatParam(),
        ],
      ),
      _javaTool(
        name: 'confluence_find_content_by_title_and_space',
        description: 'Find Confluence content by title and space key. '
            'Returns the first matching content or null if not found. Use '
            'format=md to convert body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('title', 'The title of the content to find'),
          _param('space', 'The space key where to search for the content'),
          _formatParam(),
        ],
      ),
    ];

/// Find-or-create + children-by-name: `confluence_find_or_create` / `confluence_get_children_by_name`.
List<ToolDefinition> _javaNameFindOrCreateTools() => [
      _javaTool(
        name: 'confluence_find_or_create',
        description: 'Find a Confluence page by title in the default space, '
            "or create it if it doesn't exist. Returns the found or created "
            'content.',
        category: 'content_management',
        params: [
          _param('title', 'Title of the page to find or create'),
          _param('parentId', 'ID of the parent page for creation'),
          _param('body',
              'Body content for the new page (if creation is ' 'needed)'),
        ],
      ),
      _javaTool(
        name: 'confluence_get_children_by_name',
        description: 'Get child pages of a Confluence page by space key and '
            'content name. Returns a list of child content objects. Use '
            'format=md to convert body.storage.value to Markdown.',
        category: 'content_retrieval',
        params: [
          _param('spaceKey', 'The space key where the parent page is located'),
          _param('contentName', 'The name/title of the parent page'),
          _formatParam(),
        ],
      ),
    ];

/// Attachment listing: `confluence_get_content_attachments`.
List<ToolDefinition> _javaNameAttachmentListTools() => [
      _javaTool(
        name: 'confluence_get_content_attachments',
        description: 'Get all attachments for a specific Confluence content. '
            'Returns a list of attachment objects with metadata.',
        category: 'content_management',
        params: [
          _param('contentId', 'The content ID to get attachments for'),
        ],
      ),
    ];

/// Inline comment tools: `confluence_get_page_inline_comments` /
/// `confluence_reply_to_inline_comment`.
List<ToolDefinition> _javaNameInlineCommentTools() => [
      _javaTool(
        name: 'confluence_get_page_inline_comments',
        description: 'Get inline comments (annotations) for a Confluence page. '
            'Uses the Confluence REST API v2 and returns comment bodies in '
            'storage format.',
        category: 'content_retrieval',
        params: [
          _param('pageId', 'The content ID of the Confluence page'),
          ToolParam(
            name: 'limit',
            description: 'Maximum number of inline comments to return. '
                'Defaults to 25 if not provided.',
            required: false,
          ),
        ],
      ),
      _javaTool(
        name: 'confluence_reply_to_inline_comment',
        description: 'Reply to an existing inline comment (annotation) on a '
            'Confluence page. The reply body is treated as plain text and '
            'converted to Confluence storage format.',
        category: 'content_management',
        params: [
          _param(
            'pageId',
            'The content ID of the Confluence page where the inline comment is '
                'located',
          ),
          _param(
            'commentId',
            'The ID of the inline comment (annotation) to reply to',
          ),
          _param(
            'body',
            'The reply text in plain text. Line breaks are converted to '
                'paragraphs.',
          ),
        ],
      ),
    ];

/// User profiles + text search: `confluence_get_current_user_profile`, `confluence_get_user_profile_by_id`, `confluence_search_content_by_text`.
List<ToolDefinition> _javaNameProfileAndSearchTools() => [
      _javaTool(
        name: 'confluence_get_current_user_profile',
        description: "Get the current user's profile information from "
            'Confluence. Returns user details for the authenticated user.',
        category: 'user_management',
        params: [],
      ),
      _javaTool(
        name: 'confluence_get_user_profile_by_id',
        description: "Get a specific user's profile information from "
            'Confluence by user ID. Returns user details for the specified '
            'user.',
        category: 'user_management',
        params: [
          _param('userId', 'The account ID of the user to get profile for'),
        ],
      ),
      _javaTool(
        name: 'confluence_search_content_by_text',
        description: 'Search Confluence content by text query using CQL '
            '(Confluence Query Language). Returns search results with content '
            'excerpts. Default limit is 20 if not specified.',
        category: 'search',
        params: [
          _param('query', 'Search query text to find in Confluence content'),
          ToolParam(
            name: 'limit',
            description:
                'Maximum number of search results to return. Default is 20 '
                'if not provided.',
            required: false,
          ),
        ],
      ),
    ];

/// History-aware page update: `confluence_update_page_with_history`.
List<ToolDefinition> _javaNameHistoryUpdateTools() => [
      _javaTool(
        name: 'confluence_update_page_with_history',
        description: 'Update an existing Confluence page with new content and '
            'add a history comment. Returns the updated content object.',
        category: 'content_management',
        params: [
          _param('contentId', 'The ID of the page to update'),
          _param('title', 'The new title for the page'),
          _param('parentId', 'The ID of the new parent page'),
          ToolParam(
            name: 'body',
            description:
                'The new body content of the page in Confluence storage format',
            required: true,
          ),
          _param('space', 'The space key where the page is located'),
          _param('historyComment', 'Comment to add to the page history'),
        ],
      ),
    ];

/// Attachment uploads: `confluence_upload_attachment` / `confluence_upload_attachments`.
List<ToolDefinition> _javaNameUploadTools() => [
      ToolDefinition(
        name: 'confluence_upload_attachment',
        description:
            'Upload a single file as an attachment to a Confluence page. '
            'Skips existing attachments by default. Returns the attachment '
            'object.',
        integration: 'confluence',
        category: 'content_management',
        params: [
          ToolParam(
            name: 'contentId',
            description: 'The content ID of the page to attach the file to',
            required: true,
          ),
          ToolParam(
            name: 'file',
            description: 'The local file to upload',
            required: true,
          ),
          ToolParam(
            name: 'updateIfExists',
            description:
                'Whether to overwrite an existing attachment with the same '
                'name',
            required: false,
          ),
        ],
      ),
      ToolDefinition(
        name: 'confluence_upload_attachments',
        description:
            'Upload all files in a directory as attachments to a Confluence '
            'page. Existing attachments are skipped by default. Returns a '
            'JSON summary.',
        integration: 'confluence',
        category: 'content_management',
        params: [
          ToolParam(
            name: 'contentId',
            description: 'The content ID of the page to attach files to',
            required: true,
          ),
          ToolParam(
            name: 'directory',
            description: 'The local directory containing files to upload',
            required: true,
          ),
          ToolParam(
            name: 'updateIfExists',
            description:
                'Whether to overwrite existing attachments with the same names',
            required: false,
          ),
        ],
      ),
    ];

/// Handlers: content/find/URL/profile/search/history-update tools.
Map<String, Future<dynamic> Function(Map<String, dynamic>)>
    _javaNameLookupHandlers(ConfluenceClient client) => {
          'confluence_content_by_title': (a) => client.contentByTitle(
                a['title'] as String,
                a['format'] as String?,
                a['space'] as String?,
              ),
          'confluence_content_by_title_and_space': (a) =>
              client.contentByTitleAndSpace(
                a['title'] as String,
                a['space'] as String,
                a['format'] as String?,
              ),
          'confluence_contents_by_urls': (a) => client.contentsByUrls(
                (a['urlStrings'] as List).map((e) => e as String).toList(),
                a['format'] as String?,
              ),
          'confluence_download_pages': (a) => client.downloadPages(
                (a['urlStrings'] as List).map((e) => e as String).toList(),
                a['outputPath'] as String,
                _intArg(a, 'depth', 1) ?? 1,
                _boolArg(a, 'downloadAttachments', fallback: true),
              ),
          'confluence_find_content': (a) => client.findContent(
                a['title'] as String,
                space: a['space'] as String?,
                format: a['format'] as String?,
              ),
          'confluence_find_content_by_title_and_space': (a) =>
              client.findContent(
                a['title'] as String,
                space: a['space'] as String,
                format: a['format'] as String?,
              ),
          'confluence_find_or_create': (a) => client.findOrCreate(
                a['title'] as String,
                a['parentId'] as String,
                a['body'] as String,
              ),
          'confluence_get_children_by_name': (a) => client.getChildrenByName(
                a['spaceKey'] as String,
                a['contentName'] as String,
                a['format'] as String?,
              ),
        };

/// Handlers: attachment listing + uploads.
Map<String, Future<dynamic> Function(Map<String, dynamic>)>
    _javaNameTransferHandlers(ConfluenceClient client) => {
          'confluence_get_content_attachments': (a) =>
              client.getContentAttachments(a['contentId'] as String),
          'confluence_get_current_user_profile': (_) =>
              client.getCurrentUserProfile(),
          'confluence_get_user_profile_by_id': (a) =>
              client.getUserProfileById(a['userId'] as String),
          'confluence_search_content_by_text': (a) =>
              client.searchContentByText(
                a['query'] as String,
                _intArg(a, 'limit'),
              ),
          'confluence_update_page_with_history': (a) =>
              client.updatePageWithHistory(
                contentId: a['contentId'] as String,
                title: a['title'] as String,
                parentId: a['parentId'] as String,
                body: a['body'] as String,
                space: a['space'] as String,
                historyComment: a['historyComment'] as String,
              ),
          'confluence_upload_attachment': (a) => client.uploadAttachment(
                a['contentId'] as String,
                a['file'] as String,
                _boolArg(a, 'updateIfExists'),
              ),
          'confluence_upload_attachments': (a) => client.uploadAttachments(
                a['contentId'] as String,
                a['directory'] as String,
                _boolArg(a, 'updateIfExists'),
              ),
          'confluence_get_page_inline_comments': (a) =>
              client.getPageInlineComments(
                a['pageId'] as String,
                _intArg(a, 'limit'),
              ),
          'confluence_reply_to_inline_comment': (a) =>
              client.replyToInlineComment(
                a['pageId'] as String,
                a['commentId'] as String,
                a['body'] as String,
              ),
        };

/// Handler entries for the Java-named tools, spread into
/// `ConfluenceToolExecutor._handlers`.
Map<String, Future<dynamic> Function(Map<String, dynamic>)> javaNameHandlers(
  ConfluenceClient client,
) =>
    {
      ..._javaNameLookupHandlers(client),
      ..._javaNameTransferHandlers(client),
    };
