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
clear_notifications(); loop.setup({ server_url = "http://127.0.0.1" })
check(notification_count("invalid_setup") == 1 and #calls == 0, "independently missing sprint_root fails without process")
for _, unknown_key in ipairs({
  "api_key=synthetic-setup-credential",
  "https://user:synthetic-setup-credential@example.invalid/path",
  "unknown\n\27control",
  string.rep("oversized", 16384),
}) do
  clear_notifications()
  loop.setup({ sprint_root = "/tmp/root", server_url = "http://127.0.0.1", [unknown_key] = true })
  check(#notifications == 1 and notifications[1].message == "SprintLoop: invalid_setup", "unknown setup key uses fixed diagnostic")
  check(not vim.inspect(notifications):find(unknown_key, 1, true) and #calls == 0, "unknown setup key content is never disclosed")
end
clear_notifications(); loop.setup({ sprint_root = {}, server_url = "http://127.0.0.1" })
check(notification_count("invalid_setup") == 1 and #calls == 0, "wrong setup value type fails")
loop._test_set_version_check(function() return false end)
clear_notifications(); loop.setup({ sprint_root = "/tmp/root", server_url = "http://127.0.0.1" })
check(notification_count("unsupported_neovim") == 1 and #calls == 0, "controlled older-version fixture fails without mutation")
loop._test_reset()

-- The public setup/action path uses the exact documented executable default.
calls = {}
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = argv[2] == "status" and json(no_run()) or "", stderr = "" }) end)
  return {}
end)
loop.setup({ sprint_root = "/tmp/default-root", server_url = "http://127.0.0.1" })
wait_for(function() return #calls == 1 end, "default executable drives setup status")
loop.pause()
wait_for(function() return #calls == 2 end, "default executable drives public action")
check(calls[1].argv[1] == "sprint-loop" and calls[2].argv[1] == "sprint-loop", "public path defaults executable to exact sprint-loop")
loop._test_reset()

local function resolve_result(value, timeout, callback_style)
  local result, resolve_error, count
  count = 0
  config.resolve(value, 1, function() return true end, function(resolved, err) result, resolve_error, count = resolved, err, count + 1 end, callback_style)
  vim.wait(timeout or 200, function() return count > 0 end, 5)
  return result, resolve_error, count
end
local resolved, resolve_error, resolve_count = resolve_result(function() return "value" end)
check(resolved == "value" and resolve_error == nil and resolve_count == 1, "synchronous resolver completes once")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("callback") end, nil, true)
check(resolved == "callback" and resolve_error == nil and resolve_count == 1, "callback resolver completes once")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("first"); done("second") end, nil, true)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "duplicate callback rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done) done("callback"); return "return" end, nil, true)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "callback plus return rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done)
  vim.defer_fn(function() done("delayed callback") end, 5)
  return "synchronous return"
end, nil, true)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "delayed callback after return rejects before consumer")
resolved, resolve_error, resolve_count = resolve_result(function(done)
  done("first callback")
  vim.defer_fn(function() done("delayed duplicate") end, 5)
end, nil, true)
check(resolved == nil and resolve_error == "resolver_failed" and resolve_count == 1, "delayed duplicate callback rejects before consumer")
resolved, resolve_error = resolve_result(function() error("synthetic") end)
check(resolved == nil and resolve_error == "resolver_failed", "throwing resolver has concise error")
resolved, resolve_error = resolve_result(function() return "bad\0value" end)
check(resolved == nil and resolve_error == "invalid_resolved_value", "control-bearing resolver value rejects")
resolved, resolve_error = resolve_result(function(_) end, 200, true)
check(resolved == nil and resolve_error == "resolver_failed", "resolver timeout is bounded")
resolved, resolve_error = resolve_result(function(done) done("callback misuse") end)
check(resolved == nil and resolve_error == "resolver_failed", "non-URL callback-style resolver is rejected")
for _, invalid_result in ipairs({ false, 17, {}, "" }) do
  resolved, resolve_error = resolve_result(function() return invalid_result end)
  check(resolved == nil and resolve_error == "invalid_resolved_value", "non-URL malformed synchronous result rejects")
end
resolved, resolve_error = resolve_result(function() return nil end)
check(resolved == nil and resolve_error == "invalid_resolved_value", "non-URL nil synchronous result rejects")
local stale_called = false
config.resolve(function(done) vim.defer_fn(function() done("late") end, 20) end, 1, function() return false end, function() stale_called = true end, true)
vim.wait(50)
check(not stale_called, "stale resolver completion is ignored")
local cancelled_called = false
local cancellable = config.resolve(function(_) end, 1, function() return true end, function() cancelled_called = true end, true)
check(cancellable.is_active(), "function resolver exposes an active cancellable lifetime")
cancellable.cancel()
check(not cancellable.is_active(), "function resolver cancellation closes its timer")
vim.wait(30)
check(not cancelled_called, "cancelled function resolver cannot invoke its consumer")

-- A scheduled synchronous setup resolution is invalidated when setup is replaced.
calls = {}; loop._test_reset()
process.set_runner_for_test(function(argv, _, callback)
  table.insert(calls, vim.deepcopy(argv))
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = "fake",
  sprint_root = function() return "/tmp/stale" end,
  server_url = "http://127.0.0.1",
})
loop.setup({ executable = "fake", sprint_root = "/tmp/replacement", server_url = "http://127.0.0.1" })
wait_for(function() return #calls == 1 and table_count(loop._test_state().resolvers) == 0 end, "repeated setup invalidates old scheduled resolution")
vim.wait(30)
check(#calls == 1 and calls[1][4] == "/tmp/replacement", "cancelled setup resolution cannot spawn stale status")

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

-- Every setup option form is proven through public status/action/session/CA wiring.
local function public_option_matrix(label, options, expected)
  local matrix_calls, opened = {}, nil
  loop._test_reset()
  loop._test_set_browser(function(target) opened = target; return {} end)
  process.set_runner_for_test(function(argv, process_options, callback)
    table.insert(matrix_calls, { argv = vim.deepcopy(argv), options = process_options })
    vim.schedule(function()
      callback({
        code = 0,
        signal = 0,
        stdout = argv[2] == "status" and json(persisted("validating", false, "running")) or "",
        stderr = "",
      })
    end)
    return {}
  end)
  loop.setup(options)
  wait_for(function() return #matrix_calls >= 1 end, label .. " setup status spawns")
  loop.start()
  wait_for(function()
    for _, call in ipairs(matrix_calls) do if call.argv[2] == "run" then return true end end
  end, label .. " start spawns")
  loop.open_session()
  wait_for(function() return opened ~= nil end, label .. " session opens")
  local status_call, run_call
  for _, call in ipairs(matrix_calls) do
    if call.argv[2] == "status" and not status_call then status_call = call end
    if call.argv[2] == "run" then run_call = call end
  end
  check(vim.deep_equal(status_call.argv, { expected.executable, "status", "--root", expected.root, "--json" }), label .. " executable/root reach public status")
  check(vim.deep_equal(run_call.argv, { expected.executable, "run", "--root", expected.root, "--server-url", expected.server }), label .. " server reaches public start")
  if expected.ca then
    check(run_call.options.env.SSL_CERT_FILE == expected.ca and not vim.tbl_contains(run_call.argv, expected.ca), label .. " CA reaches only child environment")
  else
    check(run_call.options.env == nil, label .. " leaves the child environment override exactly absent")
  end
  check(opened:find(expected.web, 1, true) == 1 and opened:find("/session/ses%2Fone%20two", 1, true) ~= nil, label .. " web URL reaches public session route")
end

local string_ca = vim.fn.tempname()
vim.fn.writefile({ "synthetic string CA" }, string_ca)
public_option_matrix("string option forms", {
  executable = "string-executable",
  sprint_root = "/tmp/string-root",
  server_url = "https://string.example.test",
  web_url = "https://string-web.example.test/prefix",
  server_ca_cert = string_ca,
}, {
  executable = "string-executable", root = "/tmp/string-root", server = "https://string.example.test",
  web = "https://string-web.example.test/prefix", ca = string_ca,
})
vim.fn.delete(string_ca)

public_option_matrix("synchronous URL function forms", {
  executable = function() return "sync-url-executable" end,
  sprint_root = function() return "/tmp/sync-url-root" end,
  server_url = function() return "https://sync-server.example.test" end,
  web_url = function() return "https://sync-web.example.test/prefix" end,
}, {
  executable = "sync-url-executable", root = "/tmp/sync-url-root", server = "https://sync-server.example.test",
  web = "https://sync-web.example.test/prefix", ca = nil,
})

local function_ca = vim.fn.tempname()
vim.fn.writefile({ "synthetic function CA" }, function_ca)
local callback_counts = { server = 0, web = 0, ca = 0 }
public_option_matrix("function option forms", {
  executable = function() return "function-executable" end,
  sprint_root = function() return "/tmp/function-root" end,
  server_url = function(done)
    callback_counts.server = callback_counts.server + 1
    vim.defer_fn(function() done("https://function.example.test") end, 1)
  end,
  web_url = function(done)
    callback_counts.web = callback_counts.web + 1
    vim.defer_fn(function() done("https://function-web.example.test/prefix") end, 1)
  end,
  server_ca_cert = function()
    callback_counts.ca = callback_counts.ca + 1
    return function_ca
  end,
}, {
  executable = "function-executable", root = "/tmp/function-root", server = "https://function.example.test",
  web = "https://function-web.example.test/prefix", ca = function_ca,
})
check(callback_counts.server >= 1 and callback_counts.web == 1 and callback_counts.ca >= 1, "callback URL and function CA resolvers are consumed by public actions")
vim.fn.delete(function_ca)
loop._test_reset()

-- Non-URL callback misuse and malformed public resolver results cannot launch actions.
for _, option in ipairs({ "executable", "sprint_root" }) do
  local misuse_calls = 0
  clear_notifications(); loop._test_reset()
  process.set_runner_for_test(function(_, _, callback)
    misuse_calls = misuse_calls + 1
    vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
    return {}
  end)
  local options = { executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1" }
  options[option] = function(done) done("callback misuse") end
  loop.setup(options)
  wait_for(function() return notification_count("resolver_failed") == 1 end, option .. " callback misuse reports resolver failure")
  check(misuse_calls == 0, option .. " callback misuse has no process side effect")
end
for _, malformed in ipairs({
  { "sprint_root nil", "sprint_root", function() return nil end },
  { "executable empty", "executable", function() return "" end },
  { "executable non-string", "executable", function() return 17 end },
}) do
  local malformed_calls = 0
  clear_notifications(); loop._test_reset()
  process.set_runner_for_test(function(_, _, callback)
    malformed_calls = malformed_calls + 1
    vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
    return {}
  end)
  local options = { executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1" }
  options[malformed[2]] = malformed[3]
  loop.setup(options)
  wait_for(function() return notification_count("invalid_resolved_value") == 1 end, malformed[1] .. " reports publicly")
  check(malformed_calls == 0, malformed[1] .. " has no process side effect")
end

local ca_misuse_calls = {}
clear_notifications(); loop._test_reset()
process.set_runner_for_test(function(argv, _, callback)
  table.insert(ca_misuse_calls, vim.deepcopy(argv))
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = argv[2] == "status" and json(no_run()) or "", stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = "fake", sprint_root = "/tmp/root", server_url = "https://example.test",
  server_ca_cert = function(done) done("callback misuse") end,
})
wait_for(function() return #ca_misuse_calls == 1 end, "CA misuse setup observation completes")
loop.start()
wait_for(function() return notification_count("resolver_failed") == 1 end, "CA callback misuse reports resolver failure")
check(#ca_misuse_calls == 1, "CA callback misuse cannot launch a controller child or install an environment")

clear_notifications(); loop._test_reset(); ca_misuse_calls = {}
loop.setup({
  executable = "fake", sprint_root = "/tmp/root", server_url = "https://example.test",
  server_ca_cert = function() return false end,
})
wait_for(function() return #ca_misuse_calls == 1 end, "non-string CA setup observation completes")
loop.start()
wait_for(function() return notification_count("invalid_resolved_value") == 1 end, "non-string CA result rejects publicly")
check(#ca_misuse_calls == 1, "non-string CA result cannot launch or install an environment")

for _, invalid_result in ipairs({ false, 17, {}, "" }) do
  local invalid_calls = {}
  clear_notifications(); loop._test_reset()
  process.set_runner_for_test(function(argv, _, callback)
    table.insert(invalid_calls, vim.deepcopy(argv))
    vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
    return {}
  end)
  loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = function() return invalid_result end })
  wait_for(function() return #invalid_calls == 1 end, "malformed server result setup status completes")
  loop.start()
  wait_for(function() return notification_count("invalid_resolved_value") == 1 end, "malformed server result rejects publicly")
  check(#invalid_calls == 1, "malformed server result cannot launch")
end
do
  local nil_server_calls = {}
  clear_notifications(); loop._test_reset()
  process.set_runner_for_test(function(argv, _, callback)
    table.insert(nil_server_calls, vim.deepcopy(argv))
    vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(no_run()), stderr = "" }) end)
    return {}
  end)
  loop.setup({ executable = "fake", sprint_root = "/tmp/root", server_url = function() return nil end })
  wait_for(function() return #nil_server_calls == 1 end, "nil server result setup status completes")
  loop.start()
  wait_for(function() return notification_count("resolver_failed") == 1 end, "nil server result rejects publicly")
  check(#nil_server_calls == 1, "nil server result cannot launch")
end
for _, web_case in ipairs({
  { "nil", function() return nil end, "resolver_failed" },
  { "empty", function() return "" end, "invalid_resolved_value" },
  { "boolean", function() return false end, "invalid_resolved_value" },
  { "number", function() return 17 end, "invalid_resolved_value" },
  { "table", function() return {} end, "invalid_resolved_value" },
}) do
  local nil_calls = {}
  clear_notifications(); loop._test_reset()
  process.set_runner_for_test(function(argv, _, callback)
    table.insert(nil_calls, vim.deepcopy(argv))
    vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(persisted("validating", false, "running")), stderr = "" }) end)
    return {}
  end)
  loop.setup({
    executable = "fake", sprint_root = "/tmp/root", server_url = "http://127.0.0.1",
    web_url = web_case[2],
  })
  wait_for(function() return #nil_calls == 1 end, web_case[1] .. " web result setup status completes")
  loop.open_session()
  wait_for(function() return notification_count(web_case[3]) == 1 end, web_case[1] .. " web result rejects publicly")
  check(#nil_calls == 2, web_case[1] .. " web result performs only the required status read")
end
loop._test_reset()

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
local provider_families = {
  { "ghs_", string.rep("A.", 18), string.rep("A", 35) },
  { "gho_", string.rep("A", 36), string.rep("A", 35) },
  { "ghp_", string.rep("A", 36), string.rep("A", 35) },
  { "ghu_", string.rep("A", 36), string.rep("A", 35) },
  { "ghr_", string.rep("A", 36), string.rep("A", 35) },
  { "github_pat_", string.rep("A_", 10), string.rep("A", 19) },
}
for _, prefix in ipairs({
  "glpat-", "glcbt-", "glptt-", "glrt-", "glimt-", "glsoat-", "gldt-",
  "glrtr-", "glft-", "glagent-", "glwt-", "glffct-", "gloas-",
}) do table.insert(provider_families, { prefix, string.rep("A_", 10), string.rep("A", 19) }) end
for _, prefix in ipairs({ "sk-proj-", "sk-svcacct-", "sk-admin-", "sk-ant-api01-", "sk-ant-oat99-", "sk-or-v1-" }) do
  table.insert(provider_families, { prefix, string.rep("A", 20), "." .. string.rep("A", 20) })
end
table.insert(provider_families, { "sk-", string.rep("A_", 10), string.rep("A", 19) })
table.insert(provider_families, { "AIza", string.rep("A_", 15), string.rep("A", 29) })
table.insert(provider_families, { "hf_", string.rep("A", 20), "_" .. string.rep("A", 20) })
for _, prefix in ipairs({ "xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-", "xapp-", "xwfp-" }) do
  table.insert(provider_families, { prefix, string.rep("A-", 10), "_" .. string.rep("A", 20) })
end
table.insert(provider_families, { "AKIA", string.rep("A", 16), "_" .. string.rep("A", 16) })
table.insert(provider_families, { "ASIA", string.rep("A", 16), "_" .. string.rep("A", 16) })

local credential_parity_positives = {
  "Authorization: Basic c3ludGhldGljOnBhc3N3b3Jk",
  "proxy-authorization\t:\tBeArEr synthetic-token_123",
  "password = synthetic-password",
  "https://user:synthetic@example.invalid/path",
  "https://example.invalid/path?opaque=synthetic",
  "-----BEGIN SYNTHETIC PRIVATE KEY-----",
}
local credential_parity_near_misses = {
  "Authorization:\194\160Bearer synthetic-token",
  "Authorization: ſasic c3ludGhldGlj",
  "paſsword=synthetic-password",
  "toKen=synthetic-token",
  "AKIA" .. string.rep("A", 16),
}
for _, family in ipairs(provider_families) do
  table.insert(credential_parity_positives, family[1] .. family[2])
  table.insert(credential_parity_near_misses, family[1] .. family[3])
end
for _, credential in ipairs(credential_parity_positives) do
  local credential_document = persisted("validating", false, "running")
  credential_document.updated_at = credential
  decoded, decode_error = status.decode(json(credential_document))
  check(decoded == nil and decode_error == "inconsistent_status", "ASCII parity credential rejects")
end
for _, near_miss in ipairs(credential_parity_near_misses) do
  local near_miss_document = persisted("validating", false, "running")
  near_miss_document.updated_at = near_miss
  decoded, decode_error = status.decode(json(near_miss_document))
  check(decoded ~= nil and decode_error == nil, "ASCII parity unsupported near miss remains accepted")
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

-- Setup/watcher replacement serializes globally and only cancels status children.
local lifecycle_active, lifecycle_max = 0, 0
local lifecycle_status_spawns, lifecycle_status_kills, lifecycle_controller_kills = 0, 0, 0
local lifecycle_controller_spawns = 0
local lifecycle_browser_opens = 0
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(1000)
loop._test_set_browser(function() lifecycle_browser_opens = lifecycle_browser_opens + 1; return {} end)
process.set_runner_for_test(function(argv, _, callback)
  if argv[2] ~= "status" then
    lifecycle_controller_spawns = lifecycle_controller_spawns + 1
    local completed = false
    vim.defer_fn(function()
      if completed then return end
      completed = true
      callback({ code = 0, signal = 0, stdout = "", stderr = "" })
    end, 30)
    return { kill = function()
      lifecycle_controller_kills = lifecycle_controller_kills + 1
    end }
  end
  lifecycle_status_spawns = lifecycle_status_spawns + 1
  lifecycle_active = lifecycle_active + 1
  lifecycle_max = math.max(lifecycle_max, lifecycle_active)
  local completed, kill_requested = false, false
  local function complete(signal)
    if completed then return end
    completed = true
    lifecycle_active = lifecycle_active - 1
    callback({
      code = signal and 1 or 0,
      signal = signal or 0,
      stdout = signal and "" or json(persisted("validating", true, "running")),
      stderr = "",
    })
  end
  vim.defer_fn(function() complete(nil) end, 80)
  return { kill = function(_, signal)
    if completed or kill_requested then return end
    kill_requested = true
    lifecycle_status_kills = lifecycle_status_kills + 1
    vim.schedule(function() complete(signal or 15) end)
  end }
end)

local lifecycle_options = { executable = "fake", sprint_root = "/tmp/lifecycle-one", server_url = "http://127.0.0.1", web_url = "https://example.test" }
loop.setup(lifecycle_options)
wait_for(function() return lifecycle_active == 1 end, "delayed setup status child is retained")
lifecycle_options = { executable = "fake", sprint_root = "/tmp/lifecycle-two", server_url = "http://127.0.0.1", web_url = "https://example.test" }
loop.setup(lifecycle_options)
wait_for(function()
  local active = loop._test_state().status_active
  return lifecycle_status_kills >= 1 and active and active.owner.kind == "setup" and active.argv[4] == "/tmp/lifecycle-two"
end, "repeated setup cancels then serializes replacement status")
wait_for(function()
  local active = loop._test_state().status_active
  return loop._test_state().watching and active and active.owner.kind == "watcher"
end, "setup observation transitions to retained watcher status")

local spawns_before_public_queries = lifecycle_status_spawns
loop.progress()
loop.open_session()
vim.wait(20)
check(lifecycle_active == 1 and lifecycle_status_spawns == spawns_before_public_queries, "progress and session status queries queue behind the global status child")

local kills_before = lifecycle_status_kills
loop.start()
wait_for(function() return lifecycle_controller_spawns >= 1 and lifecycle_status_kills > kills_before end, "start replaces watcher status observation")
wait_for(function() return lifecycle_browser_opens == 1 and ui.buffer ~= nil and vim.api.nvim_buf_is_valid(ui.buffer) end, "start preserves queued public progress and session completions")
wait_for(function()
  local active = loop._test_state().status_active
  return active and active.owner.kind == "watcher"
end, "start watcher status waits for cancelled child callback")

loop.progress()
loop.open_session()
kills_before = lifecycle_status_kills
loop.resume()
wait_for(function() return lifecycle_controller_spawns >= 2 and lifecycle_status_kills > kills_before end, "resume replaces watcher status observation")
wait_for(function() return lifecycle_browser_opens == 2 end, "resume preserves queued public session completion")
wait_for(function()
  local active = loop._test_state().status_active
  return active and active.owner.kind == "watcher"
end, "resume watcher status remains globally serialized")

loop.progress()
loop.open_session()
kills_before = lifecycle_status_kills
loop.stop()
wait_for(function() return lifecycle_controller_spawns >= 3 and lifecycle_browser_opens == 3 end, "stop preserves queued public status actions")
check(lifecycle_status_kills == kills_before and loop._test_state().watching, "stop preserves the current watcher until status confirms inactivity")

loop._test_replace_watcher("/tmp/lifecycle-two")
wait_for(function()
  local active = loop._test_state().status_active
  return active ~= nil and active.owner.kind == "watcher" and not active.cancelled
end, "exit test owns one uncancelled status child")
kills_before = lifecycle_status_kills
local spawns_before_exit = lifecycle_status_spawns
vim.api.nvim_exec_autocmds("VimLeavePre", {})
wait_for(function() return lifecycle_status_kills > kills_before and loop._test_state().status_active == nil end, "VimLeavePre cancels retained status child")
vim.wait(100)
check(lifecycle_status_spawns == spawns_before_exit, "VimLeavePre cannot spawn a replacement status child")
check(lifecycle_max == 1, "all setup, watcher, and public status children are globally non-overlapping")
check(lifecycle_controller_kills == 0, "status cancellation never signals detached or control controller children")
loop._test_reset()

-- Stop failures and a successful delegation cannot invalidate observation of an active controller.
local function stop_observation_case(label, outcome)
  local case_status_calls, root_resolutions = 0, 0
  clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(10)
  process.set_runner_for_test(function(argv, _, callback)
    if argv[2] == "status" then
      case_status_calls = case_status_calls + 1
      vim.defer_fn(function()
        callback({ code = 0, signal = 0, stdout = json(persisted("validating", true, "running")), stderr = "" })
      end, 1)
      return {}
    end
    if outcome == "spawn" then return nil end
    vim.schedule(function()
      callback({
        code = outcome == "nonzero" and 4 or 0,
        signal = outcome == "signal" and 15 or 0,
        stdout = "",
        stderr = "",
      })
    end)
    return {}
  end)
  loop.setup({
    executable = "fake",
    sprint_root = function()
      root_resolutions = root_resolutions + 1
      if outcome == "resolver" and root_resolutions > 1 then return nil end
      return "/tmp/stop-observation"
    end,
    server_url = "http://127.0.0.1",
  })
  wait_for(function() return loop._test_state().watching and case_status_calls >= 2 end, label .. " establishes observation")
  local before = case_status_calls
  loop.stop()
  if outcome == "success" then
    wait_for(function() return notification_count("stop delegated") == 1 end, label .. " delegates successfully")
  elseif outcome == "resolver" then
    wait_for(function() return notification_count("invalid_resolved_value") == 1 end, label .. " reports resolver failure")
  elseif outcome == "spawn" then
    wait_for(function() return notification_count("process_spawn_failed") == 1 end, label .. " reports spawn failure")
  else
    wait_for(function() return notification_count("controller_command_failed") == 1 end, label .. " reports command failure")
  end
  wait_for(function() return case_status_calls > before end, label .. " continues status observation")
  check(loop._test_state().watching, label .. " remains observed while status says process_running true")
end
for _, case in ipairs({
  { "stop resolver failure", "resolver" },
  { "stop spawn failure", "spawn" },
  { "stop signal outcome", "signal" },
  { "stop non-zero outcome", "nonzero" },
  { "stop success-but-still-active outcome", "success" },
}) do stop_observation_case(case[1], case[2]) end
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

-- Replacing a watcher invalidates a scheduled synchronous executable result before it can spawn.
local resolver_invocations = 0
local watcher_status_spawns, watcher_argv = 0, {}
clear_notifications(); loop._test_reset(); loop._test_set_watch_interval(100)
process.set_runner_for_test(function(argv, _, callback)
  table.insert(watcher_argv, vim.deepcopy(argv))
  if argv[2] == "status" then watcher_status_spawns = watcher_status_spawns + 1 end
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = json(persisted("validating", true, "running")), stderr = "" }) end)
  return {}
end)
loop.setup({
  executable = function()
    resolver_invocations = resolver_invocations + 1
    if resolver_invocations == 2 then
      vim.schedule(function() loop._test_replace_watcher("/tmp/root") end)
      return "stale-executable"
    end
    return "fake"
  end,
  sprint_root = "/tmp/root",
  server_url = "http://127.0.0.1",
})
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
if ui.window and vim.api.nvim_win_is_valid(ui.window) then vim.api.nvim_win_close(ui.window, true) end
ui.buffer, ui.window = nil, nil
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
