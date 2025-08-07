-- lua/todo-notify/init.lua
local M = {}

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

    if text and date then
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
              notify("TODO Due Soon", task.text .. " (due " .. task.due .. ", " .. hours_left .. "h left)")
              found_tasks = found_tasks + 1
            end
          end
        end
      end
    end
  end

  if found_tasks == 0 then
    notify("TODO Check", "No urgent TODOs found")
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
function M.cleanup_orphaned_uuids()
  local current_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
  local cleaned_count = 0
  local lines_to_remove = {}

  for i, line in ipairs(lines) do
    local uuid = line:match("<!%-%- TW%-UUID: ([a-f0-9%-]+) %-%->")
    if uuid then
      -- Check if task still exists in TaskWarrior
      local handle = io.popen("task _get " .. uuid .. ".uuid 2>/dev/null")
      if handle then
        local result = handle:read("*a")
        handle:close()

        if not result or not result:match(uuid) then
          -- Task no longer exists, mark line for removal
          table.insert(lines_to_remove, i)
          cleaned_count = cleaned_count + 1
        end
      end
    end
  end

  -- Remove lines in reverse order to maintain correct indices
  for i = #lines_to_remove, 1, -1 do
    local line_num = lines_to_remove[i]
    vim.api.nvim_buf_set_lines(current_buf, line_num - 1, line_num, false, {})
  end

  if cleaned_count > 0 then
    notify("TaskWarrior", "Cleaned up " .. cleaned_count .. " orphaned UUIDs")
  else
    notify("TaskWarrior", "No orphaned UUIDs found")
  end
end
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
      local cmd = string.format('task add "%s" due:%s project:TODO 2>/dev/null', task.text:gsub('"', '\\"'), task.due)

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

-- start up
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

  -- Create timer for periodic checking (every hour)
  if timer then
    timer:stop()
    timer:close()
  end

  timer = vim.loop.new_timer()
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

-- cleanup function
function M.cleanup()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

return M
