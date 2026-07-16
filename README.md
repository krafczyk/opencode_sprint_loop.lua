# opencode_sprint_loop.lua

A thin Neovim 0.12 client for the `sprint-loop` controller. It launches and
observes the controller; it does not implement workflow transitions, Git,
OpenCode question APIs, persistence, CI, or a server launcher.

## Installation and setup

Plugin managers should add this repository to Neovim's runtime path and run
their normal install/update step. Ensure the manager's help-tag generation is
enabled; if it does not generate tags automatically, run `:helptags ALL` after
installation.

For a manual native-package installation, clone the repository beneath a
`pack/*/start` directory and generate tags for its `doc` directory explicitly:

```bash
mkdir -p ~/.local/share/nvim/site/pack/sprint-loop/start
git clone git@github.com:krafczyk/opencode_sprint_loop.lua.git \
  ~/.local/share/nvim/site/pack/sprint-loop/start/opencode_sprint_loop.lua
nvim --headless \
  "+helptags ~/.local/share/nvim/site/pack/sprint-loop/start/opencode_sprint_loop.lua/doc" \
  +qa
```

After either installation path, `:help SprintLoop` must open this plugin's help.
Then configure it explicitly:

```lua
require("opencode_sprint_loop").setup({
  sprint_root = function() return vim.fn.getcwd() end,
  server_url = function() return "http://127.0.0.1:4096" end,
  executable = "sprint-loop", -- optional; this is the default
  web_url = "http://127.0.0.1:4096", -- optional, for session opening only
})
```

`setup()` is required before every action. Each option accepts a non-empty
string. Function-valued `sprint_root`, `executable`, and `server_ca_cert` must
return that string synchronously; they are invoked without a completion
callback, and callback-style misuse is rejected before a controller child or CA
environment override is created. Only `server_url` and `web_url` functions may
either return synchronously or call `done(value, error)` once. A URL function has
a five-second arbitration window: even a synchronous URL return remains private
until that window closes so return-plus-callback and duplicate callbacks reject
before an action launches. The required values are not discovered or guessed.

Setup resolves `sprint_root` and `executable` for its mandatory initial status
observation. Every public action re-resolves the options it needs, including root
and executable, so setup-time observation does not freeze later action values.
Resolver lifetimes belong to the setup, watcher, or action that created them and
are invalidated on replacement or Neovim exit, including a result already
arbitrated but still queued for delivery.

All six commands are registered when the plugin loads, so invoking one before
successful setup reports `setup_required` instead of an unknown command. A
later `setup()` replaces the active configuration and watcher, but pending
question IDs remain deduplicated for the lifetime of that Neovim process.
Unknown setup fields report only the fixed `invalid_setup` category; the
untrusted field name is never copied into a notification.

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
an absolute readable regular file. An asynchronous libuv stat rejects directories,
devices, and FIFOs before open; readability and the opened descriptor type are
then checked through asynchronous open, fstat, and close callbacks. Its path is supplied only as `SSL_CERT_FILE` to `run` and `resume` child
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
`process_running` status. Detached controller stdout and stderr are connected to
`/dev/null`, not launcher-owned pipes, so later writes neither depend on Neovim
nor expose controller output. If Neovim remains open, a separate bounded notice
reports zero process exit and directs the user to progress without claiming the
workflow reached a terminal state. The asynchronous `/dev/null` open and queued
spawn are generation- and exit-gated: setup replacement or `VimLeavePre` closes
the pending descriptor and suppresses a stale launch, watcher mutation, and
launch notice. Once a controller has spawned successfully, replacement never
signals it. Controls delegate to the current controller. In the
Sprint 2-compatible controller, pause, resume, and stop accurately report
the rejection as `controller_command_failed` without copying controller stderr;
the controller's current reason remains `feature_not_implemented`, and the
plugin does not simulate a state change.
Before start or resume constructs argv, it requires the complete resolved
`server_url` to be a credential-free HTTP(S) origin. User-info, paths, queries,
fragments (including a non-empty fragment after an empty query), named-value or
provider-token components, malformed authorities, and other schemes are rejected
without echoing the value. The same complete-value credential scan runs on the
resolved browser base before browser use.
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
The no-run view explicitly includes the root, `process_running: false`, and the
controller version. A pre-CI round greater than its configured maximum is
inconsistent. Every final display line is scanned again so otherwise safe fields
cannot compose an authorization or named credential across a join; such a line
is replaced by a fixed withheld-detail notice.
If interruption leaves a durable active invocation, progress accepts and shows
its truthful `running` status even when `process_running` is false; this does
not claim that a controller process is alive. Blocked, failed, and stopped
status documents require a reason. Persisted documents also require the exact V1
state vocabulary, an update time and last event, compatible repository keys in
object-shaped local/pushed commit maps, and no active invocation in a
terminal state. `stopped`, `failed`, and `finished` accept
`process_running: true` while the controller finishes exiting as well as
`false`; stopped and failed still require reasons. Recognizable credentials, credential-bearing URLs, URL query or
fragment data, and common provider-token forms in any displayed field make the
entire status inconsistent instead of producing a lossy progress view.
Controller and plugin recognizers use the same explicit ASCII case-folding and
ASCII-whitespace grammar. Conventional ASCII authorization, URI, named-value,
private-key, and provider-token credentials reject; Unicode lookalikes such as
long-s or Kelvin-sign letters and NBSP separators are unsupported near misses.

Setup first performs one asynchronous status observation, notifies for a valid
pending request in that first document, and only then starts the single
ephemeral watcher when the document reports a running controller.
Successful start/resume launches also begin discovery. The watcher polls at a
bounded two-second interval. All plugin status queries share one serialized
child-process slot. Repeated setup and Neovim exit invalidate all work from the
replaced configuration. Watcher replacement and successful start/resume
replacement cancel only setup/watcher-owned reads and wait for their completion
callback; queued or active public progress/session reads remain serialized and
complete normally. Successfully spawned start/resume processes have independent
launch identities. Same-root discovery survives a newer duplicate or rejected
launch's no-run completion while an older launch remains alive, and completion
of either launch updates its own ownership even if the watcher was replaced.
Different roots and replaced setup generations cannot mutate the current
watcher. Stop preserves the current watcher through resolver, spawn,
signal/non-zero, and success-while-still-active outcomes; only status confirming
`process_running: false` ends observation. Detached and control controller
processes are never cancellation targets. The watcher stops
after an observed controller exits (including a final launch-completion observation)
and emits one notification per pending request ID
for future-compatible `waiting_for_user` status. It never reads question text,
answers questions, writes files, or changes controller state.

`open_session()` first validates status, then opens
`<web-base>/<base64url(canonical-sprint-root)>/session/<encoded-session-id>`
through Neovim. Missing web configuration, no active session, invalid web URL,
and browser failures are actionable notifications. Browser-facing URLs must be
credential-free HTTP(S) bases.
Neovim 0.12 returns an asynchronous `SystemObj` handler process. Its `wait()`
method force-kills the process whenever a supplied timeout elapses, including a
zero timeout, so the plugin never calls it. Instead, bounded timer polling reads
the completion result retained by Neovim after process exit and inherited output
pipes close. A handler whose result is not retained yet continues polling within
a five-second bound without signalling or otherwise changing that process.
The plugin reports terminal success only after a zero exit, and reports non-zero,
signalled, or observation-timeout completion as `browser_open_failed`. A missing handler fails immediately; an overridden handler
whose completion cannot be observed receives a warning and no success claim.
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
headless Neovim and proves that the detached child writes both output streams and
records completion after the launcher exits without disclosing either stream.

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
with `mkdir -p /tmp/opencode-mkchad` followed by
`export SPRINT_LOOP_DEMO_TEMP="$(mktemp -d /tmp/opencode-mkchad/sprint-loop-demo.XXXXXX)"`,
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
