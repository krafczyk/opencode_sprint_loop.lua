--- Credential-safe HTTP(S) URL validation without compatibility-only APIs.
local M = {}
local security = require("opencode_sprint_loop.security")

local function valid_port(port)
  if port == nil then return true end
  if port == "" or not port:match("^%d+$") then return false end
  local number = tonumber(port)
  return number ~= nil and number >= 1 and number <= 65535
end

local function valid_ipv6(host)
  if host:find(":::", 1, true) then return false end
  local _, doubles = host:gsub("::", "")
  if doubles > 1 then return false end
  local groups = 0
  for group in host:gmatch("[^:]+") do
    if #group > 4 or not group:match("^%x+$") then return false end
    groups = groups + 1
  end
  return (doubles == 1 and groups < 8) or (doubles == 0 and groups == 8)
end

local function valid_hostname(host)
  if #host > 253 or host:sub(1, 1) == "." or host:sub(-1) == "." then return false end
  for label in host:gmatch("[^%.]+") do
    if #label > 63 or not label:match("^[%w%-]+$") or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return false end
  end
  return not host:find("..", 1, true)
end

local function valid_authority(authority)
  if authority == "" or authority:find("@", 1, true) or authority:find("\\", 1, true) then return false end
  if authority:sub(1, 1) == "[" then
    local host, separator, port = authority:match("^%[([^%]]+)%](:?)(.*)$")
    if not host or not valid_ipv6(host) then return false end
    if separator == ":" then return valid_port(port) end
    return port == ""
  end
  local host, separator, port = authority:match("^([^:]+)(:?)(.*)$")
  if not host or not valid_hostname(host) then return false end
  if separator == ":" then return valid_port(port) end
  return port == ""
end

local function valid_path(path)
  local index = 1
  while index <= #path do
    local character = path:sub(index, index)
    if character == "%" then
      if not path:sub(index + 1, index + 2):match("^%x%x$") then return false end
      index = index + 3
    elseif character:match("^[%w%-%._~!%$&'%(%)%*%+,;=:@/]$") then
      index = index + 1
    else
      return false
    end
  end
  return true
end

local function parse(value, allow_path)
  if type(value) ~= "string" or value == "" or value:find("[%z\1-\31\127]") then return nil end
  if security.contains_credential(value) then return nil end
  if value:find("?", 1, true) or value:find("#", 1, true) then return nil end
  local scheme, remainder = value:match("^([%a][%w+%.%-]*)://(.+)$")
  if scheme then scheme = scheme:lower() end
  if scheme ~= "http" and scheme ~= "https" then return nil end
  local authority, path = remainder:match("^([^/]*)(/.*)$")
  if authority == nil then authority, path = remainder, "" end
  if not valid_authority(authority) then return nil end
  if not valid_path(path) or (not allow_path and path ~= "" and path ~= "/") then return nil end
  return { scheme = scheme, authority = authority, path = path }
end

function M.valid_server_origin(value)
  return parse(value, false) ~= nil
end

function M.normalize_web_base(value)
  local parsed = parse(value, true)
  if not parsed then return nil end
  local path = parsed.path:gsub("/+$", "")
  return parsed.scheme .. "://" .. parsed.authority .. path
end

function M.encode_path_segment(value)
  return (value:gsub("([^%w%-%._~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

return M
