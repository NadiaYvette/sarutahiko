# Hermes Design — Plugins, Execution Model, and CLI Architecture

A consolidated picture of how Hermes (the personal AI agent in `hermes-agent`) is
structured: its plugin system, how extension surfaces execute and communicate, and
the gross component structure of the CLI. Derived from the codebase as of
Sep 2026 (`plugins/AGENTS.md`, `hermes_cli/`, `tools/mcp_tool_*.py`,
`website/docs/developer-guide/plugins/`).

---

## 1. What Hermes Is

Hermes runs the same agent core across a CLI, a messaging gateway (~20 platforms),
a TUI, and an Electron desktop app. It learns across sessions (memory + skills),
delegates to subagents, runs scheduled jobs, and drives a terminal and browser.
It is extended primarily through **plugins and skills**, not by growing the core.

Two invariants shape almost every design decision:

- **Per-conversation prompt caching is sacred.** Anything that mutates past
  context, swaps toolsets, or rebuilds the system prompt mid-conversation
  invalidates the cached prefix. The one sanctioned break is context compression.
- **The core is a narrow waist; capability lives at the edges.** Every model tool
  is sent on every API call, so the bar for a new *core* tool is high. New
  capability arrives as a CLI command + skill, a service-gated tool, a plugin, or
  an MCP server — last resort: a new core tool (Footprint Ladder).

---

## 2. Plugin System Overview

### Plugin kinds

| Kind | Where | Discovery | Notes |
|---|---|---|---|
| General | `plugins/<name>/`, `~/.hermes/plugins/`, `./.hermes/plugins/` (opt-in), pip entry points | `PluginManager` (`hermes_cli/plugins*.py`), later-wins | `register(ctx)` registers hooks, tools, CLI subcommands, slash commands, skills |
| Memory provider | `plugins/memory/<name>/` | bundled → `$HERMES_HOME/plugins/` → project → entry points; **bundled-first** | `MemoryProvider` ABC, orchestrated by `agent/memory_manager.py` |
| Model provider | `plugins/model-providers/<name>/` | lazy, last-writer-wins | `ProviderProfile` registered at import |
| Context engine / image-gen / others | `plugins/context_engine/`, `plugins/image_gen/`, … | ABC + orchestrator | plug into `agent/context_engine.py`, etc. |
| Platform adapters | `plugins/platforms/<name>/adapter.py` | gateway | asyncio adapters; token locks + scoped secrets |

### Native plugin anatomy

```
~/.hermes/plugins/my-plugin/
├── plugin.yaml      # manifest (name, version, description, kind…)
├── __init__.py      # register(ctx) — wires schemas/hooks to handlers
├── schemas.py       # tool schemas (what the LLM sees)
└── tools.py         # tool handlers (what runs when called)
```

Minimal shape:

```python
def register(ctx):
    ctx.register_tool(name="hello_world", toolset="hello_world",
                      schema=schema, handler=handle_hello)
    ctx.register_hook("post_tool_call", on_tool_call)
```

### What `ctx` (PluginContext) can do

- `register_tool` / `register_hook` / `register_middleware`
- `register_cli_command` (argparse tree wired into `hermes` at startup)
- `register_command` (slash) / `register_skill`
- `register_platform` / `register_platform_handler`
- `register_memory_provider` / `register_context_engine`
- `register_auxiliary_task`, `register_system_prompt_section`
- `register_approval_transport`, `register_source` (secrets)
- `get_config` / `set_config`, `has_capability`, `call_mcp` (default-deny allowlist)
- `spawn_task` (supervised asyncio), `llm` access, `emit` (namespaced event bus)

### Rules

- **Plugins never touch core.** They work within ABCs / hooks / `ctx`. If a
  capability is missing, widen the *generic* plugin surface — never hardcode
  plugin-specific logic into `run_agent.py`, `cli.py`, `gateway/run.py`, etc.
- **Policy:** no new in-tree memory providers; no third-party-product plugins in
  the core tree (ship standalone repos under `~/.hermes/plugins/` or pip entry
  points, promoted in Discord `#plugins-skills-and-skins`).
- **Plugin catalog** (`plugin-catalog/`): the only discovery system for
  out-of-tree plugins — one YAML per entry, 40-hex SHA pin, human-merged PRs,
  `removed.yaml` kill list enforced at install *and* load.
- **Compat contract** is behavioral, not a monolithic API version: additive
  keyword hook payloads, signature inspection, never rename/remove
  `PluginContext` methods, unknown manifest fields ignored, deprecations with a
  ≥2-minor-release window.

---

## 3. Execution Model — Are Plugins Python? How Do They Run?

**Not necessarily Python, and not one execution model.** Surfaces split into
in-process Python, process-spawning, and network-based categories. There is
**no OS-level plugin sandbox** — trust is policy (allowlists, consent files,
capability grants, load timeouts).

### (a) In-process Python plugins — direct function calls, no IPC

| Surface | Execution | Communication |
|---|---|---|
| General `register(ctx)` plugins | importlib / entry-point import into the host interpreter (`plugins_loader.py::_load_plugin_scoped`) | Direct calls: `register(ctx)` at load; tool handlers invoked synchronously from `handle_function_call()`; hooks via `invoke_hook()` |
| Provider plugins (memory, model, context engine, image-gen) | In-process ABC implementations | ABC method calls; background work via `spawn_context_thread` (contextvars-copying daemon threads) |
| Platform adapters | asyncio on the gateway event loop | Network sockets to Telegram/Discord/Slack/… |

- Load runs under a deadline (`plugins.load_timeout_seconds`, default 10s);
  `SystemExit` is caught so a plugin cannot kill the process; failed plugins'
  registrations are disposed.
- **Hook dispatch** (`plugins_dispatch.py`): mostly synchronous; hot-path hooks
  (`pre/post_tool_call`, `pre/post_api_request`, …) are *bounded* — run on a
  daemon worker with a 30s timeout and abandoned (never joined) on hang;
  `pre_tool_call` **fails closed** (timeout → block). Async callbacks are
  awaited on the running loop. Signature inspection: narrow callbacks get only
  declared fields; `**kwargs` callbacks get the full payload.
- **No plugin wire format for this class** — the "protocol" is Python function
  signatures and ABC methods.

### (b) Out-of-process surfaces — language-agnostic, real protocols

| Surface | Spawns | Protocol |
|---|---|---|
| **MCP servers** (`mcp_servers:` config, portable Agent Plugins v1) | Subprocess (stdio) or network (Streamable HTTP / SSE) | **JSON-RPC 2.0 (MCP)** on a dedicated `mcp-event-loop` daemon thread (`tools/mcp_tool_loop.py`), bridged via `run_coroutine_threadsafe` |
| **Shell hooks** (`hooks:` in `config.yaml`) | `subprocess.Popen`, own process group, pipes | **stdin JSON** payload → **stdout JSON** result (`{"action": "block"\|"modify"\|"approve"}` or Claude-Code dialect) + exit code 2 = block (`agent/shell_hooks.py`) |
| **Gateway hooks** (`~/.hermes/hooks/<name>/`) | In-process `importlib` load of `handler.py` | Direct `handle(event_type, context)` (sync/async) |
| Command providers (TTS/STT/secrets) | Subprocess | stdin/stdout/exit-code conventions |
| Outbound webhooks | Daemon worker thread | HMAC-signed HTTP POST |

Shell hooks **join the same Python hook dispatcher** — registered as closures on
the plugin hook manager, so one `invoke_hook()` fans out to Python callbacks
*and* spawns subprocesses.

### (c) MCP in more detail

- **MCP servers are not native plugins.** They are a separate extension surface
  (config-driven or shipped inside portable packages). Both end up registering
  tools into `tools/registry.py`, so the model sees one uniform tool list.
- The **client is embedded** in whichever Hermes process serves the turn (CLI,
  gateway, TUI backend) — not a separate client app. A daemon thread
  `mcp-event-loop` runs its own asyncio loop.
- Tool *dispatch* is in-process; the handler then issues JSON-RPC over the
  server's stdio pipes or HTTP connection.
- Discovery is coordinated cross-process with a file lock.
- Native plugins can call MCP via `ctx.call_mcp(...)` — default-deny unless an
  `mcp_allowlist` grant exists.

#### Portable Agent Plugins v1 — two schema layers

1. **Package manifests → JSON Schema (declaration only).**
   - `plugin.json` with `$schema: https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`
   - `mcp.json` with `$schema: …/mcp.schema.json`
   - Hermes checks `$schema` equality and validates fields **locally** against
     hardcoded field sets — it does **not** fetch remote schemas at load time.
2. **Runtime wire → MCP's JSON-RPC 2.0.** Portable packages contribute nothing
   to the wire format; once the server starts, the conversation is plain MCP
   (spec-defined method shapes, implemented by the official `mcp` Python SDK).
   Hermes pins protocol version `"2025-03-26"`.

Typical exchange:

```jsonc
→ {"jsonrpc":"2.0","id":"_probe","method":"initialize",
   "params":{"protocolVersion":"2025-03-26","capabilities":{},
             "clientInfo":{"name":"hermes-probe","version":"0.1"}}}
← {"jsonrpc":"2.0","id":"_probe","result":{"protocolVersion":"…",
   "capabilities":{"tools":{}},"serverInfo":{…}}}

→ {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search",
   "inputSchema":{"type":"object","properties":{…}}}]}}

→ {"jsonrpc":"2.0","id":3,"method":"tools/call",
   "params":{"name":"search","arguments":{"query":"…"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"…"}],
   "isError":false}}
```

Each MCP tool's `inputSchema` is a JSON Schema; Hermes converts it to the
OpenAI-style function-calling schema the model sees.

### Trust model (no sandbox)

| Control | Mechanism |
|---|---|
| Enablement | `plugins.enabled` allow-list; `plugins.disabled` wins; bundled auto-load |
| Catalog kill-list | `removed.yaml` refused at install AND load |
| Load timeout | 10s; abandoned worker's later registrations refused |
| Tool override | requires `allow_tool_override: true` |
| MCP from plugin | `mcp_allowlist` — default deny |
| Capabilities | `has_capability()` — bundled trusted, others need grant; fail closed |
| Shell hooks | per-(event, command) consent allowlist + TTY prompt; `HERMES_SAFE_MODE=1` disables |
| Hook timeout | bounded hooks abandoned; `pre_tool_call` fails closed |
| Process identity | children get `build_subprocess_env` / `served_profile_child_env`, never raw `os.environ.copy()` |

A loaded Python plugin runs with the full privileges of the Hermes process.

---

## 4. CLI Gross Component Structure

### Layer 0 — Entry & boot (`hermes_cli/main.py`)

```
pyproject: hermes = "hermes_cli.main:main"
                │
                ▼
   main()  ── bootstrap ──────────────────────────────────
   1. hermes_bootstrap (Windows UTF-8 stdio)
   2. _startup_fast (HERMES_HOME normalize; fast paths:
      Termux TUI / fast serve / fast chat → exec out early)
   3. _early_recovery (venv self-heal before 3rd-party imports)
   4. startup watchdog (gateway run)
   5. _build_cli_parser() — argparse tree; each subcommand
      registers build_X_parser() from subcommands/*.py and
      set_defaults(func=cmd_X)
   6. _prepare_agent_startup(args) — plugin discovery + shell
      hooks (gated so introspection cmds pay no cost)
   7. args.func(args)   ← subcommand dispatch
```

Two dispatch worlds share this entry:

| Invocation | Route |
|---|---|
| `hermes tools`, `hermes gateway`, `hermes plugins`, … (~60 subcommands) | argparse → `cmd_*` in `hermes_cli/subcommands/*.py` — one-shot, **no HermesCLI** |
| `hermes` / `hermes chat` / `-q` | `cmd_chat` → classic REPL (`cli.main`) or Ink TUI (`--tui`, Node child via `main_tui_launch.py`) |

### Layer 1 — Interactive core: `cli.py` facade + 17 mixins

```
HermesCLI(CLIInitMixin, CLITuiRuntimeMixin, CLIProcessNotificationsMixin,
          CLIAgentSetupMixin, CLICommandsMixin, CLIBillingMixin, CLITuiMixin,
          CLIStatusBarMixin, CLIVoiceMixin, CLIModelSwitchMixin, CLISessionMixin,
          CLIStreamMixin, CLIModalMixin, CLITerminalMixin, CLIInfoMixin,
          CLILoopsMixin, CLIChatTurnMixin)
```

| Mixin | Responsibility |
|---|---|
| `cli_init` | Constructor phases: model/provider, toolsets, session store, UI state |
| `cli_tui_runtime` | REPL run loop: input → process → after-turn; prompt_toolkit Application; signals |
| `cli_chat_turn` | `chat()`: stage → agent thread → `run_conversation()` → stream/render → interrupt |
| `cli_agent_setup` | Builds/resumes `AIAgent` (`self.agent`), credentials, session resume |
| `cli_commands` | Slash-command handlers (`_handle_*_command`) |
| `cli_session` | Session lifecycle: new/resume/save/undo/compress |
| `cli_stream` / `cli_status_bar` | Streaming output, spinner, status bar |
| `cli_modal` | Overlays: clarify, approval, sudo capture, palette |
| `cli_model_switch` | `/model` picker, runtime snapshot/restore |
| `cli_tui` | prompt_toolkit construction & keybindings |
| `cli_terminal` | Repaint/resize, paste, file-drop, clipboard |
| `cli_voice` | STT/TTS, wake word |
| `cli_info` / `cli_billing` / `cli_loops` | Help/views, billing, goal/heartbeat loops |

**Interaction rule:** mixins never import `cli` at module load (cycle) — they
`from cli import ...` lazily inside methods. Pure functions live in non-mixin
siblings (`cli_render`, `cli_config_load`, `cli_shutdown`, `cli_single_query`,
`cli_terminal_input`, `cli_auto_maintenance`) that `cli.py` re-exports, with
bodies late-binding through the facade so monkeypatch seams hold.

### Layer 2 — Slash-command dispatch (in-REPL)

```
user input "/resume 3"
   → resolve_command()        # hermes_cli/commands.py COMMAND_REGISTRY
   → fire_pre_command_hook()  # plugin observer
   → HermesCLI.process_command()
        _SLASH_DISPATCH[canonical] → (method_name, pass_original)   # cli.py
        fallback: getattr(cls, f"_handle_{name}_command")
        OR slash_exec.EXECUTORS[key]   # surface-independent pure formatters
   → handler runs (mutates session/config) or returns False → exit REPL
```

`COMMAND_REGISTRY` is the single source shared by CLI help, gateway dispatch,
Telegram BotCommand menus, Slack mapping, and autocomplete. Table-driven; no
`elif` ladders ≥ 4 branches.

### Layer 3 — The chat turn (CLI meets agent)

```
CLIChatTurnMixin.chat()
  │  stage images, resolve config
  ├─ thread: agent.run_conversation(msg)     ← run_agent.py / agent/turn_*.py
  │     ├─ model_tools.get_tool_definitions()   (tool schemas → LLM)
  │     ├─ handle_function_call()               (tool dispatch → tools/registry)
  │     │     └─ plugin hooks pre/post_tool_call
  │     ├─ hermes_state.SessionDB                (persistence)
  │     └─ plugin hooks pre/post_api_request
  ├─ main thread: stream callbacks → cli_stream / cli_status_bar render
  └─ interrupt monitor → agent.interrupt()
```

The CLI owns the UI thread and lifecycle; the agent runs on a worker thread.
Seams are late-bound: `cli.py` wraps `AIAgent`, `get_tool_definitions`, etc. as
thin facades so tests monkeypatch through `cli.*`.

### Layer 4 — Topical sibling domains in `hermes_cli/` (~400 modules)

Facade + `<stem>_<topic>.py` siblings — find code by topic, not by reading the
facade:

| Domain | Facade | Siblings (examples) |
|---|---|---|
| Config | `config.py` | `config_defaults`, `config_effective`, `config_migrations`, `config_env_routing` |
| Gateway control | `gateway.py` | `gateway_service_unit`, `gateway_launchd`, `gateway_migrate`, `gateway_multiplex_*` |
| Models | `models.py`, `model_switch.py` | `model_setup_flows*`, `model_search`, `runtime_provider*` |
| Auth | `auth.py` | `auth_nous`, `auth_xai`, `auth_device_flow`, `credential_lifecycle` |
| Plugins | `plugins.py` | `plugins_discovery`, `plugins_loader`, `plugins_dispatch`, `plugins_ledger`, `plugin_catalog` |
| Update | `update_cmd.py` | `update_cmd_git/deps/fleet/…`, `update_inventory`, `update_handoff` |
| Kanban | `kanban.py` | `kanban_db*`, `kanban_decompose`, `kanban_swarm` |
| Sessions | `sessions_cmd.py` | `session_recovery`, `session_export*` |
| MCP | `mcp_config.py` | `mcp_catalog`, `mcp_picker`, `mcp_startup` |
| Dashboard | `web_server.py` | `web_server_{chat,config,cron,…}` + `web_routers/` |
| Profiles | `profiles.py` | `profile_channels`, `profile_identity` |

### Layer 5 — Packages the CLI drives (not part of it)

```
hermes_cli  ──direct import──►  run_agent.py / agent/turn_*.py   (the loop)
                 │              model_tools.py → tools/registry  (tools)
                 │              hermes_state*.py                 (session DB)
                 │              hermes_cli/plugins*.py → plugins/ (extension)
                 │
                 ├──spawn──►   gateway/ (GatewayRunner; long-lived;
                 │              systemd/launchd; messaging platforms)
                 ├──spawn──►   ui-tui (Node/Ink; --tui child; JSON-RPC
                 │              to tui_gateway/)
                 ├──in-proc─►  tui_gateway/server.py (JSON-RPC backend
                 │              for TUI + Desktop; agents in-process)
                 ├──spawn──►   MCP servers (stdio children, JSON-RPC)
                 ├──spawn──►   terminal backends (local/docker/ssh/modal)
                 └──spawn──►   shell hooks / command providers (Popen)
```

### Alternate surfaces (same core, different shells)

| Surface | Relation to HermesCLI |
|---|---|
| Classic REPL | **Is** HermesCLI |
| Ink TUI (`--tui`) | Separate Node process; backend = `tui_gateway/` JSON-RPC |
| Dashboard / Desktop (`serve`) | FastAPI `web_server.py` + routers; embeds real TUI via PTY |
| ACP (VS Code/Zed) | `acp_adapter/` — separate entry, JSON-RPC on stdio |
| One-shot (`-q`) | `cli_single_query.py` — agent once, no REPL |
| Gateway | `gateway/` — long-lived; CLI only *controls* it |

---

## 5. Design Rules That Emerge

1. **Facade + topic siblings** — never grow a god file; find code by topic
   (`grep def X <stem>_*.py`), not by reading the facade.
2. **Mixin composition over inheritance trees** — `HermesCLI` is a thin shell;
   behavior lives in named mixins with lazy `from cli import` to break cycles.
3. **Table-driven dispatch** — `_SLASH_DISPATCH`, `COMMAND_REGISTRY`,
   `_command_handler_table`; no if/elif ≥ 4 branches.
4. **One registry, many surfaces** — `COMMAND_REGISTRY` and `tools/registry`
   derive every consumer's view.
5. **Late binding at seams** — facades re-export siblings; patch where
   production reads (`cli.X`, not the defining module).
6. **CLI controls, doesn't embed, the long-lived world** — gateway/MCP/TUI
   children are spawned or RPC'd; only the agent loop runs in-process with the
   REPL.
7. **Plugins stay at the edges** — in-process Python for tight coupling (hooks,
   tools, providers); subprocess/JSON-RPC for foreign capability (MCP, shell
   hooks); never hardcode plugin logic into core.
8. **Policy over sandbox** — allowlists, consent, capability grants, and
   fail-closed gates instead of OS isolation; Python plugins are full-trust.
9. **Profile scope is explicit** — one process may serve many profiles; code
   outside a turn binds the owning profile (`hermes_home_key()`, secret scope,
   `served_profile_child_env`); never freeze `HERMES_HOME` at import.
10. **Cache-safe evolution** — additive hook payloads, signature inspection,
    deferred system-prompt invalidation (`--now` opt-in), compression as the
    only mid-conversation context mutation.
