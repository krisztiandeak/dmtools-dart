import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/integrations/ai/ai_request.dart';
import 'package:dmtools/src/integrations/ai/ai_tools.dart';
import 'package:dmtools/src/js/sync_tools/ai_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart' show hasPython3;

/// Tests for [AiSyncTools] — the per-provider `*_ai_chat` sync executors.
///
/// Server-dependent tests start an AI-shaped echo server subprocess (see
/// `ai_echo_server.py`): the response nests the request echo under every
/// provider extraction path, so the extracted tool result IS the echoed
/// request details. Pure groups cover the Bedrock wire shapes and the
/// `__jsError` sentinel contract without any network.
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  _testDefinitions();
  _testUnconfigured();
  _bedrockConfigGapTests();
  _testBedrockShapes();
  _testExtractors();
  if (hasPython3()) {
    _testRequestShapes();
    _testTransportFailures();
  }
}

/// Starts the AI-shaped echo server from `ai_echo_server.py`.
class AiEchoServer {
  Process? _process;

  /// The bound port (valid after [start]).
  int port = 0;

  /// Starts the echo server on an ephemeral port.
  Future<void> start() async {
    final script =
        '${Directory.current.path}/test/js/sync_tools/ai_echo_server.py';
    _process = await Process.start('python3', [script, '0']);
    final firstLine = await _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    port = int.parse(firstLine.trim());
  }

  /// Kills the server process.
  void stop() => _process?.kill();
}

/// Blanks every AI provider key so unconfigured paths are hermetic.
Map<String, String> _blankAiConfig() => {
      'GEMINI_API_KEY': '',
      'OPENAI_API_KEY': '',
      'ANTHROPIC_API_KEY': '',
      'DIAL_API_KEY': '',
      'DIAL_BASE_PATH': '',
      'BEDROCK_MODEL_ID': '',
      'AWS_BEARER_TOKEN_BEDROCK': '',
      'BEDROCK_BEARER_TOKEN': '',
      'BEDROCK_BASE_PATH': '',
      'BEDROCK_REGION': '',
    };

/// The six Java @MCPTool names, in catalog order.
const _expectedNames = [
  'gemini_ai_chat',
  'openai_ai_chat',
  'anthropic_ai_chat',
  'ollama_ai_chat',
  'dial_ai_chat',
  'bedrock_ai_chat',
];

void _testDefinitions() {
  group('aiChatTools definitions', () {
    test('exposes the six Java per-provider tool names', () {
      expect(aiChatTools().map((t) => t.name), _expectedNames);
    });

    test('every tool takes a single required message param', () {
      for (final tool in aiChatTools()) {
        expect(tool.integration, 'ai');
        expect(tool.params, hasLength(1));
        expect(tool.params.single.name, 'message');
        expect(tool.params.single.required, isTrue);
      }
    });

    test('handlers keys match the tool names 1:1', () {
      final tools = AiSyncTools(PropertyReader());
      expect(
        tools.handlers.keys.toSet(),
        aiChatTools().map((t) => t.name).toSet(),
      );
    });
  });
}

void _testUnconfigured() {
  group('AiSyncTools unconfigured providers', () {
    late AiSyncTools tools;

    setUp(() {
      PropertyReader.setOverrides(_blankAiConfig());
      tools = AiSyncTools(PropertyReader());
    });

    tearDown(() => PropertyReader.clearOverrides());

    /// Runs [toolName] and returns its `__jsError` message ('' when the
    /// sentinel is missing).
    String jsErrorFor(String toolName) {
      final result = tools.handlers[toolName]!({'message': 'hi'});
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      return (decoded['__jsError'] ?? '') as String;
    }

    test('gemini_ai_chat surfaces a JS error sentinel', () {
      expect(jsErrorFor('gemini_ai_chat'), contains('GEMINI_API_KEY'));
    });

    test('openai_ai_chat surfaces a JS error sentinel', () {
      expect(jsErrorFor('openai_ai_chat'), contains('OPENAI_API_KEY'));
    });

    test('anthropic_ai_chat surfaces a JS error sentinel', () {
      expect(jsErrorFor('anthropic_ai_chat'), contains('ANTHROPIC_API_KEY'));
    });

    test('dial_ai_chat surfaces a JS error sentinel', () {
      expect(jsErrorFor('dial_ai_chat'), contains('DIAL_BASE_PATH'));
    });

    test('bedrock_ai_chat requires BEDROCK_MODEL_ID', () {
      expect(jsErrorFor('bedrock_ai_chat'), contains('BEDROCK_MODEL_ID'));
    });
  });
}

/// Bedrock config-gap tests that override parts of the blank config.
void _bedrockConfigGapTests() {
  group('AiSyncTools unconfigured providers (bedrock gaps)', () {
    late AiSyncTools tools;

    setUp(() {
      PropertyReader.setOverrides(_blankAiConfig());
      tools = AiSyncTools(PropertyReader());
    });

    tearDown(() => PropertyReader.clearOverrides());

    /// Runs [toolName] and returns its `__jsError` message ('' when the
    /// sentinel is missing).
    String jsErrorFor(String toolName) {
      final result = tools.handlers[toolName]!({'message': 'hi'});
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      return (decoded['__jsError'] ?? '') as String;
    }

    test('bedrock_ai_chat with model but no token reports the auth gap', () {
      PropertyReader.setOverrides({
        ..._blankAiConfig(),
        'BEDROCK_MODEL_ID': 'anthropic.claude-3-sonnet-20240229-v1:0',
      });
      expect(
        jsErrorFor('bedrock_ai_chat'),
        contains('AWS_BEARER_TOKEN_BEDROCK'),
      );
    });

    test(
      'bedrock_ai_chat with token+model but no base path reports it',
      () {
        PropertyReader.setOverrides({
          ..._blankAiConfig(),
          'BEDROCK_MODEL_ID': 'anthropic.claude-3-sonnet-20240229-v1:0',
          'AWS_BEARER_TOKEN_BEDROCK': 'bt',
        });
        expect(jsErrorFor('bedrock_ai_chat'), contains('BEDROCK_BASE_PATH'));
      },
    );
  });
}

void _testBedrockShapes() {
  _bedrockModelTypeTests();
  _bedrockRequestBodyTests();
  _bedrockModelPathTests();
}

void _bedrockModelTypeTests() {
  group('bedrock model type detection', () {
    test('classifies ids into families, defaulting to claude', () {
      expect(
        detectBedrockModelType('anthropic.claude-3-sonnet-20240229-v1:0'),
        BedrockModelType.claude,
      );
      expect(detectBedrockModelType('Claude'), BedrockModelType.claude);
      expect(
        detectBedrockModelType('eu.amazon.nova-lite-v1:0'),
        BedrockModelType.nova,
      );
      expect(detectBedrockModelType('qwen2.5-v1:0'), BedrockModelType.qwen);
      expect(
        detectBedrockModelType('mistral.mistral-large-2407-v1:0'),
        BedrockModelType.mistral,
      );
      expect(detectBedrockModelType('unknown-model'), BedrockModelType.claude);
      expect(detectBedrockModelType(null), BedrockModelType.claude);
    });
  });
}

void _bedrockRequestBodyTests() {
  group('bedrockRequestBody', () {
    test('claude envelope: anthropic_version + block content', () {
      final body = bedrockRequestBody(
        BedrockModelType.claude,
        'hi',
        4096,
        1.0,
      );
      expect(body['anthropic_version'], 'bedrock-2023-05-31');
      expect(body['max_tokens'], 4096);
      expect(body['temperature'], 1.0);
      expect(body['messages'][0]['content'][0], {'type': 'text', 'text': 'hi'});
    });

    test('nova envelope: schemaVersion + inferenceConfig', () {
      final body = bedrockRequestBody(BedrockModelType.nova, 'hi', 512, 0.7);
      expect(body['schemaVersion'], 'messages-v1');
      expect(body['inferenceConfig']['maxTokens'], 512);
      expect(body['inferenceConfig']['temperature'], 0.7);
      expect(body['messages'][0]['content'][0], {'text': 'hi'});
    });

    test('qwen/mistral envelope: plain OpenAI-style body', () {
      for (final type in [
        BedrockModelType.qwen,
        BedrockModelType.mistral,
      ]) {
        final body = bedrockRequestBody(type, 'hi', 256, 0.5);
        expect(body['messages'][0], {'role': 'user', 'content': 'hi'});
        expect(body['max_tokens'], 256);
        expect(body.containsKey('anthropic_version'), isFalse);
        expect(body.containsKey('schemaVersion'), isFalse);
      }
    });
  });
}

void _bedrockModelPathTests() {
  group('bedrockModelPath', () {
    test('plain model ids ride the path unencoded', () {
      expect(
        bedrockModelPath('anthropic.claude-3-sonnet-20240229-v1:0'),
        'anthropic.claude-3-sonnet-20240229-v1:0',
      );
    });

    test('inference-profile ARNs are percent-encoded', () {
      final encoded = bedrockModelPath(
        'arn:aws:bedrock:us-east-1:1:inference-profile/my model',
      );
      expect(encoded, contains('%3A'));
      expect(encoded, contains('%20'));
      expect(encoded, isNot(contains(':')));
    });
  });
}

void _testExtractors() {
  group('extractGeminiText', () {
    test('reads candidates[0].content.parts[0].text', () {
      const body =
          '{"candidates":[{"content":{"parts":[{"text":"gem reply"}]}}]}';
      expect(extractGeminiText(body), 'gem reply');
    });

    test('returns empty string without candidates', () {
      expect(extractGeminiText('{}'), '');
    });
  });

  group('extractBedrockText', () {
    test('claude reads content[0].text', () {
      const body = '{"content":[{"type":"text","text":"claude reply"}]}';
      expect(
        extractBedrockText(body, BedrockModelType.claude),
        'claude reply',
      );
    });

    test('nova reads output.message.content[0].text', () {
      const body = '{"output":{"message":{"content":[{"text":"nova reply"}]}}}';
      expect(extractBedrockText(body, BedrockModelType.nova), 'nova reply');
    });

    test('qwen reads root choices[0].message.content', () {
      const body = '{"choices":[{"message":{"content":"qwen reply"}}]}';
      expect(extractBedrockText(body, BedrockModelType.qwen), 'qwen reply');
    });

    test('qwen falls back to output.choices', () {
      const body =
          '{"output":{"choices":[{"message":{"content":"fallback"}}]}}';
      expect(extractBedrockText(body, BedrockModelType.mistral), 'fallback');
    });

    test('error envelopes are returned verbatim', () {
      const body = '{"message":"AccessDeniedException"}';
      expect(
        extractBedrockText(body, BedrockModelType.claude),
        body,
      );
      const typed = '{"Output":{"__type":"ValidationException"}}';
      expect(
        extractBedrockText(typed, BedrockModelType.claude),
        typed,
      );
    });

    test('non-object bodies yield an empty string', () {
      expect(extractBedrockText('[]', BedrockModelType.claude), '');
    });
  });
}

/// Runs [body] with the AI echo server up, returns the decoded echo map
/// captured from one tool call.
Map<String, dynamic> _echoOf(
  AiEchoServer server,
  Map<String, String> config,
  String toolName,
  String message,
) {
  PropertyReader.setOverrides(config);
  final result =
      AiSyncTools(PropertyReader()).handlers[toolName]!({'message': message});
  return jsonDecode(result) as Map<String, dynamic>;
}

/// The shared AI echo server for the request-shape test groups.
AiEchoServer? _aiServer;

void _testRequestShapes() {
  group('AiSyncTools request shapes', () {
    setUp(() async {
      _aiServer = AiEchoServer();
      await _aiServer!.start();
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      _aiServer!.stop();
    });

    _geminiRequestTests();
    _openAiRequestTests();
    _anthropicRequestTests();
    _ollamaAndDialRequestTests();
    _bedrockRequestTests();
  });
}

void _geminiRequestTests() {
  test('gemini_ai_chat POSTs generateContent with the key in the query', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'GEMINI_API_KEY': 'gem-test-key',
        'GEMINI_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'GEMINI_MODEL': 'gemini-2.0-flash',
      },
      'gemini_ai_chat',
      'hello gemini',
    );
    expect(echo['method'], 'POST');
    expect(echo['path'], '/gemini-2.0-flash:generateContent?key=gem-test-key');
    expect(echo['headers']['Content-Type'], 'application/json');
    expect(echo['headers'].containsKey('Authorization'), isFalse);
    final body = jsonDecode(echo['body'] as String);
    expect(body['contents'][0]['parts'][0]['text'], 'hello gemini');
  });

  test('gemini_ai_chat falls back to the catalog default model', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'GEMINI_API_KEY': 'gem-test-key',
        'GEMINI_BASE_PATH': 'http://127.0.0.1:${server.port}',
      },
      'gemini_ai_chat',
      'hi',
    );
    expect(
      (echo['path'] as String).startsWith('/gemini-1.5-flash:generateContent'),
      isTrue,
    );
  });
}

void _openAiRequestTests() {
  test('openai_ai_chat POSTs a chat-completions body with Bearer auth', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'OPENAI_API_KEY': 'oai-test-key',
        'OPENAI_BASE_PATH':
            'http://127.0.0.1:${server.port}/v1/chat/completions',
        'OPENAI_MODEL': 'gpt-4o',
      },
      'openai_ai_chat',
      'hello openai',
    );
    expect(echo['path'], '/v1/chat/completions');
    expect(echo['headers']['Authorization'], 'Bearer oai-test-key');
    final body = jsonDecode(echo['body'] as String);
    expect(body['model'], 'gpt-4o');
    expect(body['messages'][0], {'role': 'user', 'content': 'hello openai'});
    expect(body['max_completion_tokens'], 4096);
    expect(body.containsKey('temperature'), isFalse);
  });

  test('openai_ai_chat honors token/temperature overrides', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'OPENAI_API_KEY': 'oai-test-key',
        'OPENAI_BASE_PATH': 'http://127.0.0.1:${server.port}/v1',
        'OPENAI_MAX_TOKENS': '128',
        'OPENAI_TEMPERATURE': '0.5',
        'OPENAI_MAX_TOKENS_PARAM_NAME': 'max_tokens',
      },
      'openai_ai_chat',
      'hi',
    );
    final body = jsonDecode(echo['body'] as String);
    expect(body['max_tokens'], 128);
    expect(body['temperature'], 0.5);
    expect(body.containsKey('max_completion_tokens'), isFalse);
  });
}

void _anthropicRequestTests() {
  test('anthropic_ai_chat POSTs a messages body with x-api-key', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'ANTHROPIC_API_KEY': 'ant-test-key',
        'ANTHROPIC_BASE_PATH': 'http://127.0.0.1:${server.port}/v1/messages',
        'ANTHROPIC_MODEL': 'claude-3-haiku',
      },
      'anthropic_ai_chat',
      'hello claude',
    );
    expect(echo['path'], '/v1/messages');
    expect(echo['headers']['x-api-key'], 'ant-test-key');
    final body = jsonDecode(echo['body'] as String);
    expect(body['model'], 'claude-3-haiku');
    expect(body['max_tokens'], 4096);
    expect(body['messages'][0], {'role': 'user', 'content': 'hello claude'});
  });
}

void _ollamaAndDialRequestTests() {
  test('ollama_ai_chat POSTs /api/chat with stream false and no auth', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'OLLAMA_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'OLLAMA_MODEL': 'llama3',
      },
      'ollama_ai_chat',
      'hello llama',
    );
    expect(echo['path'], '/api/chat');
    expect(echo['headers'].containsKey('Authorization'), isFalse);
    final body = jsonDecode(echo['body'] as String);
    expect(body['model'], 'llama3');
    expect(body['stream'], isFalse);
    expect(body['messages'][0], {'role': 'user', 'content': 'hello llama'});
  });

  test('dial_ai_chat POSTs model+messages only', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'DIAL_BASE_PATH':
            'http://127.0.0.1:${server.port}/openai/v1/chat/completions',
        'DIAL_API_KEY': 'dial-test-key',
        'DIAL_MODEL': 'gpt-4',
      },
      'dial_ai_chat',
      'hello dial',
    );
    expect(echo['path'], '/openai/v1/chat/completions');
    expect(echo['headers']['Authorization'], 'Bearer dial-test-key');
    final body = jsonDecode(echo['body'] as String);
    expect(body.keys, unorderedEquals(['model', 'messages']));
    expect(body['model'], 'gpt-4');
  });
}

void _bedrockRequestTests() {
  test('bedrock_ai_chat POSTs the claude invoke envelope', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'BEDROCK_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'BEDROCK_MODEL_ID': 'anthropic.claude-3-sonnet-20240229-v1:0',
        'AWS_BEARER_TOKEN_BEDROCK': 'bt-test',
      },
      'bedrock_ai_chat',
      'hello bedrock',
    );
    expect(
      echo['path'],
      '/model/anthropic.claude-3-sonnet-20240229-v1:0/invoke',
    );
    expect(echo['headers']['Authorization'], 'Bearer bt-test');
    expect(echo['headers']['Content-Type'], 'application/json');
    final body = jsonDecode(echo['body'] as String);
    expect(body['anthropic_version'], 'bedrock-2023-05-31');
    expect(body['max_tokens'], 4096);
    expect(body['temperature'], 1.0);
    expect(body['messages'][0]['content'][0]['text'], 'hello bedrock');
  });

  test('bedrock_ai_chat switches to the nova envelope by model id', () {
    final server = _aiServer!;
    final echo = _echoOf(
      server,
      {
        'BEDROCK_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'BEDROCK_MODEL_ID': 'amazon.nova-lite-v1:0',
        'AWS_BEARER_TOKEN_BEDROCK': 'bt-test',
      },
      'bedrock_ai_chat',
      'hi',
    );
    final body = jsonDecode(echo['body'] as String);
    expect(body['schemaVersion'], 'messages-v1');
    expect(body['inferenceConfig']['maxTokens'], 4096);
    expect(body['messages'][0]['content'][0], {'text': 'hi'});
  });
}

void _testTransportFailures() {
  group('AiSyncTools transport failures', () {
    tearDown(() => PropertyReader.clearOverrides());

    test('connection refused surfaces the JS error sentinel', () {
      PropertyReader.setOverrides({
        'OPENAI_API_KEY': 'oai-test-key',
        'OPENAI_BASE_PATH': 'http://127.0.0.1:1/v1/chat/completions',
        'JIRA_RETRY_ENABLED': 'false',
      });
      final result = AiSyncTools(PropertyReader())
          .handlers['openai_ai_chat']!({'message': 'hi'});
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['__jsError'] as String, contains('AI request failed'));
    });
  });
}
