dependencies = { 'nvim-lua/plenary.nvim' }

config = function()
  local helpful_prompt = 'You are a helpful assistant. What I have sent are my notes so far.'
  local replace_prompt =
    'You will receive a code snippet, with "inline" instructions given in comments. Rewrite the code according to the instructions.\n- YOUR RESPONSE WILL DIRECTLY BE INSERTED INTO A PRODUCTION CODEBASE, SO DO NOT USE NATURAL LANGUAGE AT ALL.\n- NEVER WRAP YOUR CODE RESPONSE IN BACKTICKS.\n- REPLICATE THE INDENTATION.\n- REMOVE INSTRUCTION COMMENTS, preserving non-instruction comments that are relevant to humans.\nAs always, write production-level code, comment appropriately, and make sure the codebase continues to function after your edit.'
  local dingllm = require 'dingllm'

  local function handle_openrouter_spec_data(data_stream)
    local success, json = pcall(vim.json.decode, data_stream)
    if success then
      if json.choices and json.choices[1] and json.choices[1].delta then
        local content = json.choices[1].delta.content
        if content then
          dingllm.write_string_at_cursor(content)
        end
      end
    else
      print('non json ' .. data_stream)
    end
  end

  local function make_openrouter_spec_args(opts, prompt, system_prompt)
    local url = opts.url
    local api_key
    local key_file = io.open('./or_key', 'r')
    if key_file then
      api_key = key_file:read '*line'
      key_file:close()
    else
      error 'Failed to read OpenRouter API key from ./or_key'
    end
    local data = {
      messages = { { role = 'system', content = system_prompt }, { role = 'user', content = prompt } },
      model = opts.model,
      temperature = 0.7,
      stream = true,
      provider = { order = { 'DeepInfra', 'OpenAI', 'Anthropic' } },
    }
    local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '-d', vim.json.encode(data) }
    if api_key then
      table.insert(args, '-H')
      table.insert(args, 'Authorization: Bearer ' .. api_key)
    end
    table.insert(args, url)
    return args
  end

  local function replace_mini()
    dingllm.invoke_llm_and_stream_into_editor({
      url = 'https://openrouter.ai/api/v1/chat/completions',
      model = 'openai/gpt-4o-mini',
      api_key_name = 'OPEN_ROUTER_API_KEY',
      max_tokens = '1000',
      system_prompt = replace_prompt,
      replace = true,
    }, make_openrouter_spec_args, handle_openrouter_spec_data)
  end

  local function replace_sonnet()
    dingllm.invoke_llm_and_stream_into_editor({
      url = 'https://openrouter.ai/api/v1/chat/completions',
      model = 'anthropic/claude-3.5-sonnet:beta',
      api_key_name = 'OPEN_ROUTER_API_KEY',
      max_tokens = '1000',
      system_prompt = replace_prompt,
      replace = true,
    }, make_openrouter_spec_args, handle_openrouter_spec_data)
  end

  local function replace_405()
    dingllm.invoke_llm_and_stream_into_editor({
      url = 'https://openrouter.ai/api/v1/chat/completions',
      model = 'meta-llama/llama-3.1-405b-instruct',
      api_key_name = 'OPEN_ROUTER_API_KEY',
      max_tokens = '1000',
      system_prompt = replace_prompt,
      replace = true,
    }, make_openrouter_spec_args, handle_openrouter_spec_data)
  end

  vim.keymap.set({ 'n', 'v' }, '<leader>r', replace_mini, { desc = '4o mini replace' })
  vim.keymap.set({ 'n', 'v' }, '<leader>R', replace_405, { desc = '405b replace' })
  vim.keymap.set({ 'n', 'v' }, '<leader>s', replace_sonnet, { desc = 'sonnet 3.5 replace' })
end

config()
