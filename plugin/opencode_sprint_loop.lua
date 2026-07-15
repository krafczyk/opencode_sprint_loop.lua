if vim.g.loaded_opencode_sprint_loop then return end
vim.g.loaded_opencode_sprint_loop = true

require("opencode_sprint_loop")._register_commands()
