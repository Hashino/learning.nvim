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
        if not cok then
          local stripped = content:match("^```[Jj][Ss][Oo][Nn]?\n(.-)\n```$")
          if stripped then
            cok, suggestion = pcall(vim.json.decode, stripped)
          end
        end
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
---@param filetype string filetype of the buffer being edited
---@param callback fun(suggestion: learning.Suggestion?)
function AI.suggestion(diff, filetype, callback)
  local old_content = table.concat(diff.old_content, "\n")
  local new_content = table.concat(diff.new_content, "\n")

  local prompt_parts = {}

  table.insert(prompt_parts,
    "You are a language-learning assistant for " .. filetype .. ".\n" ..
    "The user just made an edit. Teach a single language feature that is " ..
    "relevant *exclusively* to what changed in this edit.\n")

  table.insert(prompt_parts, "\n--- Region before the edit (context) ---\n```" .. filetype .. "\n")
  table.insert(prompt_parts, old_content)
  table.insert(prompt_parts, "\n```\n")

  table.insert(prompt_parts, "\n--- Region after the edit (context) ---\n```" .. filetype .. "\n")
  table.insert(prompt_parts, new_content)
  table.insert(prompt_parts, "\n```\n")

  table.insert(prompt_parts, [[
The two blocks above are the same region of the file before and after the edit.
The surrounding lines are given only so you can understand the change; they are
NOT the subject of your suggestion.

Rules:
- Base your suggestion ONLY on the lines that actually differ between "before"
  and "after".
- Do NOT mention, refactor, or react to any code that did not change in this
  edit, even if you think it could be improved.
- If the changed lines don't clearly miss an idiomatic ]] .. filetype .. [[ feature,
  return nothing at all.

Respond in JSON with no extra commentary:
{"summary": "concise markdown tip about the edited lines, with a short code snippet", "edit": {"start": ]] ..
    tostring(diff.start) .. [[, "final": integer, "content": [...]}, "importance": 0.0-1.0}

The "edit" field replaces buffer lines from "start" to "final" (0-indexed,
"final" exclusive) with "content"; omit it if you have no concrete replacement.
Be concise.]])

  local prompt = table.concat(prompt_parts, "\n")

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
