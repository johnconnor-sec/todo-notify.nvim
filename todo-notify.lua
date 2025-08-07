return {
	{
		name = "johnconnor-sec/todo-notify.nvim",

		-- load on these filetypes/events/commands:
		ft = { "markdown" },
		event = { "BufReadPost", "BufNewFile" },
		cmd = { "TodoCheck", "TodoSync" },

		-- your defaults, overrideable via lazy setup
		opts = {
			markdown_ext = { ".md", ".markdown" },
			notify_threshold_hours = 24,
			-- alert_before_days = 3,
			-- alert_overdue = true,
			-- check_interval = 1000,
		},

		-- run after loading the module
		config = function(_, opts)
			require("todo-notify").setup(opts)
		end,
	},
}
