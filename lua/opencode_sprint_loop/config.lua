--- Configuration validation and deferred resolver support.
local M = {}

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
      return nil, "invalid_setup: unknown option " .. tostring(key)
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

---Resolve a configured string or callback-style resolver exactly once.
---@param value string|function
---@param generation number
---@param current fun(): boolean
---@param callback fun(string|nil, string|nil)
function M.resolve(value, generation, current, callback)
  if type(value) == "string" then
    vim.schedule(function()
      if current(generation) then
        if valid_resolved(value) then callback(value, nil) else callback(nil, "invalid_resolved_value") end
      end
    end)
    return
  end
  local completed = false
  local resolver_returned = false
  local callback_count = 0
  local callback_result, callback_error
  local return_value
  local timer = vim.uv.new_timer()
  local function finish(result, error)
    if completed then return end
    completed = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    if not current(generation) then return end
    if error ~= nil then callback(nil, "resolver_failed")
    elseif not valid_resolved(result) then callback(nil, "invalid_resolved_value")
    else callback(result, nil) end
  end
  local function arbitrate()
    if completed or not resolver_returned then return end
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
      if completed then return end
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
end

function M.valid_ca_path(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%z\1-\31\127]") then
    return false
  end
  local details = vim.uv.fs_stat(path)
  return details ~= nil and details.type == "file" and vim.fn.filereadable(path) == 1
end

return M
