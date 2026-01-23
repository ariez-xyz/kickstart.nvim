local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local make_entry = require 'telescope.make_entry'
local conf = require('telescope.config').values

local M = {}

local find_include_dirs = function(opts)
  opts = opts or {}
  opts.cwd = opts.cwd or vim.uv.cwd()

  local exclude_patterns = {
    'venv',
    '.venv',
    'node_modules',
    '.git',
    '__pycache__',
    '.pytest_cache',
    'build',
    'dist',
    '.tox',
    'vendor',
  }

  local fd_cmd = vim.fn.executable 'fd' == 1 and 'fd' or 'fdfind'
  local has_fd = vim.fn.executable(fd_cmd) == 1

  if not has_fd then
    vim.notify('fdfind is not installed. Please install fd to use this feature.', vim.log.levels.WARN)
    return
  end

  local fdfind_args = { 'fdfind' }
  for _, pattern in ipairs(exclude_patterns) do
    table.insert(fdfind_args, '--exclude')
    table.insert(fdfind_args, pattern)
  end

  local finder = finders.new_oneshot_job(fdfind_args, {
    entry_maker = make_entry.gen_from_file(opts),
    cwd = opts.cwd,
  })
  pickers
    .new(opts, {
      --debounce = 100,
      prompt_title = 'Search files',
      finder = finder,
      previewer = conf.grep_previewer(opts),
      sorter = require('telescope.sorters').get_generic_fuzzy_sorter(),
    })
    :find()
end

M.setup = function()
  vim.keymap.set('n', '<leader><leader>', find_include_dirs, { desc = '[ ] Search Files' })
end

return M
