local config = require("opencode_sprint_loop.config")
local process = require("opencode_sprint_loop.process")
local status = require("opencode_sprint_loop.status")
local ui = require("opencode_sprint_loop.ui")
local url = require("opencode_sprint_loop.url")
local loop = require("opencode_sprint_loop")

local failures = 0
local tests = 0
local function check(condition, message)
  tests = tests + 1
  if not condition then failures = failures + 1; io.stderr:write("FAIL: " .. message .. "\n") end
end
local function wait_for(predicate, message, timeout)
  check(vim.wait(timeout or 1000, predicate, 5), message)
end
local function json(value) return vim.json.encode(value) end
local null = vim.NIL
local function table_count(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

local function no_run(root)
  return {
    schema_version = 1, controller_version = "0.1.0", sprint_root = root or "/tmp/sprint",
    run_exists = false, process_running = false, run_id = null, sprint = null, state = null,
    reason = null, active = null, commits = null, audit = null, ci = null, counters = null,
    checklist = null, last_event = null, updated_at = null,
  }
end

local function persisted(state_name, running, active_status)
  local active = { role = null, invocation_id = null, session_id = null, status = null, interaction = null }
  if active_status then
    active = {
      role = "auditor", invocation_id = "0001-auditor", session_id = "ses/one two",
      status = active_status,
      interaction = active_status == "waiting_for_user" and {
        request_id = "que_example", question_count = 2, asked_at = "2026-07-15T12:00:00Z",
      } or null,
    }
  end
  local reason = (state_name == "blocked" or state_name == "failed" or state_name == "stopped") and { code = state_name .. "_reason", message = "safe detail" } or null
  return {
    schema_version = 1, controller_version = "0.1.0", sprint_root = "/tmp/canonical root",
    run_exists = true, process_running = running, run_id = "run-1",
    sprint = { multisprint = "foundation", index = 3 }, state = state_name, reason = reason,
    active = active, commits = { ["local"] = { zebra = null, alpha = "abc123" }, pushed = { zebra = "def456", alpha = null } },
    audit = { phase = null, pre_ci_round = 1, pre_ci_max_rounds = 2, remaining_effort = null },
    ci = { status = "not_started", attempt = 0, commit_sha = null },
    counters = { implementation_cycles = 4, ci_fix_attempts = 1 },
    checklist = { satisfied = 7, partial = 2, unsatisfied = 1, not_evaluated = 3, assessed_at = null },
    last_event = { sequence = 9, type = "agent.started", timestamp = "2026-07-15T12:00:00Z" },
    updated_at = "2026-07-15T12:01:00Z",
  }
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level) table.insert(notifications, { message = message, level = level }) end
local function clear_notifications() notifications = {} end
local function notification_count(fragment)
  local count = 0
  for _, item in ipairs(notifications) do if item.message:find(fragment, 1, true) then count = count + 1 end end
  return count
end

-- Commands are registered at plugin load and fail safely before setup.
local command_names = { "SprintLoopStart", "SprintLoopProgress", "SprintLoopPause", "SprintLoopResume", "SprintLoopStop", "SprintLoopOpenSession" }
for _, name in ipairs(command_names) do check(vim.fn.exists(":" .. name) == 2, name .. " registers at plugin load") end
local calls = {}
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = argv[2] == "status" and json(no_run()) or "feature_not_implemented\n", stderr = "" }) end)
  return {}
end)
loop._test_reset()
for _, method in ipairs({ "start", "progress", "pause", "resume", "stop", "open_session" }) do loop[method]() end
for _, name in ipairs(command_names) do vim.cmd(name) end
check(#calls == 0, "public methods and commands do not spawn before setup")
check(notification_count("setup_required") == 12, "all pre-setup actions report setup_required")

-- Setup shape, version gate, defaults, and resolver completion rules.
check(config.RESOLVER_TIMEOUT_MS == 5000, "resolver arbitration uses the documented five-second window")
local production_resolver_timeout = config.RESOLVER_TIMEOUT_MS
config.RESOLVER_TIMEOUT_MS = 20
clear_notifications(); loop.setup({ sprint_root = "/tmp/root" })
check(notification_count("invalid_setup") == 1 and #calls == 0, "missing required setup field fails without process")
clear_notifications(); loop.setup({ sprint_root = "/tmp/root", server_url = "http://127.0.0.1", surprise = true })
check(notification_count("unknown option") == 1, "unknown setup key fails")
clear_notifications(); loop.setup({ sprint_root = {}, server_url = "http://127.0.0.1" })
check(notification_count("invalid_setup") == 1 and #calls == 0, "wrong setup value type fails")
loop._test_set_version_check(function() return false end)
clear_notifications(); loop.setup({ sprint_root = "/tmp/root", server_url = "http://127.0.0.1" })
check(notification_count("unsupported_neovim") == 1 and #calls == 0, "controlled older-version fixture fails without mutation")
loop._test_reset()

local function resolve_result(value, timeout)
  local result, resolve_error, count
  count = 0
  config.resolve(value, 1, function() return true end, function(resolved, err) result, resolve_error, count = resolved, err, count + 1 end)
  vim.wait(timeout or 200, function() return count > 0 end, 5)
  return result, resolve_error, count
end
local resolved, resolve_error, resolve_count = resolve_result(function() return "value" end)
check(resolved == "value" and resolve_error == nil and resolve_count == 1, "synchronous resolver completes once")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("callback") end)
check(resolved == "callback" and resolve_error == nil and resolve_count == 1, "callback resolver completes once")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("first"); done("second") end)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "duplicate callback rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("callback"); return "return" end)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "callback plus return rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done)
  vim.defer_fn(function() done("delayed callback") end, 5)
  return "synchronous return"
end)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "delayed callback after return rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done)
  done("first callback")
  vim.defer_fn(function() done("delayed duplicate") end, 5)
end)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "delayed duplicate callback rejects before consumer")
resolved, resolve_error = resolve_result(function() error("synthetic") end)
check(resolved == nil and resolve_error == "resolver_failed", "throwing resolver has concise error")
resolved, resolve_error = resolve_result(function() return "bad\0value" end)
check(resolved == nil and resolve_error == "invalid_resolved_value", "control-bearing resolver value rejects")
resolved, resolve_error = resolve_result(function(_) end, 200)
check(resolved == nil and resolve_error == "resolver_failed", "resolver timeout is bounded")
local stale_called = false
config.resolve(function(done) vim.defer_fn(function() done("late") end, 20) end, 1, function() return false end, function() stale_called = true end)
vim.wait(50)
check(not stale_called, "stale resolver completion is ignored")
local cancelled_called = false
local cancellable = config.resolve(function(_) end, 1, function() return true end, function() cancelled_called = true end)
check(cancellable.is_active(), "function resolver exposes an active cancellable lifetime")
cancellable.cancel()
check(not cancellable.is_active(), "function resolver cancellation closes its timer")
vim.wait(30)
check(not cancelled_called, "cancelled function resolver cannot invoke its consumer")

-- Resolver timers are owned by setup and closed when setup is replaced.
local old_setup_done
calls = {}; loop._test_reset()
process.set_runner_for_test(function(argv, _, callback)
  table.insert(calls, vim.deepcopy(argv))
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = "fake",
  sprint_root = function(done) old_setup_done = done end,
  server_url = "http://127.0.0.1",
})
wait_for(function() return table_count(loop._test_state().resolvers) == 1 end, "setup owns its pending resolver timer")
loop.setup({ executable = "fake", sprint_root = "/tmp/replacement", server_url = "http://127.0.0.1" })
wait_for(function() return #calls == 1 and table_count(loop._test_state().resolvers) == 0 end, "repeated setup cancels old resolver timers")
old_setup_done("/tmp/stale")
vim.wait(30)
check(#calls == 1, "cancelled setup resolver cannot spawn stale status")

-- URL validation rejects malformed or credential-bearing values without disclosure.
check(url.valid_server_origin("http://127.0.0.1:4096") and url.valid_server_origin("https://[::1]:443/"), "valid server origins pass")
for _, invalid in ipairs({
  "ftp://example.test", "http://", "http://:4096", "http://host:", "http://host:abc",
  "http://host:70000", "http://user:synthetic-secret@example.test", "http://host/path",
  "http://host?token=synthetic-secret", "http://host#synthetic-secret", "//host", "http:///path",
}) do check(not url.valid_server_origin(invalid), "invalid server origin rejects") end
check(url.normalize_web_base("https://example.test/prefix/") == "https://example.test/prefix", "web path prefix normalizes")
for _, valid in ipairs({
  "https://example.test/a%20b", "https://example.test/a%2Fb", "https://example.test/a~b!$&'()*+,;=:@/c",
}) do check(url.normalize_web_base(valid) ~= nil, "RFC-compatible encoded web path passes") end
for _, invalid in ipairs({
  "https://example.test/raw space", "https://example.test/%", "https://example.test/%2",
  "https://example.test/%GG", "https://example.test/{bad}", "https://example.test/[bad]",
}) do check(url.normalize_web_base(invalid) == nil, "malformed web path rejects") end

local status_document = no_run()
local executable_resolutions = 0
calls = {}; clear_notifications(); loop._test_reset()
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function()
    local is_control = argv[2] == "pause" or argv[2] == "resume" or argv[2] == "stop"
    callback({ code = is_control and 4 or 0, signal = 0, stdout = argv[2] == "status" and json(status_document) or "", stderr = is_control and "feature_not_implemented" or "" })
  end)
  return {}
end)
loop.setup({
  executable = function() executable_resolutions = executable_resolutions + 1; return "fake loop " .. executable_resolutions end,
  sprint_root = function() return "/tmp/root with spaces;$(literal)" end,
  server_url = "http://127.0.0.1:4096",
  web_url = "https://example.test/prefix/",
})
wait_for(function() return #calls >= 1 end, "setup performs initial status observation")
loop.start(); loop.pause(); loop.resume(); loop.stop(); loop.progress()
wait_for(function() return #calls >= 8 end, "all public process actions execute asynchronously")
wait_for(function() return notification_count("controller_command_failed") >= 3 end, "pause, resume, and stop report controller rejection safely")
local by_command = {}
for _, call in ipairs(calls) do by_command[call.argv[2]] = call end
check(vim.deep_equal(by_command.run.argv, { by_command.run.argv[1], "run", "--root", "/tmp/root with spaces;$(literal)", "--server-url", "http://127.0.0.1:4096" }), "start argv preserves literal hostile-looking root")
check(vim.deep_equal(by_command.pause.argv, { by_command.pause.argv[1], "pause", "--root", "/tmp/root with spaces;$(literal)" }), "pause argv is exact")
check(vim.deep_equal(by_command.resume.argv, { by_command.resume.argv[1], "resume", "--root", "/tmp/root with spaces;$(literal)", "--server-url", "http://127.0.0.1:4096" }), "resume argv is exact")
check(vim.deep_equal(by_command.stop.argv, { by_command.stop.argv[1], "stop", "--root", "/tmp/root with spaces;$(literal)" }), "stop argv is exact")
check(by_command.run.options.detach == true and by_command.resume.options.detach ~= true, "only start uses detached option")
check(executable_resolutions >= #calls, "executable callback resolves before every process invocation")
check(by_command.run.argv[1]:find("fake loop", 1, true) == 1 and by_command.run.argv[1] ~= "sh" and by_command.run.argv[1] ~= "bash", "process adapter receives executable argv, not a shell")
local pauses_before_command = 0
for _, call in ipairs(calls) do if call.argv[2] == "pause" then pauses_before_command = pauses_before_command + 1 end end
vim.cmd("SprintLoopPause")
wait_for(function()
  local count = 0; for _, call in ipairs(calls) do if call.argv[2] == "pause" then count = count + 1 end end
  return count == pauses_before_command + 1
end, "registered command delegates through the public pause behavior")

for _, invalid in ipairs({
  "ssh://host", "http://host:", "http://user:synthetic-secret@host", "http://host?token=synthetic-secret", "http://host#synthetic-secret",
}) do
  calls = {}; clear_notifications(); loop._test_reset()
  loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = invalid })
  wait_for(function() return #calls == 1 end, "invalid URL setup status completes")
  loop.start(); vim.wait(50)
  check(#calls == 1, "invalid server URL rejects before run argv")
  local messages = vim.inspect(notifications)
  check(not messages:find("synthetic-secret", 1, true) and notification_count("credential-free HTTP(S) origin") == 1, "rejected URL is never echoed")
end

calls = {}; clear_notifications(); loop._test_reset()
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = "fake",
  sprint_root = "/tmp/root",
  server_url = function(done)
    vim.defer_fn(function() done("http://127.0.0.1:4096") end, 5)
    return "http://127.0.0.1:4096"
  end,
})
wait_for(function() return #calls == 1 end, "dual-completion action setup status completes")
loop.start()
wait_for(function() return notification_count("resolver_failed") == 1 end, "dual-completion action reports resolver failure")
local action_spawned = false
for _, call in ipairs(calls) do if call.argv[2] == "run" then action_spawned = true end end
check(not action_spawned, "dual-completion resolver cannot launch controller action")

-- Duplicate/synchronous malformed callbacks cannot invoke consumers or launch.
local malformed_consumers, malformed_spawns = 0, 0
process.set_runner_for_test(function(_, _, callback) callback({ code = 0, signal = 0, stdout = "", stderr = "" }); return {} end)
process.run({ "fake" }, { on_spawn = function() malformed_spawns = malformed_spawns + 1 end }, function(_, err) if err then malformed_consumers = malformed_consumers + 1 end end)
check(malformed_spawns == 0 and malformed_consumers == 1, "synchronous process callback plus return cannot launch")
local duplicate_consumers, duplicate_error = 0, nil
process.set_runner_for_test(function(_, _, callback)
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = "one", stderr = "" }); callback({ code = 0, signal = 0, stdout = "two", stderr = "" }) end)
  return {}
end)
process.run({ "fake" }, {}, function(_, err) duplicate_consumers, duplicate_error = duplicate_consumers + 1, err end)
wait_for(function() return duplicate_consumers == 1 end, "duplicate process callback completes once")
check(duplicate_error == "process_spawn_failed", "duplicate process callback fails closed")

-- Private CA is passed only through the child environment.
calls = {}; loop._test_reset()
local ca_path = vim.fn.tempname(); vim.fn.writefile({ "synthetic CA" }, ca_path)
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = argv[2] == "status" and json(no_run()) or "", stderr = "" }) end)
  return {}
end)
loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = "https://example.test", server_ca_cert = ca_path })
wait_for(function() return #calls >= 1 end, "CA setup status completes")
loop.start(); wait_for(function() for _, call in ipairs(calls) do if call.argv[2] == "run" then return true end end end, "CA start spawns")
local ca_call
for _, call in ipairs(calls) do if call.argv[2] == "run" then ca_call = call end end
check(ca_call.options.env.SSL_CERT_FILE == ca_path and not vim.tbl_contains(ca_call.argv, ca_path), "CA path reaches run only as SSL_CERT_FILE")
check(not config.valid_ca_path("/dev/null"), "non-regular readable device cannot be a CA certificate")
check(not config.valid_ca_path(vim.fn.fnamemodify(ca_path, ":h")), "directory cannot be a CA certificate")
vim.fn.delete(ca_path)

-- Status grammar, compatibility states, malformed categories, and complete rendering.
for _, fixture in ipairs({
  no_run(), persisted("validating", true, "running"), persisted("implementing", true, "waiting_for_user"),
  persisted("paused", false), persisted("blocked", false), persisted("failed", false), persisted("stopped", false), persisted("finished", false),
}) do
  local decoded, err = status.decode(json(fixture))
  check(decoded ~= nil and err == nil and #status.render(decoded) > 0, "supported status state validates and renders")
end
local decoded, decode_error = status.decode('{"a":1,"\\u0061":2}')
check(decoded == nil and decode_error == "invalid_status_json", "escaped-equivalent duplicate keys reject")
decoded, decode_error = status.decode('{"schema_version":1,"schema_version":1}')
check(decoded == nil and decode_error == "invalid_status_json", "literal duplicate keys reject")
decoded, decode_error = status.decode(json(no_run()) .. " {}")
check(decoded == nil and decode_error == "invalid_status_json", "trailing JSON value rejects")
decoded, decode_error = status.decode('{"x":1e999}')
check(decoded == nil and decode_error == "invalid_status_json", "non-finite number rejects")
decoded, decode_error = status.decode('{"x":"' .. string.char(255) .. '"}')
check(decoded == nil and decode_error == "invalid_status_json", "invalid UTF-8 rejects")
decoded, decode_error = status.decode(string.rep("x", status.MAX_STATUS_BYTES + 1))
check(decoded == nil and decode_error == "status_output_too_large", "oversized status rejects before decode")
decoded, decode_error = status.decode("")
check(decoded == nil and decode_error == "invalid_status_json", "empty status rejects")
local unknown = no_run(); unknown.future = { ignored = true }
check(status.decode(json(unknown)) ~= nil, "unknown additional fields are ignored")
local wrong_schema = no_run(); wrong_schema.schema_version = 2
decoded, decode_error = status.decode(json(wrong_schema))
check(decoded == nil and decode_error == "unsupported_status_schema", "unknown status schema rejects")
local contradiction = persisted("paused", false, "running")
decoded, decode_error = status.decode(json(contradiction))
check(decoded ~= nil and decode_error == nil, "interrupted durable running invocation remains truthful")
local inactive_waiting = persisted("implementing", false, "waiting_for_user")
decoded, decode_error = status.decode(json(inactive_waiting))
check(decoded == nil and decode_error == "inconsistent_status", "waiting interaction still requires a running controller")
check(status.decode(json(persisted("validating", true))) ~= nil, "running controller may have no active invocation")
local missing_reason = persisted("blocked", false)
missing_reason.reason = null
decoded, decode_error = status.decode(json(missing_reason))
check(decoded == nil and decode_error == "inconsistent_status", "blocked status requires a reason")
local nullable_reason = persisted("validating", false)
check(status.decode(json(nullable_reason)) ~= nil, "non-reason state accepts a null reason")
nullable_reason.reason = { code = "safe_observation", message = "safe detail" }
check(status.decode(json(nullable_reason)) ~= nil, "non-reason state accepts a present safe reason")
local malformed_interaction = persisted("implementing", true, "waiting_for_user")
malformed_interaction.active.interaction.question_count = 0
decoded, decode_error = status.decode(json(malformed_interaction))
check(decoded == nil and decode_error == "inconsistent_status", "malformed interaction counter rejects")
local malformed_counter = persisted("paused", false)
malformed_counter.counters.implementation_cycles = -1
decoded, decode_error = status.decode(json(malformed_counter))
check(decoded == nil and decode_error == "inconsistent_status", "invalid workflow counter rejects")
local malformed_shapes = {
  { "unknown workflow state", function(value) value.state = "future_state" end },
  { "null persisted updated_at", function(value) value.updated_at = null end },
  { "null persisted last_event", function(value) value.last_event = null end },
  { "array-shaped local commit map", function(value) value.commits["local"] = { "abc123" } end },
  { "array-shaped pushed commit map", function(value) value.commits.pushed = { "abc123" } end },
  { "empty commit maps", function(value) value.commits["local"] = {}; value.commits.pushed = {} end },
  { "different repository keys", function(value) value.commits.pushed = { other = null } end },
  { "incomplete repository key set", function(value) value.commits["local"].other = null end },
  { "running terminal process", function(value) value.state = "finished"; value.process_running = true end },
  { "active terminal invocation", function(value) value.state = "failed"; value.reason = { code = "failed_reason", message = "safe detail" }; value.active = persisted("validating", false, "running").active end },
}
for _, case in ipairs(malformed_shapes) do
  local malformed = persisted("validating", false)
  case[2](malformed)
  decoded, decode_error = status.decode(json(malformed))
  check(decoded == nil and decode_error == "inconsistent_status", case[1] .. " rejects")
end
local rendered_credentials = {
  { "no-run root", function(value, unsafe) value.sprint_root = unsafe end, no_run },
  { "controller version", function(value, unsafe) value.controller_version = unsafe end },
  { "persisted root", function(value, unsafe) value.sprint_root = unsafe end },
  { "run ID", function(value, unsafe) value.run_id = unsafe end },
  { "multisprint", function(value, unsafe) value.sprint.multisprint = unsafe end },
  { "reason code", function(value, unsafe) value.reason = { code = unsafe, message = "safe detail" } end },
  { "reason message", function(value, unsafe) value.reason = { code = "safe_reason", message = unsafe } end },
  { "active role", function(value, unsafe) value.active.role = unsafe end },
  { "invocation ID", function(value, unsafe) value.active.invocation_id = unsafe end },
  { "session ID", function(value, unsafe) value.active.session_id = unsafe end },
  { "interaction request", function(value, unsafe) value.active.interaction.request_id = unsafe end, function() return persisted("implementing", true, "waiting_for_user") end },
  { "interaction time", function(value, unsafe) value.active.interaction.asked_at = unsafe end, function() return persisted("implementing", true, "waiting_for_user") end },
  { "repository name", function(value, unsafe) value.commits["local"] = { [unsafe] = null }; value.commits.pushed = { [unsafe] = null } end },
  { "commit SHA", function(value, unsafe) value.commits["local"].alpha = unsafe end },
  { "audit phase", function(value, unsafe) value.audit.phase = unsafe end },
  { "audit effort", function(value, unsafe) value.audit.remaining_effort = unsafe end },
  { "CI status", function(value, unsafe) value.ci.status = unsafe end },
  { "CI SHA", function(value, unsafe) value.ci.commit_sha = unsafe end },
  { "assessment time", function(value, unsafe) value.checklist.assessed_at = unsafe end },
  { "last event type", function(value, unsafe) value.last_event.type = unsafe end },
  { "last event time", function(value, unsafe) value.last_event.timestamp = unsafe end },
  { "updated time", function(value, unsafe) value.updated_at = unsafe end },
}
local unsafe_status_values = {
  "Authorization: Bearer synthetic-status-value",
  "https://user:synthetic-status-value@example.invalid/path",
  "https://example.invalid/path?opaque=synthetic-status-value",
  "token=synthetic-status-value",
  "ghp_" .. string.rep("A", 36),
}
for index, case in ipairs(rendered_credentials) do
  local factory = case[3] or function() return persisted("validating", false, "running") end
  local unsafe = unsafe_status_values[((index - 1) % #unsafe_status_values) + 1]
  local document = factory()
  case[2](document, unsafe)
  decoded, decode_error = status.decode(json(document))
  check(decoded == nil and decode_error == "inconsistent_status", case[1] .. " rejects credential-bearing display text")
end
local rendered = table.concat(status.render(persisted("validating", true, "running")), "\n")
for _, evidence in ipairs({ "remaining effort -", "commit -", "3 not evaluated", "assessed -", "Last event: #9" }) do check(rendered:find(evidence, 1, true) ~= nil, "progress renders " .. evidence) end
check(rendered:find("alpha=abc123", 1, true) < rendered:find("zebra=-", 1, true), "commit maps render in deterministic order")
local waiting_rendered = table.concat(status.render(persisted("implementing", true, "waiting_for_user")), "\n")
check(waiting_rendered:find("WAITING FOR USER", 1, true) ~= nil, "waiting state is prominent")
local extra = persisted("validating", true, "running"); extra.server_url = "https://synthetic-secret.example"
check(not table.concat(status.render(extra), "\n"):find("synthetic-secret", 1, true), "unknown sensitive-looking status field does not render")

-- Progress float options, mappings, dimensions, and replacement lifecycle.
local old_columns, old_lines = vim.o.columns, vim.o.lines
vim.o.columns, vim.o.lines = 30, 10
ui.show({ "Sprint Loop", "State: blocked", "Reason: safe" })
local first_buffer, first_window = ui.buffer, ui.window
check(vim.bo[first_buffer].buftype == "nofile" and vim.bo[first_buffer].bufhidden == "wipe" and not vim.bo[first_buffer].swapfile and not vim.bo[first_buffer].modifiable, "progress buffer is disposable and read-only")
local mappings = vim.api.nvim_buf_get_keymap(first_buffer, "n")
local mapped = {}; for _, mapping in ipairs(mappings) do mapped[mapping.lhs] = true end
check(mapped.q and mapped["<Esc>"], "progress close mappings are buffer-local")
local dimensions = vim.api.nvim_win_get_config(first_window)
check(dimensions.width <= 28 and dimensions.height <= 8, "small editor produces bounded float")
ui.show({ "replacement" })
check(not vim.api.nvim_buf_is_valid(first_buffer) and not vim.api.nvim_win_is_valid(first_window), "repeated progress replaces prior view")
if vim.api.nvim_win_is_valid(ui.window) then vim.api.nvim_win_close(ui.window, true) end
vim.o.columns, vim.o.lines = old_columns, old_lines

-- Session opening uses canonical encoding, handles both browser returns, and never needs vim.uri_parse.
status_document = persisted("validating", true, "running")
calls = {}; clear_notifications(); loop._test_reset()
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(status_document), stderr = "" }) end)
  return {}
end)
local opened_target
loop._test_set_browser(function(target) opened_target = target; return {} end)
loop.setup({ executable = "fake", sprint_root = "/different/root", server_url = "http://127.0.0.1", web_url = "https://example.test/prefix/" })
wait_for(function() return #calls >= 1 end, "session setup status completes")
loop.open_session(); wait_for(function() return opened_target ~= nil end, "browser success opens target")
local expected_root = vim.base64.encode(status_document.sprint_root):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
check(opened_target == "https://example.test/prefix/" .. expected_root .. "/session/ses%2Fone%20two", "session route encodes canonical root and one path segment")
loop._test_set_browser(function() return nil, "no handler" end)
clear_notifications(); loop.open_session(); wait_for(function() return notification_count("browser_open_failed") == 1 end, "nil,error browser return fails")
loop._test_set_browser(function() error("synthetic browser failure") end)
clear_notifications(); loop.open_session(); wait_for(function() return notification_count("browser_open_failed") == 1 end, "throwing browser fails without traceback")
for _, invalid in ipairs({ "ftp://host", "http://", "http://user:synthetic-secret@host", "http://host?x=synthetic-secret", "http://host#synthetic-secret" }) do
  opened_target = nil; clear_notifications(); loop._test_reset()
  loop._test_set_browser(function(target) opened_target = target; return {} end)
  loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1", web_url = invalid })
  wait_for(function() return #calls >= 1 end, "invalid web setup status completes")
  loop.open_session(); vim.wait(50)
  check(opened_target == nil and notification_count("invalid_web_url") == 1, "invalid web base does not invoke browser")
  check(not vim.inspect(notifications):find("synthetic-secret", 1, true), "rejected web URL is not echoed")
end
status_document = no_run(); clear_notifications(); loop.open_session()
wait_for(function() return notification_count("active_session_unavailable") == 1 end, "no-run session opening fails actionably")
status_document = persisted("validating", true, "running"); clear_notifications(); loop._test_reset()
loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1" })
vim.wait(30); loop.open_session()
wait_for(function() return notification_count("web_url_unavailable") == 1 end, "missing web URL fails only when opening a session")

-- Watcher handles vim.NIL, deduplicates across setup replacement, suppresses failures, and shuts down.
local discovery_sequence = 0
calls = {}; clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
process.set_runner_for_test(function(argv, _, callback)
  table.insert(calls, vim.deepcopy(argv))
  if argv[2] == "status" then discovery_sequence = discovery_sequence + 1 end
  local document = discovery_sequence == 1 and persisted("implementing", true, "waiting_for_user") or persisted("implementing", true, "running")
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(document), stderr = "" }) end)
  return {}
end)
loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1" })
wait_for(function() return discovery_sequence >= 2 end, "setup discovery starts watcher after validated first document")
check(notification_count("needs user input") == 1, "setup notifies from first document before a changed second query")
loop._test_reset()

local provider = persisted("implementing", true, "waiting_for_user")
local status_calls = 0
calls = {}; clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  if argv[2] == "status" then status_calls = status_calls + 1 end
  vim.defer_fn(function()
    local output = argv[2] == "status" and json(provider) or ""
    callback({ code = 0, signal = 0, stdout = output, stderr = "" })
  end, argv[2] == "run" and 30 or 1)
  return {}
end)
local setup_options = { executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1", web_url = "https://example.test" }
loop.setup(setup_options)
wait_for(function() return notification_count("needs user input") == 1 end, "setup watcher notifies for pending request")
vim.wait(40)
check(notification_count("needs user input") == 1, "repeated watcher polls deduplicate request")
loop.setup(setup_options); vim.wait(40)
check(notification_count("needs user input") == 1, "setup replacement preserves process-lifetime deduplication")
provider.active.interaction.request_id = "que_second"
wait_for(function() return notification_count("needs user input") == 2 end, "distinct request notifies once")
provider = persisted("finished", false)
wait_for(function() return not loop._test_state().watching and loop._test_state().timer == nil end, "watcher stops timer after active controller becomes inactive")

-- Launch completion performs a final no-run observation and stops its timer.
provider = no_run(); status_calls = 0; loop._test_reset(); loop._test_set_watch_interval(10)
loop.setup(setup_options)
wait_for(function() return status_calls >= 1 end, "no-run setup query completes")
status_calls = 0; loop.start()
wait_for(function() return not loop._test_state().watching and status_calls >= 2 end, "launch exit triggers final observation and watcher shutdown")

-- One in-flight status process and one warning per continuous failure episode.
local concurrent, max_concurrent, sequence = 0, 0, 0
loop._test_reset(); loop._test_set_watch_interval(5); clear_notifications()
process.set_runner_for_test(function(argv, _, callback)
  if argv[2] ~= "status" then vim.schedule(function() callback({ code = 0, signal = 0, stdout = "", stderr = "" }) end); return {} end
  concurrent = concurrent + 1; max_concurrent = math.max(max_concurrent, concurrent); sequence = sequence + 1
  local this = sequence
  vim.defer_fn(function()
    concurrent = concurrent - 1
    if this == 1 or this == 5 then callback({ code = 0, signal = 0, stdout = json(persisted("validating", true, "running")), stderr = "" })
    else callback({ code = 7, signal = 0, stdout = "", stderr = "synthetic watcher failure" }) end
  end, 20)
  return {}
end)
loop.setup(setup_options)
wait_for(function() return sequence >= 7 end, "watcher exercises failure recovery", 1000)
check(max_concurrent == 1, "watcher permits at most one status process in flight")
check(notification_count("controller_command_failed") == 2, "watcher warns once per continuous failure episode")
loop._test_reset()

-- A delayed callback from a replaced setup generation cannot notify current state.
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
process.set_runner_for_test(function(argv, _, callback)
  local old = argv[4] == "/tmp/old-root"
  vim.defer_fn(function()
    callback({ code = 0, signal = 0, stdout = json(old and persisted("implementing", true, "waiting_for_user") or no_run("/tmp/new-root")), stderr = "" })
  end, old and 50 or 1)
  return {}
end)
loop.setup({ executable = "fake", sprint_root = "/tmp/old-root", server_url = "http://127.0.0.1" })
loop.setup({ executable = "fake", sprint_root = "/tmp/new-root", server_url = "http://127.0.0.1" })
vim.wait(100)
check(notification_count("needs user input") == 0 and not loop._test_state().watching, "stale setup callback cannot notify or replace watcher")
loop._test_reset()

-- Replacing a watcher cancels its executable resolver before stale resolution can spawn.
local resolver_invocations, stale_watcher_done = 0, nil
local watcher_status_spawns, watcher_argv = 0, {}
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(100)
process.set_runner_for_test(function(argv, _, callback)
  table.insert(watcher_argv, vim.deepcopy(argv))
  if argv[2] == "status" then watcher_status_spawns = watcher_status_spawns + 1 end
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(persisted("validating", true, "running")), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = function(done)
    resolver_invocations = resolver_invocations + 1
    if resolver_invocations == 2 then stale_watcher_done = done; return end
    return "fake"
  end,
  sprint_root = "/tmp/root",
  server_url = "http://127.0.0.1",
})
wait_for(function() return stale_watcher_done ~= nil end, "watcher owns its pending executable resolver")
loop._test_replace_watcher("/tmp/root")
stale_watcher_done("stale-executable")
wait_for(function() return watcher_status_spawns >= 2 end, "replacement watcher resolves and spawns its own status query")
vim.wait(40)
local stale_spawned = false
for _, argv in ipairs(watcher_argv) do if argv[1] == "stale-executable" then stale_spawned = true end end
check(not stale_spawned, "stale watcher resolution cannot spawn a status process")
loop._test_reset()

-- Neovim exit closes action-owned resolver timers without completing the action.
local exit_server_done
calls = {}; loop._test_reset()
process.set_runner_for_test(function(argv, _, callback)
  table.insert(calls, vim.deepcopy(argv))
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = "fake", sprint_root = "/tmp/root",
  server_url = function(done) exit_server_done = done end,
})
wait_for(function() return #calls == 1 end, "exit lifecycle setup observation completes")
loop.start()
wait_for(function() return exit_server_done ~= nil and table_count(loop._test_state().resolvers) == 1 end, "action owns pending resolver timer")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
check(table_count(loop._test_state().resolvers) == 0 and not loop._test_state().watching, "VimLeavePre closes resolver and watcher timers")
exit_server_done("http://127.0.0.1")
vim.wait(30)
check(#calls == 1, "exit-cancelled action cannot spawn a controller")
loop._test_reset()

-- The repository fake drives the production vim.system adapter and public actions.
process.set_runner_for_test(nil)
local fake = vim.fn.getcwd() .. "/tests/fake-sprint-loop"
local prior_fake_mode = vim.env.SPRINT_LOOP_FAKE_MODE

vim.env.SPRINT_LOOP_FAKE_MODE = nil
clear_notifications(); loop._test_reset()
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
loop.progress()
wait_for(function() return ui.buffer ~= nil and vim.api.nvim_buf_is_valid(ui.buffer) end, "production adapter renders successful fake status")
check(table.concat(vim.api.nvim_buf_get_lines(ui.buffer, 0, -1, false), "\n"):find("State: no run", 1, true) ~= nil, "production status success reaches the public progress UI")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-credential"
clear_notifications(); loop._test_reset()
if ui.window and vim.api.nvim_win_is_valid(ui.window) then vim.api.nvim_win_close(ui.window, true) end
ui.buffer, ui.window = nil, nil
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
loop.progress()
wait_for(function() return notification_count("inconsistent_status") >= 1 end, "production status rejects credential-bearing rendered field")
check(ui.buffer == nil, "credential-bearing status cannot open a progress buffer")
check(not vim.inspect(notifications):find("synthetic-status-value", 1, true), "rejected status credential is not copied into notifications")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-malformed"
clear_notifications(); loop._test_reset()
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
wait_for(function() return notification_count("invalid_status_json") >= 1 end, "production status reports malformed fake output")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-nonzero"
clear_notifications(); loop._test_reset()
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
wait_for(function() return notification_count("controller_command_failed") >= 1 end, "production status reports non-zero fake exit")
local external_diagnostics = vim.inspect(notifications)
for _, forbidden in ipairs({ "synthetic-token", "synthetic-secret", "synthetic-query", "https://", string.char(27), "\r" }) do
  check(not external_diagnostics:find(forbidden, 1, true), "external stderr detail is absent from notifications")
end
local notification_has_control = false
for _, item in ipairs(notifications) do
  if item.message:find("[%z\1-\31\127]") then notification_has_control = true end
end
check(not notification_has_control, "external stderr control characters cannot reach notifications")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-signal"
clear_notifications(); loop._test_reset()
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
wait_for(function() return notification_count("controller_command_failed") >= 1 end, "production status reports signal termination")
local signal_result, signal_error
process.run({ fake, "status", "--root", "/tmp/synthetic-sprint", "--json" }, {}, function(result, err)
  signal_result, signal_error = result, err
end)
wait_for(function() return signal_result ~= nil or signal_error ~= nil end, "production vim.system exposes signal result")
check(signal_error == nil and signal_result.code == 0 and signal_result.signal > 0, "code zero with nonzero signal is covered through vim.system")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-oversized"
clear_notifications(); loop._test_reset()
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
wait_for(function() return notification_count("status_output_too_large") >= 1 end, "public production status reports explicit oversized output")

vim.env.SPRINT_LOOP_FAKE_MODE = "status-delayed-active"
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
loop.setup({ executable = fake, sprint_root = "/tmp/synthetic-sprint", server_url = "http://127.0.0.1:4096" })
wait_for(function() return loop._test_state().watching end, "delayed production status activates watcher", 1500)
vim.env.SPRINT_LOOP_FAKE_MODE = nil
wait_for(function() return not loop._test_state().watching end, "production watcher observes controller exit without overlap", 1500)

vim.env.SPRINT_LOOP_FAKE_MODE = "status-interrupted-active"
clear_notifications(); loop._test_reset(); opened_target = nil
loop._test_set_browser(function(target) opened_target = target; return {} end)
loop.setup({
  executable = fake,
  sprint_root = "/tmp/synthetic-sprint",
  server_url = "http://127.0.0.1:4096",
  web_url = "https://example.test/prefix",
})
loop.open_session()
wait_for(function() return opened_target ~= nil end, "production session retrieval accepts interrupted active invocation")
check(opened_target:find("/session/ses_synthetic", 1, true) ~= nil, "production session retrieval opens exact fake session")

local production_ca = vim.fn.tempname()
vim.fn.writefile({ "synthetic production CA" }, production_ca)
vim.env.SPRINT_LOOP_FAKE_MODE = "ca-observation"
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
loop.setup({
  executable = fake,
  sprint_root = "/tmp/synthetic-sprint",
  server_url = "https://example.test",
  server_ca_cert = production_ca,
})
loop.start()
wait_for(function() return notification_count("controller launch requested") == 1 end, "production CA action launches fake child")
wait_for(function() return not loop._test_state().watching end, "production CA-observing fake child exits cleanly", 1500)
local ca_notifications = vim.inspect(notifications)
check(notification_count("controller_command_failed") == 0, "real fake child observes SSL_CERT_FILE placement")
check(not ca_notifications:find(production_ca, 1, true) and not ca_notifications:find("synthetic production CA", 1, true), "CA path and content are not printed")
local ca_observation, ca_observation_error
process.run({ fake, "observe-ca" }, { env = { SSL_CERT_FILE = production_ca } }, function(result, err)
  ca_observation, ca_observation_error = result, err
end)
wait_for(function() return ca_observation ~= nil or ca_observation_error ~= nil end, "production adapter CA observation child completes")
check(ca_observation_error == nil and ca_observation.code == 0 and ca_observation.stdout == "synthetic CA environment observed\n", "real fake child confirms SSL_CERT_FILE without disclosing its value")
vim.fn.delete(production_ca)

vim.env.SPRINT_LOOP_FAKE_MODE = nil
local actual_result, actual_error
process.run({ fake, "emit-large" }, {}, function(result, err) actual_result, actual_error = result, err end)
wait_for(function() return actual_result ~= nil or actual_error ~= nil end, "actual fake executable completes")
check(actual_error == nil and #actual_result.stdout <= process.MAX_OUTPUT and #actual_result.stderr <= process.MAX_OUTPUT, "stdout and stderr are bounded while streaming")
check(actual_result.stdout:sub(-11) == "[TRUNCATED]" and actual_result.stderr:sub(-11) == "[TRUNCATED]", "stream truncation is explicit")
check(actual_result.stdout_truncated == true and actual_result.stderr_truncated == true, "production adapter exposes explicit truncation metadata")
local missing_error
process.run({ "/definitely/missing/sprint-loop" }, {}, function(_, err) missing_error = err end)
wait_for(function() return missing_error ~= nil end, "missing executable reports spawn failure")
check(missing_error == "process_spawn_failed", "missing executable error is actionable")

local detached_directory = vim.fn.tempname()
check(vim.fn.mkdir(detached_directory, "p", 448) == 1, "detached test creates a unique owned directory")
local marker = detached_directory .. "/completion"
local nested = vim.system({ vim.v.progpath, "--headless", "--noplugin", "-u", "tests/minimal_init.lua", "-l", "tests/detached_launcher.lua" }, {
  env = {
    SPRINT_LOOP_FAKE_EXECUTABLE = fake,
    SPRINT_LOOP_TEST_MARKER = marker,
    SPRINT_LOOP_TEST_ROOT = detached_directory .. "/sprint root",
    PATH = vim.env.PATH,
  },
  text = true,
}):wait()
check(nested.code == 0, "launching headless Neovim exits cleanly")
local survived = vim.wait(3000, function()
  return vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker)[1] == "survived"
end, 5)
if not survived then io.stderr:write("Detached diagnostic: " .. vim.inspect(nested) .. " marker=" .. marker .. "\n") end
check(survived, "detached controller child survives launching Neovim")
check(vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker)[1] == "survived", "detached child records independent completion")
check(vim.fn.delete(detached_directory, "rf") == 0, "detached test removes only its unique owned directory")
vim.env.SPRINT_LOOP_FAKE_MODE = prior_fake_mode

loop._test_reset()
process.set_runner_for_test(nil)
config.RESOLVER_TIMEOUT_MS = production_resolver_timeout
vim.notify = original_notify
io.stdout:write(string.format("Plugin tests: %d assertions, %d failures\n", tests, failures))
if failures > 0 then vim.cmd("cquit " .. failures) end
