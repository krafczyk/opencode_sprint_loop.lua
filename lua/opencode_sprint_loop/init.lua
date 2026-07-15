--- Thin asynchronous Neovim client for the Sprint Loop Controller.
local config = require("opencode_sprint_loop.config")
local process = require("opencode_sprint_loop.process")
local status = require("opencode_sprint_loop.status")
local ui = require("opencode_sprint_loop.ui")
local url = require("opencode_sprint_loop.url")

local M = {}
local WATCH_INTERVAL_MS = 2000
local commands_registered = false
local browser_override = nil
local version_check_override = nil
local state = {
  options = nil,
  generation = 0,
  watcher_id = 0,
  watching = false,
  timer = nil,
  in_flight = false,
  observed_active = false,
  launch_alive = false,
  final_pending = false,
  warned = false,
  requests = {},
  resolvers = {},
  action_id = 0,
  status_active = nil,
  status_queue = {},
  openers = {},
  exiting = false,
}

local function notify(message, level)
  vim.notify("SprintLoop: " .. message, level or vim.log.levels.ERROR)
end

local function current(generation)
  return not state.exiting and state.options ~= nil and state.generation == generation
end

local function cancel_openers()
  for timer in pairs(state.openers) do
    if not timer:is_closing() then timer:stop(); timer:close() end
    state.openers[timer] = nil
  end
end

local function cancel_resolvers(kind, identifier)
  for handle, owner in pairs(state.resolvers) do
    if kind == nil or (owner.kind == kind and (identifier == nil or owner.id == identifier)) then
      handle.cancel()
      state.resolvers[handle] = nil
    end
  end
end

local function resolve_value(value, generation, owner, predicate, callback, callback_style)
  local handle
  handle = config.resolve(value, generation, predicate, function(result, error)
    if handle then state.resolvers[handle] = nil end
    callback(result, error)
  end, callback_style)
  if handle.is_active() then state.resolvers[handle] = owner end
end

local function close_timer()
  if state.timer and not state.timer:is_closing() then state.timer:stop(); state.timer:close() end
  state.timer = nil
end

local cancel_status_requests

local function invalidate_watcher()
  local replaced_id = state.watcher_id
  cancel_resolvers("watcher", replaced_id)
  if cancel_status_requests then cancel_status_requests("watcher", replaced_id) end
  state.watcher_id = state.watcher_id + 1
  state.watching = false
  close_timer()
  state.in_flight = false
  state.observed_active = false
  state.launch_alive = false
  state.final_pending = false
  state.warned = false
end

local function watcher_current(generation, watcher_id)
  return current(generation) and state.watching and state.watcher_id == watcher_id
end

local function stop_watcher(generation, watcher_id)
  if not watcher_current(generation, watcher_id) then return end
  invalidate_watcher()
end

local function command_error(result, error)
  if error then return error end
  if type(result) ~= "table" then return "process_spawn_failed" end
  if result.code ~= 0 or (type(result.signal) == "number" and result.signal ~= 0) then
    -- External stderr can contain credentials, URLs, terminal controls, or
    -- arbitrary service output. Do not attempt partial sanitization here.
    return "controller_command_failed: inspect controller status with :SprintLoopProgress"
  end
end

local function owner_matches(owner, kind, identifier)
  return kind == nil or (owner.kind == kind and (identifier == nil or owner.id == identifier))
end

local drain_status_queue

local function complete_status_request(request, result, spawn_error)
  if state.status_active ~= request then return end
  state.status_active = nil
  if not request.cancelled and request.predicate(request.generation) then
    local error = command_error(result, spawn_error)
    if error then request.callback(nil, error)
    elseif result.stdout_truncated == true then request.callback(nil, "status_output_too_large")
    else
      local decoded, decode_error = status.decode(result.stdout)
      if not decoded then request.callback(nil, decode_error) else request.callback(decoded, nil) end
    end
  end
  drain_status_queue()
end

drain_status_queue = function()
  if state.exiting or state.status_active ~= nil then return end
  local request
  while #state.status_queue > 0 and request == nil do
    local candidate = table.remove(state.status_queue, 1)
    if not candidate.cancelled and candidate.predicate(candidate.generation) then request = candidate end
  end
  if not request then return end
  state.status_active = request
  request.handle = process.run(request.argv, {}, function(result, spawn_error)
    complete_status_request(request, result, spawn_error)
  end)
end

cancel_status_requests = function(kind, identifier)
  local retained = {}
  for _, request in ipairs(state.status_queue) do
    if owner_matches(request.owner, kind, identifier) then request.cancelled = true
    else table.insert(retained, request) end
  end
  state.status_queue = retained
  local active = state.status_active
  if not active or not owner_matches(active.owner, kind, identifier) then return end
  active.cancelled = true
  local ok, kill = pcall(function() return active.handle and active.handle.kill end)
  if ok and type(kill) == "function" then
    -- This handle belongs only to `status --json`; detached controller handles
    -- are never retained by this scheduler and therefore cannot be signalled.
    pcall(kill, active.handle, 15)
  end
  -- Do not clear status_active here. A replacement remains serialized until
  -- the cancelled child's completion callback closes the ownership lifetime.
end

local function resolve_option(key, generation, owner, predicate, callback)
  local callback_style = key == "server_url" or key == "web_url"
  resolve_value(state.options[key], generation, owner, predicate or current, callback, callback_style)
end

local function ca_environment(generation, owner, predicate, callback)
  local value = state.options.server_ca_cert
  if not value then callback(nil, nil); return end
  resolve_value(value, generation, owner, predicate or current, function(path, error)
    if error then callback(nil, error); return end
    local validation
    validation = config.validate_ca_path(path, generation, predicate or current, function(valid)
      if validation then state.resolvers[validation] = nil end
      if valid then callback({ SSL_CERT_FILE = path }, nil)
      else callback(nil, "invalid_server_ca_cert") end
    end)
    if validation.is_active() then state.resolvers[validation] = owner end
  end)
end

local function query_status(root, generation, owner, predicate, callback)
  predicate = predicate or current
  if not predicate(generation) then return end
  resolve_option("executable", generation, owner, predicate, function(executable, executable_error)
    if executable_error then callback(nil, executable_error); return end
    if not predicate(generation) then return end
    table.insert(state.status_queue, {
      argv = { executable, "status", "--root", root, "--json" },
      generation = generation,
      owner = owner,
      predicate = predicate,
      callback = callback,
      cancelled = false,
      handle = nil,
    })
    drain_status_queue()
  end)
end

local function cancel_observation_work()
  cancel_resolvers("setup")
  cancel_status_requests("setup")
  -- Watcher/setup reads are replaceable observation work. User-requested
  -- progress and open-session reads stay serialized in the public queue and
  -- receive their normal actionable completion.
  invalidate_watcher()
end

local function notify_interaction(document)
  local active = document.active
  if type(active) ~= "table" or active.status ~= "waiting_for_user" or type(active.interaction) ~= "table" then return end
  local request = active.interaction.request_id
  if not state.requests[request] then
    state.requests[request] = true
    notify("loop needs user input from " .. active.role .. "; use :SprintLoopOpenSession", vim.log.levels.WARN)
  end
end

local observe

local function finish_launch(root, generation, watcher_id)
  if not watcher_current(generation, watcher_id) then return end
  state.launch_alive = false
  state.final_pending = true
  if not state.in_flight then
    state.final_pending = false
    observe(root, generation, watcher_id, true)
  end
end

observe = function(root, generation, watcher_id, final_observation)
  if not watcher_current(generation, watcher_id) or state.in_flight then return end
  state.in_flight = true
  local owner = { kind = "watcher", id = watcher_id }
  local predicate = function(candidate) return watcher_current(candidate, watcher_id) end
  query_status(root, generation, owner, predicate, function(document, error)
    if not watcher_current(generation, watcher_id) then return end
    state.in_flight = false
    if error then
      if not state.warned then notify(error, vim.log.levels.WARN); state.warned = true end
    else
      state.warned = false
      if document.process_running then state.observed_active = true end
      notify_interaction(document)
      if state.observed_active and not document.process_running then
        stop_watcher(generation, watcher_id)
        return
      end
    end
    if final_observation and (error or not document.process_running) then
      stop_watcher(generation, watcher_id)
    elseif state.final_pending and not state.launch_alive then
      state.final_pending = false
      observe(root, generation, watcher_id, true)
    end
  end)
end

local function start_watcher(root, generation, already_observed)
  invalidate_watcher()
  state.watching = true
  state.observed_active = already_observed == true
  state.warned = false
  local watcher_id = state.watcher_id
  observe(root, generation, watcher_id, false)
  if not watcher_current(generation, watcher_id) then return watcher_id end
  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(WATCH_INTERVAL_MS, WATCH_INTERVAL_MS, vim.schedule_wrap(function()
    observe(root, generation, watcher_id, false)
  end))
  return watcher_id
end

local function resolve_root(generation, owner, predicate, callback)
  resolve_option("sprint_root", generation, owner, predicate or current, callback)
end

local function action_needs_server(name)
  return name == "run" or name == "resume"
end

local function controller_action(name)
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  state.action_id = state.action_id + 1
  local owner = { kind = "action", id = state.action_id }
  resolve_root(generation, owner, current, function(root, root_error)
    if root_error then notify(root_error); return end
    local function with_server(server_url, server_error)
      if server_error then notify(server_error); return end
      if action_needs_server(name) and not url.valid_server_origin(server_url) then notify("invalid_resolved_value: server_url must be a credential-free HTTP(S) origin"); return end
      local environment_resolver = action_needs_server(name) and ca_environment or function(_, _, _, callback) callback(nil, nil) end
      environment_resolver(generation, owner, current, function(environment, ca_error)
        if ca_error then notify(ca_error); return end
        resolve_option("executable", generation, owner, current, function(executable, executable_error)
          if executable_error then notify(executable_error); return end
          local argv = { executable, name, "--root", root }
          if action_needs_server(name) then table.insert(argv, "--server-url"); table.insert(argv, server_url) end
          local launch_watcher_id = nil
          process.run(argv, {
            detach = name == "run",
            env = environment,
            on_spawn = function()
              if name == "run" or name == "resume" then
                cancel_observation_work()
                launch_watcher_id = start_watcher(root, generation)
                state.launch_alive = true
                notify(name == "run" and "controller launch requested; confirm activity with progress" or "controller resume requested; confirm activity with progress", vim.log.levels.INFO)
              end
            end,
          }, function(result, spawn_error)
            if not current(generation) then return end
            if launch_watcher_id then finish_launch(root, generation, launch_watcher_id) end
            local error = command_error(result, spawn_error)
            if error then notify(error); return end
            if name == "run" or name == "resume" then
              notify("controller " .. name .. " process exited successfully; inspect progress for workflow state", vim.log.levels.INFO)
            else
              notify(name .. " delegated", vim.log.levels.INFO)
            end
          end)
        end)
      end)
    end
    if action_needs_server(name) then resolve_option("server_url", generation, owner, current, with_server) else with_server(nil, nil) end
  end)
end

---Register all commands once at plugin load. Actions still require setup().
function M._register_commands()
  if commands_registered then return end
  local commands = {
    SprintLoopStart = "start",
    SprintLoopProgress = "progress",
    SprintLoopPause = "pause",
    SprintLoopResume = "resume",
    SprintLoopStop = "stop",
    SprintLoopOpenSession = "open_session",
  }
  for name, method in pairs(commands) do
    vim.api.nvim_create_user_command(name, function() M[method]() end, { nargs = 0 })
  end
  commands_registered = true
end

---Configure the plugin. Values are resolved only when an action needs them.
function M.setup(options)
  local supported
  if version_check_override then supported = version_check_override()
  else supported = vim.fn.has("nvim-0.12") == 1 end
  if not supported then notify("unsupported_neovim: Neovim 0.12 or newer is required"); return end
  local validated, error = config.validate(options)
  if not validated then notify(error); return end
  cancel_openers()
  cancel_resolvers()
  cancel_status_requests()
  state.generation = state.generation + 1
  invalidate_watcher()
  state.options = validated
  state.exiting = false
  local generation = state.generation
  local owner = { kind = "setup", id = generation }
  resolve_root(generation, owner, current, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, owner, current, function(document, query_error)
      if query_error then notify(query_error, vim.log.levels.WARN)
      else
        notify_interaction(document)
        if document.process_running then start_watcher(root, generation, true) end
      end
    end)
  end)
end

function M.start() controller_action("run") end
function M.pause() controller_action("pause") end
function M.resume() controller_action("resume") end
function M.stop() controller_action("stop") end

function M.progress()
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  state.action_id = state.action_id + 1
  local owner = { kind = "status_action", id = state.action_id }
  resolve_root(generation, owner, current, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, owner, current, function(document, query_error)
      if query_error then notify(query_error); return end
      ui.show(status.render(document))
    end)
  end)
end

function M.open_session()
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  state.action_id = state.action_id + 1
  local owner = { kind = "status_action", id = state.action_id }
  resolve_root(generation, owner, current, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, owner, current, function(document, query_error)
      if query_error then notify(query_error); return end
      if not document.run_exists or type(document.active) ~= "table" or type(document.active.session_id) ~= "string" or document.active.session_id == "" then notify("active_session_unavailable"); return end
      if not state.options.web_url then notify("web_url_unavailable"); return end
      resolve_option("web_url", generation, owner, current, function(base, web_error)
        if web_error then notify(web_error); return end
        local normalized = url.normalize_web_base(base)
        if not normalized then notify("invalid_web_url"); return end
        local root64 = vim.base64.encode(document.sprint_root):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
        local session = url.encode_path_segment(document.active.session_id)
        local target = normalized .. "/" .. root64 .. "/session/" .. session
        local opener = browser_override or vim.ui.open
        local ok, handle, open_error = pcall(opener, target)
        if not ok or handle == nil or open_error ~= nil then notify("browser_open_failed"); return end
        if type(handle.is_closing) ~= "function" or type(handle.wait) ~= "function" then
          notify("browser launch requested; handler completion unavailable", vim.log.levels.WARN)
          return
        end
        local timer = vim.uv.new_timer()
        state.openers[timer] = true
        local function close()
          state.openers[timer] = nil
          if not timer:is_closing() then timer:stop(); timer:close() end
        end
        timer:start(0, 50, vim.schedule_wrap(function()
          if not current(generation) then close(); return end
          local observed, closing = pcall(handle.is_closing, handle)
          if not observed then close(); notify("browser_open_failed"); return end
          if not closing then return end
          close()
          -- is_closing() means the process has reached terminal completion;
          -- wait() only retrieves the retained result and does not block here.
          local waited, result = pcall(handle.wait, handle)
          if not waited or type(result) ~= "table" or result.code ~= 0 or (type(result.signal) == "number" and result.signal ~= 0) then
            notify("browser_open_failed")
          else
            notify("opened active session", vim.log.levels.INFO)
          end
        end))
      end)
    end)
  end)
end

function M._test_state() return state end
function M._test_set_browser(opener) browser_override = opener end
function M._test_set_watch_interval(milliseconds) WATCH_INTERVAL_MS = milliseconds end
function M._test_set_version_check(checker) version_check_override = checker end
function M._test_replace_watcher(root)
  if state.options then start_watcher(root, state.generation, false) end
end
function M._test_reset()
  local next_generation = state.generation + 1
  cancel_openers()
  cancel_resolvers()
  cancel_status_requests()
  invalidate_watcher()
  state = {
    options = nil,
    generation = next_generation,
    watcher_id = state.watcher_id,
    watching = false,
    timer = nil,
    in_flight = false,
    observed_active = false,
    launch_alive = false,
    final_pending = false,
    warned = false,
    requests = {},
    resolvers = {},
    action_id = 0,
    status_active = nil,
    status_queue = {},
    openers = {},
    exiting = false,
  }
  browser_override = nil
  version_check_override = nil
  WATCH_INTERVAL_MS = 2000
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = function()
  state.exiting = true
  cancel_openers()
  cancel_resolvers()
  cancel_status_requests()
  invalidate_watcher()
end })
return M
