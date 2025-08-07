local M = {}

-- enhanced TODO parsing that includes UUID information
local function parse_todos_with_uuids(bufnr)
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

		if text and date then
			local uuid = nil

			-- Check if the next line contains a UUID comment
			if i < #lines then
				local next_line = lines[i + 1]
				local potential_uuid = next_line:match("<!%-%- TW%-UUID: ([a-f0-9%-]+) %-%->")
				-- Validate UUID format (TaskWarrior UUIDs are 36 chars with hyphens)
				if potential_uuid and #potential_uuid >= 32 then
					uuid = potential_uuid
				end
			end

			table.insert(todos, {
				text = vim.trim(text),
				due = date,
				line_num = i,
				bufnr = bufnr,
				uuid = uuid,
				has_uuid = uuid ~= nil,
				original_line = line,
			})
		end
	end

	return todos
end

-- verify if a TaskWarrior task still exists
local function verify_task_exists(uuid)
	if not uuid then
		return false
	end

	local cmd = string.format("task _get %s.uuid 2>/dev/null", uuid)
	local output = vim.fn.system(cmd)
	local exit_code = vim.v.shell_error

	return exit_code == 0 and output:match(uuid) ~= nil
end

function M.debug_taskwarrior()
	local current_buf = vim.api.nvim_get_current_buf()
	local todos = parse_todos_with_uuids(current_buf)

	print("=== TaskWarrior Debug Info ===")
	print("Buffer number: " .. current_buf)
	print("Buffer name: " .. vim.api.nvim_buf_get_name(current_buf))
	print("TODOs found: " .. #todos)

	-- Show all lines for debugging
	local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
	print("\nAll buffer lines:")
	for i, line in ipairs(lines) do
		print(string.format("Line %d: '%s'", i, line))
	end

	print("\nParsed TODOs:")
	for i, todo in ipairs(todos) do
		print(
			string.format(
				"TODO %d: '%s' due: %s (line %d) has_uuid: %s",
				i,
				todo.text,
				todo.due,
				todo.line_num,
				tostring(todo.has_uuid)
			)
		)
		if todo.uuid then
			print(string.format("  UUID: %s", todo.uuid))
		end
	end

	-- Test TaskWarrior availability
	local tw_available = vim.fn.executable("task") == 1
	print("\nTaskWarrior executable found: " .. tostring(tw_available))

	if tw_available then
		local version_output = vim.fn.system("task --version 2>&1")
		local version_exit = vim.v.shell_error
		print("TaskWarrior version check exit code: " .. version_exit)
		print("TaskWarrior version output: " .. vim.trim(version_output))

		-- Test basic TaskWarrior functionality
		print("\nTesting basic TaskWarrior commands:")

		-- Test 1: Check if TaskWarrior database is initialized
		local init_test = vim.fn.system("task _get rc.verbose=nothing 2>&1")
		local init_exit = vim.v.shell_error
		print("Database init test exit code: " .. init_exit)
		print("Database init test output: '" .. vim.trim(init_test) .. "'")

		-- Test 2: Count existing tasks
		local count_cmd = "task count 2>&1"
		local count_output = vim.fn.system(count_cmd)
		local count_exit = vim.v.shell_error
		print("Task count exit code: " .. count_exit)
		print("Task count output: '" .. vim.trim(count_output) .. "'")

		-- Test 3: Try adding a simple test task
		local test_cmd = "task add 'Debug test task from Neovim plugin' project:DEBUG rc.verbose=nothing 2>&1"
		print("Executing test command: " .. test_cmd)
		local test_output = vim.fn.system(test_cmd)
		local test_exit = vim.v.shell_error
		print("Test task add exit code: " .. test_exit)
		print("Test task add output: '" .. vim.trim(test_output) .. "'")

		if test_exit == 0 then
			-- Test 4: Get the UUID of the test task
			local uuid_cmd = "task _get rc.verbose=nothing +LATEST.uuid 2>&1"
			print("Executing UUID command: " .. uuid_cmd)
			local uuid_output = vim.fn.system(uuid_cmd)
			local uuid_exit = vim.v.shell_error
			print("UUID get exit code: " .. uuid_exit)
			print("UUID get output: '" .. vim.trim(uuid_output) .. "'")

			if uuid_exit == 0 and vim.trim(uuid_output) ~= "" then
				local test_uuid = vim.trim(uuid_output)
				print("Test UUID: " .. test_uuid .. " (length: " .. #test_uuid .. ")")

				-- Test 5: Verify we can read the task back using our function
				local exists = verify_task_exists(test_uuid)
				print("Task exists check: " .. tostring(exists))

				-- Test 6: Get task description
				local verify_cmd = "task _get " .. test_uuid .. ".description 2>&1"
				local verify_output = vim.fn.system(verify_cmd)
				local verify_exit = vim.v.shell_error
				print("Verify task exit code: " .. verify_exit)
				print("Verify task output: '" .. vim.trim(verify_output) .. "'")

				-- Clean up test task
				local cleanup_cmd = "task " .. test_uuid .. " delete rc.confirmation=off 2>&1"
				local cleanup_result = vim.fn.system(cleanup_cmd)
				print("Cleanup result: " .. vim.trim(cleanup_result))
			else
				print("ERROR: Could not get UUID for test task")
			end
		else
			print("ERROR: Could not create test task")

			-- Check if it's a configuration issue
			if test_output:match("configuration") or test_output:match("Could not") then
				print("This looks like a TaskWarrior configuration issue.")
				print("Try running 'task add test' in your terminal to initialize TaskWarrior.")
			end
		end
	end

	print("=== End Debug Info ===")
end

return M
