import 'tool_definition.dart';

/// GitHub key formats (`gh-123`, `owner/repo#123`) — unambiguously GitHub
/// keys, never valid anywhere else (dm.ai #577 `ToolAliasResolver`).
final RegExp _gitHubKeyHint =
    RegExp(r'^(?:gh-\d+|[\w.-]+/[\w.-]+#\d+)$', caseSensitive: false);

/// Classic Jira key: `PROJ-123`.
final RegExp _jiraKeyHint = RegExp(r'^[A-Z][A-Z0-9]+-\d+$');

/// Bare numeric id — ADO work item.
final RegExp _adoKeyHint = RegExp(r'^\d+$');

/// Registry of all MCP tools, keyed by tool name.
///
/// Mirrors the Java generated `MCPToolRegistry`: tools are registered at
/// startup, filtered by the configured integrations for `dmtools list`,
/// and dispatched by name (or alias) for `dmtools <tool_name>`.
class ToolRegistry {
  final Map<String, ToolDefinition> _tools = {};
  final Map<String, String> _aliasToName = {};
  List<ToolDefinition>? _sortedTools;

  /// Registers a tool definition.
  ///
  /// If a tool with the same name is already registered, it is replaced.
  /// Each alias in [ToolDefinition.aliases] is mapped to the tool name,
  /// overwriting any earlier alias binding.
  void register(ToolDefinition tool) {
    _sortedTools = null;
    _tools[tool.name] = tool;
    for (final alias in tool.aliases) {
      _aliasToName[alias] = tool.name;
    }
  }

  /// Registers multiple tool definitions.
  void registerAll(Iterable<ToolDefinition> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// Returns `true` if [name] is a known tool name or alias.
  bool hasTool(String name) =>
      _tools.containsKey(name) || _aliasToName.containsKey(name);

  /// Returns every tool carrying [alias], in registration order.
  ///
  /// Unlike the single-binding [_aliasToName] map this keeps all
  /// candidates, mirroring the Java generated registry's
  /// `ALIAS_TO_TOOL_NAMES` multimap (one alias may be carried by several
  /// integrations, e.g. `tracker_get_ticket` on jira and ado).
  List<ToolDefinition> toolsByAlias(String alias) =>
      _tools.values.where((t) => t.aliases.contains(alias)).toList();

  /// Resolves a tool name or alias to the canonical tool name.
  ///
  /// Returns `null` when [name] is neither a registered tool nor an alias.
  String? resolveName(String name) {
    if (_tools.containsKey(name)) return name;
    return _aliasToName[name];
  }

  /// Resolves [name] following the Java `McpCliHandler.resolveToolAlias`
  /// contract.
  ///
  /// A registered canonical name resolves to itself. When [keyHint] carries
  /// a ticket/issue key, an explicit GitHub key format (`gh-123`,
  /// `owner/repo#123`) routes to the GitHub carrier before anything else —
  /// it is not a valid key anywhere else — and after the default-integration
  /// check a classic Jira key (`PROJ-123`) routes to Jira, a bare integer
  /// to ADO (dm.ai #577 `ToolAliasResolver` parity). An alias with exactly
  /// one carrier resolves to that carrier. An alias carried by several
  /// integrations picks the carrier matching the configured default
  /// integration: [defaultTracker] for `tracker_*` aliases and
  /// [defaultSourceCode] for `source_code_*` aliases (values are trimmed
  /// and lowercased like Java's env reads; other aliases ignore both).
  /// Anything unresolved falls back to the first candidate. Returns `null`
  /// when [name] is unknown.
  ///
  /// When [integrations] is given, alias candidates narrow to carriers
  /// from those integrations before routing — the first-candidate fallback
  /// then picks a carrier visible under `DMTOOLS_INTEGRATIONS` rather than
  /// one the tools list would filter out (gh-136). A canonical name still
  /// resolves to itself, and an alias with no visible carrier falls back
  /// to the unrestricted candidate list.
  String? resolveToolAlias(
    String name, {
    String? keyHint,
    String? defaultTracker,
    String? defaultSourceCode,
    Set<String>? integrations,
  }) {
    if (_tools.containsKey(name)) return name;
    final candidates = _aliasCandidates(name, integrations);
    if (candidates.isEmpty) return null;
    // 1. An explicit GitHub key format (`gh-123`, `owner/repo#123`)
    //    always routes to GitHub — it is not a valid key anywhere else.
    final githubHint = _githubHintCarrier(candidates, keyHint);
    if (githubHint != null) return githubHint.name;
    // 2. A single registered candidate needs no disambiguation.
    if (candidates.length == 1) return candidates.first.name;
    // 3. DEFAULT_TRACKER / DEFAULT_SOURCE_CODE from the property chain.
    final wanted = _defaultIntegrationFor(
      name,
      defaultTracker: defaultTracker,
      defaultSourceCode: defaultSourceCode,
    );
    if (wanted != null) {
      final byDefault = _firstByIntegration(candidates, wanted);
      if (byDefault != null) return byDefault.name;
    }
    // 4. Key-format detection: classic Jira key, then bare ADO integer id.
    final byKeyFormat = _keyFormatCarrier(candidates, keyHint);
    if (byKeyFormat != null) return byKeyFormat.name;
    // 5. Fallback: first candidate.
    return candidates.first.name;
  }

  /// The GitHub carrier for an explicit GitHub key format — `gh-123` or
  /// `owner/repo#123` (case-insensitive, surrounding whitespace trimmed) —
  /// or `null` when [hint] gives no such signal or no GitHub carrier
  /// exists.
  ToolDefinition? _githubHintCarrier(
      List<ToolDefinition> candidates, String? keyHint) {
    final hint = keyHint?.trim();
    if (hint == null || hint.isEmpty || !_gitHubKeyHint.hasMatch(hint)) {
      return null;
    }
    return _firstByIntegration(candidates, 'github');
  }

  /// The carrier picked by key-format detection — a classic Jira key
  /// (`PROJ-123`) routes to Jira, a bare integer to ADO — or `null` when
  /// the hint gives no vendor signal or the carrier is absent.
  ToolDefinition? _keyFormatCarrier(
      List<ToolDefinition> candidates, String? keyHint) {
    final hint = keyHint?.trim();
    if (hint == null || hint.isEmpty) return null;
    if (_jiraKeyHint.hasMatch(hint)) {
      return _firstByIntegration(candidates, 'jira');
    }
    if (_adoKeyHint.hasMatch(hint)) {
      return _firstByIntegration(candidates, 'ado');
    }
    return null;
  }

  /// The first candidate from [integration], or `null` when none exists.
  ToolDefinition? _firstByIntegration(
      List<ToolDefinition> candidates, String integration) {
    for (final candidate in candidates) {
      if (candidate.integration == integration) return candidate;
    }
    return null;
  }

  /// The carriers of [alias], narrowed to [integrations] when any of them
  /// is visible there — an alias with no visible carrier keeps the
  /// unrestricted candidate list, leaving the visibility decision to the
  /// caller's filter.
  List<ToolDefinition> _aliasCandidates(
      String alias, Set<String>? integrations) {
    final candidates = toolsByAlias(alias);
    if (integrations == null) return candidates;
    final visible =
        candidates.where((t) => integrations.contains(t.integration)).toList();
    return visible.isNotEmpty ? visible : candidates;
  }

  /// The integration name configured for [alias]'s prefix, if any.
  ///
  /// Java `McpCliHandler.resolveDefaultIntegrationForAlias` reads
  /// `DEFAULT_TRACKER` for `tracker_*` and `DEFAULT_SOURCE_CODE` for
  /// `source_code_*`; both are trimmed and lowercased before matching.
  String? _defaultIntegrationFor(
    String alias, {
    String? defaultTracker,
    String? defaultSourceCode,
  }) {
    final raw = alias.startsWith('tracker_')
        ? defaultTracker
        : alias.startsWith('source_code_')
            ? defaultSourceCode
            : null;
    if (raw == null) return null;
    final value = raw.trim().toLowerCase();
    return value.isEmpty ? null : value;
  }

  /// Returns the tool definition for [name], resolving aliases.
  ToolDefinition? getTool(String name) {
    final resolved = resolveName(name);
    return resolved != null ? _tools[resolved] : null;
  }

  /// Returns all registered tools, sorted alphabetically by name.
  List<ToolDefinition> get allTools => _sortedTools ??= List.unmodifiable(
      _tools.values.toList()..sort((a, b) => a.name.compareTo(b.name)));

  /// Returns tools for the given integrations, or all when [integrations]
  /// is `null`. Results are sorted alphabetically by name.
  List<ToolDefinition> toolsForIntegrations([Set<String>? integrations]) {
    if (integrations == null) return allTools;
    return _tools.values
        .where((t) => integrations.contains(t.integration))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Returns the set of integrations that have at least one tool.
  Set<String> get availableIntegrations =>
      _tools.values.map((t) => t.integration).toSet();

  /// Generates the `dmtools list` response in MCP protocol format.
  ///
  /// When [integrations] is given, only tools from those integrations are
  /// included; otherwise every registered tool is returned.
  Map<String, dynamic> generateToolsListResponse([Set<String>? integrations]) {
    final tools = toolsForIntegrations(integrations);
    return {
      'tools': tools.map((t) => t.toJson()).toList(),
    };
  }

  /// Filters a tools list response by a case-insensitive substring match on
  /// the tool name or description.
  Map<String, dynamic> filterToolsList(
    Map<String, dynamic> toolsList,
    String filter,
  ) {
    final lowerFilter = filter.toLowerCase();
    final tools = toolsList['tools'] as List;
    final filtered = tools.where((t) {
      final map = t as Map<String, dynamic>;
      return (map['name'] as String).toLowerCase().contains(lowerFilter) ||
          (map['description'] as String).toLowerCase().contains(lowerFilter);
    }).toList();
    return {'tools': filtered};
  }

  /// Clears all registered tools and aliases (for testing).
  void clear() {
    _sortedTools = null;
    _tools.clear();
    _aliasToName.clear();
  }
}
