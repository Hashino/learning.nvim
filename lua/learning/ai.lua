local config = require("learning.config")

local AI = {}

--- true when the configured provider is Anthropic (different request shape)
---@return boolean
local function is_anthropic()
  return config.options.provider.api_url:find("anthropic%.com") ~= nil
end

--- extracts the assistant text from a decoded response (content-only fallback)
---@param body table
---@param anthropic boolean
---@return string|nil
local function extract_content(body, anthropic)
  if anthropic then
    for _, block in ipairs(body.content or {}) do
      if block.type == "text" then return block.text end
    end
    return nil
  end
  local msg = body.choices and body.choices[1] and body.choices[1].message
  return msg and type(msg.content) == "string" and msg.content or nil
end

--- extracts every tool call from a decoded response
---@param decoded table
---@param anthropic boolean
---@return { name: string, arguments: table }[]
local function extract_tool_calls(decoded, anthropic)
  local calls = {}
  if anthropic then
    for _, block in ipairs(decoded.content or {}) do
      if block.type == "tool_use" then
        table.insert(calls, { name = block.name, arguments = block.input or {}, })
      end
    end
  else
    local msg = decoded.choices and decoded.choices[1] and decoded.choices[1].message
    for _, call in ipairs(msg and msg.tool_calls or {}) do
      if call.type == "function" and call["function"] then
        local ok, args = pcall(vim.json.decode, call["function"].arguments)
        if ok then
          table.insert(calls, { name = call["function"].name, arguments = args, })
        end
      end
    end
  end
  return calls
end

--- maps the model's importance score onto the 0..1 range the eagerness gate
--- expects. Models reliably use the 0..10 integer scale we ask for, but some
--- still answer on a 0..1 scale, so values <= 1 are treated as already-normalized.
---@param raw any
---@return number
local function normalize_importance(raw)
  local n = tonumber(raw) or 0
  if n > 1 then n = n / 10 end
  return math.max(0, math.min(1, n))
end

--- builds a tool definition in the active provider's format
---@param anthropic boolean
---@param name string
---@param description string
---@param properties table<string, table>
---@param required string[] names of the required properties
---@return table
local function make_tool(anthropic, name, description, properties, required)
  local schema = { type = "object", properties = properties, required = required, }
  if anthropic then
    return { name = name, description = description, input_schema = schema, }
  end
  return {
    type = "function",
    ["function"] = { name = name, description = description, parameters = schema, },
  }
end

--- builds the request headers and body, including tool definitions
---@param prompt string
---@param tools table[]
---@param tool_name string name of the tool the model must use
---@return table headers, string body, boolean anthropic
local function build_request(prompt, tools, tool_name)
  local anthropic = is_anthropic()

  local headers = { ["Content-Type"] = "application/json", }
  local payload = {
    model = config.options.provider.model,
    messages = { { role = "user", content = prompt, }, },
    tools = tools,
  }

  if anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    payload.max_tokens = 1024
    payload.tool_choice = { type = "tool", name = tool_name, }
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    payload.tool_choice = {
      type = "function",
      ["function"] = { name = tool_name, },
    }
  end

  -- DEVELOPMENT ONLY: merge user-supplied headers over the defaults so the test
  -- harness can reach keyless dev endpoints (an empty-string value removes a
  -- header, e.g. blanking Authorization). Not a supported production feature.
  for k, v in pairs(config.options.provider.headers or {}) do
    headers[k] = (v ~= "" and v) or nil
  end

  return headers, vim.json.encode(payload), anthropic
end

--- POSTs the prompt and forces the model to answer through `tool_name`,
--- invoking `callback` with that tool's arguments (or nil on failure)
---@param prompt string
---@param tools table[]
---@param tool_name string
---@param callback fun(arguments: table?)
local function make_ai_request(prompt, tools, tool_name, callback)
  local headers, body, anthropic = build_request(prompt, tools, tool_name)

  local cmd = { "curl", "-s", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  -- guarantee `callback` runs exactly once, even when curl produces no output
  -- (e.g. network failure), so callers relying on it to clear state don't hang.
  local done = false
  local function finish(arg)
    if done then return end
    done = true
    callback(arg)
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data, _)
      if not data then return end

      vim.schedule(function()
        local ok, decoded = pcall(vim.json.decode, table.concat(data, ""))
        if not ok or type(decoded) ~= "table" then
          finish(nil)
          return
        end

        for _, tc in ipairs(extract_tool_calls(decoded, anthropic)) do
          if tc.name == tool_name then
            finish(tc.arguments)
            return
          end
        end

        -- content-only fallback: the model replied with text instead of a tool
        -- call. surface it so the user still gets something useful.
        local content = extract_content(decoded, anthropic)
        finish(content and { explanation = content, } or nil)
      end)
    end,
    on_exit = function()
      -- if stdout produced nothing parseable, ensure the callback still fires
      vim.schedule(function() finish(nil) end)
    end,
  })
end

---@class learning.Suggestion
---@field summary string explanation of the edit (markdown)
---@field feature? string short identifier of the language feature taught
---@field language? string language the feature belongs to (the buffer filetype)
---@field edit? learning.Edit edit to apply if the user accepts
---@field importance? number between 0 and 1 indicating how important this suggestion is.
---@field track_dismiss? boolean when true, dismissing the window records a dismissal for (language, feature)

---@class learning.Edit
---@field start integer start line of the edit (0-indexed)
---@field final integer final line of the edit (0-indexed, exclusive)
---@field content string[] the content of the edit

---@class learning.Diff
---@field start integer start line of the change (0-indexed)
---@field old_content string[] content of the old lines
---@field new_content string[] content of the new lines

--- asks the model to teach a single language feature about an edit.
---@param diff learning.Diff
---@param filetype string filetype of the buffer being edited
---@param suppressed string[] features already dismissed for this language
---@param callback fun(suggestion: learning.Suggestion?)
function AI.suggestion(diff, filetype, suppressed, callback)
  local old_content = table.concat(diff.old_content, "\n")
  local new_content = table.concat(diff.new_content, "\n")

  local prompt_parts = {
    "You are a language-learning assistant for " .. filetype .. ".\n" ..
    "The user just made an edit. Teach a single language feature that is " ..
    "relevant *exclusively* to what changed in this edit.\n",
    "\n--- Region before the edit (context) ---\n```" .. filetype .. "\n",
    old_content,
    "\n```\n",
    "\n--- Region after the edit (context) ---\n```" .. filetype .. "\n",
    new_content,
    "\n```\n",
  }

  if #suppressed > 0 then
    table.insert(prompt_parts,
      "\nThe user has already dismissed these features; do NOT teach them again " ..
      "(use the `suggest` tool with importance 0 if the edit only relates to them): " ..
      table.concat(suppressed, ", ") .. "\n")
  end

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
  call the `suggest` tool with importance 0.

Always answer by calling the `suggest` tool. The "edit" field replaces buffer
lines from "start" to "final" (0-indexed, "final" exclusive) with "content";
omit it if you have no concrete replacement. Edits start at line ]] ..
    tostring(diff.start) .. [[. Be concise.]])

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "suggest",
      "Teach a single language feature relevant to the edited lines.",
      {
        explanation = {
          type = "string",
          description = "Concise markdown tip about the edited lines, with a short code snippet.",
        },
        feature = {
          type = "string",
          description = "Short lowercase identifier of the single language feature taught, " ..
            "e.g. 'list comprehension', 'pattern matching', 'string interpolation'.",
        },
        language = {
          type = "string",
          description = "The language the feature belongs to. Use exactly: " .. filetype,
        },
        importance = {
          type = "integer",
          description = "Integer from 0 to 10 for how important it is to show this. Use 0 when " ..
            "there is nothing worth teaching about the edited lines, 10 for an essential idiom.",
        },
        edit = {
          type = "object",
          description = "Optional concrete replacement for the edited lines.",
          properties = {
            start = { type = "integer", description = "start line, 0-indexed", },
            final = { type = "integer", description = "final line, 0-indexed exclusive", },
            content = { type = "array", items = { type = "string", }, description = "replacement lines", },
          },
          required = { "start", "final", "content", },
        },
      },
      { "explanation", "feature", "language", "importance", }),
  }

  make_ai_request(table.concat(prompt_parts, "\n"), tools, "suggest", function(args)
    if not args then
      callback(nil)
      return
    end
    callback({
      summary = args.explanation,
      feature = args.feature,
      language = args.language,
      importance = normalize_importance(args.importance),
      edit = args.edit,
    })
  end)
end

--- explains a selection on demand (the `:Learning explain` command).
---@param code string code to explain
---@param filetype string filetype of the buffer
---@param callback fun(explanation: learning.Suggestion?)
function AI.explain(code, filetype, callback)
  local prompt =
    "Explain this " .. filetype .. " code concisely. Focus on language features " ..
    "particular to " .. filetype .. ". Answer by calling the `explain` tool.\n\n```" ..
    filetype .. "\n" .. code .. "\n```"

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "explain",
      "Explain the selected code, focusing on notable language features.",
      {
        explanation = {
          type = "string",
          description = "Concise markdown explanation, with code in fenced blocks.",
        },
        feature = {
          type = "string",
          description = "Short lowercase identifier of the main language feature explained.",
        },
        language = {
          type = "string",
          description = "The language explained. Use exactly: " .. filetype,
        },
      },
      { "explanation", "feature", "language", }),
  }

  make_ai_request(prompt, tools, "explain", function(args)
    if not args or not args.explanation then
      callback(nil)
      return
    end
    callback({
      summary = args.explanation,
      feature = args.feature,
      language = args.language,
    })
  end)
end

return AI
