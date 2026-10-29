# GOAL — dmtools-dart

## Mission

Port **DMTools** (Java 17 / GraalJS, `github.com/epam/dm.ai`) to **pure Dart** so the
orchestrator runs cross-platform — CLI, desktop, and mobile — without a JVM.

The JavaScript scripting layer moves from GraalJS (Truffle, JVM-only) to **QuickJS**
(via `dart:ffi`), reusing the proven bridge pattern from
https://github.com/IstiN/flutter_js_widget_runtime (`jsr.*` host-controlled I/O).

**JS runtime extension rule:** the `jsr` runtime lives in its own repo —
https://github.com/IstiN/flutter_js_widget_runtime. If the port needs anything added
or extended on the JS-runtime side (new bridge capabilities, engine fixes, renderer
features), that work goes **to that repository, via fork + pull request** — never
vendored or patched locally inside dmtools-dart.

## Reference implementation (source of truth)

> Reviewers: any claim about Java behavior must be checked against a fresh clone of https://github.com/epam/dm.ai and cited as `path/File.java:NN` — see `.dmtools/instructions/java_parity.md`.

**Java DMTools: https://github.com/epam/dm.ai** — always the latest upstream; clone
it fresh and treat its source as the spec for behavior and signatures. Do not rely
on any local checkout paths.

Agent scripts, configs, and the JS test suite (the primary acceptance gate):
https://github.com/IstiN/dmtools-agents — also cloned when needed.

---

## Core abstractions (how dmtools thinks)

Every integration dmtools exposes belongs to one of two unified abstractions.
Agent scripts, job configs, and the port itself must be written against the
abstraction — never against a concrete vendor.

### 1. Tracker — any work-tracking system

Jira, ADO Boards, GitHub Issues, Rally, … — one interface:
`tracker_get_ticket`, `tracker_search`, `tracker_post_comment`,
`tracker_move_to_status`, `tracker_add_label`, … Every concrete
`jira_*` / `ado_*` / `github_*` issue tool is an implementation of the same
contract, and the `tracker_*` surface must route to whichever tracker the
environment configures (`DEFAULT_TRACKER`). A script written against
`params.ticket.key` + tracker tools must run unchanged on any tracker
backend. Context hydration follows the same contract: `params.ticket` /
`params.ticketKey` carry the ticket key and data regardless of vendor.

### 2. SCM — any source-control system

GitHub, GitLab, Bitbucket, ADO Repos, … — one interface for PR / branch /
commit / review operations (the `js/common/scm.js` provider abstraction in
the agent ecosystem; `github_*` / `gitlab_*` / `bitbucket_*` sync tools
underneath). Review, rework, and development flows must be SCM-agnostic:
ticket → PR → review → rework → merge works the same regardless of vendor.

### Consequences

- **Porting rule:** a vendor integration is "done" only when its tools are
  reachable through the unified interface (tracker routing, SCM providers) —
  native tool names alone are not enough.
- **Runtime rule:** context hydration, JS actions, and post-actions must
  resolve `params.ticket` and the ticket key the same way for every tracker
  (no `jira_post_comment("gh-35")`-style cross-vendor calls that silently
  fail — route through the tracker abstraction).
- The `tracker_*` aliases and `scm.js` providers are the contract surface;
  vendor tools are the implementation detail.

---

## Hard constraints (non-negotiable)

### 1. Signature parity with Java DMTools

All configurations, parameters, CLI commands, tool names, and env variables MUST keep
**exactly the same names and shapes** as in Java DMTools. A config JSON or `dmtools.env`
that works with the Java version MUST work unchanged with the Dart version.

- Job config JSON keys — identical (e.g. `cliCommands`, `preJSAction`,
  `cleanupInputFolder`, `timerIntervalSeconds`), including defaults.
- MCP tool names — identical snake_case (`jira_post_comment`, `cli_execute_command`,
  `github_get_pr`, ...). Tool argument schemas — identical.
- Env variables — identical names (`JIRA_BASE_PATH`, `JIRA_API_TOKEN`, `ADO_PAT`,
  `SOURCE_GITHUB_TOKEN`, `CLI_ALLOWED_COMMANDS`, ...).
- CLI surface — identical commands and flags (`run`, `list`, `doctor`, `interactive`,
  `--version`, `--help`, `--list-jobs`, `<tool_name> <json_args>`,
  `dmtools run <config> [override]`).
- JS scripting API visible to agent scripts — identical globals
  (`jira_*`, `github_*`, `file_*`, `cli_execute_command`, `require`, `set_env_variable`,
  `params.jobParams/ticket/response`, ...). Agent JS files from the Java ecosystem
  must run unmodified (synchronous call style preserved).
- **Full `@MCPTool` coverage**: every method annotated `@MCPTool` in
  `dmtools-mcp-annotations`-processed classes (328 annotations across 26 classes in
  `dmtools-core`) gets a Dart implementation with the same tool name, argument
  schema, and behavior. No "partial registry" releases.
- **The existing agent test suite is a primary acceptance gate** (see below).

### 2. Quality gate: crap4dart from commit #1

`github.com/IstiN/crap4dart` is wired in **before any feature code**:

- `crap4dart.yaml` in repo root (`crap4dart init`), **CRAP threshold = 8.0**
  (the default; do not raise).
- **Pre-commit hook** installed (`crap4dart install`) — runs `check --staged` on
  every commit.
- **CI workflow** (`.github/workflows/quality.yml` via `crap4dart install --ci`) —
  format, `dart analyze`, tests with coverage, `crap4dart check`, `crap4dart analyze`
  on every push/PR. Exit code 2 fails the pipeline.
- `sources: [lib, bin, test]` — test code is held to the same bar.
- Every ported class ships with tests; coverage gate stays enabled
  (`coverage.required: true`).

### 3. No JVM, no GraalVM

Dart only. QuickJS is embedded via `dart:ffi` (not via the `flutter_js` plugin) so
that host calls from JS are **synchronous** — this preserves the sync call style of
all 177 existing agent scripts and works in headless CLI (where Flutter plugins are
unavailable).

---

## Audit facts that shape the port

(From auditing `dmtools-core` + `dmtools-agents`, 2026-08-11.)

- The Java JS sandbox is already bridge-shaped: GraalJS `Context` with
  `allowAllAccess(false)` plus exactly three host primitives:
  `executeToolViaJava(toolName, args)`, `require(path)`, `set_env_variable(name, envVar)`.
- All snake_case tool functions are **generated wrappers** over
  `executeToolViaJava`, produced from `MCPSchemaGenerator` schemas for 16 integrations:
  `jira, ado, ai, confluence, figma, file, cli, teams, sharepoint, kb, mermaid,
  testrail, github, gitlab, bitrise, jenkins` (+ `jira_xray` when the tracker is Xray).
- Java interop in agent scripts: **1 guarded call** in 177 files
  (`Java.type('java.lang.Thread').sleep(ms)` behind `typeof Java !== 'undefined'`).
- Script module system: CommonJS — `require` ×287, `module.exports` ×234, with a custom
  loader supporting relative paths, module cache, and circular requires
  (`RequireProxy` in `JobJavaScriptBridge.java`). This loader logic must be ported 1:1.
- ES feature usage is modest (`??` ×6, `async` ×3); QuickJS ES2020 covers everything.
- Most-used tools in agent scripts: `jira_post_comment` (132), `cli_execute_command`
  (126), `jira_remove_label` (102), `jira_move_to_status` (93), `file_read` (89),
  `file_write` (64), `jira_search_by_jql` (45), `jira_add_label` (42),
  `jira_get_ticket` (32).
- The MCP surface is annotation-driven: 328 `@MCPTool` annotations across 26 classes,
  processed by `dmtools-annotation-processor` into the schema registry
  (`MCPSchemaGenerator`). The Dart port needs an equivalent build-time registry
  generation (annotated Dart classes → tool schemas), not a hand-maintained list.

## Primary acceptance gate: the dmtools-agents test suite

`dmtools-agents` ships a GraalJS-based unit test suite for the agent scripts
(`agents/js/unit-tests/`, ~115 test files plus `js/test/*.test.js`), executed through
the product itself:

```bash
dmtools run agents/js/unit-tests/run_all.json
```

The suite runs on a custom in-JS framework (`testRunner.js`) providing
`test/suite`, `assert.*`, and — critically — `loadModule(path, requireFn, mocks)`
with mock injection that shadows global dmtools tool functions per module, and
`makeRequire(moduleMap)`.

**Rule: the Dart build must run this suite, unmodified, green.** It is the
end-to-end proof that the QuickJS runtime, the CommonJS loader, the tool bridge,
and the job-context injection are all behaviorally identical to GraalJS. The suite
is wired into CI (as a dedicated job, not part of `dart test`) and must pass before
any phase is called complete. `testRunner.js` itself runs under the ported runtime —
if the framework runs, the runtime is compatible.

When the Dart CLI exists, the exact gate command becomes:

```bash
dart run bin/dmtools.dart run agents/js/unit-tests/run_all.json
```

---

## Scope & phases

### Phase 0 — Repo bootstrap (quality first)

- [x] `dart create` package layout (`lib/`, `bin/dmtools.dart`, `test/`).
- [x] `crap4dart init` → review config, keep `crap.threshold: 8.0`.
- [x] `crap4dart install --ci` → pre-commit hook + `.github/workflows/quality.yml`.
- [x] GitHub repo connected; first CI run green on the empty skeleton.

**Done when:** an empty Dart skeleton commits through the hook and passes the workflow.

### Phase 1 — Property config (`PropertyReader` / `ApplicationConfiguration` parity)

Reference: `dmtools-core/.../common/utils/PropertyReader.java` (1567 lines),
`common/config/ApplicationConfiguration.java`.

- [x] Config resolution order identical to Java: overrides → `config.properties`
      → `dmtools.env` → OS env; OS env is checked *last* (mirrors
      `PropertyReader.getValue()`, so `dmtools.env` in CWD overrides real OS
      env vars).
      **Note:** the `dmtools-local.env` tier was removed per the 2026-08-24
      audit — Java has no such tier (P6-CFG-03).
- [x] Thread-local/zone-local overrides (`PropertyReader.getOverrides()` equivalent)
      — required by `CLI_ALLOWED_COMMANDS` and job-level `envVariables`.
- [x] Every env var getter used by integrations (Jira, ADO, GitHub, GitLab,
      Confluence, Figma, TestRail, AI providers, Bitrise, Jenkins, Teams, SharePoint)
      with identical names and defaults.
- [ ] `set_env_variable(name, envVar)` runtime switching. **Deferred to Phase 4**
      (lives in `JobJavaScriptBridge`, requires the QuickJS runtime).

**Done when:** a Java `dmtools.env` dropped into a Dart run resolves to the same
effective configuration (unit-tested against fixture env files).

### Phase 2 — CLI interface (`JobRunner` parity)

Reference: `dmtools-core/.../job/JobRunner.java`, `job/RunCommandProcessor.java`,
`dmtools.sh`.

- [x] Commands: `run <config_file> [override_json]`, `list`, `doctor`, `interactive`,
      `--version`/`-v`, `--help`/`-h`, `--list-jobs`.
      **Note:** `--version`, `--help`, `--list-jobs`, `doctor` are fully live.
      `run` resolves configs (deep-merge, parent inheritance, encoding detection)
      but defers job execution to Phase 3+. `list`, `interactive`, and direct
      tool invocation are stubs (require MCP tool registry from Phase 3).
- [x] Direct tool invocation: `dmtools <tool_name> '<json_args>'` — **stub**
      (dispatches to MCP tool registry, which is Phase 3).
- [x] Deep-merge semantics of the `run` override: override wraps into `params`
      exactly like Java (`{"params":{"jobParams":{...}}}`); bare `{"jobParams":...}`
      is ignored the same way (documented quirk preserved). Implemented in
      `config_merger.dart` + `run_command_processor.dart`.
- [x] Job-name dispatch (`cliagent`, `teammate`, `jsrunner`, ...) — registry keyed by
      the same lowercase names, aliases included. Implemented in `job_registry.dart`
      (26 names, case-insensitive).
- [ ] STDIN / heredoc / file input modes of `dmtools.sh` (as a Dart executable).
      `--data` and `--file` flag parsing is done (`cli_args.dart`); STDIN reading
      still needs wiring in `bin/dmtools.dart`.

**Done when:** `dmtools list` prints the same tool catalog as Java for the same env
configuration; golden tests on CLI stdout/stderr and exit codes.

### Phase 3 — Integrations (MCP tool registry parity)

Reference: `dmtools-core/.../job/JobJavaScriptBridge.java` (`exposeMCPToolsUsingGenerated`),
`mcp/MCPSchemaGenerator.java`, integration clients under `atlassian/`, `github/`,
`gitlab/`, `ado/`, `figma/`, `bitrise/`, `jenkins/`, `teams/`, `sharepoint/`,
`testrail/`, `kb/`, `mermaid/`.

**Implementation order: Jira first.** It is the tracker backbone of the whole agent
ecosystem (top-10 most used tools in agent scripts are mostly `jira_*`), and it is
the hardest auth/semantics case — solving it first sets the pattern for everything
after.

- [x] **Jira (+ Xray) — with explicit Server/Data Center vs Cloud duality.** Java
      reference: `atlassian/jira/BasicJiraClient.java`, `atlassian/jira/JiraClient.java`,
      `PropertyReader.getJiraAuthType()`. **33 Jira tools ported** (search, comments,
      labels, transitions, fields, fix versions, components, subtasks, links, projects,
      ADF updates). Auth chain + API version routing (latest/v3) + Cloud cursor/
      Server offset pagination implemented. Xray and L2/L3 contract tests pending.
- [x] Tool schema registry: same tool names, same argument schemas, same
      availability rules (tool appears only when its integration is configured).
      `default_tool_registry.dart` registers all 17 catalogs; `dmtools list` prints
      the full catalog (457 tools).
- [x] **Complete `@MCPTool` parity for the agent-used surface**: all Java
      @MCPTool methods the dmtools-agents scripts call are ported —
      **457 canonical tools across 17 integrations** (Jira 67, GitHub 58,
      GitLab 47, ADO 44, Confluence 47, File 19, TestRail 18, Figma 15,
      AI 14 (incl. per-provider `*_ai_chat`), Jenkins 14, Bitrise 13,
      SharePoint 12, Teams 11, Xray 8, KB 8, Mermaid 4, CLI 3).
      Registry is the Dart equivalent of the generated catalog — the catalog cannot
      drift because all tools are defined in the `*_tools.dart` files next to their
      implementations. CI catalog comparison: `test/mcp/catalog_parity_test.dart`
      against the frozen gap snapshot
      (`test/fixtures/java_mcp_tool_gaps.txt`, 98 remaining non-agent names; gh-191 removed the final 15 Confluence entries — the snapshot had 113 before this PR).
- [x] HTTP clients for the remaining integrations on `dio` (after Jira): ADO,
      GitHub, GitLab, Confluence, Figma, TestRail, Bitrise, Jenkins, Teams,
      SharePoint, KB, Mermaid.
- [x] `file_*` tools, `cli_execute_command` with the same whitelist mechanics
      (`git, gh, dmtools, npm, yarn, docker, kubectl, terraform, ansible, aws,
      gcloud, az` + `CLI_ALLOWED_COMMANDS` extension).
- [x] AI providers: Gemini, OpenAI, DIAL, Bedrock, Ollama — same env-var
      selection, plus per-provider `*_ai_chat` sync executors.

**Done when:** the generated Dart tool catalog matches the Java `@MCPTool` catalog
100% (CI comparison green), and contract tests replay recorded Java tool
requests/responses against the Dart implementations (fixtures captured from the Java
version).

### Phase 4 — JS runtime (GraalJS → QuickJS)

- [x] QuickJS via `dart:ffi` with **synchronous** host callbacks.
      **Proven:** compiled QuickJS from source, C bridge with flat ABI, JSON
      marshaling, `NativeCallable.isolateLocal` for sync callbacks on aarch64.
- [x] `executeToolViaJava` equivalent (single generic dispatch into the Phase 3
      registry), `file_read` host function, `set_env_variable`.
      CommonJS `require` loader ported 1:1 from the Java `RequireProxy` /
      `loadModule` (`lib/src/js/require_loader.dart`): a JS bootstrap prelude
      over `file_read` + `eval()` — `./`/`../` resolution against the current
      script directory, module cache with a pre-eval placeholder for circular
      requires, Java's exact module wrapper, and save/restore of the script
      directory around each module eval. testRunner.js's own closure-scoped
      `require` shims keep shadowing the global.
- [x] Generated snake_case wrappers from the tool schema registry — same generation
      approach as Java. All 164 tools get auto-generated wrappers.
- [x] Job context injection: `params.jobParams`, `params.ticket` via `setGlobal`,
      plus `response`, `initiator`, `inputJql`, `metadata` forwarded by
      `JsRunnerJob` exactly as Java `JSRunner.runJobImpl` +
      `JavaScriptExecutor.withJobContext()`/`.with()` do.
- [x] The dmtools-agents suite (`agents/js/unit-tests/run_all.json`) runs under
      the Dart runtime: **751 tests pass, 0 fail** (upstream fixed the former
      4 pre-existing bugs).

**Done when:** `dart run bin/dmtools.dart run agents/js/unit-tests/run_all.json`
passes **unmodified and green** — **met**: 751/751 pass locally and in CI
(the suite job is a hard gate: `run_agents_suite.dart` fails on any test
failure or malformed result). Run via
`dart run bin/run_agents_suite.dart /path/to/dmtools-agents` — executed as
parallel contiguous chunks over worker isolates (same totals as serial; see
`lib/src/js/agents_suite.dart`), `DMTOOLS_SUITE_SHARDS` overrides the
worker count. Each chunk runs in a disposable copy of the agents tree
(`.git` becomes an absolute gitfile ref so real `git ls-files` calls in
`test_agentDocsCoverage`/`test_agentValidator` still answer from the
original index); `DMTOOLS_SUITE_ISOLATED_COPIES=0` shares one tree —
not recommended on CI, where interleaved chunk writes on a shared tree
once parked two chunks in a minutes-long CLI-resume backoff
(`publishDiscoveryToConfluence` waiting on `outputs/response.md`,
2026-10-01 run 36891377431).

### Phase 5 — CliAgent port (first agent)

Reference: `dmtools-core/.../cliagent/CliAgent.java`, `cliagent/CliAgentParams.java`,
`teammate/CliExecutionHelper.java`, `teammate/CliCommandBuilder.java`.

- [x] Lifecycle ported (exact order): `setup → preJSAction → preCliJSAction →
      cliCommands → postJSAction → cache → reset` (reset always runs, even on
      failure).
- [x] Parameter contract: all 26 keys/types/defaults preserved in
      `CliAgentParams.fromJson`. Dual accessors for `cliPrompts` (flat array
      and structured config) included.
- [x] Behavioral details: stale `outputs/response.md` cleanup on start,
      `input/<contextId>` folder convention, outputs-first folder preference,
      `contextId` fallback to `"cli-agent"`, `cleanupInputFolder` (default true),
      `cleanupOutputsFolder` (default false).
- [x] Timer/error/line JS actions: `timerJSAction` (periodic), `cliExecutionErrorJSAction`
      (on failure), `cliOutputLineJSAction` (per line, can stop batch).
- [x] `InstructionProcessor` content extraction — file paths embedded
      inline; GitHub PR URLs and Jira keys annotated.
- [x] `TicketInputContextBuilder` — input context from ticket data
      (ticket.md, ticket.json, subtasks/, comments.md; empty folder fallback).

**Done when:** a real CliAgent config JSON from the Java ecosystem runs under Dart
with identical observable behavior (files created, commands executed, JS actions
fired in order).

### Phase 6 — Java parity completion (2026-08-24 audit; owner mandate)

**Owner mandate (2026-08-24):** the port must behave EXACTLY like the Java
original — zero deviations, zero simplifications, zero "equivalents". The Java
source (`/tmp/dm.ai` clone of github.com/epam/dm.ai, always re-clone fresh) is
the ONLY spec. Where Dart and Java differ, Java wins — always. This phase
closes every gap found by the 2026-08-24 eight-sector audit (config, JS
bridge, sync executors ×4, runners/CLI/doctor, registry metadata, integrations
layer).

**Tracking rules (cross-session):**

- Every item has a stable ID `P6-<SECTOR>-<NN>`. Never renumber; close or
  split with new IDs.
- `- [ ]` open · `- [~]` in progress · `- [x]` done and verified.
- An item is `[x]` ONLY after: Java reference re-read, fix landed, targeted
  tests added/updated, and the full gate sequence green
  (`dart format --set-exit-if-changed .` → `dart analyze` → `dart test` →
  coverage ≥ 80% → `crap4dart check --all` → `crap4dart analyze` → agents
  suite 763/763 via `dart run bin/run_agents_suite.dart <dmtools-agents>`).
- Log every working session in the Phase 6 session log below.

**Fitness function** (progress = closed Phase 6 items):

```bash
scripts/parity_progress.sh   # prints {"score": N, "max": M, "open": M-N}
```

Baseline 2026-08-24: score 2 / 221.

#### Phase 6 wave tracker (items live in `phases/`)

Each wave is a separate file in `phases/` with its item ledger, status
header, and blocked-by/blocks metadata. This table is the global state of
record — update a wave's `status:` header AND this table together.

| Wave | File | Items | Status | Blocked by | Blocks |
|------|------|-------|--------|------------|--------|
| W0 | `phases/phase6-w0-owner-regressions.md` | 2 | **done** | — | — |
| W1 | `phases/phase6-w1-jira-sync.md` | 18 | in-progress | W6 | — |
| W2 | `phases/phase6-w2-config.md` | 13 | in-progress | — | W3 |
| W3 | `phases/phase6-w3-runners-cli.md` | 28 | open | W2 | — |
| W4 | `phases/phase6-w4-vcs-sync.md` | 23 | open | W6 | — |
| W5 | `phases/phase6-w5-ci-docs-sync.md` | 35 | open | W6 | — |
| W6 | `phases/phase6-w6-js-bridge.md` | 13 | open | — | W1, W4, W5 |
| W7 | `phases/phase6-w7-integrations.md` | 29 | open | — | W9 |
| W8 | `phases/phase6-w8-rewrites.md` | 9 | open | — | W9 |
| W9 | `phases/phase6-w9-registry.md` | 51 | open | W7, W8 | — |

Dependency notes:

- **W6 gates the sync-executor error surfaces** (W1/W4/W5): land
  `P6-BRG-02` (Java's thrown-Error contract via the `__jsError` sentinel)
  before the error-path items of those waves; their non-error items may
  proceed in parallel.
- **W2 gates W3** (doctor/CLI text settles after the config chain is final).
- **W9 runs last**: the registry must reflect the final toolsets produced by
  W7/W8; `P6-REG-51` regenerates the gaps fixture from a fresh Java clone.
- Parallel-safe starting set: **W2, W6, W7, W8**.

Wave lifecycle: `open` → `in-progress` (first item claimed; set BOTH the
file's `status:` header and this table) → `done` (all items `[x]` and the
full gate sequence green; unblock dependents in this table).

#### Phase 6 session log (append-only)

- **2026-08-24 (session 1, CI follow-up):** PR #13 integration (jira) exposed two latent contract bugs. (1) The smoke test decoded the sync search result as a map — now reads Java's bare issues list. (2) `_bodyOrError` flagged 2xx empty bodies (204) as errors while Java returns the raw string (`""` for transitions POST, `"Success"` for deleteTicket) — main silently swallowed real HTTP failures the same way. P6-JSY-01 closed; W1 in-progress.

- **2026-08-24 (session 1):** Owner directive: strict Java parity, no
  deviations. Closed W0 (P6-W00-01, P6-W00-02) after the user-reported
  Jira Server search and CLI positional-args failures. Eight-sector audit
  produced the 219-item ledger (split into `phases/phase6-w*-*.md`);
  baseline score 2/221. Gates green:
  format/analyze/tests/coverage/crap4dart (Max CRAP 8.00)/agents suite
  763/763.

- **2026-09-07 (session 2):** Closed P6-REG-03, P6-REG-04, P6-REG-29
  (W9; score 5/221). Registry alias metadata now mirrors the Java
  @MCPTool aliases map exactly (extracted from a fresh dm.ai clone,
  66 entries): Dart-only tracker_* tool family and source_code_*
  inventions removed (032abf8), the full Java alias set restored with
  canonical-only JS surface + ToolDefinition.applyParamAliases honoring
  (a480ba0), Dart-only jira_assign/jira_assign_to/jira_create_ticket
  removed. Lesson recorded: the 032abf8 removal of source_code_* was
  wrong — aliases are Java-real CLI metadata; verify against a fresh
  clone before deleting anything that looks invented. Gates green:
  format/analyze/2260 tests/coverage 97.5%/crap4dart (Max CRAP 8.00)/
  agents suite 898 passed / 14 failed (unchanged upstream-gap baseline).

- **2026-09-07 (session 3):** Closed P6-BRG-04 + P6-REG-05 (W6/W9).
  `cli_execute_command` through the JS bridge now matches Java
  `CliCommandExecutor` exactly (tool_bridge.dart): full command LINE with
  first-token whitelist (base 12 + CLI_ALLOWED_COMMANDS), temp shell
  script (`/bin/sh`, cmd.exe /c) with stdout+stderr merged via `2>&1`
  group, trimmed combined output returned as a plain STRING (JSON-encoded
  for the FFI marshal), `workingDirectory` resolution per
  `resolveWorkingDirectory` (explicit dir validated within allowed bases
  — job dir / its git root / tmpdir — else git root, else job base), env
  injection per `loadEnvironmentVariables` (GIT_PAGER=cat,
  GIT_TERMINAL_PROMPT=0, PATH extension, dmtools.env from the working
  directory, PropertyReader overrides on top). Registry schema changed
  from invented [command, args[]] to Java-real [command,
  workingDirectory]. Root-caused the 14 agents-suite failures: only the
  cli_execute_command deviation was ours; the other 13 red tests + the
  docs drift now failing agentDocsCoverage are agents-repo bugs
  (test_workingDir.js stale makeRequire map missing baseBranchMarker x5,
  testRunner.js missing assert.doesNotThrow x2, checkWipLabel.js
  swallowing the ticket-not-found guard x3, smAgent x3, docs regenerated
  x1) — upstream fixes go via PR. Gates green: format/analyze/2286
  tests/coverage/crap4dart (Max CRAP 8.00); agents suite unchanged 903/14
  (all remaining failures agents-repo-side).

- **2026-09-07 (session 4):** Ported the Teammate job (Java
  `teammate/Teammate.java`, ticket-driven mode only) — new
  `TeammateJob` (`lib/src/agents/teammate_job.dart`) dispatched by
  `AgentFactory` (`teammate`, case-insensitive) and the CLI dispatcher.
  Scope decision recorded: Java Teammate's internal AI-processing branch
  (`ContextOrchestrator`/`RequestDecompositionAgent`/LLM providers) is
  NOT ported — dmtools-agents Teammate configs run with
  `skipAIProcessing: true` and delegate the AI work to the CLI agent via
  `cliCommands`; the job reuses [CliAgent] under the hood for the full
  lifecycle (setup → preJSAction → input folder → preCliJSAction →
  cliCommands → postJSAction → cache → reset) with `metadata.contextId`
  pinned to the ticket key (input folder `input/<ticketKey>/`, Java
  `TicketInputContextBuilder` parity). Ticket selection: `inputJql` →
  default Jira source (jira_search_by_jql → jira_get_ticket +
  jira_get_comments hydration; empty `inputJql` = no-op success, matching
  Java "skipping ticket processing"). `run-teammate-local.sh` contract
  works out of the box: `--inputJql "key = P-1"` lands in `params` via
  the existing override merge, `--ciRunUrl` + comments gate
  (`alwaysPostComments` / `outputType != none`) post the Java trace
  comment `[<contextId>|<agentId>] Processing started. CI Run: <url>`
  (AbstractJob.agentNamePrefix/shouldPostComments parity). Gates green:
  format/analyze/2311 tests/coverage 97.4%/crap4dart (20 gates, Max CRAP
  8.00); agents suite 882/882 fully green (see next entry).

- **2026-09-07 (session 4, L4 gate restored):** The agents/ submodule
  moved to 432cd4c (upstream "test(suite): fix 14 broken/failing unit
  tests") and the Dart runtime passes the FULL dmtools-agents suite:
  **882 passed / 0 failed**. The `continue-on-error` fuse on the
  quality.yml agents-suite job has been removed — the gate is blocking
  again (per the standing rule: fuse only while the runtime lags
  upstream). Suite output shape `{"success":true,"passed":882,
  "failed":0}` is the new baseline.
- **2026-09-11 (session 5, first full e2e subagent run):** W2 opened:
  P6-CFG-01..05 closed via a four-agent pipeline (explore research →
  implement → review → review-fix), score 13/221. The config chain is
  now Java-exact: overrides → config.properties (disk
  `<root>/src/main/resources` wins even when empty, else the
  setConfigFile resource) → dmtools.env (project root FIRST, then CWD;
  empty-parse file skipped; unreadable file warns + continues) → OS
  env. Empty values fall through file tiers; root marker is
  settings.gradle(.kts) with CWD fallback; the dmtools-local.env tier
  is REMOVED (P6-CFG-03 — Java has none; GOAL.md Phase-1 note and the
  integration-strategy credentials line updated accordingly). Gates
  green: format/analyze/2363 tests/coverage 98.9%/crap4dart (Max CRAP
  8.00)/agents suite 917/917.

**Phase 6 done when:** `scripts/parity_progress.sh` prints score == max,
the catalog parity test reports zero gaps against a fresh Java clone, and
all standing gates stay green.

### Later phases (out of initial scope, listed for direction)

Teammate, JSRunner, TestCasesGenerator and the remaining JobRunner jobs; MCP server
mode; GitHub Actions workflow compatibility (`ai-teammate.yml`).

---

## Integration testing strategy

Live-API tests are a separate, opt-in layer — they must never slow down or
destabilize the default quality loop.

### Test layers

| Layer | What | When it runs |
|---|---|---|
| L1 unit | Dart tests, everything mocked | pre-commit + CI `quality.yml` |
| L2 contract | Recorded Java tool requests/responses replayed against Dart clients | CI `quality.yml` |
| L3 **live integration** | Real APIs (Jira, ADO, GitHub, ...) against sandbox instances | nightly + manual (`workflow_dispatch`), never per-PR by default |
| L4 agents suite | `agents/js/unit-tests/run_all.json` under the Dart runtime | CI dedicated job (from Phase 4) |

### Mechanics

- Live tests live under `test/` tagged `@Tags(['integration'])` with a
  `dart_test.yaml` that **excludes the tag by default**; run explicitly via
  `dart test -t integration`.
- **Credentials come from the standard resolution chain** — overrides →
  `config.properties` → `dmtools.env` → OS env vars (the Phase 1 config layer,
  same path production uses). Locally the expected setup is a git-ignored `dmtools.env` with
  real keys; in CI the same variables arrive as injected secrets. No test-specific
  config files, no hardcoded values anywhere.
- **Sandbox targeting** via test-scoped overrides: `DMTOOLS_IT_JIRA_PROJECT`,
  `DMTOOLS_IT_GITHUB_REPO`, `DMTOOLS_IT_ADO_PROJECT`, `DMTOOLS_IT_CONFLUENCE_SPACE`,
  etc. These point tests at throwaway projects/repos/spaces; they select *where*
  to test, never *how to authenticate*.
- **Skip-or-fail policy**: missing credentials → test skips locally. In the CI
  integration job, `DMTOOLS_IT_REQUIRE_CREDS=true` turns cred-skips into failures,
  so the suite cannot silently rot when a secret expires.
- **Fixture lifecycle**: every created object is namespaced `it-<runId>-...`,
  created in setUp, deleted in tearDown. A standalone sweeper (`bin/it_sweep.dart`)
  deletes leaked `it-*` objects older than N hours; CI runs it after the suite.
- **CI shape** (`.github/workflows/integration.yml`): nightly schedule +
  `workflow_dispatch`, matrix per integration (jira / ado / github / gitlab / ...),
  secrets injected as env vars, `concurrency` group per integration to prevent
  parallel writes to the same sandbox. One red integration does not block others.
- **Token hygiene**: sandbox-only tokens with minimal scopes, stored as GitHub
  secrets; test output scrubbed of credential material; read-only checks preferred
  over write checks where a write is not the point of the test.
- **Recording mode**: the same live runs can regenerate L2 contract fixtures
  (`DMTOOLS_IT_RECORD=true`), keeping contract tests fresh against real API
  responses — this replaces manual fixture capture from the Java version over time.

### Coverage expectations (per integration)

Smoke path first: auth → read (get ticket / get PR) → search (JQL/list) → write
(post comment, add label, transition) → cleanup. Each smoke maps 1:1 to the most
used tools from the audit (`jira_post_comment`, `jira_search_by_jql`,
`jira_move_to_status`, `github_get_pr`, ...). Deeper edge cases grow only when a
bug demands them — the crap4dart coverage gate measures L1+L2, not L3.

---

## Working agreements

- Small commits; the pre-commit hook is law (bypass via `--no-verify` is a code
  smell, not a workflow).
- CI red = stop and fix, no merging on red.
- When Java behavior is ambiguous, the Java source is the spec; record the decision
  in the commit message.
- Generated code (`*.g.dart`, `*.freezed.dart`) is excluded from gates via
  crap4dart defaults — keep it that way.
