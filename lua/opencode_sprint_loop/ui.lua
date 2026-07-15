--- Disposable floating progress window.
local M = { buffer = nil, window = nil }

function M.show(lines)
  if M.window and vim.api.nvim_win_is_valid(M.window) then vim.api.nvim_win_close(M.window, true) end
  if M.buffer and vim.api.nvim_buf_is_valid(M.buffer) then vim.api.nvim_buf_delete(M.buffer, { force = true }) end
  local columns, rows = vim.o.columns, vim.o.lines
  local width = math.max(20, math.min(columns - 2, math.max(20, math.floor(columns * 0.75))))
  local height = math.max(3, math.min(rows - 2, math.max(3, math.min(#lines + 2, math.floor(rows * 0.75)))))
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"; vim.bo[buffer].bufhidden = "wipe"; vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor", style = "minimal", border = "rounded", width = width, height = height,
    row = math.max(0, math.floor((rows - height) / 2 - 1)), col = math.max(0, math.floor((columns - width) / 2)),
    title = " Sprint Loop ", title_pos = "center",
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end end, { buffer = buffer, silent = true })
  end
  M.buffer, M.window = buffer, window
end

return M
