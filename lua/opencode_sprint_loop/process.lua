--- Narrow asynchronous controller-process adapter.
local M = { MAX_OUTPUT = 64 * 1024 }
local override = nil

local function bounded(value)
  if type(value) ~= "string" then return "" end
  if #value <= M.MAX_OUTPUT then return value end
  return value:sub(1, M.MAX_OUTPUT) .. "[TRUNCATED]"
end

function M.set_runner_for_test(runner)
  override = runner
end

---Spawn argv without a shell. Callback receives a bounded result table.
function M.run(argv, options, callback)
  if override then return override(argv, options, callback) end
  local ok, handle = pcall(vim.system, argv, {
    text = true,
    detach = options.detach == true,
    env = options.env,
  }, function(result)
    callback({ code = result.code, signal = result.signal, stdout = bounded(result.stdout), stderr = bounded(result.stderr) })
  end)
  if not ok then
    callback({ code = -1, signal = 0, stdout = "", stderr = "" }, "process_spawn_failed")
    return
  end
  if options.on_spawn then options.on_spawn() end
  return handle
end

return M
