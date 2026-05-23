local config = require("learning.config")

local AI = {}

local function extract_content(body, is_anthropic)
  if is_anthropic then
    return body.content and body.content[1] and body.content[1].text
  else
    return body.choices and body.choices[1] and body.choices[1].message.content
  end
end

local function build_request(prompt)
  local is_anthropic = config.options.provider.api_url:find("anthropic%.com")

  local headers = { ["Content-Type"] = "application/json", }
  local body

  if is_anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    body = vim.json.encode({
      model = config.options.provider.model,
      max_tokens = 1024,
      messages = { { role = "user", content = prompt, }, },
    })
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    body = vim.json.encode({
      model = config.options.provider.model,
      messages = { { role = "user", content = prompt, }, },
    })
  end

  return headers, body, is_anthropic
end

local function make_ai_request(prompt, callback)
  local headers, body, is_anthropic = build_request(prompt)

  local cmd = { "curl", "-s", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data, _)
      if not data then return end

      vim.schedule(function()
        local output = table.concat(data, "")
        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then return end

        local content = extract_content(decoded, is_anthropic)
        if type(content) ~= "string" then return end

        local cok, suggestion = pcall(vim.json.decode, content)
        if cok then
          callback(suggestion)
        elseif content then
          callback({ summary = tostring(content) })
        end
      end)
    end,
  })
end

---@class learning.Suggestion
---@field summary string summary of the edit (markdown)
---@field edit? learning.Edit edit to apply if the user accepts
---@field importance? number between 0 and 1 indicating how important this suggestion is.

---@class learning.Edit
---@field start integer start line of the edit (0-indexed)
---@field final integer final line of the edit (0-indexed, exclusive)
---@field content string[] the content of the edit

---@class learning.Diff
---@field start integer start line of the change (0-indexed)
---@field old_content string[] content of the old lines
---@field new_content string[] content of the new lines

---@param diff learning.Diff
---@param callback fun(suggestion: learning.Suggestion?)
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
  "importance": number, // a number between 0 and 1 indicating how important this suggestion is. 0 means the suggestion is just a matter of taste with no measurable improvement, 1 means it's a critical improvement that should be made.
}

make suggestion only if there's an obvious language feature that can be used that the user isn't using.
make the suggestion only about the changed lines.
be direct and concise.
otherwise, return nothing
]]

  make_ai_request(prompt, callback)
end

---
---@param code string code to explain
---@param callback fun(explanation: string?) callback to receive the explanation.
function AI.explain(code, callback)
  local prompt = [[
  explain this code in a concise way. focus on explaining any language features being used that are particular to this language: ]] ..
      code

  make_ai_request(prompt, function(suggestion)
    if type(suggestion) == "string" then
      callback(suggestion)
    elseif suggestion and suggestion.summary then
      callback(suggestion.summary)
    else
      callback(nil)
    end
  end)
end

return AI
