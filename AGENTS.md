# Repository Guidance

## Purpose

This repository contains the Lua Neovim client for the Sprint Loop Controller. It is included as a submodule of the controller source repository but has its own Git history and releases.

The plugin is intentionally thin. The Python controller remains authoritative for all sprint workflow behavior.

## Architecture Boundary

The plugin may:

- Resolve the sprint repository root.
- Resolve the active OpenCode server URL and optional browser-facing web URL.
- Launch the controller as a detached Neovim job.
- Invoke controller status and control commands asynchronously.
- Render progress, failures, and blocked reasons.
- Open the active OpenCode session in a browser.

The plugin must not:

- Implement workflow transitions or retry policy.
- Inspect or mutate Git state directly.
- Monitor or interpret GitHub CI directly.
- Parse agent findings into workflow decisions.
- Maintain authoritative sprint state.
- Start an OpenCode server when no valid URL is available.
- Hard-code mkchad module APIs into the generic plugin.

## Public Commands

V1 provides:

- `:SprintLoopStart`
- `:SprintLoopProgress`
- `:SprintLoopPause`
- `:SprintLoopResume`
- `:SprintLoopStop`
- `:SprintLoopOpenSession`

These commands delegate to the documented `sprint-loop` CLI contract.

## Implementation Rules

- Execute controller commands asynchronously so Neovim remains responsive.
- Construct argument arrays directly. Do not build shell command strings from paths, URLs, or user input.
- Resolve configured options at command execution time because workspace and server URLs may change. Sprint-root, executable, and CA functions return synchronously; only server/web URL functions may use `done(value, error)` callbacks.
- Launch the controller with detached process semantics so closing Neovim does not terminate it.
- Treat `sprint-loop status --json` as the status source of truth.
- Validate required JSON fields, tolerate unknown fields, and report malformed output clearly.
- Keep presentation code separate from process invocation and configuration resolution.
- Display blocked and failure reasons prominently.
- Do not expose server credentials in notifications, logs, command arguments, or buffers.
- Avoid synchronous filesystem, process, or network work on Neovim's main interaction path.

## Configuration

Accept strings or synchronous-return functions for the controller executable and sprint root. Accept strings or synchronous/callback functions for the OpenCode server URL and optional web URL. Keep mkchad integration in configuration or an adapter rather than coupling the core plugin to mkchad internals.

## Development Practices

- Be sure to document public API methods.
- Update user-facing documentation in the same change as commands, setup options, defaults, key mappings, progress fields, error behavior, or controller compatibility requirements.
- Keep the README and Neovim help documentation aligned with the actual public Lua API and supported `sprint-loop` CLI contract.
- Include working setup and command examples for new public behavior, and remove examples for behavior that is no longer supported.
- Document required dependencies, detached-process behavior, and actionable troubleshooting steps for integration failures.
- Do not advertise planned mkchad integration, multiplexer support, or other future features as implemented.

## Testing

- Test command registration and argument construction.
- Test missing executable, sprint root, and server URL errors.
- Test asynchronous and detached launch behavior.
- Test status rendering for running, paused, blocked, failed, stopped, and finished states.
- Test malformed JSON, non-zero process exits, and unknown additional status fields.
- Prefer a fake `sprint-loop` executable for default tests; do not require a live OpenCode server.

## Git Workflow

Commit plugin changes in this repository before updating the parent repository's submodule pointer. Keep generated runtime state and local test artifacts out of version control.
