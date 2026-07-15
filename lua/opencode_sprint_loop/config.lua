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
  local timed_out = false
  local timer = vim.uv.new_timer()
  local function finish(result, error)
    if completed then
      if current(generation) then callback(nil, "resolver_failed: resolver completed more than once") end
      return
    end
    completed = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    if not current(generation) then return end
    if error ~= nil then callback(nil, "resolver_failed")
    elseif not valid_resolved(result) then callback(nil, "invalid_resolved_value")
    else callback(result, nil) end
  end
  timer:start(M.RESOLVER_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    timed_out = true
    finish(nil, "timeout")
  end))
  local ok, returned = xpcall(function() return value(function(result, error) finish(result, error) end) end, debug.traceback)
  if not ok then
    finish(nil, "exception")
  elseif returned ~= nil then
    if completed then
      finish(nil, "dual completion")
    elseif timed_out then
      return
    else
      finish(returned, nil)
    end
  end
end

function M.valid_ca_path(path)
  return type(path) == "string" and vim.startswith(path, "/") and not path:find("[%z\1-\31\127]")
    and vim.fn.filereadable(path) == 1 and vim.fn.isdirectory(path) == 0
end

return M
