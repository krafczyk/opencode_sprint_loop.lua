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
    truncated = function() return truncated end,
  }
end

function M.set_runner_for_test(runner)
  override = runner
end

local function system_runner(argv, options, callback)
  local stdout, stderr = collector(), collector()
  local detached = options.detach == true
  if detached then
    local proxy = { _spawn_pending = true }
    local process_handle
    function proxy.kill(_, signal)
      if process_handle and not process_handle:is_closing() then process_handle:kill(signal) end
    end
    vim.uv.fs_open("/dev/null", "w", 438, function(open_error, null_descriptor)
      if open_error or not null_descriptor then
        callback(nil, "process_spawn_failed")
        return
      end
      vim.schedule(function()
        local arguments = {}
        for index = 2, #argv do table.insert(arguments, argv[index]) end
        local handle, spawn_error
        -- luv needs a complete environment list when `env` is present. Apply
        -- only the validated child overrides for the synchronous spawn call and
        -- restore Neovim's environment before yielding instead of copying the
        -- complete inherited environment into plugin-owned data.
        local prior_environment = {}
        for key, value in pairs(options.env or {}) do
          prior_environment[key] = vim.env[key] == nil and false or vim.env[key]
          vim.env[key] = tostring(value)
        end
        local spawned, spawn_failure = pcall(function()
          handle, spawn_error = vim.uv.spawn(argv[1], {
            args = arguments,
            detached = true,
            stdio = { nil, null_descriptor, null_descriptor },
          }, function(code, signal)
            if process_handle and not process_handle:is_closing() then process_handle:close() end
            callback({
              code = code,
              signal = signal,
              stdout = "",
              stderr = "",
              stdout_truncated = false,
              stderr_truncated = false,
            })
          end)
        end)
        for key, value in pairs(prior_environment) do vim.env[key] = value == false and nil or value end
        if not spawned then spawn_error = spawn_failure end
        process_handle = handle
        vim.uv.fs_close(null_descriptor, function() end)
        if not handle then
          callback(nil, spawn_error or "process_spawn_failed")
          return
        end
        handle:unref()
        if options.on_spawn then options.on_spawn() end
      end)
    end)
    return proxy
  end
  return vim.system(argv, {
    text = true,
    detach = false,
    env = options.env,
    stdout = function(error, data)
      if error then stderr:add("standard output read failed") else stdout:add(data) end
    end,
    stderr = function(error, data)
      if error then stderr:add("standard error read failed") else stderr:add(data) end
    end,
  }, function(result)
    callback({
      code = result.code,
      signal = result.signal,
      stdout = stdout.value(),
      stderr = stderr.value(),
      stdout_truncated = stdout.truncated(),
      stderr_truncated = stderr.truncated(),
    })
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
  if options.on_spawn and handle._spawn_pending ~= true then options.on_spawn() end
  deliver()
  return handle
end

return M
