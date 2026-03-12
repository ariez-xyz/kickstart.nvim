local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local previewers = require 'telescope.previewers'
local actions = require 'telescope.actions'
local action_state = require 'telescope.actions.state'

local M = {}

local function resolve_journal_dir(opts)
  local dir = opts.journal_dir or vim.g.journal_dir or vim.env.JOURNAL_DIR
  if not dir or dir == '' then
    local fallback_dirs = { vim.fn.expand '~/Projects/jrnl', vim.fn.expand '~/P/jrnl' }
    for _, candidate in ipairs(fallback_dirs) do
      if vim.loop.fs_stat(candidate) then
        dir = candidate
        break
      end
    end
  else
    dir = vim.fn.expand(dir)
  end

  if not vim.loop.fs_stat(dir) then
    return nil, 'Journal directory not found: ' .. tostring(dir)
  end
  return vim.loop.fs_realpath(dir) or vim.fn.expand(dir), nil
end

local function day_dirs(root)
  local entries = {}
  local children = vim.fn.glob(root .. '/*', false, true) ---@type string[]

  for _, child in ipairs(children) do
    if vim.fn.isdirectory(child) == 1 then
      local name = vim.fn.fnamemodify(child, ':t')
      if name:match '^%d%d%d%d%-%d%d%-%d%d$' then
        table.insert(entries, { day = name, entry = child .. '/entry.md' })
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.day > b.day
  end)

  return entries
end

local function open_or_create_entry(path)
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')

  local stat = vim.loop.fs_stat(path)
  if not stat then
    local date_header = '# ' .. os.date '%b %d, %Y'
    local ok, err = pcall(vim.fn.writefile, { date_header }, path)
    if not ok then
      vim.notify('Failed to create ' .. path .. ': ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

local function make_journal_entries(root)
  local items = {}
  local today = os.date '%Y-%m-%d'
  local found_today = false

  for _, day in ipairs(day_dirs(root)) do
    local entry_exists = vim.loop.fs_stat(day.entry) and true or false
    if day.day == today then
      found_today = true
    end
    table.insert(items, {
      day = day.day,
      path = day.entry,
      exists = entry_exists,
      display = string.format('%s%s', day.day, entry_exists and '' or ' (missing entry.md)'),
      ordinal = day.day .. (entry_exists and ' entry' or ' missing'),
    })
  end

  if not found_today then
    local today_entry = root .. '/' .. today .. '/entry.md'
    table.insert(items, 1, {
      day = today,
      path = today_entry,
      exists = false,
      display = today .. ' (today, create entry.md)',
      ordinal = today .. ' today create',
    })
  end

  return items
end

local function uri_decode(str)
  return (str:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local resolve_image_path

local function collect_image_refs_by_line(md_lines, path, journal_root)
  local refs = {}
  for line_num, line in ipairs(md_lines) do
    for raw in line:gmatch '!%[[^%]]*%]%(([^%)]-)%)' do
      local candidate = raw
      local quoted_double = candidate:match '^%s*"(.-)"'
      local quoted_single = candidate:match "^%s*'(.-)'"
      if quoted_double then
        candidate = quoted_double
      elseif quoted_single then
        candidate = quoted_single
      else
        candidate = candidate:match '^%s*(.-)%s*$'
      end
      if candidate ~= '' and not (candidate:match '^https?://') and not (candidate:match '^[%a][%a%d+.-]*:') then
        local resolved, tries = resolve_image_path(candidate, path, journal_root)
        if resolved then
          refs[line_num] = { resolved = resolved, raw = candidate }
        else
          local tries_hint = tries and (' (tried: ' .. table.concat(tries, ', ') .. ')') or ''
          refs[line_num] = { error = 'image not found: ' .. candidate .. tries_hint, raw = candidate }
        end
        break
      end
    end
  end
  return refs
end

resolve_image_path = function(raw_path, path, journal_root)
  raw_path = uri_decode(raw_path)
  raw_path = raw_path:gsub('^%./', '')
  local tries = {}
  local base_dir = vim.fn.fnamemodify(path, ':h')
  if raw_path:match '^/' then
    local stripped = raw_path:gsub('^/+', '')
    local without_journal = stripped:gsub('^journal/', '')

    table.insert(tries, vim.fn.fnamemodify(raw_path, ':p'))
    if journal_root then
      local journal_root_p = vim.fn.fnamemodify(journal_root, ':p')
      table.insert(tries, vim.fn.fnamemodify(journal_root_p .. '/' .. stripped, ':p'))
      if stripped ~= without_journal then
        table.insert(tries, vim.fn.fnamemodify(journal_root_p .. '/' .. without_journal, ':p'))
      end
    end
    table.insert(tries, vim.fn.fnamemodify(base_dir .. '/../' .. stripped, ':p'))
  elseif raw_path:match '^~/' then
    table.insert(tries, vim.fn.expand(raw_path))
  else
    table.insert(tries, vim.fn.fnamemodify(base_dir .. '/' .. raw_path, ':p'))
    if journal_root then
      local journal_root_p = vim.fn.fnamemodify(journal_root, ':p')
      table.insert(tries, vim.fn.fnamemodify(journal_root_p .. '/' .. raw_path, ':p'))
      local stripped = raw_path:gsub('^journal/', '')
      if stripped ~= raw_path then
        table.insert(tries, vim.fn.fnamemodify(journal_root_p .. '/' .. stripped, ':p'))
      end
    end
  end

  for _, candidate in ipairs(tries) do
    if vim.loop.fs_stat(candidate) then
      return candidate, tries
    end
  end

  return nil, tries
end

local function has_any_refs(refs)
  for _ in pairs(refs) do
    return true
  end
  return false
end

local function terminal_preview_message(text)
  return { 'printf', '%s\n', text }
end

local function build_preview_command(path, refs, status)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return terminal_preview_message('Could not read entry: ' .. tostring(lines))
  end

  if #lines == 0 then
    return terminal_preview_message 'No content yet.'
  end

  local preview_win = status and status.preview_win
  local cols = preview_win and math.max(20, vim.api.nvim_win_get_width(preview_win) - 2) or 80
  local rows = preview_win and math.max(6, math.floor(vim.api.nvim_win_get_height(preview_win) * 0.6) - 2) or 20
  local has_bat = vim.fn.executable 'bat' == 1
  local has_chafa = vim.fn.executable 'chafa' == 1
  local file_arg = vim.fn.shellescape(path)

  if not has_any_refs(refs) then
    if has_bat then
      return {
        'bat',
        '--color=always',
        '--style=plain',
        '--paging=never',
        '--terminal-width=' .. tostring(cols),
        path,
      }
    end
    return { 'cat', path }
  end

  local preview_parts = {}
  local max_lines = 300
  local chafa_size = string.format('%sx%s', cols, rows)

  for line_no, _ in ipairs(lines) do
    if line_no > max_lines then
      break
    end
    if has_bat then
      table.insert(
        preview_parts,
        string.format('bat --color=always --style=plain --paging=never --line-range=%d:%d --terminal-width=%s %s', line_no, line_no, tostring(cols), file_arg)
      )
    else
      table.insert(preview_parts, string.format("sed -n '%dp' %s", line_no, file_arg))
    end

    local image = refs[line_no]
    if image then
      if image.resolved then
        if has_chafa then
          table.insert(preview_parts, "printf '%s\\n' " .. vim.fn.shellescape('Image: ' .. image.raw))
          table.insert(preview_parts, 'chafa -s ' .. chafa_size .. ' ' .. vim.fn.shellescape(image.resolved))
          table.insert(preview_parts, "printf '\\n'")
        else
          table.insert(preview_parts, "printf 'chafa not installed\\n'")
        end
      else
        table.insert(preview_parts, "printf '%s\\n' " .. vim.fn.shellescape('Failed to render image: ' .. image.error))
      end
    end
  end

  if #lines > max_lines then
    table.insert(preview_parts, "printf '... truncated\\n'")
  end

  if #preview_parts == 0 then
    return {
      'cat',
      path,
    }
  end

  return {
    'sh',
    '-lc',
    table.concat(preview_parts, '\n'),
  }
end

local function journal_previewer(journal_root)
  return previewers.new_termopen_previewer {
    title = 'Journal Preview',
    env = {
      TERM = 'xterm-256color',
      COLORTERM = 'truecolor',
    },
    get_command = function(entry, status)
      local item = entry.value or entry
      local path = item and item.path
      if not path then
        return terminal_preview_message 'No journal entry selected.'
      end

      if not vim.loop.fs_stat(path) then
        return terminal_preview_message(('No entry.md yet.\n\nPress <CR> to create this day and open it.\nPath: %s'):format(path))
      end

      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then
        return terminal_preview_message('Could not read entry: ' .. tostring(lines))
      end

      local refs = collect_image_refs_by_line(lines, path, journal_root)
      return build_preview_command(path, refs, status)
    end,
  }
end

local function open_journal(opts)
  local root, err = resolve_journal_dir(opts)
  if not root then
    return vim.notify(err, vim.log.levels.ERROR)
  end

  local entries = make_journal_entries(root)

  pickers
    .new(opts, {
      prompt_title = 'Journal Entries',
      finder = finders.new_table {
        results = entries,
        entry_maker = function(item)
          return {
            value = item,
            display = item.display,
            ordinal = item.ordinal,
            path = item.path,
          }
        end,
      },
      layout_strategy = 'horizontal',
      layout_config = {
        width = 0.95,
        height = 0.9,
        preview_cutoff = 1,
        preview_width = 0.7,
      },
      sorter = require('telescope.sorters').get_generic_fuzzy_sorter(),
      previewer = journal_previewer(root),

      attach_mappings = function(prompt_bufnr, map)
        local function open_selected()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selection or not selection.value then
            return
          end
          open_or_create_entry(selection.value.path)
        end

        map('i', '<CR>', open_selected)
        map('n', '<CR>', open_selected)
        return true
      end,
    })
    :find()
end

M.setup = function(opts)
  opts = opts or {}
  vim.keymap.set('n', opts.key or '<leader>jo', function()
    open_journal(opts)
  end, { desc = opts.desc or '[J]ournal [O]pen' })
end

return M
