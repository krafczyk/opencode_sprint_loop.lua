vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.expand("<sfile>"), ":h:h"))
vim.cmd("runtime plugin/opencode_sprint_loop.lua")
