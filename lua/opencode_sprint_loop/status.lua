--- Strict controller status decoding and presentation-safe validation.
local M = { MAX_STATUS_BYTES = 256 * 1024, MAX_DISPLAY_BYTES = 2048 }

local required = {
  "schema_version", "controller_version", "sprint_root", "run_exists", "process_running", "run_id",
  "sprint", "state", "reason", "active", "commits", "audit", "ci", "counters", "checklist",
  "last_event", "updated_at",
}

local function bounded_string(value)
  return type(value) == "string" and value ~= "" and #value <= M.MAX_DISPLAY_BYTES
    and not value:find("[%z\1-\31\127]")
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function positive_integer(value)
  return type(value) == "number" and value % 1 == 0 and value > 0
end

-- vim.json.decode accepts duplicate object keys. This compact grammar walk rejects
-- them before decoding, while also rejecting trailing values and non-JSON numbers.
local function no_duplicate_keys(document)
  local position, length = 1, #document
  local function whitespace()
    while position <= length and document:sub(position, position):match("[%s]") do position = position + 1 end
  end
  local value
  local function string_value()
    if document:sub(position, position) ~= '"' then error("expected string") end
    local start = position
    position = position + 1
    while position <= length do
      local character = document:sub(position, position)
      if character == '"' then
        position = position + 1
        return document:sub(start, position - 1)
      elseif character == "\\" then
        position = position + 1
        local escape = document:sub(position, position)
        if not escape:match('["\\/bfnrt]') and escape ~= "u" then error("invalid escape") end
        if escape == "u" then
          local hex = document:sub(position + 1, position + 4)
          if not hex:match("^%x%x%x%x$") then error("invalid unicode escape") end
          position = position + 4
        end
      elseif character:byte() < 32 then error("control character") end
      position = position + 1
    end
    error("unterminated string")
  end
  local function object()
    local keys = {}; position = position + 1; whitespace()
    if document:sub(position, position) == "}" then position = position + 1; return end
    while true do
      whitespace(); local key = string_value()
      if keys[key] then error("duplicate key") end
      keys[key] = true; whitespace()
      if document:sub(position, position) ~= ":" then error("expected colon") end
      position = position + 1; value(); whitespace()
      local separator = document:sub(position, position)
      if separator == "}" then position = position + 1; return end
      if separator ~= "," then error("expected comma") end
      position = position + 1
    end
  end
  local function array()
    position = position + 1; whitespace()
    if document:sub(position, position) == "]" then position = position + 1; return end
    while true do
      value(); whitespace(); local separator = document:sub(position, position)
      if separator == "]" then position = position + 1; return end
      if separator ~= "," then error("expected comma") end
      position = position + 1; whitespace()
    end
  end
  value = function()
    whitespace(); local character = document:sub(position, position)
    if character == "{" then object() elseif character == "[" then array() elseif character == '"' then string_value()
    else
      local token = document:sub(position):match("^[-0-9%.eE]+") or document:sub(position):match("^[a-z]+")
      if not token or (tonumber(token) == nil and token ~= "true" and token ~= "false" and token ~= "null") then error("invalid value") end
      position = position + #token
    end
  end
  local ok = pcall(function() value(); whitespace(); if position <= length then error("trailing data") end end)
  return ok
end

local function fields(table_value, names)
  if type(table_value) ~= "table" then return false end
  for _, name in ipairs(names) do if table_value[name] == nil then return false end end
  return true
end

local function validate_active(active, running)
  if type(active) ~= "table" or not fields(active, { "role", "invocation_id", "session_id", "status", "interaction" }) then return false end
  if is_null(active.status) then return is_null(active.role) and is_null(active.invocation_id) and is_null(active.session_id) and is_null(active.interaction) end
  if active.status == "running" then return bounded_string(active.role) and bounded_string(active.invocation_id) and bounded_string(active.session_id) and is_null(active.interaction) end
  if active.status ~= "waiting_for_user" or not running then return false end
  local interaction = active.interaction
  return bounded_string(active.role) and bounded_string(active.invocation_id) and bounded_string(active.session_id)
    and fields(interaction, { "request_id", "question_count", "asked_at" }) and bounded_string(interaction.request_id)
    and positive_integer(interaction.question_count) and bounded_string(interaction.asked_at)
end

local function nonnegative_integer(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function nullable_string(value)
  return is_null(value) or bounded_string(value)
end

local function validate_run_fields(status)
  if not fields(status.commits, { "local", "pushed" }) or type(status.commits["local"]) ~= "table" or type(status.commits.pushed) ~= "table" then return false end
  for _, map in ipairs({ status.commits["local"], status.commits.pushed }) do
    for key, value in pairs(map) do if not bounded_string(key) or not nullable_string(value) then return false end end
  end
  if not fields(status.audit, { "phase", "pre_ci_round", "pre_ci_max_rounds", "remaining_effort" })
    or not nullable_string(status.audit.phase) or not nonnegative_integer(status.audit.pre_ci_round) or not positive_integer(status.audit.pre_ci_max_rounds) or not nullable_string(status.audit.remaining_effort) then return false end
  if not fields(status.ci, { "status", "attempt", "commit_sha" }) or not bounded_string(status.ci.status) or not nonnegative_integer(status.ci.attempt) or not nullable_string(status.ci.commit_sha) then return false end
  if not fields(status.counters, { "implementation_cycles", "ci_fix_attempts" }) or not nonnegative_integer(status.counters.implementation_cycles) or not nonnegative_integer(status.counters.ci_fix_attempts) then return false end
  if not fields(status.checklist, { "satisfied", "partial", "unsatisfied", "not_evaluated", "assessed_at" }) then return false end
  for _, key in ipairs({ "satisfied", "partial", "unsatisfied", "not_evaluated" }) do if not nonnegative_integer(status.checklist[key]) then return false end end
  if not nullable_string(status.checklist.assessed_at) or not nullable_string(status.updated_at) then return false end
  if not is_null(status.reason) and (not fields(status.reason, { "code", "message" }) or not bounded_string(status.reason.code) or not bounded_string(status.reason.message)) then return false end
  return is_null(status.last_event) or (fields(status.last_event, { "sequence", "type", "timestamp" }) and positive_integer(status.last_event.sequence) and bounded_string(status.last_event.type) and bounded_string(status.last_event.timestamp))
end

function M.decode(output)
  if type(output) ~= "string" or output == "" then return nil, "invalid_status_json" end
  if #output > M.MAX_STATUS_BYTES then return nil, "status_output_too_large" end
  if not no_duplicate_keys(output) then return nil, "invalid_status_json" end
  local ok, status = pcall(vim.json.decode, output)
  if not ok or type(status) ~= "table" then return nil, "invalid_status_json" end
  if not fields(status, required) then return nil, "inconsistent_status" end
  if status.schema_version ~= 1 or type(status.schema_version) ~= "number" then return nil, "unsupported_status_schema" end
  if not bounded_string(status.controller_version) or not bounded_string(status.sprint_root)
    or type(status.run_exists) ~= "boolean" or type(status.process_running) ~= "boolean" then return nil, "inconsistent_status" end
  if not status.run_exists then
    for _, key in ipairs({ "run_id", "sprint", "state", "reason", "active", "commits", "audit", "ci", "counters", "checklist", "last_event", "updated_at" }) do
      if not is_null(status[key]) then return nil, "inconsistent_status" end
    end
    if status.process_running then return nil, "inconsistent_status" end
    return status
  end
  if not bounded_string(status.run_id) or not fields(status.sprint, { "multisprint", "index" })
    or not bounded_string(status.sprint.multisprint) or not positive_integer(status.sprint.index)
    or not bounded_string(status.state) or not validate_active(status.active, status.process_running) or not validate_run_fields(status) then return nil, "inconsistent_status" end
  return status
end

function M.display(value)
  if type(value) ~= "string" then return "-" end
  return #value > M.MAX_DISPLAY_BYTES and value:sub(1, M.MAX_DISPLAY_BYTES) .. "[TRUNCATED]" or value
end

function M.render(status)
  if not status.run_exists then return { "Sprint Loop", "", "Sprint root: " .. M.display(status.sprint_root), "State: no run" } end
  local lines = {
    "Sprint Loop", "", "Sprint root: " .. M.display(status.sprint_root),
    "Sprint: " .. M.display(status.sprint.multisprint) .. " / " .. status.sprint.index,
    "State: " .. M.display(status.state) .. "    Process running: " .. tostring(status.process_running),
  }
  if not is_null(status.reason) then table.insert(lines, "Reason: " .. M.display(status.reason.code) .. ": " .. M.display(status.reason.message)) end
  local active = status.active
  if not is_null(active.status) then
    table.insert(lines, "Active: " .. M.display(active.role) .. " " .. M.display(active.invocation_id) .. " (" .. M.display(active.session_id) .. ")")
    table.insert(lines, "Active status: " .. M.display(active.status))
    if not is_null(active.interaction) then table.insert(lines, "WAITING FOR USER: question " .. active.interaction.question_count .. " at " .. M.display(active.interaction.asked_at)) end
  end
  for _, kind in ipairs({ "local", "pushed" }) do
    local pairs_list = {}
    for name, commit in pairs(status.commits[kind]) do table.insert(pairs_list, { name, commit }) end
    table.sort(pairs_list, function(left, right) return left[1] < right[1] end)
    local rendered = {}
    for _, item in ipairs(pairs_list) do table.insert(rendered, item[1] .. "=" .. M.display(item[2])) end
    table.insert(lines, "Commits " .. kind .. ": " .. table.concat(rendered, ", "))
  end
  table.insert(lines, "Audit: " .. M.display(status.audit.phase) .. " round " .. tostring(status.audit.pre_ci_round) .. "/" .. tostring(status.audit.pre_ci_max_rounds))
  table.insert(lines, "CI: " .. M.display(status.ci.status) .. " attempt " .. tostring(status.ci.attempt))
  table.insert(lines, "Counters: implementations " .. status.counters.implementation_cycles .. ", CI fixes " .. status.counters.ci_fix_attempts)
  table.insert(lines, "Checklist: " .. status.checklist.satisfied .. " satisfied, " .. status.checklist.partial .. " partial, " .. status.checklist.unsatisfied .. " unsatisfied")
  if not is_null(status.last_event) then table.insert(lines, "Last event: " .. M.display(status.last_event.type) .. " at " .. M.display(status.last_event.timestamp)) end
  table.insert(lines, "Controller: " .. M.display(status.controller_version) .. "    Updated: " .. M.display(status.updated_at))
  return lines
end

return M
