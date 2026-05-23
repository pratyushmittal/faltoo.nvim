# faltoo.nvim

A small Neovim proof-of-concept for running FaltooBot review sessions directly inside Neovim.

## Requirements

- Neovim 0.10+
- `faltoobot` installed, configured, and available on `$PATH`

Install `faltoobot` however you prefer, such as `uv`, `pipx`, or `brew`.

## Setup

With `vim.pack`, add this to your `init.lua`:

```lua
vim.pack.add({ "https://github.com/pratyushmittal/faltoo.nvim" })
require("faltoo").setup()
```

With any other plugin manager, install `https://github.com/pratyushmittal/faltoo.nvim` and call `require("faltoo").setup()`.

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
- `:Faltoo open-unstaged` opens current unstaged git files as buffers and closes saved normal buffers outside that set.

Review mode installs these buffer-local keybindings on readonly review buffers. These are the defaults:

```lua
require("faltoo").setup({
  mappings = {
    comment = "c", -- line review comment
    file_comment = "C", -- file-level review comment
    history = "<leader>f", -- open message history
    ask = "<leader>a", -- ask AI directly
    submit = "<S-CR>", -- submit saved question or pending comments
    open_unstaged = "R", -- open unstaged git files
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
- Leading `/` opens saved FaltooBot slash commands.
- `<C-s>` also saves the question.
- Normal-mode `<Esc>` or `q` cancels.

After saving a question, press `<S-CR>` from a review buffer or run `:Faltoo submit` to fetch the assistant response.

Message-history modal keybindings:

- `p` or `[` jumps to the previous message.
- `n` or `]` jumps to the next message.
- `r` opens Ask Faltoo for a follow-up.
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
```

The LuaLS hook falls back to Mason's `~/.local/share/nvim/mason/bin/lua-language-server` when it is not on `$PATH`. Ruff and ty run through `uvx`. The headless E2E test is also wired into pre-commit.

This is intentionally minimal. The plugin stores pending comments in Lua memory and uses `python/faltoo_bridge.py` to read/write FaltooBot sessions through `faltoobot.sessions`.
