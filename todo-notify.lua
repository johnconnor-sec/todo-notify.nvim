-- ~/.config/nvim/lua/plugins/todo_notify.lua
-- ~/.config/nvim/lua/plugins/todo_notify.lua
return {
  {
    name = "todo-notify",
    -- tell lazy.nvim "this is a local plugin, load from this dir"
    dir = vim.fn.stdpath("config") .. "/lua/todo-notify",

    -- load on these filetypes/events/commands:
    ft = { "markdown" },
    event = { "BufReadPost", "BufNewFile" },
    cmd = { "TodoCheck", "TodoSync" },

    -- your defaults, overrideable via lazy setup
    opts = {
      markdown_ext = { ".md", ".markdown" },
      notify_threshold_hours = 24,
    },

    -- run after loading the module
    config = function(_, opts)
      require("todo-notify").setup(opts)
    end,
  },
}
