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
callback resolver has a five-second bound. The required `sprint_root` and
`server_url` are not discovered or guessed.

The generic plugin has no mkchad dependency or hard-coded mkchad API. A mkchad
adapter may read an existing URL through a user-supplied callback such as
`vim.g.opencode_opts.server.url(done)`, but it must never call `ensure` or any
server-start operation. Do not develop against `~/.config/mkchad`: use a
disposable remote clone and isolated XDG roots for any integration exercise.

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
`feature_not_implemented`; the plugin does not simulate a state change.

Progress calls `status --json` asynchronously and opens a disposable centered,
read-only float. `q` and `Esc` close that buffer. It displays no-run, state,
safe reason, active session, commits, audit/CI/counters/checklist, and last
event. Server URLs, credentials, prompts, transcripts, and question text are
never displayed.

After setup and start/resume, one ephemeral watcher polls at a bounded
two-second interval with at most one status process in flight. It stops after
an observed controller exits and emits one notification per pending request ID
for future-compatible `waiting_for_user` status. It never reads question text,
answers questions, writes files, or changes controller state.

`open_session()` first validates status, then opens
`<web-base>/<base64url(canonical-sprint-root)>/session/<encoded-session-id>`
through Neovim. Missing web configuration, no active session, invalid web URL,
and browser failures are actionable notifications. Browser-facing URLs must be
credential-free HTTP(S) bases.

## Verification

Default tests use a fake controller process and no network, browser, OpenCode,
GitHub, model, or credentials:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -l tests/run.lua
```

A real-server/mkchad demonstration is opt-in and is not performed by this
suite. Sprint 3 supports presentation of a fixture-only waiting status; real
Builder questions begin in Sprint 4, while functional pause/recovery controls
belong to Sprint 7.
