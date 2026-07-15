--- Narrow asynchronous controller-process adapter.
local M = { MAX_OUTPUT = 64 * 1024 }
local override = nil

local function collector()
  local chunks, size, truncated = {}, 0, false
  local marker = "[TRUNCATED]"
  local limit = M.MAX_OUTPUT - #marker
  return {
    add = function(_, value)
      if type(value) ~= "string" or value == "" or truncated then return end
      local remaining = limit - size
      if #value > remaining then
        if remaining > 0 then table.insert(chunks, value:sub(1, remaining)); size = size + remaining end
        truncated = true
      else
        table.insert(chunks, value); size = size + #value
      end
    end,
    value = function()
      local result = table.concat(chunks)
      return truncated and result .. marker or result
    end,
  }
end

function M.set_runner_for_test(runner)
  override = runner
end

local function system_runner(argv, options, callback)
  local stdout, stderr = collector(), collector()
  return vim.system(argv, {
    text = true,
    detach = options.detach == true,
    env = options.env,
    stdout = function(error, data)
      if error then stderr:add("standard output read failed") else stdout:add(data) end
    end,
    stderr = function(error, data)
      if error then stderr:add("standard error read failed") else stderr:add(data) end
    end,
  }, function(result)
    callback({ code = result.code, signal = result.signal, stdout = stdout.value(), stderr = stderr.value() })
  end)
end

---Spawn argv without a shell. Callback receives one bounded result table.
function M.run(argv, options, callback)
  local runner = override or system_runner
  local returned, completed, callback_count = false, false, 0
  local first_result, first_error
  local delivery_scheduled = false
  local function deliver()
    if completed or not returned or callback_count == 0 or delivery_scheduled then return end
    delivery_scheduled = true
    vim.schedule(function()
      delivery_scheduled = false
      if completed then return end
      completed = true
      if callback_count > 1 then
        callback({ code = -1, signal = 0, stdout = "", stderr = "" }, "process_spawn_failed")
      else
        callback(first_result, first_error)
      end
    end)
  end
  local ok, handle = pcall(runner, argv, options, function(result, error)
    if completed then return end
    callback_count = callback_count + 1
    if callback_count == 1 then first_result, first_error = result, error end
    deliver()
  end)
  returned = true
  if not ok then
    completed = true
    callback({ code = -1, signal = 0, stdout = "", stderr = "" }, "process_spawn_failed")
    return
  end
  if callback_count > 0 then
    completed = true
    callback({ code = -1, signal = 0, stdout = "", stderr = "" }, "process_spawn_failed")
    return
  end
  if handle == nil then
    completed = true
    callback({ code = -1, signal = 0, stdout = "", stderr = "" }, "process_spawn_failed")
    return
  end
  if options.on_spawn then options.on_spawn() end
  deliver()
  return handle
end

return M
