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
}

local function notify(message, level)
  vim.notify("SprintLoop: " .. message, level or vim.log.levels.ERROR)
end

local function current(generation)
  return state.options ~= nil and state.generation == generation
end

local function close_timer()
  if state.timer and not state.timer:is_closing() then state.timer:stop(); state.timer:close() end
  state.timer = nil
end

local function invalidate_watcher()
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
  if result.code ~= 0 then
    local detail = type(result.stderr) == "string" and result.stderr ~= "" and result.stderr:gsub("[\r\n]+", " ") or "controller command failed"
    return "controller_command_failed: " .. detail:sub(1, 512)
  end
end

local function resolve_option(key, generation, callback)
  config.resolve(state.options[key], generation, current, callback)
end

local function ca_environment(generation, callback)
  local value = state.options.server_ca_cert
  if not value then callback(nil, nil); return end
  config.resolve(value, generation, current, function(path, error)
    if error then callback(nil, error)
    elseif not config.valid_ca_path(path) then callback(nil, "invalid_server_ca_cert")
    else callback({ SSL_CERT_FILE = path }, nil) end
  end)
end

local function query_status(root, generation, callback)
  if not current(generation) then return end
  resolve_option("executable", generation, function(executable, executable_error)
    if executable_error then callback(nil, executable_error); return end
    process.run({ executable, "status", "--root", root, "--json" }, {}, function(result, spawn_error)
      if not current(generation) then return end
      local error = command_error(result, spawn_error)
      if error then callback(nil, error); return end
      local decoded, decode_error = status.decode(result.stdout)
      if not decoded then callback(nil, decode_error); return end
      callback(decoded, nil)
    end)
  end)
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
  query_status(root, generation, function(document, error)
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

local function resolve_root(generation, callback)
  resolve_option("sprint_root", generation, callback)
end

local function action_needs_server(name)
  return name == "run" or name == "resume"
end

local function controller_action(name)
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    local function with_server(server_url, server_error)
      if server_error then notify(server_error); return end
      if action_needs_server(name) and not url.valid_server_origin(server_url) then notify("invalid_resolved_value: server_url must be a credential-free HTTP(S) origin"); return end
      local environment_resolver = action_needs_server(name) and ca_environment or function(_, callback) callback(nil, nil) end
      environment_resolver(generation, function(environment, ca_error)
        if ca_error then notify(ca_error); return end
        resolve_option("executable", generation, function(executable, executable_error)
          if executable_error then notify(executable_error); return end
          local argv = { executable, name, "--root", root }
          if action_needs_server(name) then table.insert(argv, "--server-url"); table.insert(argv, server_url) end
          local launch_watcher_id = nil
          process.run(argv, {
            detach = name == "run",
            env = environment,
            on_spawn = function()
              if name == "run" or name == "resume" then
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
            if name ~= "run" and name ~= "resume" then
              notify(result.stdout ~= "" and result.stdout:sub(1, 512) or name .. " delegated", vim.log.levels.INFO)
            end
          end)
        end)
      end)
    end
    if action_needs_server(name) then resolve_option("server_url", generation, with_server) else with_server(nil, nil) end
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
  state.generation = state.generation + 1
  invalidate_watcher()
  state.options = validated
  local generation = state.generation
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, function(document, query_error)
      if query_error then notify(query_error, vim.log.levels.WARN)
      elseif document.process_running then start_watcher(root, generation, true) end
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
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, function(document, query_error)
      if query_error then notify(query_error); return end
      ui.show(status.render(document))
    end)
  end)
end

function M.open_session()
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, function(document, query_error)
      if query_error then notify(query_error); return end
      if not document.run_exists or type(document.active) ~= "table" or type(document.active.session_id) ~= "string" or document.active.session_id == "" then notify("active_session_unavailable"); return end
      if not state.options.web_url then notify("web_url_unavailable"); return end
      resolve_option("web_url", generation, function(base, web_error)
        if web_error then notify(web_error); return end
        local normalized = url.normalize_web_base(base)
        if not normalized then notify("invalid_web_url"); return end
        local root64 = vim.base64.encode(document.sprint_root):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
        local session = url.encode_path_segment(document.active.session_id)
        local target = normalized .. "/" .. root64 .. "/session/" .. session
        local opener = browser_override or vim.ui.open
        local ok, handle, open_error = pcall(opener, target)
        if not ok or handle == nil or open_error ~= nil then notify("browser_open_failed")
        else notify("opened active session", vim.log.levels.INFO) end
      end)
    end)
  end)
end

function M._test_state() return state end
function M._test_set_browser(opener) browser_override = opener end
function M._test_set_watch_interval(milliseconds) WATCH_INTERVAL_MS = milliseconds end
function M._test_set_version_check(checker) version_check_override = checker end
function M._test_reset()
  local next_generation = state.generation + 1
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
  }
  browser_override = nil
  version_check_override = nil
  WATCH_INTERVAL_MS = 2000
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = invalidate_watcher })
return M
