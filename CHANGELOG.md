# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Agent-action JS: `require` in dispatched functions resolves from the declaring module's directory (gh-409). Config action paths (`thenAction`, `preJSAction`, `postJSAction`, `preCliJSAction`) rebase to the config file's directory when the file exists there; otherwise the CWD-relative path is kept. If a file exists in both the config directory and the CWD, the config-directory copy now wins.

- `CliDispatcher` takes its engine-worker and Confluence pools through
  `CliDispatcherPools` (the `asyncPool` / `confluencePool` named parameters
  moved there). Internal `src` API; out-of-tree callers must update.

### Fixed

- Restored the `DMTOOLS_FILE_READ_ALLOWED_PATHS` escape hatch the gh-365
  sandbox never ported (gh-367): read-flavored `file_*` operations on both
  surfaces — the synchronous bridge (`file_read`, `file_read_lines`,
  `file_list`, `file_exists`, `file_info`) and the async executor (plus
  `readJson`, `getSize`, `watch`, `existsInPath`, `search`) — now consult
  the comma-separated glob list after the base/tmpdir/git-root containment
  fails, so pack-internal reads under the dmtools home
  (`~/.dmtools/packs/<pack>/js/*.js`, the SM pack's `require()` chain)
  pass again and the red SM ticks clear. Java `FileTools` parity:
  `isAllowedByConfig`/`matchesPattern`/`indexOfWildcard` ported 1:1 —
  each pattern's literal prefix resolves against the working dir
  (`../.dmtools/**` names the sibling `.dmtools` of the checkout; absolute
  prefixes pass through per `Path.resolve`), and the glob suffix matches
  Java `PathMatcher` semantics (`**` crosses directory boundaries,
  `*`/`?` stay inside one segment, `[...]`/`{...}` classes and
  alternatives; malformed patterns are skipped, not fatal). Write-flavored
  operations keep the strict guard — Java's `writeFile`/`deleteFile` never
  consult the config — so the allowance cannot smuggle writes or
  copy/move/delete endpoints outside the allowed bases.
- Sandboxed the JS-bridge `file_*` family behind the job working directory
  (gh-365): every `file_*` tool on both surfaces — the synchronous bridge
  (`ToolBridge._fileFns`, including the direct `file_read` host) and the
  async `FileToolExecutor` — now resolves paths through the new shared
  `resolveWithinAllowedBase` and rejects anything outside the job base, its
  git repository root, or the system temp dir with the standard
  `{"error": …}` envelope (rethrown as a JS `Error` via `executeToolViaJava`;
  the direct `file_read` host answers null per its testRunner.js contract).
  Closes the family-wide traversal gap the gh-361 parent-directory creation
  could materialize through (`file_write`/`file_mkdir` absolute and `..`
  escapes, `file_copy`/`file_move` leaking in both endpoint directions).
  Java parity: `FileTools.java` normalizes and rejects such paths
  ("Path traversal attempt blocked") — the Dart check runs the same lexical
  normalization BEFORE containment (not-yet-existing escape targets have no
  filesystem entry to canonicalize) plus symlink resolution for existing
  paths, and shares the allowed-base semantics of `cli_execute_command`
  (`validateWithinAllowedBase`) so the file and CLI surfaces cannot drift.
- Hardened the gh-365 sandbox canonicalization after review (gh-365 rework):
  `canonicalizePath` now resolves the deepest existing ancestor and
  re-attaches the non-existent tail (normalized), so a first write through
  an in-base symlinked parent resolves to its real target and is rejected
  when that target is outside the allowed bases (the fully lexical fallback
  let it materialize outside), and symlink-flavored tmpdir prefixes
  (macOS `/var/folders/...` → `/private/var/...`) compare equal to their
  canonical candidates instead of false-rejecting every first temp write.
  The executor's recursive traversals (`FileToolExecutor.existsInPath`,
  `search`) pass `followLinks: false` — Java `Files.walk` parity
  (AGENTS.md rule 2) — so an in-base directory symlink pointing outside
  cannot leak outside entry names; and both sandbox validators check the
  tmpdir candidate before the git root, keeping the common temp-fixture
  traffic off the blocking `git rev-parse` spawn on the synchronous bridge
  path (boolean outcome unchanged).

### Changed

- Retired the legacy `machine-kit` layer (gh-146): the machine loop runs on
  the factory pack (reusable `agents/.github/workflows/factory/teammate.yml`
  + `sm.yml` behind the thin `.github/workflows/ai-teammate.yml` and
  `machine-sm.yml` stubs). Deleted `machine-kit/teammate-install/`
  (runners/scripts/instructions — superseded by `.dmtools/runners/` +
  `.dmtools/config.js` and the pack's `setup/` scripts),
  `machine-kit/templates/` (superseded by the factory reusable workflows),
  and the pre-factory `machine-kit/setup.sh` installer + `machine-kit/README.md`
  (nothing invokes them; the only mention left is the historical provenance
  comment in `merge-trigger.yml`). `machine-kit/scripts/
  install-source-git-credentials.sh` stays — `release-cli.yml` still calls
  it. Docs (README, ai_factory, factory_setup) and the machine contract
  tests repointed to the factory equivalents; runner-wiring contract tests
  moved to `test/machine_kit/runner_wiring_test.dart`.
- The factory stubs pin `dmtools-agents` to the immutable SHA the `agents`
  submodule pins instead of the `feature/factory-reusable` branch
  (gh-146): the branch head renamed the reusable workflows away from
  `factory/<name>.yml`, so a branch ref would fail every machine trigger
  at run start while the gates stayed green against the submodule copy.
  Locked in lockstep by `test/machine_kit/factory_stub_ref_test.dart`.

### Fixed

- `jira_move_to_status` surfaces transport failures with their real reason
  (commit 38fee63, gh-146 review): a failed or malformed transitions fetch
  now reports `fetch failed: HTTP …` / `fetch failed: malformed JSON
  response` instead of masquerading as `No transition found for status: …`
  (the legacy `_fetchTransitions` swallowed failures into an empty list —
  a sandbox transient flaked the integration job on main). The legacy
  message stays reserved for the genuine empty-transitions case; error
  paths pinned by `test/js/jira_move_error_semantics_test.dart`.

- Alias help/list resolution under `DMTOOLS_INTEGRATIONS` (gh-136):
  `dmtools <alias> --help` and `dmtools list <alias>` now narrow alias
  candidates to carriers visible under the configured integrations before
  `DEFAULT_TRACKER` / `DEFAULT_SOURCE_CODE` routing, so the filtered tools
  list shows a usable backend schema instead of `{"tools": []}` when the
  default carrier sits outside the filter (`DMTOOLS_INTEGRATIONS=ado` +
  unset default now resolves `tracker_get_ticket` to `ado_get_work_item`).
  An unresolvable name on the help path (`dmtools some_typo_tool --help`)
  answers with the invocation path's unknown-tool error and exit code 1
  instead of a silent empty list; free-text `dmtools list <filter>` keeps
  its exit-0 search semantics.

### Added

- GitHub Issues backend for tracker-shaped `jira_*` tool calls (gh-62):
  when the ticket key matches `gh-<number>` and Jira is not configured (no
  `JIRA_BASE_PATH` / Jira auth token), `jira_get_ticket`,
  `jira_get_comments`, `jira_post_comment`, `jira_add_label`,
  `jira_remove_label`, `jira_move_to_status`, and `jira_search_by_jql`
  route to GitHub Issues on the tracker repo (`DMTOOLS_TRACKER_REPO`, else
  `GITHUB_REPOSITORY`, else `SOURCE_GITHUB_REPOSITORY`) through the JS
  bridge, CLI direct dispatch, and JS-generated wrappers alike.
  `jira_move_to_status` swaps the `status:<name>` label and closes/reopens
  the issue for Done-ish/Open-ish names; `jira_search_by_jql` supports
  key/labels/status/assignee filters — a `key` clause combined with other
  filters fetches by number and applies them client-side with JQL `in` =
  ANY semantics (absent issues skipped), keyless queries map single-value
  filters onto the issues list (multi-value `in` clauses there are an
  honest "unsupported JQL" error, since GitHub's list endpoint cannot
  express ANY) — and reports an honest "unsupported JQL" error for
  anything else; search and comments walk `per_page=100` pages instead of
  silently capping at the first 100 items. Any real Jira config keeps the
  Jira path — zero regression for Java-parity environments. This unblocks
  the agents' `postPRReviewComments` `pr_approved` hand-off on `gh-N`
  tickets.
- TestRail section-aware case creation, porting Java PR
  [epam/dm.ai#462](https://github.com/epam/dm.ai/pull/462):
  `testrail_get_sections` (`project_name` + optional `suite_id`, paginated,
  always fetched fresh) and the `testrail_create_case`,
  `testrail_create_case_detailed`, `testrail_create_case_steps` tools with an
  optional `section_id` that falls back to the project's default section
  (creating a "Test Cases" section when the project has none). Markdown
  tables in text fields convert to TestRail `|||:Col|Col` format or HTML for
  the Steps template. The L3 suite exercises the new tools against the
  TestRail sandbox (sections read + create/delete round-trips per flavour,
  resolving the project id → name via the Java-parity `getProjects`
  envelope), the nightly integration job gains the missing
  `DMTOOLS_IT_TESTRAIL_SUITE` wiring, and `integration-pr.yml` gains a
  `testrail` matrix leg.
- Generic named tool arguments on the CLI: `dmtools <tool> --key value` and
  `--key=value` map onto the tool's arguments (merged over a positional JSON
  blob), porting the Java `McpCliHandler.parseToolArguments` change from the
  same PR.
- `IntegrationClients` — process-wide per-integration client singletons
  (mirroring the Java `getInstance()` pattern): one Jira/GitHub/GitLab/
  Confluence/ADO/TestRail/Bitrise/Jenkins/Figma/Xray client (and its `Dio`
  transport with the connection pool) per process, built lazily through the
  standard factories. Unconfigured integrations throw and are not cached.
  Guards against the many-client socket-churn/timeout failure mode the Java
  side hit elsewhere.
- `ToolBridge` now holds a single `SyncToolDispatcher` (with its
  `PropertyReader`) for the bridge lifetime instead of constructing both on
  every tool call — repeated tool calls no longer re-read `dmtools.env`
  from disk per call.

- `make install` — build and install the CLI from a source checkout into
  `~/.local/bin` (override with `PREFIX=…`): a `dmtools` launcher plus the
  AOT binary (`dmtools.bin`) and the QuickJS shared library in
  `native/quickjs/` beside them. The launcher exports `JSR_QUICKJS_LIB`
  with the absolute library path — the runtime's exe-relative fallback uses
  `Platform.script`, which does not resolve to the installed executable in
  AOT builds, so without it `dmtools run` fails with a dlopen error from
  any directory outside the checkout. `install.sh` gained the same launcher
  layout plus macOS quarantine stripping and an ad-hoc re-sign
  (flutter_agent_harness installer pattern). macOS/Linux; Windows remains
  on the prebuilt installer.
- Sync tool dispatch for the full agent-used surface — the dispatcher
  (`lib/src/js/sync_tool_dispatcher.dart`) now routes by prefix to
  self-contained per-integration classes in `lib/src/js/sync_tools/`
  (mirroring the Java integration clients):
  - **Jira** (`jira_sync_tools.dart`): the previous 16 tools plus
    `jira_link_issues`, `jira_attach_file_to_ticket` (multipart),
    `jira_create_ticket_with_parent`, `jira_set_priority`,
    `jira_assign_ticket_to`, `jira_create_ticket_with_json`,
    `jira_get_field_custom_code`; `jira_create_ticket_basic` restored as the
    canonical name (Java `JiraClient` parity) with
    `tracker_create_ticket`/`jira_create_ticket` aliases.
  - **GitHub** (`github_sync_tools.dart` + workflow-log and release-asset
    helpers): 23 executors — PR comments/labels/threads/diff/merge, workflow
    runs (302+ZIP log resolution), draft releases, binary asset upload.
    Existing `github_get_pr`/`github_create_comment` args fixed to the Java
    `workspace`/`repository`/`pullRequestId`/`text` names (agents passed
    these; the old `owner`/`repo`/`number` shape produced
    `GET repos///pulls/0`).
  - **GitLab** (`gitlab_sync_tools.dart`): MR comments/threads/labels/diff/
    merge/rebase, pipelines, statuses, discussions, releases with binary
    asset transfer, accepts both Java (`workspace`/`repository`/
    `pullRequestId`) and legacy (`project`/`iid`/`body`) args.
  - **ADO** (`ado_sync_tools.dart`): PR comments/threads/labels/diff/merge,
    pipelines (list/runs/logs/trigger) alongside the moved work-item tools.
  - **Confluence** (`confluence_sync_tools.dart` + `confluence_markdown.dart`
    + `markdown_confluence_sync.dart`): search/pages/children/update plus the
    full Markdown→storage directory sync engine (`confluence_sync_markdown_
    directory`, port of Java `MarkdownConfluenceSync`) with multipart
    attachments.
  - **Bitrise** (`bitrise_sync_tools.dart`): builds/artifacts with the
    `BITRISE_ALLOW_WRITES` write guard (same knob as the async client).
  - **Jenkins** (`jenkins_sync_tools.dart`): job info + build logs
    (`toApiJobPath` ported 1:1).
  - **AI** (`ai_sync_tools.dart`): per-provider `gemini_ai_chat`,
    `openai_ai_chat`, `anthropic_ai_chat`, `ollama_ai_chat`,
    `dial_ai_chat`, `bedrock_ai_chat` (Java exposes one @MCPTool per
    provider; the dmtools-agents `aiChat.js` helper resolves
    `globalThis[provider + '_ai_chat']` dynamically and falls through on
    error — failures surface as JS errors via the `__jsError` sentinel).
  Canonical tool catalog: 328 → 387 definitions; the Java↔Dart gap snapshot
  shrinks 210 → 159 entries (no agent-script tool call remains uncovered).
- Tool wrappers for aliases — the wrapper generator emits a JS global per
  alias dispatching the canonical name (Java's schema registry exposes
  aliases as dispatchable tools; scripts call e.g.
  `jira_create_ticket_basic` directly).
- CommonJS `require()` loader (`lib/src/js/require_loader.dart`) — 1:1 port
  of the Java `JobJavaScriptBridge` module loader (`RequireProxy` /
  `loadModule` / `resolveModulePath` / `setCurrentScriptDirectory`).
  Implemented as a JS bootstrap prelude over the `file_read` host function
  and `eval()` so module exports can carry functions (the FFI JSON marshaling
  cannot). Java-parity semantics: `./`/`../` resolution against the current
  script directory with `..` normalization, module cache keyed by resolved
  path with a placeholder cached before eval (circular requires terminate),
  the exact Java module wrapper, script-directory save/set/restore in
  `try`/`finally`, `Failed to require module: <path>` on failure with the
  `JavaScript file not found` cause preserved, and the
  `require() expects exactly one argument (module path)` validation.
- JSRunner job context forwarding (`lib/src/agents/agent_factory.dart`) —
  `ticket`, `response`, `initiator`, `inputJql`, `metadata` from the job
  params block now land in the JS `params` object exactly as Java
  `JSRunner.runJobImpl` + `JavaScriptExecutor.withJobContext()`/`.with()`
  place them; missing/blank `jsPath` fails with the Java message
  `jsPath parameter is required`, and script failures return
  `{'success': false, 'error': …}` instead of crashing (Java
  `JavaScriptExecutor.execute()` error-result parity).
- Script source resolution parity (`lib/src/js/job_runner.dart`) — Java
  `loadJavaScriptCode` semantics: http(s) `jsPath` fetches the source
  synchronously (curl-backed [SyncHttpClient]), inline JS (`function`-prefixed,
  `action`-containing, or non-path non-`.js` strings) executes directly, and
  file paths that are missing fail with
  `JavaScript file not found in resources or filesystem: <path>`.
- Action contract and error surfacing — scripts without `action(params)`
  fail with the Java-parity
  `JavaScript code must define an 'action' function` (Java CliAgent JS
  actions use the same `JavaScriptExecutor` contract, so it is enforced on
  both the JSRunner and CliAgent paths); script/action eval exceptions now
  surface as `JavaScript execution failed: <message>` instead of a silent
  `null` result.
- Host-function argument validation with JS-visible errors — FFI host
  functions cannot throw into JS, so `executeToolViaJava` /
  `set_env_variable` validation failures return a `{'__jsError': …}`
  sentinel that a JS bootstrap wrapper rethrows as a real `Error`, matching
  the Java `IllegalArgumentException` messages
  (`executeToolViaJava requires at least 1 argument: toolName`,
  `set_env_variable requires 2 arguments: propertyName, envVarName`).
  `executeToolViaJava(toolName)` with no args object now executes with empty
  args, as in Java.
- Community files ported from the Java [dm.ai](https://github.com/epam/dm.ai)
  repository: `LICENSE` (Apache-2.0), `SECURITY.md` (vulnerability disclosure
  policy, repo links adapted), `CODE_OF_CONDUCT.md` (Contributor Covenant
  2.1), `CONTRIBUTING.md` (dm.ai structure rewritten for the Dart toolchain —
  `make native`/`dart test`/crap4dart gates instead of Gradle).
- CLI installer (`install.sh`): one-line `curl | sh` install of prebuilt
  AOT binaries from GitHub Releases — standalone (no Dart/Flutter needed on
  the target machine), version-pinned installs (`sh -s -- v0.1.0` or
  `DMTOOLS_VERSION`), optional `DMTOOLS_GITHUB_TOKEN` auth for the private
  repo, best-effort sha256 verification, installs to `~/.dmtools/bin`
  (binary + `native/quickjs/libquickjs_bridge.so` beside it) with PATH
  management. Modeled on the Java `dm.ai` installer and IstiN's
  `flutter_agent_harness` `install.sh`.
- `release-cli.yml`: dm.ai-style **button release** — `workflow_dispatch`
  with an optional custom version; empty input auto-increments the patch
  version from `pubspec.yaml`, commits the bump (pubspec +
  `lib/src/version.dart`), tags `vX.Y.Z`, pushes, and publishes the release
  with a generated changelog. Builds `dmtools-<os>-<arch>.tar.gz` bundles
  (linux-x64, macos-x64, macos-arm64), smoke-tests each bundle on its
  builder, and attaches `install.sh` + `dmtools-checksums.sha256`; the
  compiled-in version is synced from the tag so `dmtools --version` always
  matches the release.
- `install-test.yml`: simulates clean-machine installs across the OS
  matrix and exercises `dmtools --version` / `dmtools list`; `dash -n` +
  `shellcheck` the installer on every PR.

### Changed

- Tracker-specific CLI prompts engage on the GitHub machine (gh-125):
  `CliAgent` now passes the active tracker (`DEFAULT_TRACKER` via
  `PropertyReader`, Java `configuration.getDefaultTracker()` parity) into
  `CliCommandBuilder.buildCommands`, so a `cliPromptsByTracker` entry for
  the serving tracker is actually selected — previously the lookup always
  fell back to `ado` and tracker-specific prompt files were dead config.
  The dev + rework machine-kit runners (`fa-bug-dev`, `fa-story-dev`,
  `fa-rework-zai`) pin `DEFAULT_TRACKER=github` and add
  `cliPromptsByTracker.github → machine-kit/teammate-install/instructions/
  github_comment_format.md`, so machine comments on GitHub issues render as
  GitHub-flavored Markdown (fenced code blocks, `##` headings, `[text](url)`
  links, GFM tables) instead of the Jira wiki markup observed on gh-122
  (`{code}` blocks, `h3.` headers). Parents in dmtools-agents stay
  tracker-agnostic — the `github` entries are this deployment's override.
- `jira_post_comment` bodies routed to GitHub Issues convert from Jira
  wiki markup to GitHub-flavored Markdown before POSTing
  (`jiraMarkupToMarkdown` in `TrackerGitHubRouter._postComment`):
  `{code:lang}` / `{code}lang` / `{code}` blocks (all spellings,
  whitespace-tolerant tags) → fenced blocks, `h1.`–`h6.` → ATX headings,
  `[text|url]` → `[text](url)`, `*bold*`, `{panel:title=X}` → blockquote,
  `{color}` stripped, `{{monospace}}` → backtick span. Bodies without any
  Jira marker pass through byte-for-byte (GFM `*emphasis*` preserved), and
  lines inside existing Markdown fences are never rewritten. Jira-routed
  bodies stay byte-for-byte (the converter is wired only into the GitHub
  router).
- Live child-output streaming (gh-50): the process paths behind
  `cli_execute_command` and the CliAgent command phases — buffered and
  monitored — now mirror every child output line to dmtools' own stderr as
  it arrives (line-buffered, always on; no flags or env toggles) while the
  captured strings stay byte-identical for well-formed UTF-8 output
  (malformed byte sequences decode leniently to U+FFFD on both the
  buffered and monitored paths where the previous strict decode threw a
  `FormatException`; mirroring itself is best-effort — a failing stderr
  sink never aborts the capture or the batch).
  `dmtools run <config>` therefore streams the inner agent's work into the
  CI step log live, and the ai-teammate workflow drops its `FA_LOG_FILE` +
  `tail -F | sed` follower side-channel (the trace file itself stays,
  feeding the artifact upload). The synchronous JS-bridge capture
  (`executeToolViaJava`) cannot mirror — FFI host calls are synchronous
  and `dart:io` has no synchronous streaming API — so its captured-string
  contract is unchanged. Public API note for package consumers: the
  `CliToolExecutor.executeCommand` / `executeCommandWithEnv` signatures
  (exported via `lib/dmtools.dart`) changed from trailing
  positional-optional parameters to named ones (`args`, `envVars`) and
  gained an injectable `OutputLineSink? mirror` (the stderr target, for
  tests) — a compile-breaking change for external callers.
  `executeCommand` additionally accepts the `workingDirectory` the
  `cli_execute_command` schema always advertised: the async executor now
  forwards it to the child process instead of silently ignoring it (the
  JS-bridge path already resolved it per Java `resolveWorkingDirectory`),
  validated within the allowed base directories (process CWD, its git
  root, the system temp dir — Java `validateWithinAllowedBase` parity)
  through the same shared check the JS-bridge path uses, so both surfaces
  of the tool enforce the same sandbox; a directory outside them throws.
  Both surfaces also agree on a directory that does not exist: it falls
  back to the git root of the base (then the base), the
  `resolveWorkingDirectory` resolution the bridge always applied, instead
  of failing the executor with a `ProcessException` — and the shared
  containment check is separator-aware (`pathIsWithin`), so Windows
  backslash paths validate exactly like POSIX ones (Java
  `Path.startsWith` parity). The CliAgent monitored path kills its child
  process when a JS line-stop callback throws mid-stream, so a failed
  batch can no longer leave the agent run executing detached.

## [0.1.0] — 2026-08-13

Initial feature-complete release. Dart port of [DMTools](https://github.com/epam/dm.ai)
(Java/GraalJS → Dart/QuickJS). All 5 GOAL.md phases implemented.

### Added

#### Phase 1 — Property config
- `PropertyReader` with full resolution chain: overrides → `dmtools.env` → `dmtools-local.env` → OS env → defaults
- All ~120 env var getters with identical names/defaults to Java source
- Auth chains: Jira base64, Confluence Bearer/Basic, Gemini/Bedrock fallback chains, range clamping
- Fixture-based end-to-end tests proving Java `dmtools.env` compatibility

#### Phase 2 — CLI interface
- `dmtools run <config>` — end-to-end: config resolution, deep-merge, AgentFactory dispatch
- `dmtools list [filter]` — prints 325-tool catalog with filtering
- `dmtools doctor` — 13-integration config presence check
- `dmtools <tool_name> '<json_args>'` — direct tool invocation with STDIN/heredoc support
- `dmtools --version`, `--help`, `--list-jobs`, `interactive` (stub)

#### Phase 3 — Integrations (325 tools, 17 integrations)
- Jira (65), GitHub (40), GitLab (31), ADO (31), Confluence (29), File (19),
  TestRail (18), Figma (15), Jenkins (13), SharePoint (12), Teams (11),
  Bitrise (10), AI (8), Xray (8), KB (8), Mermaid (4), CLI (3)
- 100% Java @MCPTool parity (325 Dart tools cover all 328 Java `@MCPTool`
  names — directly, via aliases, or via documented renames — verified by
  `catalog_parity_test.dart`)
- Shared `BaseHttpClient` + `BearerHttpClient` base classes
- AI providers: Gemini, OpenAI, DIAL, Anthropic, Ollama (+ embeddings, summarize, complete)
- L2 contract test framework

#### Phase 4 — JS runtime (QuickJS via dart:ffi)
- QuickJS compiled from source (`native/quickjs/`), C bridge with flat ABI
- Synchronous JS→Dart→JS host callbacks via `NativeCallable.isolateLocal`
- `executeToolViaJava` tool dispatch to Phase 3 registry
- Auto-generated snake_case wrappers for all 325 tools
- Sync HTTP dispatch via curl subprocess (26 tools across 5 integrations)
- **738/738 dmtools-agents tests pass** (primary acceptance gate)

#### Phase 5 — CliAgent
- Full lifecycle: `setup → preJSAction → preCliJSAction → cliCommands → postJSAction → cache → reset`
- 26-field parameter contract with `fromJson` factory
- Timer/error/line JS actions
- `InstructionProcessor`: file path embedding, GitHub PR/Jira key annotation
- `TicketInputContextBuilder`: ticket.md, ticket.json, subtasks/, comments.md

#### Integration tests + CI
- 11 L3 live integration test suites (`test/integration/`)
- `.github/workflows/integration.yml`: nightly + manual, matrix per integration
- `.github/workflows/quality.yml`: dynamic badges, agents suite job
- `dart_test.yaml`: integration tag excluded from default run
- `test/integration/README.md`: all required env secrets documented

### Quality
- 1799 tests passing
- 97.8% line coverage
- Max CRAP 8.0 (threshold enforced by crap4dart)
- All 6 quality gates green (format, analyze, coverage, complexity, method_size, duplication, public_docs)
