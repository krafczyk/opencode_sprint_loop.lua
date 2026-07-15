--- Thin asynchronous Neovim client for the Sprint Loop Controller.
local config = require("opencode_sprint_loop.config")
local process = require("opencode_sprint_loop.process")
local status = require("opencode_sprint_loop.status")
local ui = require("opencode_sprint_loop.ui")

local M = {}
local state = { options = nil, generation = 0, timer = nil, in_flight = false, observed_active = false, launch_alive = false, warned = false, requests = {} }
local WATCH_INTERVAL_MS = 2000

local function notify(message, level)
  vim.notify("SprintLoop: " .. message, level or vim.log.levels.ERROR)
end

local function current(generation) return state.options ~= nil and state.generation == generation end
local function close_timer()
  if state.timer and not state.timer:is_closing() then state.timer:stop(); state.timer:close() end
  state.timer = nil
end

local function ca_environment(generation, callback)
  local value = state.options.server_ca_cert
  if not value then callback({}, nil); return end
  config.resolve(value, generation, current, function(path, error)
    if error then callback(nil, error)
    elseif not config.valid_ca_path(path) then callback(nil, "invalid_server_ca_cert")
    else callback({ SSL_CERT_FILE = path }, nil) end
  end)
end

local function command_error(result, error)
  if error then return error end
  if result.code ~= 0 then
    local detail = result.stderr ~= "" and result.stderr:gsub("[\r\n]+", " ") or "controller command failed"
    return "controller_command_failed: " .. detail:sub(1, 512)
  end
end

local function query_status(root, generation, callback)
  if not current(generation) then return end
  process.run({ state.options.executable, "status", "--root", root, "--json" }, {}, function(result, spawn_error)
    if not current(generation) then return end
    local error = command_error(result, spawn_error)
    if error then callback(nil, error); return end
    local decoded, decode_error = status.decode(result.stdout)
    if not decoded then callback(nil, decode_error); return end
    callback(decoded, nil)
  end)
end

local function stop_watcher()
  close_timer(); state.in_flight = false; state.launch_alive = false
end

local function observe(root, generation)
  if not current(generation) or state.in_flight then return end
  state.in_flight = true
  query_status(root, generation, function(document, error)
    state.in_flight = false
    if not current(generation) then return end
    if error then
      if not state.warned then notify(error, vim.log.levels.WARN); state.warned = true end
      return
    end
    state.warned = false
    if document.process_running then state.observed_active = true end
    local active = document.active
    if active and active.status == "waiting_for_user" and active.interaction then
      local request = active.interaction.request_id
      if not state.requests[request] then
        state.requests[request] = true
        notify("loop needs user input from " .. active.role .. "; use :SprintLoopOpenSession", vim.log.levels.WARN)
      end
    end
    if state.observed_active and not document.process_running then stop_watcher() end
  end)
end

local function start_watcher(root, generation)
  close_timer(); state.in_flight = false; state.observed_active = false; state.warned = false; state.requests = {}
  observe(root, generation)
  local timer = vim.uv.new_timer(); state.timer = timer
  timer:start(WATCH_INTERVAL_MS, WATCH_INTERVAL_MS, vim.schedule_wrap(function() observe(root, generation) end))
end

local function resolve_root(generation, callback)
  config.resolve(state.options.sprint_root, generation, current, callback)
end

local function action_needs_server(name)
  return name == "run" or name == "resume"
end

local function controller_action(name)
  if not state.options then notify("setup_required: call setup() first"); return end
  local generation = state.generation
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    local function spawn(server_url, server_error)
      if server_error then notify(server_error); return end
      local with_environment = action_needs_server(name) and ca_environment or function(_, callback) callback({}, nil) end
      with_environment(generation, function(env, ca_error)
        if ca_error then notify(ca_error); return end
        local argv = { state.options.executable, name, "--root", root }
        if action_needs_server(name) then table.insert(argv, "--server-url"); table.insert(argv, server_url) end
        process.run(argv, { detach = name == "run", env = env, on_spawn = function()
          if name == "run" or name == "resume" then
            state.launch_alive = true; start_watcher(root, generation)
            notify(name == "run" and "controller launch requested; confirm activity with progress" or "controller resume requested; confirm activity with progress", vim.log.levels.INFO)
          end
        end }, function(result, spawn_error)
          if not current(generation) then return end
          local error = command_error(result, spawn_error)
          if error then notify(error); return end
          if name ~= "run" and name ~= "resume" then notify(result.stdout ~= "" and result.stdout:sub(1, 512) or name .. " delegated", vim.log.levels.INFO) end
        end)
      end)
    end
    if action_needs_server(name) then config.resolve(state.options.server_url, generation, current, spawn) else spawn(nil, nil) end
  end)
end

---Configure the plugin. Values are resolved only when an action needs them.
function M.setup(options)
  if vim.fn.has("nvim-0.12") ~= 1 then notify("unsupported_neovim: Neovim 0.12 or newer is required"); return end
  local validated, error = config.validate(options)
  if not validated then notify(error); return end
  state.generation = state.generation + 1; close_timer(); state.options = validated; state.requests = {}
  local generation = state.generation
  local commands = { SprintLoopStart = M.start, SprintLoopProgress = M.progress, SprintLoopPause = M.pause, SprintLoopResume = M.resume, SprintLoopStop = M.stop, SprintLoopOpenSession = M.open_session }
  for name, method in pairs(commands) do vim.api.nvim_create_user_command(name, method, { nargs = 0, force = true }) end
  resolve_root(generation, function(root, root_error)
    if root_error then notify(root_error); return end
    query_status(root, generation, function(document, query_error)
      if query_error then notify(query_error, vim.log.levels.WARN) elseif document.process_running then start_watcher(root, generation) end
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
      if not document.run_exists or document.active == vim.NIL or not document.active or not document.active.session_id or document.active.session_id == vim.NIL then notify("active_session_unavailable"); return end
      if not state.options.web_url then notify("web_url_unavailable"); return end
      config.resolve(state.options.web_url, generation, current, function(base, web_error)
        if web_error then notify(web_error); return end
        local parsed = vim.uri_parse(base)
        if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") or not parsed.host or parsed.host == "" or parsed.user or parsed.password or parsed.query or parsed.fragment then notify("invalid_web_url"); return end
        local root64 = vim.base64.encode(document.sprint_root):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
        local session = vim.uri_encode(document.active.session_id, "rfc2396")
        local target = base:gsub("/$", "") .. "/" .. root64 .. "/session/" .. session
        local ok = pcall(vim.ui.open, target)
        if not ok then notify("browser_open_failed") else notify("opened active session", vim.log.levels.INFO) end
      end)
    end)
  end)
end

function M._test_state() return state end
function M._test_reset() close_timer(); state = { options = nil, generation = state.generation + 1, timer = nil, in_flight = false, observed_active = false, launch_alive = false, warned = false, requests = {} } end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() close_timer() end })
return M
