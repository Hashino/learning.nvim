local config = require("learning.config")
local utils  = require("learning.utils")

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
---@param mode? "force"|"auto" tool_choice strategy; some "thinking" models reject forced
---@return table headers, string body, boolean anthropic
local function build_request(prompt, tools, tool_name, mode)
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
    -- "auto" is the fallback for models that reject a forced tool_choice; we then
    -- rely on the prompt's "answer by calling the tool" instruction (see below).
    payload.tool_choice = mode == "auto" and "auto"
        or { type = "function", ["function"] = { name = tool_name, }, }
  end

  -- DEVELOPMENT ONLY: merge user-supplied headers over the defaults so the test
  -- harness can reach keyless dev endpoints (an empty-string value removes a
  -- header, e.g. blanking Authorization). Not a supported production feature.
  for k, v in pairs(config.options.provider.headers or {}) do
    headers[k] = (v ~= "" and v) or nil
  end

  return headers, vim.json.encode(payload), anthropic
end

-- how many times to re-POST when a response comes back empty or unparseable
-- (a transient endpoint hiccup), before giving up and reporting failure
local MAX_ATTEMPTS = 3

--- POSTs the prompt and forces the model to answer through `tool_name`,
--- invoking `callback` with that tool's arguments (or nil on failure).
--- retries a few times on a transient empty/unparseable response.
---@param prompt string
---@param tools table[]
---@param tool_name string
---@param callback fun(arguments: table?)
local function make_ai_request(prompt, tools, tool_name, callback)
  local anthropic = is_anthropic()

  local function build_cmd(mode)
    local headers, body = build_request(prompt, tools, tool_name, mode)
    local cmd = { "curl", "-s", "-X", "POST", config.options.provider.api_url, }
    for k, v in pairs(headers) do
      table.insert(cmd, "-H")
      table.insert(cmd, k .. ": " .. v)
    end
    table.insert(cmd, "-d")
    table.insert(cmd, body)
    return cmd
  end

  --- @param n integer attempt number
  --- @param mode "force"|"auto" current tool_choice strategy
  local function attempt(n, mode)
    -- settle this attempt exactly once: with a usable result (-> callback), or
    -- as a failure (-> retry while attempts remain, else callback(nil)). guards
    -- against curl emitting both on_stdout and on_exit, or no output at all.
    local done = false
    local function settle(arg, usable)
      if done then return end
      done = true
      if usable then
        callback(arg)
      elseif n < MAX_ATTEMPTS then
        attempt(n + 1, mode)
      else
        callback(nil)
      end
    end

    vim.fn.jobstart(build_cmd(mode), {
      stdout_buffered = true,
      on_stdout = function(_, data, _)
        if not data then return end

        vim.schedule(function()
          local ok, decoded = pcall(vim.json.decode, table.concat(data, ""))
          if not ok or type(decoded) ~= "table" then
            return settle(nil, false) -- unparseable -> retry
          end

          -- some "thinking" models reject a forced tool_choice; retry the same
          -- attempt with "auto" before counting it as a failure.
          if mode == "force" and not done and decoded.error
              and tostring(decoded.error.message or ""):find("tool_choice") then
            done = true
            return attempt(n, "auto")
          end

          for _, tc in ipairs(extract_tool_calls(decoded, anthropic)) do
            if tc.name == tool_name then
              return settle(tc.arguments, true)
            end
          end

          -- content-only fallback: the model replied with text instead of a tool
          -- call. surface it so the user still gets something useful.
          local content = extract_content(decoded, anthropic)
          settle(content and { explanation = content, } or nil, content ~= nil)
        end)
      end,
      on_exit = function()
        -- no parseable stdout (e.g. network failure) -> retry / give up
        vim.schedule(function() settle(nil, false) end)
      end,
    })
  end

  attempt(1, "force")
end

---@class learning.Classification stage-1 result: what feature the edit misses
---@field feature string short identifier of the missed language feature
---@field language string language the feature belongs to (the buffer filetype)
---@field level string skill level of the miss ("none" or one of config.LEVELS)

---@class learning.Suggestion stage-2 result shown to the user
---@field summary string explanation of the edit (markdown)
---@field feature? string short identifier of the language feature taught
---@field language? string language the feature belongs to (the buffer filetype)
---@field edit? learning.Edit edit to apply if the user accepts
---@field level? string skill level of the taught feature ("none" or one of config.LEVELS)
---@field track_dismiss? boolean when true, dismissing the window records a dismissal for (language, feature)

---@class learning.Edit
---@field start integer start line of the edit (0-indexed)
---@field final integer final line of the edit (0-indexed, exclusive)
---@field content string[] the content of the edit

-- the before/after region of an edit, the prompt fragment both stages share.
---@param diff learning.Diff
---@param filetype string
---@return string
local function region_block(diff, filetype)
  local fence = "```" .. filetype .. "\n"
  return table.concat({
    "\n--- Region before the edit (context) ---\n" .. fence,
    table.concat(diff.old_content, "\n"),
    "\n```\n",
    "\n--- Region after the edit (context) ---\n" .. fence,
    table.concat(diff.new_content, "\n"),
    "\n```\n",
    "\nThe two blocks above are the same region of the file before and after the\n" ..
    "edit; the surrounding lines are context only. Judge ONLY the lines that\n" ..
    "actually differ between \"before\" and \"after\".\n",
  })
end

-- rubric for the stage-1 level, framed by how OBVIOUS the miss is (not how clever
-- the fix is). kept verbatim across runs so weak models get a stable anchor.
local LEVEL_RUBRIC =
  "Skill level of the missed feature, judged by how OBVIOUS the miss is — NOT " ..
  "how clever the fix is. " ..
  "\"none\" = the edited lines are already idiomatic, nothing to teach. " ..
  "\"beginner\" = a clear beginner-level miss of a core builtin (manual accumulation " ..
  "loop → sum, range(len(...)) indexing → enumerate, building strings with + → join, " ..
  "append-loop → comprehension). " ..
  "\"intermediate\" = a useful everyday idiom a beginner could easily miss " ..
  "(enumerate/zip, dict.get, context managers, f-strings). " ..
  "\"advanced\" = a non-obvious refinement that already-working code only marginally " ..
  "benefits from (dropping brackets in `sum([...])`, `for k in d` vs `d.keys()`, " ..
  "`not x` vs `len(x) == 0`, comprehension vs map/filter). " ..
  "\"master\" = an expert-level construct most code never needs (generators over " ..
  "lists for memory, __slots__, functools tricks). " ..
  "Prefer \"none\" or \"advanced\" for already-working code; reserve \"beginner\" for obvious misses."

--- STAGE 1 (cheap, every non-trivial edit): names the single language feature
--- the edit misses and ranks how obvious the miss is. No explanation, no edit —
--- so the common, gated-out path stays small. The client gate
--- (`store.should_teach`) decides whether to pay for stage 2.
---@param diff learning.Diff
---@param filetype string filetype of the buffer being edited
---@param callback fun(classification: learning.Classification?)
function AI.classify(diff, filetype, callback)
  local prompt = table.concat({
    "You are a language-learning assistant for " .. filetype .. ".\n" ..
    "The user just made an edit. Identify a single " .. filetype .. " language " ..
    "feature the changed lines MISS — an idiomatic improvement the edit could have " ..
    "used — and classify how obvious that miss is.\n",
    region_block(diff, filetype),
    "\nAnswer by calling the `classify` tool. If the changed lines are already " ..
    "idiomatic (nothing worth teaching), use level \"none\". Be concise.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "classify",
      "Name the single language feature the edited lines miss and rank the miss.",
      {
        feature = {
          type = "string",
          description = "Short lowercase identifier of the single missed feature, " ..
            "e.g. 'list comprehension', 'pattern matching', 'string interpolation'.",
        },
        language = {
          type = "string",
          description = "The language the feature belongs to. Use exactly: " .. filetype,
        },
        level = {
          type = "string",
          enum = { "none", "beginner", "intermediate", "advanced", "master", },
          description = LEVEL_RUBRIC,
        },
      },
      { "feature", "language", "level", }),
  }

  make_ai_request(prompt, tools, "classify", function(args)
    if not args or not args.feature then
      callback(nil)
      return
    end
    callback({
      feature = args.feature,
      language = args.language or filetype,
      level = utils.normalize_level(args.level),
    })
  end)
end

--- STAGE 2 (heavy, only past the gate): teaches the feature stage 1 named and
--- returns the concrete idiomatic rewrite as a structured edit. The explanation
--- must NOT repeat the corrected code — it is rendered separately as a diff.
---@param diff learning.Diff
---@param filetype string filetype of the buffer being edited
---@param feature string the feature stage 1 named, taught specifically
---@param callback fun(suggestion: learning.Suggestion?)
function AI.teach(diff, filetype, feature, callback)
  local prompt = table.concat({
    "You are a language-learning assistant for " .. filetype .. ".\n" ..
    "Teach the user about this " .. filetype .. " feature: \"" .. feature .. "\". " ..
    "It is relevant to the edit they just made.\n",
    region_block(diff, filetype),
    "\nAnswer by calling the `suggest` tool. Write a concise markdown explanation " ..
    "of \"" .. feature .. "\" as it applies to the edited lines. The \"edit\" field " ..
    "replaces buffer lines from \"start\" to \"final\" (0-indexed, \"final\" " ..
    "exclusive) with \"content\" — include it with the idiomatic rewrite of the " ..
    "edited lines, anchored at line " .. tostring(diff.start) .. ".\n" ..
    "IMPORTANT: do NOT put the corrected/rewritten code in the explanation as a " ..
    "fenced code block — the edit is shown separately as a red/green diff. Describe " ..
    "the feature in prose (inline `names` are fine); do not repeat the full snippet.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "suggest",
      "Teach the named language feature about the edited lines.",
      {
        explanation = {
          type = "string",
          description = "Concise markdown explanation of the feature, WITHOUT a fenced " ..
            "code block repeating the corrected lines.",
        },
        edit = {
          type = "object",
          description = "Concrete idiomatic replacement for the edited lines.",
          properties = {
            start = { type = "integer", description = "start line, 0-indexed", },
            final = { type = "integer", description = "final line, 0-indexed exclusive", },
            content = { type = "array", items = { type = "string", }, description = "replacement lines", },
          },
          required = { "start", "final", "content", },
        },
      },
      { "explanation", }),
  }

  make_ai_request(prompt, tools, "suggest", function(args)
    if not args or not args.explanation then
      callback(nil)
      return
    end
    callback({
      summary = args.explanation,
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

-- exposed for tests/run.lua to exercise response parsing deterministically,
-- without a live provider.
AI._test = {
  extract_tool_calls = extract_tool_calls,
  extract_content = extract_content,
}

return AI
