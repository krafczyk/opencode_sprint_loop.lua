--- Configuration validation and deferred resolver support.
local M = {}
local before_delivery_for_test = nil

M.RESOLVER_TIMEOUT_MS = 5000
local allowed = {
  executable = true,
  sprint_root = true,
  server_url = true,
  web_url = true,
  server_ca_cert = true,
}
local required = { "sprint_root", "server_url" }

local function valid_value(value)
  return type(value) == "string" or type(value) == "function"
end

function M.validate(options)
  if type(options) ~= "table" then
    return nil, "invalid_setup: setup options must be a table"
  end
  for key in pairs(options) do
    if not allowed[key] then
      -- Option names are untrusted and may themselves contain credentials,
      -- terminal controls, or unbounded content. Keep this diagnostic fixed.
      return nil, "invalid_setup"
    end
  end
  for _, key in ipairs(required) do
    if not valid_value(options[key]) then
      return nil, "invalid_setup: " .. key .. " must be a string or resolver"
    end
  end
  for _, key in ipairs({ "executable", "web_url", "server_ca_cert" }) do
    if options[key] ~= nil and not valid_value(options[key]) then
      return nil, "invalid_setup: " .. key .. " must be a string or resolver"
    end
  end
  local result = vim.deepcopy(options)
  if result.executable == nil then
    result.executable = "sprint-loop"
  end
  return result
end

local function valid_resolved(value)
  return type(value) == "string" and value ~= "" and not value:find("[%z\1-\31\127]")
end

---Resolve a configured string or resolver exactly once.
---@param value string|function
---@param generation number
---@param current fun(): boolean
---@param callback fun(string|nil, string|nil)
---@param callback_style? boolean whether this is a URL resolver accepting done(value, error)
---@return table handle cancellable resolver-lifetime handle
function M.resolve(value, generation, current, callback, callback_style)
  local decided, delivered, cancelled = false, false, false
  local timer = nil
  local handle = {}
  local function close_timer()
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    timer = nil
  end
  function handle.cancel()
    if delivered or cancelled then return end
    cancelled = true
    close_timer()
  end
  function handle.is_active()
    return not delivered and not cancelled
  end
  if type(value) == "string" then
    vim.schedule(function()
      if not cancelled and not delivered and current(generation) then
        delivered = true
        if valid_resolved(value) then callback(value, nil) else callback(nil, "invalid_resolved_value") end
      end
    end)
    return handle
  end
  if not callback_style then
    -- Non-URL options have a deliberately synchronous function contract. No
    -- completion callback is supplied, so callback-style misuse fails before
    -- any consumer can spawn a process or install an environment override.
    local ok, returned = xpcall(value, debug.traceback)
    vim.schedule(function()
      if cancelled or delivered or not current(generation) then return end
      delivered = true
      if not ok then callback(nil, "resolver_failed")
      elseif not valid_resolved(returned) then callback(nil, "invalid_resolved_value")
      else callback(returned, nil) end
    end)
    return handle
  end
  local resolver_returned = false
  local callback_count = 0
  local callback_result, callback_error
  local return_value
  timer = vim.uv.new_timer()
  local function finish(result, error)
    if decided or cancelled then return end
    decided = true
    close_timer()
    if before_delivery_for_test then before_delivery_for_test() end
    vim.schedule(function()
      if cancelled or delivered or not current(generation) then return end
      delivered = true
      if error ~= nil then callback(nil, "resolver_failed")
      elseif not valid_resolved(result) then callback(nil, "invalid_resolved_value")
      else callback(result, nil) end
    end)
  end
  local function arbitrate()
    if decided or cancelled or not resolver_returned then return end
    if callback_count > 1 or (callback_count > 0 and return_value ~= nil) then
      finish(nil, "duplicate completion")
    elseif return_value ~= nil then
      finish(return_value, nil)
    elseif callback_count == 1 then
      finish(callback_result, callback_error)
    else
      finish(nil, "timeout")
    end
  end
  -- A function may return synchronously and invoke its callback later. Keep the
  -- result private for the complete callback window so dual completion cannot
  -- launch an action before it is rejected.
  timer:start(M.RESOLVER_TIMEOUT_MS, 0, vim.schedule_wrap(arbitrate))
  local ok, returned = xpcall(function()
    return value(function(result, error)
      if decided or cancelled then return end
      callback_count = callback_count + 1
      if callback_count == 1 then callback_result, callback_error = result, error end
      if resolver_returned and (callback_count > 1 or return_value ~= nil) then
        finish(nil, "duplicate completion")
      end
    end)
  end, debug.traceback)
  resolver_returned = true
  return_value = returned
  if not ok then
    finish(nil, "exception")
  elseif callback_count > 1 or (callback_count > 0 and return_value ~= nil) then
    finish(nil, "duplicate completion")
  end
  return handle
end

function M._test_set_before_delivery(callback)
  before_delivery_for_test = callback
end

---Validate a CA path through asynchronous libuv stat/open/fstat/close operations.
---@return table handle cancellable validation-lifetime handle
function M.validate_ca_path(path, generation, current, callback)
  local cancelled, delivered = false, false
  local handle = {}
  function handle.cancel()
    if cancelled or delivered then return end
    cancelled = true
  end
  function handle.is_active() return not cancelled and not delivered end
  local function deliver(valid)
    vim.schedule(function()
      if cancelled or delivered or not current(generation) then return end
      delivered = true
      callback(valid)
    end)
  end
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%z\1-\31\127]") then
    deliver(false)
    return handle
  end
  vim.uv.fs_stat(path, function(stat_error, path_details)
    if cancelled then return end
    -- Opening a FIFO for reading can occupy a libuv worker indefinitely. Reject
    -- every non-regular path from metadata before attempting the readability
    -- open; fstat below still verifies the opened descriptor.
    if stat_error or not path_details or path_details.type ~= "file" then
      deliver(false)
      return
    end
    vim.uv.fs_open(path, "r", 0, function(open_error, file_descriptor)
      if open_error or not file_descriptor then
        deliver(false)
        return
      end
      if cancelled then
        vim.uv.fs_close(file_descriptor, function() end)
        return
      end
      vim.uv.fs_fstat(file_descriptor, function(fstat_error, details)
        local valid = fstat_error == nil and details ~= nil and details.type == "file"
        vim.uv.fs_close(file_descriptor, function(close_error)
          deliver(valid and close_error == nil)
        end)
      end)
    end)
  end)
  return handle
end

return M
