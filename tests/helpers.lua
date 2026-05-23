local M = {}

function M.contains(text, expected)
  if not text:find(expected, 1, true) then
    error("Expected to find `" .. expected .. "` in:\n" .. text)
  end
end

function M.buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function M.has_map(buf, mode, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if item.lhs == lhs then
      return true
    end
  end
  return false
end

function M.press(buf, mode, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if item.lhs == lhs then
      if item.callback then
        item.callback()
        return
      end

      if item.rhs and item.rhs ~= "" then
        local keys = vim.api.nvim_replace_termcodes(item.rhs, true, false, true)
        vim.api.nvim_feedkeys(keys, "xt", false)
        return
      end
    end
  end
  error("Missing " .. mode .. " mapping: " .. lhs)
end

return M
