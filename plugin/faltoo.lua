if vim.g.loaded_faltoo_nvim == 1 then
  return
end
vim.g.loaded_faltoo_nvim = 1

require("faltoo").setup()
