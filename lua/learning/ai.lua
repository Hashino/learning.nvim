local config = require("learning.config")

local AI = {}

local function extract_content(body, is_anthropic)
  if is_anthropic then
    -- Anthropic: { content: [{ type: "text", text: "..." }] }
    return body.content and body.content[1] and body.content[1].text
  else
    -- OpenAI-compat: { choices: [{ message: { content: "..." } }] }
    return body.choices and body.choices[1] and body.choices[1].message.content
  end
end

local function build_request(prompt)
  local is_anthropic = config.options.provider.api_url:find("anthropic%.com")

  local headers = { ["Content-Type"] = "application/json" }
  local body

  if is_anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    body = vim.json.encode({
      model = config.options.provider.model,
      max_tokens = 1024,
      messages = { { role = "user", content = prompt } },
    })
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    body = vim.json.encode({
      model = config.options.provider.model,
      messages = { { role = "user", content = prompt } },
    })
  end

  return headers, body, is_anthropic
end

---@class LearningSuggestion
---@field summary string[] summary of the edit (markdown)
---@field edit LearningEdit edit to apply if the user accepts

---@class LearningEdit
---@field buffer integer buffer id of the buffer to edit
---@field start integer start line of the edit
---@field final integer final line of the edit
---@field content string[] the content of the edit

---@class AIDiff
---@field start integer start line of the change (0-indexed)
---@field old_content string[] content of the old lines
---@field new_content string[] content of the new lines

---@param diff AIDiff diff containing changed lines
---@param callback fun(suggestion: LearningSuggestion?) callback
function AI.suggestion(diff, callback)
  local old_content = table.concat(diff.old_content, "\n")
  local new_content = table.concat(diff.new_content, "\n")
  local prompt = [[
    given this change:

    old code:
    ]] .. old_content .. [[

    new code:
    ]] .. new_content .. [[

    if there's a better way of doing this in the language, return a summary of the change and the edit to apply in the following json format:
    {
      "summary": string, // a summary of the change in markdown format. also show a snippet of the change that is going to be applied in a codeblock of the language. start the message with things like: "Try this", "Consider this" or "Did you that {language} lets you do this in this way?". Be educational, but not pretentious. Link to the official documentation of the language whenever possible.
      "edit": {
        "start": integer, // start line of the edit (0-indexed). The change starts at line ]] ..
    tostring(diff.start) .. [[
          "final": integer, // final line of the edit (0-indexed, exclusive)
          "content": string[], // content of the edit to replace the lines from start to final
      }
    }

    use the paramter ]]
    ..
    tostring(config.options.eagerness)
    ..
    [[ to determine how eager you are to make a suggestion. 0 means never suggest anything, 1 means always suggest something if there's any possible improvement.

    make suggestion only if there's an obvious language feature that can be used that the user isn't using.
    make the suggestion only about the changed lines.
    otherwise, return nothing
  ]]

  local headers, body, is_anthropic = build_request(prompt)

  local cmd = { "curl", "-s", "-X", "POST", config.options.provider.api_url }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data, _)
      if data then
        vim.schedule(function()
          local output = table.concat(data, "")
          local ok, decoded = pcall(vim.json.decode, output)
          if not ok then
            vim.notify("[learning.nvim] failed to decode response: " .. output, vim.log.levels.ERROR)
            return
          end

          local content = extract_content(decoded, is_anthropic)
          if content then
            local ok, suggestion = pcall(vim.json.decode, content)

            if not ok then
              vim.notify("[learning.nvim] failed to decode suggestion content", vim.log.levels.ERROR)
              return
            else
              callback(suggestion)
            end
          else
            vim.notify("[learning.nvim] unexpected response shape", vim.log.levels.WARN)
          end
        end)
      end
    end,
    on_stderr = function(_, data, _)
      vim.schedule(function()
        if data then
          local err_str = table.concat(data, "")
          if err_str ~= "" then
            vim.notify("[learning.nvim] AI request failed (stderr): " .. err_str, vim.log.levels.ERROR)
          else
            vim.notify("[learning.nvim] AI request failed (stderr: empty)", vim.log.levels.ERROR)
          end
        else
          vim.notify("[learning.nvim] AI request failed (stderr: nil)", vim.log.levels.ERROR)
        end
      end)
    end,
    on_exit = function(_, code, _)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("[learning.nvim] AI request exited with code: " .. code, vim.log.levels.WARN)
        end)
      end
    end,
  })
end

return AI
