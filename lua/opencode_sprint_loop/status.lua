--- Strict controller status decoding and presentation-safe validation.
local M = { MAX_STATUS_BYTES = 256 * 1024, MAX_DISPLAY_BYTES = 2048 }
local security = require("opencode_sprint_loop.security")

local required = {
  "schema_version", "controller_version", "sprint_root", "run_exists", "process_running", "run_id",
  "sprint", "state", "reason", "active", "commits", "audit", "ci", "counters", "checklist",
  "last_event", "updated_at",
}

local workflow_states = {
  initializing = true, validating = true, implementing = true, committing = true,
  pre_ci_auditing = true, pushing = true, waiting_for_ci = true, fixing_ci = true,
  final_auditing = true, paused = true, blocked = true, stopping = true,
  stopped = true, failed = true, finished = true,
}
local terminal_states = { stopped = true, failed = true, finished = true }

local function bounded_string(value)
  return type(value) == "string" and value ~= "" and #value <= M.MAX_DISPLAY_BYTES
    and not value:find("[%z\1-\31\127]") and not security.contains_credential(value)
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function positive_integer(value)
  return type(value) == "number" and value % 1 == 0 and value > 0
end

local function valid_utf8(document)
  local index = 1
  while index <= #document do
    local first = document:byte(index)
    if first < 0x80 then
      index = index + 1
    else
      local count, minimum
      if first >= 0xC2 and first <= 0xDF then count, minimum = 1, 0x80
      elseif first >= 0xE0 and first <= 0xEF then count, minimum = 2, 0x800
      elseif first >= 0xF0 and first <= 0xF4 then count, minimum = 3, 0x10000
      else return false end
      local codepoint = first % (2 ^ (6 - count))
      for offset = 1, count do
        local byte = document:byte(index + offset)
        if not byte or byte < 0x80 or byte > 0xBF then return false end
        codepoint = codepoint * 64 + (byte - 0x80)
      end
      if codepoint < minimum or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then return false end
      index = index + count + 1
    end
  end
  return true
end

-- vim.json.decode accepts duplicate object keys. This compact grammar walk rejects
-- semantically duplicate keys before decoding, trailing values, and non-finite numbers.
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
        local ok, decoded = pcall(vim.json.decode, document:sub(start, position - 1))
        if not ok or type(decoded) ~= "string" then error("invalid string") end
        return decoded
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
    if character == "{" then object()
    elseif character == "[" then array()
    elseif character == '"' then string_value()
    elseif character == "t" and document:sub(position, position + 3) == "true" then position = position + 4
    elseif character == "f" and document:sub(position, position + 4) == "false" then position = position + 5
    elseif character == "n" and document:sub(position, position + 3) == "null" then position = position + 4
    else
      local start = position
      if character == "-" then position = position + 1; character = document:sub(position, position) end
      if character == "0" then
        position = position + 1
        if document:sub(position, position):match("%d") then error("leading zero") end
      elseif character:match("[1-9]") then
        repeat position = position + 1 until not document:sub(position, position):match("%d")
      else error("invalid number") end
      if document:sub(position, position) == "." then
        position = position + 1
        if not document:sub(position, position):match("%d") then error("invalid fraction") end
        repeat position = position + 1 until not document:sub(position, position):match("%d")
      end
      local exponent = document:sub(position, position)
      if exponent == "e" or exponent == "E" then
        position = position + 1
        local sign = document:sub(position, position)
        if sign == "+" or sign == "-" then position = position + 1 end
        if not document:sub(position, position):match("%d") then error("invalid exponent") end
        repeat position = position + 1 until not document:sub(position, position):match("%d")
      end
      local number = tonumber(document:sub(start, position - 1))
      if not number or number ~= number or number == math.huge or number == -math.huge then error("non-finite number") end
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
  -- The active invocation is durable evidence. It remains truthful after an
  -- interrupted controller lifetime even when process_running is false.
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

local function object_table(value)
  return type(value) == "table" and not vim.islist(value)
end

local function validate_run_fields(status)
  if not fields(status.commits, { "local", "pushed" }) or not object_table(status.commits["local"]) or not object_table(status.commits.pushed) then return false end
  local repository_keys, local_count, pushed_count = {}, 0, 0
  for key, value in pairs(status.commits["local"]) do
    if not bounded_string(key) or not nullable_string(value) then return false end
    repository_keys[key], local_count = true, local_count + 1
  end
  if local_count == 0 then return false end
  for key, value in pairs(status.commits.pushed) do
    if not repository_keys[key] or not nullable_string(value) then return false end
    pushed_count = pushed_count + 1
  end
  if pushed_count ~= local_count then return false end
  if not fields(status.audit, { "phase", "pre_ci_round", "pre_ci_max_rounds", "remaining_effort" })
    or not nullable_string(status.audit.phase) or not nonnegative_integer(status.audit.pre_ci_round) or not positive_integer(status.audit.pre_ci_max_rounds)
    or status.audit.pre_ci_round > status.audit.pre_ci_max_rounds or not nullable_string(status.audit.remaining_effort) then return false end
  if not fields(status.ci, { "status", "attempt", "commit_sha" }) or not bounded_string(status.ci.status) or not nonnegative_integer(status.ci.attempt) or not nullable_string(status.ci.commit_sha) then return false end
  if not fields(status.counters, { "implementation_cycles", "ci_fix_attempts" }) or not nonnegative_integer(status.counters.implementation_cycles) or not nonnegative_integer(status.counters.ci_fix_attempts) then return false end
  if not fields(status.checklist, { "satisfied", "partial", "unsatisfied", "not_evaluated", "assessed_at" }) then return false end
  for _, key in ipairs({ "satisfied", "partial", "unsatisfied", "not_evaluated" }) do if not nonnegative_integer(status.checklist[key]) then return false end end
  if not nullable_string(status.checklist.assessed_at) or not bounded_string(status.updated_at) then return false end
  local reason_required = status.state == "blocked" or status.state == "failed" or status.state == "stopped"
  if reason_required and is_null(status.reason) then return false end
  if not is_null(status.reason) and (not fields(status.reason, { "code", "message" }) or not bounded_string(status.reason.code) or not bounded_string(status.reason.message)) then return false end
  return fields(status.last_event, { "sequence", "type", "timestamp" }) and positive_integer(status.last_event.sequence)
    and bounded_string(status.last_event.type) and bounded_string(status.last_event.timestamp)
end

function M.decode(output)
  if type(output) ~= "string" or output == "" then return nil, "invalid_status_json" end
  if #output > M.MAX_STATUS_BYTES then return nil, "status_output_too_large" end
  if not valid_utf8(output) or not no_duplicate_keys(output) then return nil, "invalid_status_json" end
  local ok, status = pcall(vim.json.decode, output)
  if not ok or type(status) ~= "table" or vim.islist(status) then return nil, "invalid_status_json" end
  -- Classify the version before applying the V1 shape. A future schema may
  -- deliberately remove or rename V1 fields and must still receive the stable
  -- compatibility diagnostic rather than looking like corrupt V1 output.
  if status.schema_version ~= 1 or type(status.schema_version) ~= "number" then return nil, "unsupported_status_schema" end
  if not fields(status, required) then return nil, "inconsistent_status" end
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
    or not bounded_string(status.state) or not workflow_states[status.state]
    or not validate_active(status.active, status.process_running) or not validate_run_fields(status) then return nil, "inconsistent_status" end
  if terminal_states[status.state] and (status.process_running or not is_null(status.active.status)) then return nil, "inconsistent_status" end
  return status
end

function M.display(value)
  if type(value) ~= "string" then return "-" end
  return #value > M.MAX_DISPLAY_BYTES and value:sub(1, M.MAX_DISPLAY_BYTES) .. "[TRUNCATED]" or value
end

function M.render(status)
  local lines = {}
  local function add(line)
    if security.contains_credential(line) then
      table.insert(lines, "Status detail withheld: unsafe composed text")
    else
      table.insert(lines, line)
    end
  end
  add("Sprint Loop"); add(""); add("Sprint root: " .. M.display(status.sprint_root))
  if not status.run_exists then
    add("State: no run")
    add("Process running: " .. tostring(status.process_running))
    add("Controller: " .. M.display(status.controller_version))
    return lines
  end
  add("Sprint: " .. M.display(status.sprint.multisprint) .. " / " .. status.sprint.index)
  add("State: " .. M.display(status.state) .. "    Process running: " .. tostring(status.process_running))
  if not is_null(status.reason) then add("Reason: " .. M.display(status.reason.code) .. ": " .. M.display(status.reason.message)) end
  local active = status.active
  if not is_null(active.status) then
    add("Active: " .. M.display(active.role) .. " " .. M.display(active.invocation_id) .. " (" .. M.display(active.session_id) .. ")")
    add("Active status: " .. M.display(active.status))
    if not is_null(active.interaction) then add("WAITING FOR USER: question " .. active.interaction.question_count .. " at " .. M.display(active.interaction.asked_at)) end
  else
    add("Active: - - (-)")
    add("Active status: -")
  end
  for _, kind in ipairs({ "local", "pushed" }) do
    local pairs_list = {}
    for name, commit in pairs(status.commits[kind]) do table.insert(pairs_list, { name, commit }) end
    table.sort(pairs_list, function(left, right) return left[1] < right[1] end)
    local rendered = {}
    for _, item in ipairs(pairs_list) do table.insert(rendered, item[1] .. "=" .. M.display(item[2])) end
    add("Commits " .. kind .. ": " .. table.concat(rendered, ", "))
  end
  add("Audit: " .. M.display(status.audit.phase) .. " round " .. tostring(status.audit.pre_ci_round) .. "/" .. tostring(status.audit.pre_ci_max_rounds) .. ", remaining effort " .. M.display(status.audit.remaining_effort))
  add("CI: " .. M.display(status.ci.status) .. " attempt " .. tostring(status.ci.attempt) .. ", commit " .. M.display(status.ci.commit_sha))
  add("Counters: implementations " .. status.counters.implementation_cycles .. ", CI fixes " .. status.counters.ci_fix_attempts)
  add("Checklist: " .. status.checklist.satisfied .. " satisfied, " .. status.checklist.partial .. " partial, " .. status.checklist.unsatisfied .. " unsatisfied, " .. status.checklist.not_evaluated .. " not evaluated; assessed " .. M.display(status.checklist.assessed_at))
  if not is_null(status.last_event) then add("Last event: #" .. status.last_event.sequence .. " " .. M.display(status.last_event.type) .. " at " .. M.display(status.last_event.timestamp))
  else add("Last event: -") end
  add("Controller: " .. M.display(status.controller_version) .. "    Updated: " .. M.display(status.updated_at))
  return lines
end

return M
