# faltoo.nvim

A small Neovim proof-of-concept for running FaltooBot review sessions directly inside Neovim.

## Requirements

- Neovim 0.10+
  - Neovim 0.12+ if you want to use built-in `vim.pack`
- One agent backend:
  - `faltoobot` installed, configured, and available on `$PATH` (default). Install it however you prefer, such as `uv`, `pipx`, or `brew`.
  - Or the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI `claude` on `$PATH`, logged in with your Claude subscription or an API key.

### Claude Code backend

```lua
require("faltoo").setup({ backend = "claude" })
```

Prompts go to `claude -p --continue`, so each submit continues the most recent Claude conversation in the current directory, including one you started in a terminal. History reads the newest session file in `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`). `/reset` makes the next submit start a new conversation. FaltooBot-only commands like `/run-hooks` are not available.

#### Permissions

`claude -p` cannot ask for approval, so Faltoo runs it with `--permission-mode bypassPermissions` by default: Claude can edit files and run any command, like committing, without asking. Pick a stricter [permission mode](https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes) with `permission_mode`:

```lua
require("faltoo").setup({ backend = "claude", permission_mode = "acceptEdits" })
```

With `acceptEdits`, edits are auto-accepted but commands not allowed in your Claude settings are denied. Allow the commands you trust in `.claude/settings.json` in your project, or in `~/.claude/settings.json` for all projects:

```json
{
  "permissions": {
    "allow": ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git commit:*)", "Bash(git push:*)"]
  }
}
```

`Bash(git commit:*)` allows any command starting with `git commit`. Run `/permissions` inside an interactive `claude` session to review or edit the rules.

## Setup

With Neovim 0.12+ built-in `vim.pack`, add this to your `init.lua`:

```lua
vim.pack.add({ "https://github.com/pratyushmittal/faltoo.nvim" })
require("faltoo").setup()
```

Review mode auto-starts for `nvim .`. Opening a file directly, like `nvim some-file`, only registers commands.

If you use Neovim 0.10 or 0.11, `vim.pack` is not available. Use another plugin manager and call `require("faltoo").setup()`. For example, with lazy.nvim:

```lua
{
  "pratyushmittal/faltoo.nvim",
  config = function()
    require("faltoo").setup()
  end,
}
```

## Commands

```vim
:faltoo on
:faltoo off
:faltoo tree
```

`faltoo.nvim` also defines `:Faltoo`; the lowercase `:faltoo` form is a command-line abbreviation. `:Faltoo tree` opens the current workspace session `messages.json` with the system `open` command.

## Keybindings in Review Mode

When review mode is on, review buffers are marked readonly / not modifiable.

Review commands:

- `:Faltoo comment` opens a multiline modal for a line review comment on the current line or visual selection.
- `:Faltoo file-comment` opens a multiline modal for a file-level review comment on the current buffer.
- `:Faltoo submit` submits a saved Ask AI question if one exists; otherwise it submits prepared review comments and reloads review buffers from disk.
- `:Faltoo history` opens a readable message-history modal at the latest message. If the assistant is answering, the modal shows the live assistant/tool stream as the latest message.
- `:Faltoo ask` opens a textarea modal to ask AI.
- `:Faltoo reset` starts a fresh FaltooBot session for the workspace.
- `:Faltoo open-unstaged` opens current unstaged git files as buffers and closes saved normal buffers outside that set.
- `:Faltoo next-comment` / `:Faltoo prev-comment` jump between pending comments in the current buffer.

Default review-mode keybindings:

```lua
require("faltoo").setup({
  mappings = {
    comment = "c", -- line review comment
    file_comment = "C", -- file-level review comment
    history = "<leader>f", -- open message history
    ask = "<leader>a", -- ask AI directly
    submit = "<S-CR>", -- submit saved question or pending comments
    open_unstaged = "R", -- open unstaged git files
    next_comment = "]c", -- jump to next pending comment
    prev_comment = "[c", -- jump to previous pending comment
    -- ask = false, -- disable one mapping
  },
})
```

Comment modal keybindings:

The comment modal shows the target file, line range, and selected code above the editor.

- `<Enter>` submits the comment.
- `<S-CR>` inserts a newline.
- `@` opens a repository file picker and inserts `` `relative/path` ``. It uses Telescope when available, otherwise `vim.ui.select`.
- `<C-s>` also submits the comment.
- Insert-mode `<Esc>` enters normal mode; normal-mode `<Esc>` or `q` cancels.

Re-commenting an already-marked line opens the existing comment for editing instead of adding a duplicate; submitting it empty deletes it.

Ask modal keybindings:

- `<Enter>` saves the question and closes the modal.
- `<S-CR>` inserts a newline.
- `@` opens a repository file picker and inserts `` `relative/path` ``. It uses Telescope when available, otherwise `vim.ui.select`.
- Leading `/` opens built-in and saved FaltooBot slash commands. `/run-hooks` asks which Git changes to check; `/reset` starts a fresh session.
- `<C-s>` also saves the question.
- Normal-mode `<Esc>` or `q` cancels.

After saving a question, press `<S-CR>` from a review buffer or run `:Faltoo submit` to fetch the assistant response.

Message-history modal keybindings:

- `p` or `[` jumps to the previous message.
- `n` or `]` jumps to the next message.
- `r` opens Ask Faltoo for a follow-up. In visual mode it quotes the selection, appending to any saved question.
- `<Esc>` or `q` closes the modal.

## Statusline and Indicators

- Lines with pending line comments show `*` in the gutter.
- The terminal title shows the workspace name and adds `・answering` while a response is running.
- A terminal bell rings when the response completes.
- Normal quit/restart is blocked while review comments, a saved Ask AI question, or a Faltoo request is pending.
- `require("faltoo").status()` returns answering state, saved question state, and pending comment count for statusline integration.

Statusline indicator example:

```lua
vim.o.statusline = vim.o.statusline .. "%{v:lua.require('faltoo').status()}"
```

## Development

Lua/Python formatting and diagnostics run through pre-commit. StyLua formats Lua files, LuaLS checks workspace diagnostics, Ruff formats/lints `python/faltoo_bridge.py`, and ty type-checks it.

```sh
brew install pre-commit lua-language-server uv
pre-commit install
pre-commit run --all-files
nvim --headless -u NONE -c "set rtp^=." -S tests/e2e.lua
nvim --headless -u NONE -c "set rtp^=." -S tests/claude_e2e.lua
```

The LuaLS hook falls back to Mason's `~/.local/share/nvim/mason/bin/lua-language-server` when it is not on `$PATH`. Ruff and ty run through `uvx`. Both headless E2E tests are also wired into pre-commit.

This is intentionally minimal. The plugin stores pending comments in Lua memory and uses `python/faltoo_bridge.py` to read/write FaltooBot sessions through `faltoobot.sessions`.
