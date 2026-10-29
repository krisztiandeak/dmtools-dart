/// Every configuration name the [PropertyReader] family reads — the single
/// source for both the reader's lookups and the JS `env_get` allowlist
/// (`JsEnvPolicy.defaultAllowed`), so a new property cannot be read by the
/// reader yet missing from the allowlist.
///
/// Generated from the reader's former string literals; add new names here,
/// then use the constant in the reader. The `property_names_test` fails when a
/// reader literal is not declared here.
library;

/// Configuration property names (Java `PropertyReader` constant parity).
class PropertyNames {
  PropertyNames._();

  /// `ADO_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String ADO_BASE_PATH = 'ADO_BASE_PATH';

  /// `ADO_ORGANIZATION` configuration property name (Java `PropertyReader` parity).
  static const String ADO_ORGANIZATION = 'ADO_ORGANIZATION';

  /// `ADO_PAT_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String ADO_PAT_TOKEN = 'ADO_PAT_TOKEN';

  /// `ADO_PROJECT` configuration property name (Java `PropertyReader` parity).
  static const String ADO_PROJECT = 'ADO_PROJECT';

  /// `AI_ATTACHMENT_ALLOWED_EXTENSIONS` configuration property name (Java `PropertyReader` parity).
  static const String AI_ATTACHMENT_ALLOWED_EXTENSIONS =
      'AI_ATTACHMENT_ALLOWED_EXTENSIONS';

  /// `AI_ATTACHMENT_MAX_SIZE_MB` configuration property name (Java `PropertyReader` parity).
  static const String AI_ATTACHMENT_MAX_SIZE_MB = 'AI_ATTACHMENT_MAX_SIZE_MB';

  /// `AI_RETRY_AMOUNT` configuration property name (Java `PropertyReader` parity).
  static const String AI_RETRY_AMOUNT = 'AI_RETRY_AMOUNT';

  /// `AI_RETRY_DELAY_STEP` configuration property name (Java `PropertyReader` parity).
  static const String AI_RETRY_DELAY_STEP = 'AI_RETRY_DELAY_STEP';

  /// `ANTHROPIC_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_API_KEY = 'ANTHROPIC_API_KEY';

  /// `ANTHROPIC_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_BASE_PATH = 'ANTHROPIC_BASE_PATH';

  /// `ANTHROPIC_CUSTOM_HEADER_NAMES` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_CUSTOM_HEADER_NAMES =
      'ANTHROPIC_CUSTOM_HEADER_NAMES';

  /// `ANTHROPIC_CUSTOM_HEADER_VALUES` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_CUSTOM_HEADER_VALUES =
      'ANTHROPIC_CUSTOM_HEADER_VALUES';

  /// `ANTHROPIC_MAX_TOKENS` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_MAX_TOKENS = 'ANTHROPIC_MAX_TOKENS';

  /// `ANTHROPIC_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String ANTHROPIC_MODEL = 'ANTHROPIC_MODEL';

  /// `AWS_BEARER_TOKEN_BEDROCK` configuration property name (Java `PropertyReader` parity).
  static const String AWS_BEARER_TOKEN_BEDROCK = 'AWS_BEARER_TOKEN_BEDROCK';

  /// `BEDROCK_ACCESS_KEY_ID` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_ACCESS_KEY_ID = 'BEDROCK_ACCESS_KEY_ID';

  /// `BEDROCK_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_BASE_PATH = 'BEDROCK_BASE_PATH';

  /// `BEDROCK_BEARER_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_BEARER_TOKEN = 'BEDROCK_BEARER_TOKEN';

  /// `BEDROCK_MAX_TOKENS` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_MAX_TOKENS = 'BEDROCK_MAX_TOKENS';

  /// `BEDROCK_MODEL_ID` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_MODEL_ID = 'BEDROCK_MODEL_ID';

  /// `BEDROCK_REGION` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_REGION = 'BEDROCK_REGION';

  /// `BEDROCK_SECRET_ACCESS_KEY` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_SECRET_ACCESS_KEY = 'BEDROCK_SECRET_ACCESS_KEY';

  /// `BEDROCK_SESSION_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_SESSION_TOKEN = 'BEDROCK_SESSION_TOKEN';

  /// `BEDROCK_TEMPERATURE` configuration property name (Java `PropertyReader` parity).
  static const String BEDROCK_TEMPERATURE = 'BEDROCK_TEMPERATURE';

  /// `BITBUCKET_API_VERSION` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_API_VERSION = 'BITBUCKET_API_VERSION';

  /// `BITBUCKET_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_BASE_PATH = 'BITBUCKET_BASE_PATH';

  /// `BITBUCKET_BRANCH` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_BRANCH = 'BITBUCKET_BRANCH';

  /// `BITBUCKET_REPOSITORY` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_REPOSITORY = 'BITBUCKET_REPOSITORY';

  /// `BITBUCKET_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_TOKEN = 'BITBUCKET_TOKEN';

  /// `BITBUCKET_WORKSPACE` configuration property name (Java `PropertyReader` parity).
  static const String BITBUCKET_WORKSPACE = 'BITBUCKET_WORKSPACE';

  /// `BITRISE_APP_SLUG` configuration property name (Java `PropertyReader` parity).
  static const String BITRISE_APP_SLUG = 'BITRISE_APP_SLUG';

  /// `BITRISE_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String BITRISE_BASE_PATH = 'BITRISE_BASE_PATH';

  /// `BITRISE_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String BITRISE_TOKEN = 'BITRISE_TOKEN';

  /// `CACHE_MANAGER_LOGGING_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String CACHE_MANAGER_LOGGING_ENABLED =
      'CACHE_MANAGER_LOGGING_ENABLED';

  /// `CLI_ALLOWED_COMMANDS` configuration property name (Java `PropertyReader` parity).
  static const String CLI_ALLOWED_COMMANDS = 'CLI_ALLOWED_COMMANDS';

  /// `CLI_OUTPUT` configuration property name (Java `PropertyReader` parity).
  static const String CLI_OUTPUT = 'CLI_OUTPUT';

  /// `CODE_AI_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String CODE_AI_MODEL = 'CODE_AI_MODEL';

  /// `CONFLUENCE_API_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_API_TOKEN = 'CONFLUENCE_API_TOKEN';

  /// `CONFLUENCE_API_VERSION` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_API_VERSION = 'CONFLUENCE_API_VERSION';

  /// `CONFLUENCE_ATTACHMENT_RETRY_BASE_DELAY_MS` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_ATTACHMENT_RETRY_BASE_DELAY_MS =
      'CONFLUENCE_ATTACHMENT_RETRY_BASE_DELAY_MS';

  /// `CONFLUENCE_AUTH_TYPE` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_AUTH_TYPE = 'CONFLUENCE_AUTH_TYPE';

  /// `CONFLUENCE_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_BASE_PATH = 'CONFLUENCE_BASE_PATH';

  /// `CONFLUENCE_DEFAULT_SPACE` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_DEFAULT_SPACE = 'CONFLUENCE_DEFAULT_SPACE';

  /// `CONFLUENCE_EMAIL` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_EMAIL = 'CONFLUENCE_EMAIL';

  /// `CONFLUENCE_GRAPHQL_PATH` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_GRAPHQL_PATH = 'CONFLUENCE_GRAPHQL_PATH';

  /// `CONFLUENCE_LOGIN_PASS_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String CONFLUENCE_LOGIN_PASS_TOKEN =
      'CONFLUENCE_LOGIN_PASS_TOKEN';

  /// `CONFLUENCE_PARALLELISM` configuration property name (Java `ConfluenceParallel` parity).
  static const String CONFLUENCE_PARALLELISM = 'CONFLUENCE_PARALLELISM';

  /// `DEFAULT_CI` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_CI = 'DEFAULT_CI';

  /// `DEFAULT_LLM` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_LLM = 'DEFAULT_LLM';

  /// `DEFAULT_SCM` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_SCM = 'DEFAULT_SCM';

  /// `DEFAULT_SOURCE_CODE` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_SOURCE_CODE = 'DEFAULT_SOURCE_CODE';

  /// `DEFAULT_TICKET_STORY_POINTS_FIELDS` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_TICKET_STORY_POINTS_FIELDS =
      'DEFAULT_TICKET_STORY_POINTS_FIELDS';

  /// `DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES =
      'DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES';

  /// `DEFAULT_TICKET_WEIGHT_IF_NO_SP` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_TICKET_WEIGHT_IF_NO_SP =
      'DEFAULT_TICKET_WEIGHT_IF_NO_SP';

  /// `DEFAULT_TRACKER` configuration property name (Java `PropertyReader` parity).
  static const String DEFAULT_TRACKER = 'DEFAULT_TRACKER';

  /// `DIAL_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String DIAL_API_KEY = 'DIAL_API_KEY';

  /// `DIAL_API_VERSION` configuration property name (Java `PropertyReader` parity).
  static const String DIAL_API_VERSION = 'DIAL_API_VERSION';

  /// `DIAL_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String DIAL_BASE_PATH = 'DIAL_BASE_PATH';

  /// `DIAL_BATH_PATH` configuration property name (Java `PropertyReader` parity).
  static const String DIAL_BATH_PATH = 'DIAL_BATH_PATH';

  /// `DIAL_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String DIAL_MODEL = 'DIAL_MODEL';

  /// `DMTOOLS_CACHE_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String DMTOOLS_CACHE_ENABLED = 'DMTOOLS_CACHE_ENABLED';

  /// `DMTOOLS_CLI_LOG_DIR` configuration property name (Java `PropertyReader` parity).
  static const String DMTOOLS_CLI_LOG_DIR = 'DMTOOLS_CLI_LOG_DIR';

  /// `DMTOOLS_FILE_READ_ALLOWED_PATHS` configuration property name (Java `PropertyReader` parity).
  static const String DMTOOLS_FILE_READ_ALLOWED_PATHS =
      'DMTOOLS_FILE_READ_ALLOWED_PATHS';

  /// `DMTOOLS_JS_LOG_TOOL_CALLS` configuration property name (Java `PropertyReader` parity).
  static const String DMTOOLS_JS_LOG_TOOL_CALLS = 'DMTOOLS_JS_LOG_TOOL_CALLS';

  /// `FIGMA_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_BASE_PATH = 'FIGMA_BASE_PATH';

  /// `FIGMA_CLIENT_ID` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_CLIENT_ID = 'FIGMA_CLIENT_ID';

  /// `FIGMA_CLIENT_SECRET` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_CLIENT_SECRET = 'FIGMA_CLIENT_SECRET';

  /// `FIGMA_OAUTH_ACCESS_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_OAUTH_ACCESS_TOKEN = 'FIGMA_OAUTH_ACCESS_TOKEN';

  /// `FIGMA_OAUTH_REFRESH_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_OAUTH_REFRESH_TOKEN = 'FIGMA_OAUTH_REFRESH_TOKEN';

  /// `FIGMA_OAUTH_SCOPES` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_OAUTH_SCOPES = 'FIGMA_OAUTH_SCOPES';

  /// `FIGMA_REDIRECT_URI` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_REDIRECT_URI = 'FIGMA_REDIRECT_URI';

  /// `FIGMA_SCOPE` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_SCOPE = 'FIGMA_SCOPE';

  /// `FIGMA_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String FIGMA_TOKEN = 'FIGMA_TOKEN';

  /// `GEMINI_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_API_KEY = 'GEMINI_API_KEY';

  /// `GEMINI_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_BASE_PATH = 'GEMINI_BASE_PATH';

  /// `GEMINI_DEFAULT_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_DEFAULT_MODEL = 'GEMINI_DEFAULT_MODEL';

  /// `GEMINI_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_MODEL = 'GEMINI_MODEL';

  /// `GEMINI_VERTEX_API_VERSION` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_API_VERSION = 'GEMINI_VERTEX_API_VERSION';

  /// `GEMINI_VERTEX_CREDENTIALS_JSON` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_CREDENTIALS_JSON =
      'GEMINI_VERTEX_CREDENTIALS_JSON';

  /// `GEMINI_VERTEX_CREDENTIALS_PATH` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_CREDENTIALS_PATH =
      'GEMINI_VERTEX_CREDENTIALS_PATH';

  /// `GEMINI_VERTEX_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_ENABLED = 'GEMINI_VERTEX_ENABLED';

  /// `GEMINI_VERTEX_LOCATION` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_LOCATION = 'GEMINI_VERTEX_LOCATION';

  /// `GEMINI_VERTEX_PROJECT_ID` configuration property name (Java `PropertyReader` parity).
  static const String GEMINI_VERTEX_PROJECT_ID = 'GEMINI_VERTEX_PROJECT_ID';

  /// `GH_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String GH_TOKEN = 'GH_TOKEN';

  /// `GITLAB_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String GITLAB_BASE_PATH = 'GITLAB_BASE_PATH';

  /// `GITLAB_BRANCH` configuration property name (Java `PropertyReader` parity).
  static const String GITLAB_BRANCH = 'GITLAB_BRANCH';

  /// `GITLAB_REPOSITORY` configuration property name (Java `PropertyReader` parity).
  static const String GITLAB_REPOSITORY = 'GITLAB_REPOSITORY';

  /// `GITLAB_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String GITLAB_TOKEN = 'GITLAB_TOKEN';

  /// `GITLAB_WORKSPACE` configuration property name (Java `PropertyReader` parity).
  static const String GITLAB_WORKSPACE = 'GITLAB_WORKSPACE';

  /// `IMAGE_JPEG_QUALITY` configuration property name (Java `PropertyReader` parity).
  static const String IMAGE_JPEG_QUALITY = 'IMAGE_JPEG_QUALITY';

  /// `IMAGE_MAX_DIMENSION` configuration property name (Java `PropertyReader` parity).
  static const String IMAGE_MAX_DIMENSION = 'IMAGE_MAX_DIMENSION';

  /// `INPUT_ADO_CONCURRENCY` configuration property name.
  static const String INPUT_ADO_CONCURRENCY = 'INPUT_ADO_CONCURRENCY';

  /// `INPUT_ATTACHMENTS_CONCURRENCY` configuration property name.
  static const String INPUT_ATTACHMENTS_CONCURRENCY =
      'INPUT_ATTACHMENTS_CONCURRENCY';

  /// `INPUT_CLIENT_CONCURRENCY` configuration property name.
  static const String INPUT_CLIENT_CONCURRENCY = 'INPUT_CLIENT_CONCURRENCY';

  /// `INPUT_CONFLUENCE_CONCURRENCY` configuration property name.
  static const String INPUT_CONFLUENCE_CONCURRENCY =
      'INPUT_CONFLUENCE_CONCURRENCY';

  /// `INPUT_DOWNLOAD_RETRY_ATTEMPTS` configuration property name.
  static const String INPUT_DOWNLOAD_RETRY_ATTEMPTS =
      'INPUT_DOWNLOAD_RETRY_ATTEMPTS';

  /// `INPUT_DOWNLOAD_RETRY_BASE_DELAY_MS` configuration property name.
  static const String INPUT_DOWNLOAD_RETRY_BASE_DELAY_MS =
      'INPUT_DOWNLOAD_RETRY_BASE_DELAY_MS';

  /// `INPUT_FIGMA_CONCURRENCY` configuration property name.
  static const String INPUT_FIGMA_CONCURRENCY = 'INPUT_FIGMA_CONCURRENCY';

  /// `INPUT_GITHUB_CONCURRENCY` configuration property name.
  static const String INPUT_GITHUB_CONCURRENCY = 'INPUT_GITHUB_CONCURRENCY';

  /// `INPUT_JIRA_CONCURRENCY` configuration property name.
  static const String INPUT_JIRA_CONCURRENCY = 'INPUT_JIRA_CONCURRENCY';

  /// `INPUT_PARALLEL_CLIENTS` configuration property name.
  static const String INPUT_PARALLEL_CLIENTS = 'INPUT_PARALLEL_CLIENTS';

  /// `INPUT_TICKETS_CONCURRENCY` configuration property name.
  static const String INPUT_TICKETS_CONCURRENCY = 'INPUT_TICKETS_CONCURRENCY';

  /// `IS_READ_PULL_REQUEST_DIFF` configuration property name (Java `PropertyReader` parity).
  static const String IS_READ_PULL_REQUEST_DIFF = 'IS_READ_PULL_REQUEST_DIFF';

  /// `JENKINS_API_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String JENKINS_API_TOKEN = 'JENKINS_API_TOKEN';

  /// `JENKINS_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String JENKINS_BASE_PATH = 'JENKINS_BASE_PATH';

  /// `JENKINS_USER` configuration property name (Java `PropertyReader` parity).
  static const String JENKINS_USER = 'JENKINS_USER';

  /// `JIRA_API_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_API_TOKEN = 'JIRA_API_TOKEN';

  /// `JIRA_AUTH_TYPE` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_AUTH_TYPE = 'JIRA_AUTH_TYPE';

  /// `JIRA_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_BASE_PATH = 'JIRA_BASE_PATH';

  /// `JIRA_CLEAR_CACHE` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_CLEAR_CACHE = 'JIRA_CLEAR_CACHE';

  /// `JIRA_EMAIL` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_EMAIL = 'JIRA_EMAIL';

  /// `JIRA_EXTRA_FIELDS` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_EXTRA_FIELDS = 'JIRA_EXTRA_FIELDS';

  /// `JIRA_EXTRA_FIELDS_PROJECT` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_EXTRA_FIELDS_PROJECT = 'JIRA_EXTRA_FIELDS_PROJECT';

  /// `JIRA_ISSUE_ALLOWED_PREFIXES` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_ISSUE_ALLOWED_PREFIXES =
      'JIRA_ISSUE_ALLOWED_PREFIXES';

  /// `JIRA_ISSUE_IGNORE_PREFIXES` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_ISSUE_IGNORE_PREFIXES = 'JIRA_ISSUE_IGNORE_PREFIXES';

  /// `JIRA_LOGGING_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_LOGGING_ENABLED = 'JIRA_LOGGING_ENABLED';

  /// `JIRA_LOGIN_PASS_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_LOGIN_PASS_TOKEN = 'JIRA_LOGIN_PASS_TOKEN';

  /// `JIRA_MAX_SEARCH_RESULTS` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_MAX_SEARCH_RESULTS = 'JIRA_MAX_SEARCH_RESULTS';

  /// `JIRA_TRANSFORM_CUSTOM_FIELDS_TO_NAMES` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_TRANSFORM_CUSTOM_FIELDS_TO_NAMES =
      'JIRA_TRANSFORM_CUSTOM_FIELDS_TO_NAMES';

  /// `JIRA_WAIT_BEFORE_PERFORM` configuration property name (Java `PropertyReader` parity).
  static const String JIRA_WAIT_BEFORE_PERFORM = 'JIRA_WAIT_BEFORE_PERFORM';

  /// `JSAI_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_BASE_PATH = 'JSAI_BASE_PATH';

  /// `JSAI_CLIENT_NAME` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_CLIENT_NAME = 'JSAI_CLIENT_NAME';

  /// `JSAI_DEFAULT_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_DEFAULT_MODEL = 'JSAI_DEFAULT_MODEL';

  /// `JSAI_SCRIPT_CONTENT` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_SCRIPT_CONTENT = 'JSAI_SCRIPT_CONTENT';

  /// `JSAI_SCRIPT_PATH` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_SCRIPT_PATH = 'JSAI_SCRIPT_PATH';

  /// `JSAI_SECRETS_KEYS` configuration property name (Java `PropertyReader` parity).
  static const String JSAI_SECRETS_KEYS = 'JSAI_SECRETS_KEYS';

  /// `LINES_OF_CODE_DIVIDER` configuration property name (Java `PropertyReader` parity).
  static const String LINES_OF_CODE_DIVIDER = 'LINES_OF_CODE_DIVIDER';

  /// `OLLAMA_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_API_KEY = 'OLLAMA_API_KEY';

  /// `OLLAMA_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_BASE_PATH = 'OLLAMA_BASE_PATH';

  /// `OLLAMA_CUSTOM_HEADER_NAMES` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_CUSTOM_HEADER_NAMES = 'OLLAMA_CUSTOM_HEADER_NAMES';

  /// `OLLAMA_CUSTOM_HEADER_VALUES` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_CUSTOM_HEADER_VALUES =
      'OLLAMA_CUSTOM_HEADER_VALUES';

  /// `OLLAMA_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_MODEL = 'OLLAMA_MODEL';

  /// `OLLAMA_NUM_CTX` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_NUM_CTX = 'OLLAMA_NUM_CTX';

  /// `OLLAMA_NUM_PREDICT` configuration property name (Java `PropertyReader` parity).
  static const String OLLAMA_NUM_PREDICT = 'OLLAMA_NUM_PREDICT';

  /// `OPENAI_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_API_KEY = 'OPENAI_API_KEY';

  /// `OPENAI_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_BASE_PATH = 'OPENAI_BASE_PATH';

  /// `OPENAI_MAX_TOKENS` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_MAX_TOKENS = 'OPENAI_MAX_TOKENS';

  /// `OPENAI_MAX_TOKENS_PARAM_NAME` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_MAX_TOKENS_PARAM_NAME =
      'OPENAI_MAX_TOKENS_PARAM_NAME';

  /// `OPENAI_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_MODEL = 'OPENAI_MODEL';

  /// `OPENAI_TEMPERATURE` configuration property name (Java `PropertyReader` parity).
  static const String OPENAI_TEMPERATURE = 'OPENAI_TEMPERATURE';

  /// `PROMPT_CHUNK_MAX_FILES` configuration property name (Java `PropertyReader` parity).
  static const String PROMPT_CHUNK_MAX_FILES = 'PROMPT_CHUNK_MAX_FILES';

  /// `PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB` configuration property name (Java `PropertyReader` parity).
  static const String PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB =
      'PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB';

  /// `PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB` configuration property name (Java `PropertyReader` parity).
  static const String PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB =
      'PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB';

  /// `PROMPT_CHUNK_TOKEN_LIMIT` configuration property name (Java `PropertyReader` parity).
  static const String PROMPT_CHUNK_TOKEN_LIMIT = 'PROMPT_CHUNK_TOKEN_LIMIT';

  /// `RALLY_PATH` configuration property name (Java `PropertyReader` parity).
  static const String RALLY_PATH = 'RALLY_PATH';

  /// `RALLY_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String RALLY_TOKEN = 'RALLY_TOKEN';

  /// `SHAREPOINT_SCOPES` configuration property name (Java `PropertyReader` parity).
  static const String SHAREPOINT_SCOPES = 'SHAREPOINT_SCOPES';

  /// `SLEEP_TIME_REQUEST` configuration property name (Java `PropertyReader` parity).
  static const String SLEEP_TIME_REQUEST = 'SLEEP_TIME_REQUEST';

  /// `SOURCE_GITHUB_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String SOURCE_GITHUB_BASE_PATH = 'SOURCE_GITHUB_BASE_PATH';

  /// `SOURCE_GITHUB_BRANCH` configuration property name (Java `PropertyReader` parity).
  static const String SOURCE_GITHUB_BRANCH = 'SOURCE_GITHUB_BRANCH';

  /// `SOURCE_GITHUB_REPOSITORY` configuration property name (Java `PropertyReader` parity).
  static const String SOURCE_GITHUB_REPOSITORY = 'SOURCE_GITHUB_REPOSITORY';

  /// `SOURCE_GITHUB_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String SOURCE_GITHUB_TOKEN = 'SOURCE_GITHUB_TOKEN';

  /// `SOURCE_GITHUB_WORKSPACE` configuration property name (Java `PropertyReader` parity).
  static const String SOURCE_GITHUB_WORKSPACE = 'SOURCE_GITHUB_WORKSPACE';

  /// `TEAMS_AUTH_METHOD` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_AUTH_METHOD = 'TEAMS_AUTH_METHOD';

  /// `TEAMS_AUTH_PORT` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_AUTH_PORT = 'TEAMS_AUTH_PORT';

  /// `TEAMS_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_BASE_PATH = 'TEAMS_BASE_PATH';

  /// `TEAMS_CLIENT_ID` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_CLIENT_ID = 'TEAMS_CLIENT_ID';

  /// `TEAMS_REFRESH_TOKEN` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_REFRESH_TOKEN = 'TEAMS_REFRESH_TOKEN';

  /// `TEAMS_SCOPES` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_SCOPES = 'TEAMS_SCOPES';

  /// `TEAMS_TENANT_ID` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_TENANT_ID = 'TEAMS_TENANT_ID';

  /// `TEAMS_TOKEN_CACHE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String TEAMS_TOKEN_CACHE_PATH = 'TEAMS_TOKEN_CACHE_PATH';

  /// `TESTRAIL_API_KEY` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_API_KEY = 'TESTRAIL_API_KEY';

  /// `TESTRAIL_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_BASE_PATH = 'TESTRAIL_BASE_PATH';

  /// `TESTRAIL_DEFAULT_FORMAT` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_DEFAULT_FORMAT = 'TESTRAIL_DEFAULT_FORMAT';

  /// `TESTRAIL_LOGGING_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_LOGGING_ENABLED = 'TESTRAIL_LOGGING_ENABLED';

  /// `TESTRAIL_PROJECT` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_PROJECT = 'TESTRAIL_PROJECT';

  /// `TESTRAIL_USERNAME` configuration property name (Java `PropertyReader` parity).
  static const String TESTRAIL_USERNAME = 'TESTRAIL_USERNAME';

  /// `TEST_AI_MODEL` configuration property name (Java `PropertyReader` parity).
  static const String TEST_AI_MODEL = 'TEST_AI_MODEL';

  /// `TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT` configuration property name (Java `PropertyReader` parity).
  static const String TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT =
      'TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT';

  /// `TIME_SPENT_ON_DIVIDER` configuration property name (Java `PropertyReader` parity).
  static const String TIME_SPENT_ON_DIVIDER = 'TIME_SPENT_ON_DIVIDER';

  /// `XRAY_BASE_PATH` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_BASE_PATH = 'XRAY_BASE_PATH';

  /// `XRAY_CACHE_GET_REQUESTS_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_CACHE_GET_REQUESTS_ENABLED =
      'XRAY_CACHE_GET_REQUESTS_ENABLED';

  /// `XRAY_CACHE_POST_REQUESTS_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_CACHE_POST_REQUESTS_ENABLED =
      'XRAY_CACHE_POST_REQUESTS_ENABLED';

  /// `XRAY_CLIENT_ID` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_CLIENT_ID = 'XRAY_CLIENT_ID';

  /// `XRAY_CLIENT_SECRET` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_CLIENT_SECRET = 'XRAY_CLIENT_SECRET';

  /// `XRAY_ENRICHMENT_ENABLED_BY_DEFAULT` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_ENRICHMENT_ENABLED_BY_DEFAULT =
      'XRAY_ENRICHMENT_ENABLED_BY_DEFAULT';

  /// `XRAY_PARALLEL_BATCH_SIZE` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_PARALLEL_BATCH_SIZE = 'XRAY_PARALLEL_BATCH_SIZE';

  /// `XRAY_PARALLEL_DELAY_MS` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_PARALLEL_DELAY_MS = 'XRAY_PARALLEL_DELAY_MS';

  /// `XRAY_PARALLEL_FETCH_ENABLED` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_PARALLEL_FETCH_ENABLED =
      'XRAY_PARALLEL_FETCH_ENABLED';

  /// `XRAY_PARALLEL_THREADS` configuration property name (Java `PropertyReader` parity).
  static const String XRAY_PARALLEL_THREADS = 'XRAY_PARALLEL_THREADS';

  /// Every declared name, in declaration order.
  static const List<String> all = [
    ADO_BASE_PATH,
    ADO_ORGANIZATION,
    ADO_PAT_TOKEN,
    ADO_PROJECT,
    AI_ATTACHMENT_ALLOWED_EXTENSIONS,
    AI_ATTACHMENT_MAX_SIZE_MB,
    AI_RETRY_AMOUNT,
    AI_RETRY_DELAY_STEP,
    ANTHROPIC_API_KEY,
    ANTHROPIC_BASE_PATH,
    ANTHROPIC_CUSTOM_HEADER_NAMES,
    ANTHROPIC_CUSTOM_HEADER_VALUES,
    ANTHROPIC_MAX_TOKENS,
    ANTHROPIC_MODEL,
    AWS_BEARER_TOKEN_BEDROCK,
    BEDROCK_ACCESS_KEY_ID,
    BEDROCK_BASE_PATH,
    BEDROCK_BEARER_TOKEN,
    BEDROCK_MAX_TOKENS,
    BEDROCK_MODEL_ID,
    BEDROCK_REGION,
    BEDROCK_SECRET_ACCESS_KEY,
    BEDROCK_SESSION_TOKEN,
    BEDROCK_TEMPERATURE,
    BITBUCKET_API_VERSION,
    BITBUCKET_BASE_PATH,
    BITBUCKET_BRANCH,
    BITBUCKET_REPOSITORY,
    BITBUCKET_TOKEN,
    BITBUCKET_WORKSPACE,
    BITRISE_APP_SLUG,
    BITRISE_BASE_PATH,
    BITRISE_TOKEN,
    CACHE_MANAGER_LOGGING_ENABLED,
    CLI_ALLOWED_COMMANDS,
    CLI_OUTPUT,
    CODE_AI_MODEL,
    CONFLUENCE_API_TOKEN,
    CONFLUENCE_API_VERSION,
    CONFLUENCE_ATTACHMENT_RETRY_BASE_DELAY_MS,
    CONFLUENCE_AUTH_TYPE,
    CONFLUENCE_BASE_PATH,
    CONFLUENCE_DEFAULT_SPACE,
    CONFLUENCE_EMAIL,
    CONFLUENCE_GRAPHQL_PATH,
    CONFLUENCE_LOGIN_PASS_TOKEN,
    CONFLUENCE_PARALLELISM,
    DEFAULT_CI,
    DEFAULT_LLM,
    DEFAULT_SCM,
    DEFAULT_SOURCE_CODE,
    DEFAULT_TICKET_STORY_POINTS_FIELDS,
    DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES,
    DEFAULT_TICKET_WEIGHT_IF_NO_SP,
    DEFAULT_TRACKER,
    DIAL_API_KEY,
    DIAL_API_VERSION,
    DIAL_BASE_PATH,
    DIAL_BATH_PATH,
    DIAL_MODEL,
    DMTOOLS_CACHE_ENABLED,
    DMTOOLS_CLI_LOG_DIR,
    DMTOOLS_FILE_READ_ALLOWED_PATHS,
    DMTOOLS_JS_LOG_TOOL_CALLS,
    FIGMA_BASE_PATH,
    FIGMA_CLIENT_ID,
    FIGMA_CLIENT_SECRET,
    FIGMA_OAUTH_ACCESS_TOKEN,
    FIGMA_OAUTH_REFRESH_TOKEN,
    FIGMA_OAUTH_SCOPES,
    FIGMA_REDIRECT_URI,
    FIGMA_SCOPE,
    FIGMA_TOKEN,
    GEMINI_API_KEY,
    GEMINI_BASE_PATH,
    GEMINI_DEFAULT_MODEL,
    GEMINI_MODEL,
    GEMINI_VERTEX_API_VERSION,
    GEMINI_VERTEX_CREDENTIALS_JSON,
    GEMINI_VERTEX_CREDENTIALS_PATH,
    GEMINI_VERTEX_ENABLED,
    GEMINI_VERTEX_LOCATION,
    GEMINI_VERTEX_PROJECT_ID,
    GH_TOKEN,
    GITLAB_BASE_PATH,
    GITLAB_BRANCH,
    GITLAB_REPOSITORY,
    GITLAB_TOKEN,
    GITLAB_WORKSPACE,
    IMAGE_JPEG_QUALITY,
    IMAGE_MAX_DIMENSION,
    INPUT_ADO_CONCURRENCY,
    INPUT_ATTACHMENTS_CONCURRENCY,
    INPUT_CLIENT_CONCURRENCY,
    INPUT_CONFLUENCE_CONCURRENCY,
    INPUT_DOWNLOAD_RETRY_ATTEMPTS,
    INPUT_DOWNLOAD_RETRY_BASE_DELAY_MS,
    INPUT_FIGMA_CONCURRENCY,
    INPUT_GITHUB_CONCURRENCY,
    INPUT_JIRA_CONCURRENCY,
    INPUT_PARALLEL_CLIENTS,
    INPUT_TICKETS_CONCURRENCY,
    IS_READ_PULL_REQUEST_DIFF,
    JENKINS_API_TOKEN,
    JENKINS_BASE_PATH,
    JENKINS_USER,
    JIRA_API_TOKEN,
    JIRA_AUTH_TYPE,
    JIRA_BASE_PATH,
    JIRA_CLEAR_CACHE,
    JIRA_EMAIL,
    JIRA_EXTRA_FIELDS,
    JIRA_EXTRA_FIELDS_PROJECT,
    JIRA_ISSUE_ALLOWED_PREFIXES,
    JIRA_ISSUE_IGNORE_PREFIXES,
    JIRA_LOGGING_ENABLED,
    JIRA_LOGIN_PASS_TOKEN,
    JIRA_MAX_SEARCH_RESULTS,
    JIRA_TRANSFORM_CUSTOM_FIELDS_TO_NAMES,
    JIRA_WAIT_BEFORE_PERFORM,
    JSAI_BASE_PATH,
    JSAI_CLIENT_NAME,
    JSAI_DEFAULT_MODEL,
    JSAI_SCRIPT_CONTENT,
    JSAI_SCRIPT_PATH,
    JSAI_SECRETS_KEYS,
    LINES_OF_CODE_DIVIDER,
    OLLAMA_API_KEY,
    OLLAMA_BASE_PATH,
    OLLAMA_CUSTOM_HEADER_NAMES,
    OLLAMA_CUSTOM_HEADER_VALUES,
    OLLAMA_MODEL,
    OLLAMA_NUM_CTX,
    OLLAMA_NUM_PREDICT,
    OPENAI_API_KEY,
    OPENAI_BASE_PATH,
    OPENAI_MAX_TOKENS,
    OPENAI_MAX_TOKENS_PARAM_NAME,
    OPENAI_MODEL,
    OPENAI_TEMPERATURE,
    PROMPT_CHUNK_MAX_FILES,
    PROMPT_CHUNK_MAX_SINGLE_FILE_SIZE_MB,
    PROMPT_CHUNK_MAX_TOTAL_FILES_SIZE_MB,
    PROMPT_CHUNK_TOKEN_LIMIT,
    RALLY_PATH,
    RALLY_TOKEN,
    SHAREPOINT_SCOPES,
    SLEEP_TIME_REQUEST,
    SOURCE_GITHUB_BASE_PATH,
    SOURCE_GITHUB_BRANCH,
    SOURCE_GITHUB_REPOSITORY,
    SOURCE_GITHUB_TOKEN,
    SOURCE_GITHUB_WORKSPACE,
    TEAMS_AUTH_METHOD,
    TEAMS_AUTH_PORT,
    TEAMS_BASE_PATH,
    TEAMS_CLIENT_ID,
    TEAMS_REFRESH_TOKEN,
    TEAMS_SCOPES,
    TEAMS_TENANT_ID,
    TEAMS_TOKEN_CACHE_PATH,
    TESTRAIL_API_KEY,
    TESTRAIL_BASE_PATH,
    TESTRAIL_DEFAULT_FORMAT,
    TESTRAIL_LOGGING_ENABLED,
    TESTRAIL_PROJECT,
    TESTRAIL_USERNAME,
    TEST_AI_MODEL,
    TICKET_FIELDS_CHANGED_DIVIDER_DEFAULT,
    TIME_SPENT_ON_DIVIDER,
    XRAY_BASE_PATH,
    XRAY_CACHE_GET_REQUESTS_ENABLED,
    XRAY_CACHE_POST_REQUESTS_ENABLED,
    XRAY_CLIENT_ID,
    XRAY_CLIENT_SECRET,
    XRAY_ENRICHMENT_ENABLED_BY_DEFAULT,
    XRAY_PARALLEL_BATCH_SIZE,
    XRAY_PARALLEL_DELAY_MS,
    XRAY_PARALLEL_FETCH_ENABLED,
    XRAY_PARALLEL_THREADS,
  ];
}
