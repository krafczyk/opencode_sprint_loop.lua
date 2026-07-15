local loop = require("opencode_sprint_loop")

loop.setup({
  executable = assert(vim.env.SPRINT_LOOP_FAKE_EXECUTABLE),
  sprint_root = assert(vim.env.SPRINT_LOOP_TEST_ROOT),
  server_url = "http://127.0.0.1:4096",
})
loop.start()
assert(vim.wait(1000, function() return loop._test_state().watching end, 5), "detached child did not spawn")
vim.cmd("qa!")
