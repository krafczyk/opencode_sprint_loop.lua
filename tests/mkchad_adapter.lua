local mkchad_config = assert(arg[1], "pass the disposable mkchad opencode.lua path")
local plugin_root = vim.fn.getcwd()
vim.opt.runtimepath:append(plugin_root)
vim.cmd("runtime plugin/opencode_sprint_loop.lua")

vim.g.mkchad_opencode_test_api = true
dofile(mkchad_config)
local server = assert(vim.g.opencode_opts and vim.g.opencode_opts.server)
assert(type(server.url) == "function", "mkchad URL callback is unavailable")
assert(type(server.ca_cert) == "function", "mkchad CA accessor is unavailable")
assert(type(server.ensure) == "function", "mkchad ensure sentinel is unavailable")

local ensure_calls = 0
server.ensure = function() ensure_calls = ensure_calls + 1 end
local observed_url, url_calls = "unset", 0
server.url(function(value) observed_url, url_calls = value, url_calls + 1 end)
assert(url_calls == 1 and observed_url == nil, "isolated mkchad URL callback did not report inactive state")
assert(server.ca_cert() == nil, "isolated mkchad CA accessor unexpectedly reused runtime state")

local process = require("opencode_sprint_loop.process")
local loop = require("opencode_sprint_loop")
local process_calls = 0
local no_run = '{"schema_version":1,"controller_version":"0.1.0","sprint_root":"/tmp/disposable-sprint","run_exists":false,"process_running":false,"run_id":null,"sprint":null,"state":null,"reason":null,"active":null,"commits":null,"audit":null,"ci":null,"counters":null,"checklist":null,"last_event":null,"updated_at":null}'
process.set_runner_for_test(function(_, _, callback)
  process_calls = process_calls + 1
  vim.schedule(function() callback({ code = 0, signal = 0, stdout = no_run, stderr = "" }) end)
  return {}
end)

loop.setup({
  executable = "synthetic-sprint-loop",
  sprint_root = "/tmp/disposable-sprint",
  server_url = server.url,
  web_url = server.url,
  server_ca_cert = server.ca_cert,
})
assert(vim.wait(1000, function() return process_calls == 1 end, 5), "setup status observation did not complete")
loop.start()
vim.wait(100, function() return false end, 5)
assert(process_calls == 1, "inactive mkchad URL reached controller argv")
assert(ensure_calls == 0, "Sprint Loop called mkchad server.ensure")
io.stdout:write("Disposable mkchad adapter check passed\n")
loop._test_reset()
vim.cmd("qa!")
