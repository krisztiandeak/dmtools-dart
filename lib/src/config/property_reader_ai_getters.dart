/// AI and misc property getters for [PropertyReader].
///
/// Contains env-var getters for LLM providers (DIAL, Gemini, Ollama, Anthropic,
/// Bedrock, OpenAI), JSAI, metrics, and AI retry/prompt-chunk settings.
/// Split from `property_reader_getters.dart` to stay under the 800-line gate.
library;

import 'property_names.dart';
import 'property_reader.dart';

/// AI and misc getters for [PropertyReader], ported 1:1 from Java.
extension PropertyReaderAIGetters on PropertyReader {
  // --- DIAL ---

  /// DIAL base path.
  ///
  /// Misspelled method name preserved for signature parity. Tries
  /// `DIAL_BASE_PATH` then legacy `DIAL_BATH_PATH`.
  String? getDialBathPath() {
    final v = getValue(PropertyNames.DIAL_BASE_PATH);
    return v ?? getValue(PropertyNames.DIAL_BATH_PATH);
  }

  /// DIAL API key.
  ///
  /// Misspelled method name preserved for signature parity.
  /// Key: `DIAL_API_KEY`.
  String? getDialIApiKey() => getValue(PropertyNames.DIAL_API_KEY);

  /// DIAL model name. Key: `DIAL_MODEL`.
  String? getDialModel() => getValue(PropertyNames.DIAL_MODEL);

  /// DIAL API version. Key: `DIAL_API_VERSION`.
  String? getDialApiVersion() => getValue(PropertyNames.DIAL_API_VERSION);

  /// Code AI model name. Key: `CODE_AI_MODEL`.
  String? getCodeAIModel() => getValue(PropertyNames.CODE_AI_MODEL);

  /// Test AI model name. Key: `TEST_AI_MODEL`.
  String? getTestAIModel() => getValue(PropertyNames.TEST_AI_MODEL);

  // --- Gemini ---

  /// Gemini API key. Key: `GEMINI_API_KEY`.
  String? getGeminiApiKey() => getValue(PropertyNames.GEMINI_API_KEY);

  /// Gemini default model.
  ///
  /// Fallback chain: `GEMINI_MODEL` → `GEMINI_DEFAULT_MODEL`. Skips
  /// `$`-prefixed (placeholder) values.
  String? getGeminiDefaultModel() {
    var model = getValue(PropertyNames.GEMINI_MODEL);
    if (model != null && model.trim().isNotEmpty && !model.startsWith(r'$')) {
      return model;
    }
    model = getValue(PropertyNames.GEMINI_DEFAULT_MODEL);
    if (model != null && model.trim().isNotEmpty && !model.startsWith(r'$')) {
      return model;
    }
    return null;
  }

  /// Gemini API base path.
  /// Key: `GEMINI_BASE_PATH`, default: generativelanguage endpoint.
  String getGeminiBasePath() => getValueWithDefault(
        PropertyNames.GEMINI_BASE_PATH,
        'https://generativelanguage.googleapis.com/v1beta/models',
      );

  /// Whether Gemini Vertex AI mode is enabled.
  /// Key: `GEMINI_VERTEX_ENABLED`, default: false.
  bool isGeminiVertexEnabled() {
    final v = getValue(PropertyNames.GEMINI_VERTEX_ENABLED);
    return v != null && v.toLowerCase() == 'true';
  }

  /// Gemini Vertex AI project ID. Key: `GEMINI_VERTEX_PROJECT_ID`.
  String? getGeminiVertexProjectId() =>
      getValue(PropertyNames.GEMINI_VERTEX_PROJECT_ID);

  /// Gemini Vertex AI location. Key: `GEMINI_VERTEX_LOCATION`.
  String? getGeminiVertexLocation() =>
      getValue(PropertyNames.GEMINI_VERTEX_LOCATION);

  /// Gemini Vertex AI service account credentials file path.
  /// Key: `GEMINI_VERTEX_CREDENTIALS_PATH`.
  String? getGeminiVertexCredentialsPath() =>
      getValue(PropertyNames.GEMINI_VERTEX_CREDENTIALS_PATH);

  /// Gemini Vertex AI service account credentials JSON.
  /// Key: `GEMINI_VERTEX_CREDENTIALS_JSON`.
  String? getGeminiVertexCredentialsJson() =>
      getValue(PropertyNames.GEMINI_VERTEX_CREDENTIALS_JSON);

  /// Gemini Vertex AI API version.
  /// Key: `GEMINI_VERTEX_API_VERSION`, default: `v1`.
  String getGeminiVertexApiVersion() =>
      getValueWithDefault(PropertyNames.GEMINI_VERTEX_API_VERSION, 'v1');

  // --- Ollama ---

  /// Ollama API base path.
  /// Key: `OLLAMA_BASE_PATH`, default: `http://localhost:11434`.
  String getOllamaBasePath() => getValueWithDefault(
        PropertyNames.OLLAMA_BASE_PATH,
        'http://localhost:11434',
      );

  /// Ollama model name. Key: `OLLAMA_MODEL`.
  String? getOllamaModel() => getValue(PropertyNames.OLLAMA_MODEL);

  /// Ollama context window size in tokens.
  /// Key: `OLLAMA_NUM_CTX`, default: 16384.
  int getOllamaNumCtx() {
    final v = getValue(PropertyNames.OLLAMA_NUM_CTX);
    if (v == null || v.trim().isEmpty) return 16384;
    return int.tryParse(v.trim()) ?? 16384;
  }

  /// Ollama number of tokens to predict.
  /// Key: `OLLAMA_NUM_PREDICT`, default: -1.
  int getOllamaNumPredict() {
    final v = getValue(PropertyNames.OLLAMA_NUM_PREDICT);
    if (v == null || v.trim().isEmpty) return -1;
    return int.tryParse(v.trim()) ?? -1;
  }

  /// Ollama API key. Key: `OLLAMA_API_KEY`.
  String? getOllamaApiKey() => getValue(PropertyNames.OLLAMA_API_KEY);

  /// Comma-separated custom header names for Ollama.
  /// Key: `OLLAMA_CUSTOM_HEADER_NAMES`.
  String? getOllamaCustomHeaderNames() =>
      getValue(PropertyNames.OLLAMA_CUSTOM_HEADER_NAMES);

  /// Comma-separated custom header values for Ollama.
  /// Key: `OLLAMA_CUSTOM_HEADER_VALUES`.
  String? getOllamaCustomHeaderValues() =>
      getValue(PropertyNames.OLLAMA_CUSTOM_HEADER_VALUES);

  // --- Anthropic ---

  /// Anthropic API base path.
  /// Key: `ANTHROPIC_BASE_PATH`, default: messages endpoint.
  String getAnthropicBasePath() => getValueWithDefault(
        PropertyNames.ANTHROPIC_BASE_PATH,
        'https://api.anthropic.com/v1/messages',
      );

  /// Anthropic model name. Key: `ANTHROPIC_MODEL`.
  String? getAnthropicModel() => getValue(PropertyNames.ANTHROPIC_MODEL);

  /// Anthropic API key. Key: `ANTHROPIC_API_KEY`.
  String? getAnthropicApiKey() => getValue(PropertyNames.ANTHROPIC_API_KEY);

  /// Anthropic max output tokens.
  /// Key: `ANTHROPIC_MAX_TOKENS`, default: 4096.
  int getAnthropicMaxTokens() {
    final v = getValue(PropertyNames.ANTHROPIC_MAX_TOKENS);
    if (v == null || v.trim().isEmpty) return 4096;
    return int.tryParse(v.trim()) ?? 4096;
  }

  /// Comma-separated custom header names for Anthropic.
  /// Key: `ANTHROPIC_CUSTOM_HEADER_NAMES`.
  String? getAnthropicCustomHeaderNames() =>
      getValue(PropertyNames.ANTHROPIC_CUSTOM_HEADER_NAMES);

  /// Comma-separated custom header values for Anthropic.
  /// Key: `ANTHROPIC_CUSTOM_HEADER_VALUES`.
  String? getAnthropicCustomHeaderValues() =>
      getValue(PropertyNames.ANTHROPIC_CUSTOM_HEADER_VALUES);

  // --- Bedrock ---

  /// Bedrock runtime base path.
  ///
  /// Derived: uses `BEDROCK_BASE_PATH` if set, else constructs from
  /// `BEDROCK_REGION`.
  String? getBedrockBasePath() {
    final basePath = getValue(PropertyNames.BEDROCK_BASE_PATH);
    if (basePath != null && basePath.trim().isNotEmpty) return basePath;
    final region = getBedrockRegion();
    if (region != null && region.trim().isNotEmpty) {
      return 'https://bedrock-runtime.$region.amazonaws.com';
    }
    return null;
  }

  /// AWS region for Bedrock. Key: `BEDROCK_REGION`.
  String? getBedrockRegion() => getValue(PropertyNames.BEDROCK_REGION);

  /// Bedrock model ID. Key: `BEDROCK_MODEL_ID`.
  String? getBedrockModelId() => getValue(PropertyNames.BEDROCK_MODEL_ID);

  /// Bedrock bearer token.
  ///
  /// Fallback chain: `AWS_BEARER_TOKEN_BEDROCK` → `BEDROCK_BEARER_TOKEN`.
  /// Skips `$`-prefixed values.
  String? getBedrockBearerToken() {
    final token = getValue(PropertyNames.AWS_BEARER_TOKEN_BEDROCK);
    if (token != null && token.trim().isNotEmpty && !token.startsWith(r'$')) {
      return token;
    }
    return getValue(PropertyNames.BEDROCK_BEARER_TOKEN);
  }

  /// Bedrock IAM access key ID. Key: `BEDROCK_ACCESS_KEY_ID`.
  String? getBedrockAccessKeyId() =>
      getValue(PropertyNames.BEDROCK_ACCESS_KEY_ID);

  /// Bedrock IAM secret access key. Key: `BEDROCK_SECRET_ACCESS_KEY`.
  String? getBedrockSecretAccessKey() =>
      getValue(PropertyNames.BEDROCK_SECRET_ACCESS_KEY);

  /// Bedrock IAM session token. Key: `BEDROCK_SESSION_TOKEN`.
  String? getBedrockSessionToken() =>
      getValue(PropertyNames.BEDROCK_SESSION_TOKEN);

  /// Bedrock max output tokens.
  /// Key: `BEDROCK_MAX_TOKENS`, default: 4096.
  int getBedrockMaxTokens() {
    final v = getValue(PropertyNames.BEDROCK_MAX_TOKENS);
    if (v == null || v.trim().isEmpty) return 4096;
    final parsed = int.tryParse(v.trim());
    if (parsed == null || parsed < 1) return 4096;
    return parsed;
  }

  /// Bedrock sampling temperature.
  ///
  /// Range clamped to [0.0, 1.0]. Key: `BEDROCK_TEMPERATURE`, default: 1.0.
  double getBedrockTemperature() {
    final v = getValue(PropertyNames.BEDROCK_TEMPERATURE);
    if (v == null || v.trim().isEmpty) return 1.0;
    final temp = double.tryParse(v.trim());
    if (temp == null) return 1.0;
    if (temp < 0.0) return 1.0;
    if (temp > 1.0) return 1.0;
    return temp;
  }

  // --- OpenAI ---

  /// OpenAI API key. Key: `OPENAI_API_KEY`.
  String? getOpenAIApiKey() => getValue(PropertyNames.OPENAI_API_KEY);

  /// OpenAI API base path.
  /// Key: `OPENAI_BASE_PATH`, default: chat completions endpoint.
  String getOpenAIBasePath() => getValueWithDefault(
        PropertyNames.OPENAI_BASE_PATH,
        'https://api.openai.com/v1/chat/completions',
      );

  /// OpenAI model name. Key: `OPENAI_MODEL`.
  String? getOpenAIModel() => getValue(PropertyNames.OPENAI_MODEL);

  /// OpenAI max output tokens.
  /// Key: `OPENAI_MAX_TOKENS`, default: 4096.
  int getOpenAIMaxTokens() {
    final v = getValue(PropertyNames.OPENAI_MAX_TOKENS);
    if (v == null || v.trim().isEmpty) return 4096;
    return int.tryParse(v.trim()) ?? 4096;
  }

  /// OpenAI sampling temperature.
  ///
  /// Negative values returned as-is (signal to skip). Values >2.0 clamped to
  /// 2.0. Key: `OPENAI_TEMPERATURE`, default: -1.
  double getOpenAITemperature() {
    final v = getValue(PropertyNames.OPENAI_TEMPERATURE);
    if (v == null || v.trim().isEmpty) return -1;
    final temp = double.tryParse(v.trim());
    if (temp == null) return -1;
    if (temp < 0.0) return temp;
    if (temp > 2.0) return 2.0;
    return temp;
  }

  /// OpenAI max-tokens request parameter name.
  /// Key: `OPENAI_MAX_TOKENS_PARAM_NAME`, default: `max_completion_tokens`.
  String getOpenAIMaxTokensParamName() => getValueWithDefault(
        PropertyNames.OPENAI_MAX_TOKENS_PARAM_NAME,
        'max_completion_tokens',
      );

  // --- JSAI ---

  /// JSAI script file path. Key: `JSAI_SCRIPT_PATH`.
  String? getJsScriptPath() => getValue(PropertyNames.JSAI_SCRIPT_PATH);

  /// JSAI script content. Key: `JSAI_SCRIPT_CONTENT`.
  String? getJsScriptContent() => getValue(PropertyNames.JSAI_SCRIPT_CONTENT);

  /// JSAI client name.
  /// Key: `JSAI_CLIENT_NAME`, default: `JSAIClientFromProperties`.
  String getJsClientName() {
    final v = getValue(PropertyNames.JSAI_CLIENT_NAME);
    return (v == null || v.trim().isEmpty) ? 'JSAIClientFromProperties' : v;
  }

  /// JSAI default model. Key: `JSAI_DEFAULT_MODEL`.
  String? getJsDefaultModel() => getValue(PropertyNames.JSAI_DEFAULT_MODEL);

  /// JSAI base path. Key: `JSAI_BASE_PATH`.
  String? getJsBasePath() => getValue(PropertyNames.JSAI_BASE_PATH);

  /// JSAI secret keys. Key: `JSAI_SECRETS_KEYS`, comma-separated.
  List<String>? getJsSecretsKeys() {
    final v = getValue(PropertyNames.JSAI_SECRETS_KEYS);
    if (v == null || v.trim().isEmpty) return null;
    return v.split(',');
  }

  // --- Metrics ---

  /// Default ticket weight when story points are absent.
  /// Key: `DEFAULT_TICKET_WEIGHT_IF_NO_SP`, default: -1. THROWS on invalid.
  int getDefaultTicketWeightIfNoSPs() {
    final v = getValue(PropertyNames.DEFAULT_TICKET_WEIGHT_IF_NO_SP);
    if (v == null || v.isEmpty) return -1;
    return int.parse(v);
  }

  /// Divider for lines-of-code metric.
  /// Key: `LINES_OF_CODE_DIVIDER`, default: 1.0. THROWS on invalid.
  double getLinesOfCodeDivider() {
    final v = getValue(PropertyNames.LINES_OF_CODE_DIVIDER);
    if (v == null || v.isEmpty) return 1.0;
    return double.parse(v);
  }

  /// Divider for time-spent metric.
  /// Key: `TIME_SPENT_ON_DIVIDER`, default: 1.0. THROWS on invalid.
  double getTimeSpentOnDivider() {
    final v = getValue(PropertyNames.TIME_SPENT_ON_DIVIDER);
    if (v == null || v.isEmpty) return 1.0;
    return double.parse(v);
  }

  /// Per-field divider for ticket field changes.
  ///
  /// Dynamic key: `TICKET_FIELDS_CHANGED_DIVIDER_<FIELD>`, falls back to
  /// `TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT`, then 1.0. THROWS on invalid.
  double getTicketFieldsChangedDivider(String fieldName) {
    final v = getValue(
      'TICKET_FIELDS_CHANGED_DIVIDER_${fieldName.toUpperCase()}',
    );
    if (v != null) return double.parse(v);
    final def = getValue(PropertyNames.TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT);
    if (def != null && def.isNotEmpty) return double.parse(def);
    return 1.0;
  }

  // --- AI Retry & Prompt Chunk ---

  /// Number of AI retries on failure. Key: `AI_RETRY_AMOUNT`, default: 3.
  int getAiRetryAmount() {
    final v = getValue(PropertyNames.AI_RETRY_AMOUNT);
    if (v == null || v.trim().isEmpty) return 3;
    return int.tryParse(v) ?? 3;
  }

  /// Base delay step for AI retry backoff in ms.
  /// Key: `AI_RETRY_DELAY_STEP`, default: 20000.
  int getAiRetryDelayStep() {
    final v = getValue(PropertyNames.AI_RETRY_DELAY_STEP);
    if (v == null || v.trim().isEmpty) return 20000;
    return int.tryParse(v) ?? 20000;
  }

  /// Token limit for prompt chunking.
  /// Key: `PROMPT_CHUNK_TOKEN_LIMIT`, default: 50000.
  int getPromptChunkTokenLimit() {
    final v = getValue(PropertyNames.PROMPT_CHUNK_TOKEN_LIMIT);
    if (v == null || v.trim().isEmpty) return 50000;
    return int.tryParse(v) ?? 50000;
  }

  /// Max size of a single file in a prompt chunk (bytes).
  ///
  /// Parses MB, returns bytes. Key: `PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB`,
  /// default: 4194304 (4MB).
  int getPromptChunkMaxSingleFileSize() {
    final v = getValue(PropertyNames.PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB);
    if (v == null || v.trim().isEmpty) return 4 * 1024 * 1024;
    return (int.tryParse(v) ?? 4) * 1024 * 1024;
  }

  /// Max total size of files in a prompt chunk (bytes).
  ///
  /// Parses MB, returns bytes. Key: `PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB`,
  /// default: 4194304 (4MB).
  int getPromptChunkMaxTotalFilesSize() {
    final v = getValue(PropertyNames.PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB);
    if (v == null || v.trim().isEmpty) return 4 * 1024 * 1024;
    return (int.tryParse(v) ?? 4) * 1024 * 1024;
  }

  /// Max number of files in a prompt chunk.
  /// Key: `PROMPT_CHUNK_MAX_FILES`, default: 10.
  int getPromptChunkMaxFiles() {
    final v = getValue(PropertyNames.PROMPT_CHUNK_MAX_FILES);
    if (v == null || v.trim().isEmpty) return 10;
    return int.tryParse(v) ?? 10;
  }

  /// Max AI attachment size in bytes.
  ///
  /// Parses MB, returns bytes. Key: `AI_ATTACHMENT_MAX_SIZE_MB`,
  /// default: 0 (no limit).
  int getAIAttachmentMaxSizeBytes() {
    final v = getValue(PropertyNames.AI_ATTACHMENT_MAX_SIZE_MB);
    if (v == null || v.trim().isEmpty) return 0;
    return (int.tryParse(v.trim()) ?? 0) * 1024 * 1024;
  }

  /// Lowercase immutable set from comma-separated
  /// `AI_ATTACHMENT_ALLOWED_EXTENSIONS`.
  Set<String> getAIAttachmentAllowedExtensions() {
    final v = getValue(PropertyNames.AI_ATTACHMENT_ALLOWED_EXTENSIONS);
    if (v == null || v.trim().isEmpty) return const {};
    return Set.unmodifiable(
      v
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .where((s) => s.isNotEmpty)
          .toSet(),
    );
  }
}
