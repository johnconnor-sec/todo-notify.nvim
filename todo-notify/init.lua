-- lua/todo-notify/init.lua
local M = {}
M.debug_taskwarrior = require("todo-notify.debug").debug_taskwarrior

-- configuration
M.opts = {
	markdown_ext = { ".md", ".markdown" },
	notify_threshold_hours = 24,
}

-- parse lines for TODO and a @due(...) tag (simple version for basic functionality)
local function parse_todos(bufnr)
	local todos = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		-- Match various TODO formats:
		-- TODO: text @due(date)
		-- - [ ] TODO: text @due(date)
		-- * TODO: text @due(date)
		local text, date = line:match("TODO:(.-)@due%(([%d%-]+)%)")
		if not text then
			-- Try checkbox format: - [ ] TODO: text @due(date)
			text, date = line:match("%-%s*%[%s*%]%s*TODO:(.-)@due%(([%d%-]+)%)")
		end
		if not text then
			-- Try bullet format: * TODO: text @due(date)
			text, date = line:match("%*%s*TODO:(.-)@due%(([%d%-]+)%)")
		end

		local exists = task_exists_by_uuid(uuid)
		if text and date and not exists then
			table.insert(todos, {
				text = vim.trim(text),
				due = date,
				line_num = i,
				bufnr = bufnr,
				original_line = line,
			})
		end
	end
	return todos
end

local function notify(title, msg)
	-- Check if we're in a GUI environment
	if os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY") then
		vim.fn.jobstart({ "notify-send", title, msg }, { detach = true })
	end

	-- Also show in Neovim if available
	if vim.notify then
		vim.notify(msg, vim.log.levels.INFO, { title = title })
	else
		print(title .. ": " .. msg)
	end
end

-- parse date string to timestamp
local function parse_date(date_str)
	local year, month, day = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
	if year and month and day then
		return os.time({
			year = tonumber(year),
			month = tonumber(month),
			day = tonumber(day),
			hour = 0,
			min = 0,
			sec = 0,
		})
	end
	return nil
end

-- check for due or upcoming tasks
function M.check_due_tasks()
	local found_tasks = 0

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		-- Check if buffer is loaded and has a name
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)

			-- Check if it's a markdown file
			local is_markdown = false
			for _, ext in ipairs(M.opts.markdown_ext) do
				if name:match(ext .. "$") then
					is_markdown = true
					break
				end
			end

			if is_markdown then
				for _, task in ipairs(parse_todos(bufnr)) do
					local due_ts = parse_date(task.due)
					if due_ts then
						local now = os.time()
						local diff = due_ts - now
						local threshold = M.opts.notify_threshold_hours * 3600

						if diff < 0 then
							-- overdue
							notify("TODO Overdue", task.text .. " (was due " .. task.due .. ")")
							found_tasks = found_tasks + 1
						elseif diff >= 0 and diff < threshold then
							-- due within threshold
							local hours_left = math.floor(diff / 3600)
							notify(
								"TODO Due Soon",
								task.text .. " (due " .. task.due .. ", " .. hours_left .. "h left)"
							)
							found_tasks = found_tasks + 1
						end
					end
				end
			end
		end
	end
end

-- get existing TaskWarrior UUIDs from buffer metadata
local function get_tracked_uuids(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local uuids = {}

	for _, line in ipairs(lines) do
		-- Look for hidden comments with UUIDs: <!-- TW-UUID: uuid -->
		local uuid = line:match("<!%-%- TW%-UUID: ([a-f0-9%-]+) %-%->")
		if uuid then
			table.insert(uuids, uuid)
		end
	end

	return uuids
end

-- add UUID comment after a TODO line
local function add_uuid_comment(bufnr, line_num, uuid)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
	if #lines > 0 then
		-- Insert UUID comment on the next line
		vim.api.nvim_buf_set_lines(bufnr, line_num, line_num, false, {
			"<!-- TW-UUID: " .. uuid .. " -->",
		})
	end
end

-- check if task exists in TaskWarrior by UUID
local function task_exists_by_uuid(uuid)
	local handle = io.popen("task _get " .. uuid .. ".uuid 2>/dev/null")
	if handle then
		local result = handle:read("*a")
		handle:close()
		return result:match(uuid) ~= nil
	end
	return false
end

-- debug function to test TaskWarrior integration

function M.sync_to_taskwarrior()
	local current_buf = vim.api.nvim_get_current_buf()
	local todos = parse_todos(current_buf)
	local existing_uuids = get_tracked_uuids(current_buf)
	local synced_count = 0
	local failed_count = 0

	if #todos == 0 then
		notify("TaskWarrior", "No TODOs found to sync")
		return
	end

	for _, task in ipairs(todos) do
		-- Check if this line already has a UUID tracked
		local has_uuid = false
		local lines = vim.api.nvim_buf_get_lines(current_buf, task.line_num, task.line_num + 1, false)
		if #lines > 0 then
			has_uuid = lines[1]:match("<!%-%- TW%-UUID:")
		end

		if not has_uuid then
			-- Create new task in TaskWarrior
			local cmd =
				string.format('task add "%s" due:%s project:TODO 2>/dev/null', task.text:gsub('"', '\\"'), task.due)

			-- Execute and capture the UUID
			local handle = io.popen(cmd .. " && task _get +LATEST.uuid")
			if handle then
				local output = handle:read("*a")
				local exit_code = handle:close()

				if exit_code and output and #output > 0 then
					local uuid = output:match("([a-f0-9%-]+)")
					if uuid then
						-- Add UUID comment to the buffer
						add_uuid_comment(current_buf, task.line_num, uuid)
						synced_count = synced_count + 1
					else
						failed_count = failed_count + 1
					end
				else
					failed_count = failed_count + 1
				end
			else
				failed_count = failed_count + 1
			end
		end
	end

	local msg = string.format("Synced %d new TODOs", synced_count)
	if failed_count > 0 then
		msg = msg .. string.format(", %d failed", failed_count)
	end
	notify("TaskWarrior", msg)
end

-- Create a timer for periodic checks
local timer = nil

-- cleanup orphaned UUID comments
-- function M.cleanup_orphaned_uuids()
-- 	local current_buf = vim.api.nvim_get_current_buf()
-- 	local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
-- 	local cleaned_count = 0
-- 	local lines_to_remove = {}
--
-- 	for i, line in ipairs(lines) do
-- 		local uuid = line:match("<!%-%- TW%-UUID: ([a-f0-9%-]+) %-%->")
-- 		if uuid then
-- 			-- Check if task still exists in TaskWarrior
-- 			local handle = io.popen("task _get " .. uuid .. ".uuid 2>/dev/null")
-- 			if handle then
-- 				local result = handle:read("*a")
-- 				handle:close()
--
-- 				if not result or not result:match(uuid) then
-- 					-- Task no longer exists, mark line for removal
-- 					table.insert(lines_to_remove, i)
-- 					cleaned_count = cleaned_count + 1
-- 				end
-- 			end
-- 		end
-- 	end
--
-- 	-- Remove lines in reverse order to maintain correct indices
-- 	for i = #lines_to_remove, 1, -1 do
-- 		local line_num = lines_to_remove[i]
-- 		vim.api.nvim_buf_set_lines(current_buf, line_num - 1, line_num, false, {})
-- 	end
--
-- 	if cleaned_count > 0 then
-- 		notify("TaskWarrior", "Cleaned up " .. cleaned_count .. " orphaned UUIDs")
-- 	else
-- 		notify("TaskWarrior", "No orphaned UUIDs found")
-- 	end
-- end

-- cleanup function
function M.cleanup()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

-- start up
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

	-- Create timer for periodic checking (every hour)
	if timer then
		timer:stop()
		timer:close()
	end

	timer = vim.loop.new_timer and vim.loop.new_timer()
	if timer then
		timer:start(
			0,
			60 * 60 * 1000,
			vim.schedule_wrap(function()
				M.check_due_tasks()
			end)
		)
	end

	-- user commands
	vim.api.nvim_create_user_command("TodoCheck", function()
		require("todo-notify").check_due_tasks()
	end, { desc = "Check for due TODOs" })

	vim.api.nvim_create_user_command("TodoSync", function()
		require("todo-notify").sync_to_taskwarrior()
	end, { desc = "Sync TODOs to TaskWarrior" })

	vim.api.nvim_create_user_command("TodoCleanup", function()
		require("todo-notify").cleanup_orphaned_uuids()
	end, { desc = "Clean up orphaned TaskWarrior UUIDs" })

	vim.api.nvim_create_user_command("TodoDebug", function()
		require("todo-notify").debug_taskwarrior()
	end, { desc = "Debug TaskWarrior integration" })

	-- Auto-check when opening markdown files
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		pattern = { "*.md", "*.markdown" },
		callback = function()
			vim.defer_fn(function()
				M.check_due_tasks()
			end, 1000) -- delay 1 second to avoid spam
		end,
		desc = "Check TODOs when opening/saving markdown files",
	})
end

return M
