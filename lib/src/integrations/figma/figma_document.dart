/// Pure JSON shaping for the Java-parity Figma tools — ports the
/// `FigmaFileResponse` / `FigmaFileDocument` / `FigmaIconsResult` /
/// `FigmaNodeChildrenResult` / `FigmaTextContentResult` /
/// `FigmaStylesResult` model behavior.
///
/// Everything here is a pure function from decoded API JSON to the result
/// envelope the Java `@MCPTool` methods build, so both the async
/// [FigmaClient] and the sync JS-surface executors share one implementation.
library;

import 'dart:convert';

/// Node types the Java `isExportableVisualElement` accepts.
const _exportableTypes = {
  'VECTOR',
  'BOOLEAN_OPERATION',
  'RECTANGLE',
  'ELLIPSE',
  'POLYGON',
  'STAR',
  'LINE',
  'FRAME',
  'GROUP',
  'COMPONENT',
  'INSTANCE',
  'COMPONENT_SET',
  'TEXT',
};

/// Node types the Java `isVectorBased` recognizes (SVG-capable).
const _vectorTypes = {
  'VECTOR',
  'BOOLEAN_OPERATION',
  'RECTANGLE',
  'ELLIPSE',
  'POLYGON',
  'STAR',
  'LINE',
};

/// Node types that additionally support PDF export.
const _pdfTypes = {'FRAME', 'COMPONENT', 'COMPONENT_SET'};

/// Name fragments the Java `isLikelyIcon` matches.
const _iconNameHints = ['icon', 'chevron', 'arrow', 'button', 'exit', 'badge'];

/// Symbol characters the Java icon-name regex carries.
const _iconSymbols = [
  '♣',
  '♠',
  '♥',
  '♦',
  '🏠',
  '📦',
  '💬',
  '👤',
  '⚙️',
  '🔒',
  '😊',
  '🤝',
  'ℹ️',
];

/// Finds all exportable visual elements in a file or nodes response —
/// Java `FigmaFileResponse.findAllComponents`.
///
/// A `nodes` envelope walks every node's `document`; a `document` envelope
/// walks the document tree directly.
List<Map<String, dynamic>> figmaFindAllComponents(
  Map<String, dynamic> response,
) {
  final components = <Map<String, dynamic>>[];
  final nodes = response['nodes'];
  if (nodes is Map) {
    for (final nodeData in nodes.values) {
      final document = figmaNodeDataDocument(nodeData);
      if (document != null) {
        _findComponentsRecursively(
          document,
          document['id']?.toString(),
          components,
        );
      }
    }
  } else {
    final document = response['document'];
    if (document is Map) {
      _findComponentsRecursively(
        Map<String, dynamic>.from(document),
        'document',
        components,
      );
    }
  }
  return components;
}

/// Recursively collects exportable elements — Java
/// `FigmaFileDocument.findComponentsRecursively`.
void _findComponentsRecursively(
  Map<String, dynamic> node,
  String? nodeId,
  List<Map<String, dynamic>> components,
) {
  if (_isExportableVisualElement(node)) {
    components.add(_iconFromNode(node, nodeId));
  }
  final children = node['children'];
  if (children is List) {
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is Map) {
        final childMap = Map<String, dynamic>.from(child);
        final childId = childMap['id']?.toString() ?? '${nodeId}_child_$i';
        _findComponentsRecursively(childMap, childId, components);
      }
    }
  }
}

/// Java `FigmaFileDocument.isExportableVisualElement` parity, decomposed
/// into its independent checks.
bool _isExportableVisualElement(Map<String, dynamic> node) {
  final type = node['type']?.toString() ?? '';
  return _exportableTypes.contains(type) &&
      !_isOvercomplexId(node['id']?.toString()) &&
      !_isExplicitlyHidden(node) &&
      !_isNearlyTransparent(node) &&
      _hasPositiveBounds(node) &&
      !_isOversizedContainer(node, type);
}

/// Java filter for `I…;…;…;…` instance ids (4+ semicolon parts).
bool _isOvercomplexId(String? id) =>
    id != null && id.contains(';') && id.split(';').length >= 4;

/// Java: `visible` present and false → not renderable.
bool _isExplicitlyHidden(Map<String, dynamic> node) =>
    node.containsKey('visible') && node['visible'] == false;

/// Java: `opacity` present and below 0.01 → not renderable.
bool _isNearlyTransparent(Map<String, dynamic> node) =>
    node.containsKey('opacity') && _asDouble(node['opacity']) < 0.01;

/// Java: positive bounding-box dimensions are required.
bool _hasPositiveBounds(Map<String, dynamic> node) =>
    _widthOf(node) > 0 && _heightOf(node) > 0;

/// Java: FRAME/GROUP larger than 200×200 are UI containers, not elements.
bool _isOversizedContainer(Map<String, dynamic> node, String type) =>
    _widthOf(node) > 200 &&
    _heightOf(node) > 200 &&
    (type == 'FRAME' || type == 'GROUP');

/// Builds one icon entry — Java `FigmaIcon.fromNode`.
Map<String, dynamic> _iconFromNode(Map<String, dynamic> node, String? nodeId) {
  final type = node['type']?.toString() ?? 'unknown';
  return {
    ..._identityOf(node, idFallback: nodeId, typeFallback: 'unknown'),
    'width': _widthOf(node),
    'height': _heightOf(node),
    'supportedFormats': _supportedFormats(type),
    'isVectorBased': _vectorTypes.contains(type),
    'category': _elementCategory(node, type),
  };
}

/// Java `FigmaFileDocument.getSupportedFormats` parity.
List<String> _supportedFormats(String type) {
  final formats = ['png', 'jpg'];
  if (_vectorTypes.contains(type)) {
    formats.add('svg');
  }
  if (_pdfTypes.contains(type)) {
    formats.add('pdf');
  }
  return formats;
}

/// Java `FigmaFileDocument.getElementCategory` parity.
String _elementCategory(Map<String, dynamic> node, String type) {
  if (_isLikelyIcon(node, type)) {
    return 'icon';
  }
  if (_isLikelyIllustration(node, type)) {
    return 'illustration';
  }
  if (type == 'TEXT') {
    return 'text';
  }
  return 'graphic';
}

/// Java `FigmaFileDocument.isLikelyIcon` parity, decomposed into the
/// name-match and small-shape heuristics.
bool _isLikelyIcon(Map<String, dynamic> node, String type) {
  final name = node['name']?.toString().toLowerCase() ?? '';
  return _iconNameMatch(name) ||
      _smallShapeByType(type, _widthOf(node), _heightOf(node));
}

/// Java icon-name heuristics: hint fragments or symbol characters.
bool _iconNameMatch(String name) =>
    _iconNameHints.any(name.contains) || _iconSymbols.any(name.contains);

/// Icon size ceilings per node type (Java small-shape parity).
const _iconCeilingByType = <String, double>{
  'COMPONENT': 48.0,
  'INSTANCE': 48.0,
  'VECTOR': 64.0,
  'RECTANGLE': 50.0,
  'ELLIPSE': 50.0,
};

/// Java small-shape heuristics per node type (positive size within the
/// type's icon ceiling).
bool _smallShapeByType(String type, double width, double height) {
  final ceiling = _iconCeilingByType[type] ?? 0.0;
  return ceiling > 0 &&
      width > 0 &&
      height > 0 &&
      width <= ceiling &&
      height <= ceiling;
}

/// Java `FigmaFileDocument.isLikelyIllustration` parity, decomposed into
/// the name-match and large-element heuristics.
bool _isLikelyIllustration(Map<String, dynamic> node, String type) {
  final name = node['name']?.toString().toLowerCase() ?? '';
  return _illustrationNameMatch(name) ||
      _largeElementByType(type, _widthOf(node), _heightOf(node));
}

/// Java illustration-name heuristics.
bool _illustrationNameMatch(String name) =>
    name.contains('illustration') ||
    name.contains('graphic') ||
    name.contains('image') ||
    name.contains('master') ||
    name.contains('header') ||
    name.contains('section') ||
    (name.contains('tab') && name.contains('services'));

/// Java large-element heuristics: big FRAMEs and large GROUP/VECTORs read
/// as illustrations.
bool _largeElementByType(String type, double width, double height) =>
    (type == 'FRAME' && width > 200 && height > 100) ||
    ((type == 'GROUP' || type == 'VECTOR') && width > 100 && height > 100);

/// Maps a node's children to the layer summaries shared by
/// `figma_get_layers` / `figma_get_layers_batch` / `figma_get_node_children`
/// — Java's `layerInfo` JSONObject.
List<Map<String, dynamic>> figmaLayerSummaries(Map<String, dynamic> document) {
  final children = document['children'];
  if (children is! List) {
    return const [];
  }
  return [
    for (final child in children)
      if (child is Map) _layerInfo(Map<String, dynamic>.from(child)),
  ];
}

/// One layer entry: id/name/type, bounding-box dims when present, and
/// `visible` defaulting to `true`.
Map<String, dynamic> _layerInfo(Map<String, dynamic> child) {
  final layer = _identityOf(child);
  final bbox = child['absoluteBoundingBox'];
  if (bbox is Map) {
    layer['width'] = _asDouble(bbox['width']);
    layer['height'] = _asDouble(bbox['height']);
    layer['x'] = _asDouble(bbox['x']);
    layer['y'] = _asDouble(bbox['y']);
  }
  layer['visible'] = child['visible'] ?? true;
  return layer;
}

/// Builds the `figma_get_icons` result envelope — Java
/// `FigmaIconsResult.create`.
Map<String, dynamic> figmaIconsResult(
  String fileId,
  List<Map<String, dynamic>> icons,
) =>
    {'fileId': fileId, 'totalIcons': icons.length, 'icons': icons};

/// Builds the `figma_get_text_content` result envelope — Java
/// `FigmaTextContentResult.create` over the per-node extraction in
/// `getTextContent`. Only requested ids whose document is a TEXT node
/// appear, keyed in request order.
Map<String, dynamic> figmaTextContent(
  Map<String, dynamic> response,
  List<String> nodeIds,
) {
  final textNodes = <String, dynamic>{};
  final nodes = response['nodes'];
  for (final nodeId in nodeIds) {
    final nodeData = nodes is Map ? nodes[nodeId] : null;
    final document = figmaNodeDataDocument(nodeData);
    if (document == null || document['type'] != 'TEXT') {
      continue;
    }
    textNodes[nodeId] = _textEntry(document);
  }
  return {'textNodes': textNodes};
}

/// One text entry — Java's `entryData` JSONObject (style keys appear only
/// when a style object exists).
Map<String, dynamic> _textEntry(Map<String, dynamic> document) {
  final entry = <String, dynamic>{
    'text': document['characters']?.toString() ?? '',
  };
  final style = document['style'];
  if (style is Map) {
    entry['fontFamily'] = style['fontFamily']?.toString() ?? '';
    entry['fontSize'] = _asDouble(style['fontSize']);
    entry['fontWeight'] = _asInt(style['fontWeight'], 400);
    entry['lineHeight'] = _asDouble(style['lineHeightPx']);
    entry['letterSpacing'] = _asDouble(style['letterSpacing']);
    entry['textAlign'] = style['textAlignHorizontal']?.toString() ?? 'LEFT';
  }
  final overrides = document['characterStyleOverrides'];
  if (overrides is List && overrides.isNotEmpty) {
    entry['characterStyleOverrides'] = overrides;
  }
  final overrideTable = document['styleOverrideTable'];
  if (overrideTable is Map && overrideTable.isNotEmpty) {
    entry['styleOverrideTable'] = overrideTable;
  }
  return entry;
}

/// The `figma_get_styles` envelope — Java returns empty token arrays (the
/// styles endpoint carries metadata, not values).
Map<String, dynamic> figmaStylesResult() => {
      'colorStyles': <dynamic>[],
      'textStyles': <dynamic>[],
    };

/// Builds the `figma_test` / `figma_me` result — Java `me()` parity.
///
/// Exactly one of [body] (a successful HTTP response) or [error] (a thrown
/// failure, with [errorClass] its type name) is given. A blank body is the
/// "Empty response" failure; a non-JSON body or one without `id`/`handle`
/// is the "Unexpected response format" failure.
Map<String, dynamic> figmaMeResult({
  String? body,
  String? error,
  String? errorClass,
}) {
  if (error != null) {
    return {
      'success': false,
      'message': 'Figma API connection failed: $error',
      'error': errorClass,
    };
  }
  if (body == null || body.isEmpty) {
    return {'success': false, 'message': 'Empty response from Figma API'};
  }
  return _figmaMeBodyResult(body);
}

/// The success/failure shape of a non-empty [body] — Java
/// `new JSONObject(response)` semantics split out of [figmaMeResult] to
/// keep the CRAP score under the project threshold.
Map<String, dynamic> _figmaMeBodyResult(String body) {
  Object? decoded;
  var parseFailed = false;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    parseFailed = true;
  }
  // Java: new JSONObject(response) throws on non-JSON, so the catch branch
  // (connection-failed shape) handles it.
  if (parseFailed) {
    return const {
      'success': false,
      'message': 'Figma API connection failed: FormatException',
      'error': 'FormatException',
    };
  }
  if (decoded is! Map<String, dynamic> ||
      (!decoded.containsKey('id') && !decoded.containsKey('handle'))) {
    return {
      'success': false,
      'message': 'Unexpected response format from Figma API',
    };
  }
  final user = <String, dynamic>{
    'id': decoded['id']?.toString() ?? 'unknown',
    'handle': decoded['handle']?.toString() ?? 'unknown',
  };
  if (decoded['email'] != null) {
    user['email'] = decoded['email'].toString();
  }
  return {
    'success': true,
    'message': 'Figma API connection successful',
    'user': user,
  };
}

/// The `document` object of one node entry in a `/nodes` response, or
/// `null` when the node or its document is absent. Callers normalize
/// dashed node ids with [figmaColonNodeId] when the API keys them by
/// colon id.
Map<String, dynamic>? figmaNodeDocument(
  Map<String, dynamic>? response,
  String nodeId,
) {
  final nodes = response?['nodes'];
  if (nodes is! Map) {
    return null;
  }
  return figmaNodeDataDocument(nodes[nodeId]);
}

/// Reads `document` out of a node-data envelope.
Map<String, dynamic>? figmaNodeDataDocument(dynamic nodeData) {
  if (nodeData is Map && nodeData['document'] is Map) {
    return Map<String, dynamic>.from(nodeData['document'] as Map);
  }
  return null;
}

/// The `{id, name, type}` identity prefix shared by icon and layer
/// entries.
Map<String, dynamic> _identityOf(
  Map<String, dynamic> node, {
  Object? idFallback = '',
  String typeFallback = '',
}) =>
    {
      'id': node['id']?.toString() ?? idFallback,
      'name': node['name']?.toString() ?? '',
      'type': node['type']?.toString() ?? typeFallback,
    };

/// Width from `absoluteBoundingBox` (Java `getWidth`, default 0).
double _widthOf(Map<String, dynamic> node) => _bboxDim(node, 'width');

/// Height from `absoluteBoundingBox` (Java `getHeight`, default 0).
double _heightOf(Map<String, dynamic> node) => _bboxDim(node, 'height');

double _bboxDim(Map<String, dynamic> node, String key) {
  final bbox = node['absoluteBoundingBox'];
  return bbox is Map ? _asDouble(bbox[key]) : 0;
}

double _asDouble(dynamic value) => value is num ? value.toDouble() : 0.0;

int _asInt(dynamic value, int fallback) =>
    value is num ? value.toInt() : fallback;
