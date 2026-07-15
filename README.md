# opencode_sprint_loop.lua

A thin Neovim 0.12 client for the `sprint-loop` controller. It launches and
observes the controller; it does not implement workflow transitions, Git,
OpenCode question APIs, persistence, CI, or a server launcher.

## Installation and setup

Put this repository on Neovim's runtime path, then configure it explicitly:

```lua
require("opencode_sprint_loop").setup({
  sprint_root = function() return vim.fn.getcwd() end,
  server_url = function(done) return "http://127.0.0.1:4096" end,
  executable = "sprint-loop", -- optional; this is the default
  web_url = "http://127.0.0.1:4096", -- optional, for session opening only
})
```

`setup()` is required before every action. Each option accepts a non-empty
string or a resolver. Resolvers are evaluated when needed, not at setup time;
they may synchronously return a string or call `done(value, error)` once. A
function resolver has a five-second arbitration window. The plugin does not
consume even a synchronous return until that window closes, because the same
function could invoke `done` later; return-plus-callback and duplicate callback
completion are rejected before an action launches. The required `sprint_root` and
`server_url` are not discovered or guessed.
Resolver timers belong to the setup, watcher, or action that created them. They
are cancelled when setup or a watcher is replaced and on Neovim exit, so a stale
watcher resolution cannot launch another status process.

All six commands are registered when the plugin loads, so invoking one before
successful setup reports `setup_required` instead of an unknown command. A
later `setup()` replaces the active configuration and watcher, but pending
question IDs remain deduplicated for the lifetime of that Neovim process.

The generic plugin has no mkchad dependency or hard-coded mkchad API. A mkchad
adapter may read an existing URL through a user-supplied callback such as
`vim.g.opencode_opts.server.url(done)`, but it must never call `ensure` or any
server-start operation. Do not develop against `~/.config/mkchad`: use a
disposable remote clone and isolated XDG roots for any integration exercise.

For the currently documented mkchad callback/CA shape, keep the adapter in user
configuration:

```lua
local function existing_mkchad_url(done)
  local server = vim.g.opencode_opts and vim.g.opencode_opts.server
  if not server or type(server.url) ~= "function" then
    done(nil, "mkchad OpenCode URL resolver is unavailable")
    return
  end
  server.url(done) -- read only; never call server.ensure()
end

require("opencode_sprint_loop").setup({
  sprint_root = function() return vim.fn.getcwd() end,
  server_url = existing_mkchad_url,
  web_url = existing_mkchad_url,
  server_ca_cert = function()
    return vim.g.opencode_opts.server.ca_cert()
  end,
})
```

When the optional `server_ca_cert` resolver is configured, it must resolve to
an absolute readable regular file. Its path is supplied only as `SSL_CERT_FILE` to `run` and `resume` child
processes; it is neither placed in argv nor used to configure browser trust.
Trust a private CA separately in the browser.

## Commands and API

The module exports asynchronous `start()`, `progress()`, `pause()`,
`resume()`, `stop()`, and `open_session()` methods, backed by:

- `:SprintLoopStart`
- `:SprintLoopProgress`
- `:SprintLoopPause`
- `:SprintLoopResume`
- `:SprintLoopStop`
- `:SprintLoopOpenSession`

All controller commands use direct argv arrays, never a shell. Start launches
`sprint-loop run --root <root> --server-url <url>` detached. A launch notice is
not proof that the controller survived; use progress to confirm later
`process_running` status. Controls delegate to the current controller. In the
Sprint 2-compatible controller, pause, resume, and stop accurately report
the rejection as `controller_command_failed` without copying controller stderr;
the controller's current reason remains `feature_not_implemented`, and the
plugin does not simulate a state change.
Before start or resume constructs argv, it requires `server_url` to be a
credential-free HTTP(S) origin. User-info, paths, queries, fragments, malformed
authorities, and other schemes are rejected without echoing the value.
Controller stderr is never copied into a notification: non-zero exits and
signal-terminated commands use a generic actionable diagnostic so credentials,
credential-bearing URLs, and terminal controls from external processes cannot
be exposed.

Progress calls `status --json` asynchronously and opens a disposable centered,
read-only float. `q` and `Esc` close that buffer. It displays no-run, state,
safe reason, active session, commits, audit remaining effort, CI commit SHA,
counters, all checklist counts and assessment time, and the last event sequence
and time. Nullable evidence is rendered explicitly as `-`. Server URLs,
credentials, prompts, transcripts, and question text are never displayed.
If interruption leaves a durable active invocation, progress accepts and shows
its truthful `running` status even when `process_running` is false; this does
not claim that a controller process is alive. Blocked, failed, and stopped
status documents require a reason. Persisted documents also require the exact V1
state vocabulary, an update time and last event, compatible repository keys in
object-shaped local/pushed commit maps, and no active invocation in a
terminal state. Recognizable credentials, credential-bearing URLs, URL query or
fragment data, and common provider-token forms in any displayed field make the
entire status inconsistent instead of producing a lossy progress view.

Setup first performs one asynchronous status observation, notifies for a valid
pending request in that first document, and only then starts the single
ephemeral watcher when the document reports a running controller.
Successful start/resume launches also begin discovery. The watcher polls at a
bounded two-second interval with at most one status process in flight. It stops
after an observed controller exits (including a final launch-completion observation)
and emits one notification per pending request ID
for future-compatible `waiting_for_user` status. It never reads question text,
answers questions, writes files, or changes controller state.

`open_session()` first validates status, then opens
`<web-base>/<base64url(canonical-sprint-root)>/session/<encoded-session-id>`
through Neovim. Missing web configuration, no active session, invalid web URL,
and browser failures are actionable notifications. Browser-facing URLs must be
credential-free HTTP(S) bases.
Deployment path prefixes may use RFC 3986 path characters and valid percent
escapes. Raw spaces, malformed percent escapes, backslashes, and other invalid
URL characters are rejected.

The plugin requires the complete schema-version-one status projection described
for Sprint 3. Unsupported schemas or missing/inconsistent fields fail closed;
upgrade the plugin and controller together if their status contracts differ.
Desktop notifications and browser opening still depend on the operator's
Neovim UI and system URL handler.

## Verification

Default tests use a fake controller process and no network, browser, OpenCode,
GitHub, model, or credentials:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -l tests/run.lua
```

The suite covers the setup/API, argv, streaming output bounds, complete status
matrix, float lifecycle, watcher lifecycle, URL/browser behavior, and CA child
environment. It also launches the repository fake executable from a nested
headless Neovim and proves that the detached child records completion after the
launcher exits.

A real-server/mkchad demonstration is opt-in and is not performed by this
suite. Sprint 3 supports presentation of a fixture-only waiting status; real
Builder questions begin in Sprint 4, while functional pause/recovery controls
belong to Sprint 7.

### Safety-bounded opt-in real demonstration

Use only a disposable clean sprint-history repository and an externally
started supported OpenCode server rooted there. Do not point any variable below
at `~/.config/mkchad`, and do not reuse its server, CA, credentials, or XDG
directories. Install the controller in a disposable virtual environment, put
this plugin checkout on the runtime path, create a uniquely named temporary root
with `export SPRINT_LOOP_DEMO_TEMP="$(mktemp -d /tmp/opencode-sprint-loop-demo.XXXXXX)"`,
and write the following init file to
`$SPRINT_LOOP_DEMO_TEMP/init.lua`:

```lua
vim.opt.runtimepath:append(assert(vim.env.SPRINT_LOOP_PLUGIN_ROOT))
require("opencode_sprint_loop").setup({
  executable = assert(vim.env.SPRINT_LOOP_EXECUTABLE),
  sprint_root = assert(vim.env.SPRINT_LOOP_DEMO_ROOT),
  server_url = assert(vim.env.SPRINT_LOOP_DEMO_SERVER_URL),
  web_url = assert(vim.env.SPRINT_LOOP_DEMO_WEB_URL),
  server_ca_cert = vim.env.SPRINT_LOOP_DEMO_CA,
})
```

After independently verifying that the root and optional CA are disposable,
regular paths and that `git -C "$SPRINT_LOOP_DEMO_ROOT" status --porcelain`
is empty, launch an isolated Neovim with a finite outer bound:

```bash
export SPRINT_LOOP_PLUGIN_ROOT="$PWD"
test -n "$SPRINT_LOOP_DEMO_TEMP"
export SPRINT_LOOP_EXECUTABLE=/absolute/path/to/disposable-venv/bin/sprint-loop
export SPRINT_LOOP_DEMO_ROOT=/absolute/path/to/disposable-sprint
export SPRINT_LOOP_DEMO_SERVER_URL=https://127.0.0.1:4096
export SPRINT_LOOP_DEMO_WEB_URL=https://127.0.0.1:4096
export SPRINT_LOOP_DEMO_CA=/absolute/path/to/disposable-ca.pem  # omit for HTTP/public CA
export OPENCODE_SERVER_PASSWORD=synthetic-demo-password
mkdir -p "$SPRINT_LOOP_DEMO_TEMP"/{config,state,data,cache}
timeout 15m env \
  XDG_CONFIG_HOME="$SPRINT_LOOP_DEMO_TEMP/config" \
  XDG_STATE_HOME="$SPRINT_LOOP_DEMO_TEMP/state" \
  XDG_DATA_HOME="$SPRINT_LOOP_DEMO_TEMP/data" \
  XDG_CACHE_HOME="$SPRINT_LOOP_DEMO_TEMP/cache" \
  nvim --clean -u "$SPRINT_LOOP_DEMO_TEMP/init.lua"
```

In Neovim run `:SprintLoopStart`, `:SprintLoopProgress`, and, after an active
session appears, `:SprintLoopOpenSession`. Close Neovim during the probe, reopen
with the same bounded command, and use progress to verify setup-time
rediscovery. The expected current controller result is
`blocked/execution_not_implemented`; waiting-for-user remains fixture-only.
Stop the externally managed server yourself, inspect only credential-free
status/evidence, unset the variables (especially the synthetic password), and
remove only the uniquely named disposable temporary root, virtual environment, sprint fixture, and
CA. This procedure is documentation, not evidence that the external
OpenCode/browser/private-CA gates have been performed.
