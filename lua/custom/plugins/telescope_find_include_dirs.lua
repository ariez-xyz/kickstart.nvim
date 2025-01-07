local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local make_entry = require 'telescope.make_entry'
local conf = require('telescope.config').values

local M = {}

local find_include_dirs = function(opts)
  opts = opts or {}
  opts.cwd = opts.cwd or vim.uv.cwd()

  local finder = finders.new_oneshot_job({ 'fdfind' }, {
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
  vim.keymap.set('n', '<leader>sf', find_include_dirs, { desc = '[S]earch [F]iles' })
end

return M
