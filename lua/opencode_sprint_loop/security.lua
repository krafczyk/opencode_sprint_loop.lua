--- Shared ASCII credential recognition for status text and resolved URLs.
local M = {}

local function previous_is(value, position, character_class)
  if position <= 1 then return false end
  return value:sub(position - 1, position - 1):match(character_class) ~= nil
end

local function find_plain(value, needle, start)
  return value:find(needle, start or 1, true)
end

local function ascii_lower(value)
  return (value:gsub("[A-Z]", function(character)
    return string.char(character:byte() + 32)
  end))
end

local function provider_token(value, lower, prefix, minimum, suffix_class)
  local start = 1
  while true do
    local first, last = find_plain(lower, prefix, start)
    if not first then return false end
    local suffix = value:sub(last + 1):match("^(" .. suffix_class .. "+)") or ""
    if #suffix >= minimum then return true end
    start = first + 1
  end
end

function M.contains_credential(value)
  if type(value) ~= "string" then return false end
  -- Credential syntax uses ASCII case folding and ASCII whitespace. Do not let
  -- Lua locale behavior drift from the controller's explicit Python grammar.
  local lower = ascii_lower(value)
  local whitespace = "[ \t\n\r\f\v]"
  local ascii_value = "[!-~]"
  for _, name in ipairs({ "authorization", "proxy-authorization" }) do
    local start = 1
    while true do
      local first, last = find_plain(lower, name, start)
      if not first then break end
      if not previous_is(lower, first, "[A-Za-z0-9_]") then
        local candidate = lower:sub(last + 1)
        for _, scheme in ipairs({ "basic", "bearer" }) do
          if candidate:match("^" .. whitespace .. "*:" .. whitespace .. "*" .. scheme .. whitespace .. "+" .. ascii_value .. "+") then return true end
        end
      end
      -- A failed boundary candidate may contain the beginning of another
      -- authorization candidate. Resume at the next possible candidate start.
      start = first + 1
    end
  end

  -- Match the controller's URI recognizers: a scheme starts at the first valid
  -- scheme character, then user-info or non-empty query/fragment data rejects.
  local uri_start = 1
  while true do
    local first, _, after = lower:match("()([a-z][a-z0-9+%.%-]*)://()", uri_start)
    if not first then break end
    if not previous_is(lower, first, "[A-Za-z0-9+%.%-]") then
      local remainder = value:sub(after)
      local at = remainder:find("@", 1, true)
      if at then
        local valid_userinfo = true
        for index = 1, at - 1 do
          local byte = remainder:byte(index)
          if byte < 33 or byte > 126 or byte == 47 or byte == 64 then valid_userinfo = false; break end
        end
        if valid_userinfo then return true end
      end
      local token = remainder:match("^([!-~]+)") or ""
      local marker = token:find("[?#]")
      if marker and marker > 1 then
        local kind = token:sub(marker, marker)
        local following = token:sub(marker + 1)
        if kind == "?" then
          if following:sub(1, 1) == "#" then
            if following:sub(2) ~= "" then return true end
          elseif following ~= "" then return true end
        elseif following ~= "" then return true end
      end
    end
    uri_start = after
  end

  local names = {
    "access_token", "access-token", "accesstoken", "api_key", "api-key", "apikey", "authorization",
    "credential", "password", "secret", "token",
  }
  for _, name in ipairs(names) do
    for _, marker in ipairs({ "?", "&", "#" }) do
      local query_start = 1
      while true do
        local _, last = find_plain(lower, marker .. name .. "=", query_start)
        if not last then break end
        local byte = lower:byte(last + 1)
        if byte and byte >= 33 and byte <= 126 and byte ~= 35 and byte ~= 38 then return true end
        query_start = last + 1
      end
    end
    local start = 1
    while true do
      local first, last = find_plain(lower, name, start)
      if not first then break end
      if not previous_is(lower, first, "[A-Za-z0-9_%-]") and lower:sub(last + 1):match("^" .. whitespace .. "*[=:]" .. whitespace .. "*" .. ascii_value .. "+") then return true end
      start = first + 1
    end
  end

  local provider_patterns = {
    { "ghs_", 36, "[A-Za-z0-9._%-]" },
    { "gho_", 36, "[A-Za-z0-9]" }, { "ghp_", 36, "[A-Za-z0-9]" },
    { "ghu_", 36, "[A-Za-z0-9]" }, { "ghr_", 36, "[A-Za-z0-9]" },
    { "github_pat_", 20, "[A-Za-z0-9_]" },
    { "glpat-", 20, "[A-Za-z0-9_%-]" }, { "glcbt-", 20, "[A-Za-z0-9_%-]" },
    { "glptt-", 20, "[A-Za-z0-9_%-]" }, { "glrt-", 20, "[A-Za-z0-9_%-]" },
    { "glimt-", 20, "[A-Za-z0-9_%-]" }, { "glsoat-", 20, "[A-Za-z0-9_%-]" },
    { "gldt-", 20, "[A-Za-z0-9_%-]" }, { "glrtr-", 20, "[A-Za-z0-9_%-]" },
    { "glft-", 20, "[A-Za-z0-9_%-]" }, { "glagent-", 20, "[A-Za-z0-9_%-]" },
    { "glwt-", 20, "[A-Za-z0-9_%-]" }, { "glffct-", 20, "[A-Za-z0-9_%-]" },
    { "gloas-", 20, "[A-Za-z0-9_%-]" },
    { "sk-", 20, "[A-Za-z0-9_%-]" }, { "aiza", 30, "[A-Za-z0-9_%-]" },
    { "hf_", 20, "[A-Za-z0-9]" },
    { "xoxb-", 20, "[A-Za-z0-9%-]" }, { "xoxa-", 20, "[A-Za-z0-9%-]" },
    { "xoxp-", 20, "[A-Za-z0-9%-]" }, { "xoxr-", 20, "[A-Za-z0-9%-]" },
    { "xoxs-", 20, "[A-Za-z0-9%-]" }, { "xapp-", 20, "[A-Za-z0-9%-]" },
    { "xwfp-", 20, "[A-Za-z0-9%-]" },
    { "akia", 16, "[A-Za-z0-9]" }, { "asia", 16, "[A-Za-z0-9]" },
  }
  for _, item in ipairs(provider_patterns) do
    if provider_token(value, lower, item[1], item[2], item[3]) then return true end
  end
  return lower:find("-----begin [a-z ]*private key-----") ~= nil
end

return M
