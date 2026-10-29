/// CLI help text — byte-identical to the Java `JobRunner.printHelp()`
/// output.
library;

/// The full `dmtools --help` text, byte-identical to the Java
/// `JobRunner.printHelp()` output.
const String cliHelpText = '''
DMTools CLI Wrapper

Usage:
  dmtools list                           # List available MCP tools
  dmtools doctor                         # Check current directory configuration
  dmtools upgrade [version]              # Upgrade dmtools (alias: update)
  dmtools run <json-file>                # Execute job with JSON config file
  dmtools run <job-name> [--key value]   # Execute a registered job without a config file
  dmtools run <json-file> <encoded>      # Execute job with file + encoded overrides
  dmtools <tool> [args...]              # Execute MCP tool with args
  dmtools <tool> --data '{"json"}'      # Execute with inline JSON
  dmtools <tool> --file params.json     # Execute with JSON file
  dmtools <tool> --verbose              # Execute with verbose output
  dmtools <tool> --debug                # Execute with debug output and error messages
  dmtools <tool> <<EOF                  # Execute with heredoc
  {"json": "data"}
  EOF

Examples:
  dmtools list
  dmtools doctor
  dmtools run job-config.json
  dmtools run codegenerator --param1 test
  dmtools jira_get_ticket DMC-479 summary,description
  dmtools jira_get_ticket --data '{"key": "DMC-479", "fields": ["summary"]}'

Output formats:
  --output <json|toon|mini|short|table|mermaid>   Select output format
  --toon                                          Shortcut for --output toon
  --mini                                          Shortcut for --output mini

Environment Variables:
  DMTOOLS_INTEGRATIONS    Comma-separated list of integrations (jira,confluence,figma)
  CLI_OUTPUT              Default output format (json|toon|mini|short|table|mermaid)
  DMTOOLS_VERSION         Version to install with `upgrade` (default: latest)
  DMTOOLS_UPGRADE_DRY_RUN=true       Print the upgrade plan without installing
  DMTOOLS_INSTALL_SCRIPT_URL         Override the install.sh URL used by `upgrade`

Environment Files:
  The tool automatically loads environment variables from dmtools.env
  (project root first, then the current working directory).

  Common variables:
  - JIRA_BASE_PATH, JIRA_EMAIL, JIRA_API_TOKEN
  - CONFLUENCE_BASE_PATH, CONFLUENCE_API_TOKEN
  - FIGMA_API_KEY
  - GEMINI_API_KEY, OPENAI_API_KEY
  - SOURCE_GITHUB_TOKEN, GITLAB_TOKEN, BITBUCKET_TOKEN''';
