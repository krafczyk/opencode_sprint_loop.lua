local status = require("opencode_sprint_loop.status")
local process = require("opencode_sprint_loop.process")
local loop = require("opencode_sprint_loop")
local failures = 0
local function check(condition, message) if not condition then failures = failures + 1; io.stderr:write("FAIL: " .. message .. "\n") end end
local function json(value) return vim.json.encode(value) end
local null = vim.NIL
local function no_run()
  return { schema_version = 1, controller_version = "0.1.0", sprint_root = "/tmp/sprint", run_exists = false, process_running = false, run_id = null, sprint = null, state = null, reason = null, active = null, commits = null, audit = null, ci = null, counters = null, checklist = null, last_event = null, updated_at = null }
end
local function running(waiting)
  return { schema_version = 1, controller_version = "0.1.0", sprint_root = "/tmp/sprint", run_exists = true, process_running = true, run_id = "run-1", sprint = { multisprint = "foundation", index = 1 }, state = "validating", reason = null,
    active = { role = "auditor", invocation_id = "0001-auditor", session_id = "ses_example", status = waiting and "waiting_for_user" or "running", interaction = waiting and { request_id = "que_example", question_count = 1, asked_at = "2026-07-15T12:00:00Z" } or null },
    commits = { ["local"] = { backend = null }, pushed = { backend = null } }, audit = { phase = null, pre_ci_round = 0, pre_ci_max_rounds = 2, remaining_effort = null }, ci = { status = "not_started", attempt = 0, commit_sha = null }, counters = { implementation_cycles = 0, ci_fix_attempts = 0 }, checklist = { satisfied = 0, partial = 0, unsatisfied = 0, not_evaluated = 0, assessed_at = null }, last_event = { sequence = 1, type = "agent.started", timestamp = "2026-07-15T12:00:00Z" }, updated_at = "2026-07-15T12:00:00Z" }
end

local decoded, decode_error = status.decode(json(no_run()))
check(decoded ~= nil and decode_error == nil, "valid no-run status decodes")
decoded, decode_error = status.decode(json(running(true)))
check(decoded ~= nil and decoded.active.status == "waiting_for_user", "waiting status decodes")
decoded, decode_error = status.decode('{"schema_version":1,"schema_version":1}')
check(decoded == nil and decode_error == "invalid_status_json", "duplicate keys reject")
decoded, decode_error = status.decode(json(running()):sub(1, -2) .. " {}")
check(decoded == nil and decode_error == "invalid_status_json", "trailing JSON rejects")
local lines = status.render(assert(status.decode(json(running(true)))))
check(table.concat(lines, "\n"):find("WAITING FOR USER", 1, true) ~= nil, "waiting is prominent")

local calls = {}
local function latest(command)
  for index = #calls, 1, -1 do if calls[index].argv[2] == command then return calls[index] end end
end
process.set_runner_for_test(function(argv, options, callback)
  table.insert(calls, { argv = vim.deepcopy(argv), options = options })
  if options.on_spawn then options.on_spawn() end
  local output = argv[2] == "status" and json(no_run()) or "feature_not_implemented\n"
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = output, stderr = "" }) end)
end)
loop._test_reset()
loop.start()
check(#calls == 0, "action before setup does not spawn")
loop.setup({ sprint_root = function() return "/tmp/root with spaces" end, server_url = function(done) done("http://127.0.0.1:4096") end, executable = "fake loop" })
vim.wait(100, function() return #calls >= 1 end)
loop.start(); vim.wait(100, function() return #calls >= 2 end)
local start_call = latest("run")
check(start_call ~= nil, "start invokes controller")
check(vim.deep_equal(start_call.argv, { "fake loop", "run", "--root", "/tmp/root with spaces", "--server-url", "http://127.0.0.1:4096" }), "start argv is literal array")
check(start_call.options.detach == true, "start is detached")
loop.pause(); vim.wait(100, function() return #calls >= 3 end)
local pause_call = latest("pause")
check(vim.deep_equal(pause_call.argv, { "fake loop", "pause", "--root", "/tmp/root with spaces" }), "pause argv delegates")
check(vim.fn.exists(":SprintLoopStart") == 2 and vim.fn.exists(":SprintLoopOpenSession") == 2, "commands register")
process.set_runner_for_test(nil)
loop._test_reset()
if failures > 0 then vim.cmd("cquit " .. failures) end
