# todo-notify

A neovim plugin and daemon to add tasks to taskwarrior from markdown files and notify when tasks are due.

In markdown files add any of these variations to add a task that will be recognized by todo-notify.nvim.

`TODO: Your todo here @due(YYYY-MM-DD)`
`- [ ] TODO: Your todo here @due(YYYY-MM-DD)`
`* [ ] TODO: Your todo here @due(YYYY-MM-DD)`

Add a task to taskwarrior with `TodoSync`
Clean old tasks with `TodoCleanUp`
Debug with `TodoDebug`

**ROADMAP:**

- [ ] Ensure UUIDs are added to the markdown task encased in comments (`<!---->`)
      Example:

  ```
  TODO: pick up the trash @due(2025-08-06)
  <!-- TW-UUID: 9eaoin-30083h-1on08n-89hogn-asuhd8 -->
  ```

- [ ] Stick to Obsidian tasks conventions
- [ ] Add user specification of task `project` in config
- [ ] Add user specification of directory that holds markdown files
- [ ] Rewrite [daemon](todo-notify.nvim/daemon.py) in Go
- [ ]
