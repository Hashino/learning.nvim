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

--- extracts a human-readable error message from an error response.
--- handles `{ error = "msg", message = "..." }` (Mercury) and
--- `{ error = { message = "..." } }` (OpenAI/Anthropic)
---@param decoded table
---@return string|nil
local function extract_error(decoded)
  local err = decoded.error
  if type(err) == "string" then
    if type(decoded.message) == "string" and decoded.message ~= "" then
      return err .. ": " .. decoded.message
    end
    return err
  elseif type(err) == "table" then
    return err.message or err.type or vim.json.encode(err)
  end
  return nil
end

--- makes a test request to validate the provider config.
--- sends a minimal prompt without tools to check basic connectivity.
---@param callback fun(result: { success: boolean, error?: string })
function AI.validate_provider(callback)
  local prompt = "Reply with exactly: OK"
  local anthropic = is_anthropic()

  local headers = { ["Content-Type"] = "application/json", }
  local payload = {
    model = config.options.provider.model,
    messages = { { role = "user", content = prompt, }, },
  }

  if anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    payload.max_tokens = 16
    payload.tools = {}
    payload.tool_choice = { type = "auto", }
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    payload.tools = {}
    payload.tool_choice = "auto"
  end

  for k, v in pairs(config.options.provider.headers or {}) do
    headers[k] = (v ~= "" and v) or nil
  end

  local body = vim.json.encode(payload)
  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url, }
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
        if not ok or type(decoded) ~= "table" then
          return callback({ success = false, error = "could not parse API response: " .. output })
        end

        local api_err = extract_error(decoded)
        if api_err then
          return callback({ success = false, error = api_err })
        end

        local content = extract_content(decoded, anthropic)
        if type(content) ~= "string" or content == "" then
          return callback({ success = false, error = "provider returned empty content" })
        end

        callback({ success = true })
      end)
    end,
    on_exit = function(_, code, _)
      if code ~= 0 then
        vim.schedule(function()
          callback({ success = false, error = "curl exited with code " .. code })
        end)
      end
    end,
  })
end

---@class learning.Evaluation stage-1 result: what to teach + what's already known
---@field need_to_learn { feature: string, level: string } the missed feature; level "none" = nothing to teach
---@field already_knows { feature: string, level: string }[] features the changed lines show the user already uses

---@class learning.Suggestion stage-2 result shown to the user
---@field summary string explanation of the edit (markdown)
---@field feature? string short identifier of the language feature taught
---@field language? string language the feature belongs to (the buffer filetype)
---@field edit? learning.Edit edit to apply if the user accepts
---@field level? string skill level of the taught feature (one of config.LEVELS)
---@field track_dismiss? boolean when true, dismissing the window records a dismissal for (language, feature)

---@class learning.Edit
---@field start integer start line of the edit (0-indexed)
---@field final integer final line of the edit (0-indexed, exclusive)
---@field content string[] the content of the edit

---@class learning.Example stage-2 drill example for one scaffold phase
---@field explanation string short prose explanation of the feature
---@field code string[] the fenced example lines

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

-- the shared skill-tier taxonomy: which features belong to each tier, by how
-- fundamental the feature is. used for BOTH evaluate fields — the tier of a
-- missed feature and the tier of a demonstrated one. three tiers (intermediate
-- left deliberately broad) because weak models separate the extremes reliably but
-- blur finer gradations. kept verbatim across runs so the model gets a stable anchor.
local LEVEL_TAXONOMY =
  "\"beginner\" = a core builtin or basic idiom essentially every user needs " ..
  "(manual accumulation loop → sum, range(len(...)) indexing → enumerate, " ..
  "building strings with + → join, append-loop → list comprehension). " ..
  "\"intermediate\" = the broad middle of everyday idioms a beginner could miss " ..
  "(zip, dict.get, context managers, f-strings, comprehensions over map/filter, " ..
  "`for k in d` vs `d.keys()`, `not x` vs `len(x) == 0`). " ..
  "\"advanced\" = an expert construct most code never needs (generators for " ..
  "memory, __slots__, functools/itertools tricks, metaclasses, descriptors)."

--- STAGE 1 (cheap, every non-trivial edit): in one `evaluate` call, reports both
--- the single feature the changed lines MISS (`need_to_learn`; level "none" when
--- already idiomatic) and the features they DEMONSTRATE the user already uses
--- (`already_knows`). The client records the knowledge — which is what advances
--- the user's level — and pays for the heavy stage 2 only when there is something
--- to teach at an unlocked level.
---@param diff learning.Diff
---@param filetype string filetype of the buffer being edited
---@param callback fun(evaluation: learning.Evaluation?)
function AI.evaluate(diff, filetype, callback)
  local prompt = table.concat({
    "You are a language-learning assistant for " .. filetype .. ".\n" ..
    "The user just made an edit. Judging ONLY the changed lines, call the " ..
    "`evaluate` tool with two things:\n" ..
    "1. need_to_learn — the single most useful " .. filetype .. " feature the " ..
    "changed lines MISS (an idiomatic improvement they could have used), and how " ..
    "obvious the miss is. If the changed lines are already idiomatic, use level \"none\".\n" ..
    "2. already_knows — the " .. filetype .. " features the changed lines " ..
    "themselves DEMONSTRATE the user already uses correctly. List only " ..
    "genuinely-demonstrated features; an empty list is correct and common.",
    region_block(diff, filetype),
    "\nBe concise.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "evaluate",
      "Report what the changed lines miss (need_to_learn) and what they show the " ..
      "user already knows (already_knows).",
      {
        need_to_learn = {
          type = "object",
          description = "The single most useful feature the changed lines miss, " ..
            "or level \"none\" if they are already idiomatic.",
          properties = {
            feature = {
              type = "string",
              description = "Short lowercase identifier of the missed feature, " ..
                "e.g. 'list comprehension', 'string interpolation'. Empty if none.",
            },
            level = {
              type = "string",
              enum = { "none", "beginner", "intermediate", "advanced", },
              description = "Skill tier of the MISSED feature, by how OBVIOUS the " ..
                "miss is (not how clever the fix is). \"none\" = already idiomatic, " ..
                "nothing to teach. " .. LEVEL_TAXONOMY,
            },
          },
          required = { "feature", "level", },
        },
        already_knows = {
          type = "array",
          description = "Features the changed lines demonstrate the user already " ..
            "uses correctly and idiomatically. Empty is correct and common — never " ..
            "invent features the changed lines do not actually show.",
          items = {
            type = "object",
            properties = {
              feature = {
                type = "string",
                description = "Short lowercase identifier of a demonstrated feature.",
              },
              level = {
                type = "string",
                enum = { "beginner", "intermediate", "advanced", },
                description = "Skill tier the demonstrated feature belongs to. " .. LEVEL_TAXONOMY,
              },
            },
            required = { "feature", "level", },
          },
        },
      },
      { "need_to_learn", "already_knows", }),
  }

  make_ai_request(prompt, tools, "evaluate", function(args)
    if type(args) ~= "table" then return callback(nil) end

    -- need_to_learn — a missing/garbled object degrades to "nothing to teach"
    local ntl = type(args.need_to_learn) == "table" and args.need_to_learn or {}
    local feature = type(ntl.feature) == "string" and ntl.feature or ""
    local level = utils.normalize_level(ntl.level)
    if feature == "" then level = "none" end

    -- already_knows — skip malformed items and any that normalize to "none"
    local knows = {}
    if type(args.already_knows) == "table" then
      for _, item in ipairs(args.already_knows) do
        if type(item) == "table" and type(item.feature) == "string" and item.feature ~= "" then
          local lvl = utils.normalize_level(item.level)
          if lvl ~= "none" then
            table.insert(knows, { feature = item.feature, level = lvl, })
          end
        end
      end
    end

    callback({
      need_to_learn = { feature = feature, level = level, },
      already_knows = knows,
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

--- (stage-2 drill) a cheap yes/no: did the learner's latest code correctly and
--- idiomatically use `feature`? drives the teach-session state machine, fired
--- only on an explicit submit (never polled) so it costs one small call per try.
---@param code string the learner's current attempt
---@param filetype string
---@param feature string
---@param callback fun(uses: boolean)
function AI.verify(code, filetype, feature, callback)
  local prompt = table.concat({
    "You are a " .. filetype .. " tutor. The learner is practicing the feature \"" ..
    feature .. "\". Judging the code below, did they use \"" .. feature ..
    "\" correctly and idiomatically?",
    "\n```" .. filetype .. "\n" .. code .. "\n```\n",
    "Answer by calling the `verify` tool.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "verify",
      "Report whether the code correctly uses the named feature.",
      { uses = { type = "boolean", description = "true if the code uses the feature correctly", }, },
      { "uses", }),
  }

  make_ai_request(prompt, tools, "verify", function(args)
    callback(type(args) == "table" and args.uses == true)
  end)
end

-- per-phase instruction for the drill example: analogous (a different context, so
-- the learner can't just copy) → related (closer) → solution (the direct rewrite).
local EXAMPLE_PHASE = {
  analogous = "Show the feature used in a DIFFERENT, unrelated snippet (NOT the " ..
    "learner's code), so they must work out how to apply it themselves.",
  related = "Show the feature in a snippet CLOSER to the learner's code, but " ..
    "still not the exact rewrite.",
  solution = "Show the DIRECT idiomatic rewrite of the learner's own code.",
}

--- (stage-2 drill) the explanation + a fenced example for one scaffold phase.
--- lazy: called per rung, tailored to the learner's current code, so each call
--- stays small and only the rungs they actually reach are paid for.
---@param feature string
---@param filetype string
---@param phase "analogous"|"related"|"solution"
---@param code string the learner's code under practice
---@param callback fun(example: learning.Example?)
function AI.gen_example(feature, filetype, phase, code, callback)
  local prompt = table.concat({
    "You are a " .. filetype .. " tutor teaching the feature \"" .. feature .. "\".",
    EXAMPLE_PHASE[phase] or EXAMPLE_PHASE.analogous,
    "Also write a short explanation (at most two short paragraphs) of the feature.",
    "\nThe learner's code:\n```" .. filetype .. "\n" .. code .. "\n```\n",
    "Answer by calling the `example` tool.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "example",
      "Provide a short explanation and a fenced example of the feature.",
      {
        explanation = { type = "string", description = "at most two short paragraphs", },
        code = { type = "array", items = { type = "string", }, description = "the example, one string per line", },
      },
      { "explanation", "code", }),
  }

  make_ai_request(prompt, tools, "example", function(args)
    if type(args) ~= "table" or type(args.explanation) ~= "string" then
      callback(nil)
      return
    end
    callback({
      explanation = args.explanation,
      code = type(args.code) == "table" and args.code or {},
    })
  end)
end

--- (stage-2 reminder) the user already KNOWS `feature` but slipped here. writes a
--- short, friendly nudge; a fenced snippet IS allowed (it's a memory jog — the
--- inverse of teach's no-snippet rule, since there is no drill to spoil).
---@param diff learning.Diff
---@param filetype string
---@param feature string
---@param callback fun(reminder: learning.Suggestion?)
function AI.remind(diff, filetype, feature, callback)
  local prompt = table.concat({
    "You are a " .. filetype .. " tutor. The learner already knows the feature \"" ..
    feature .. "\" but didn't use it in this edit. Write a SHORT, friendly reminder " ..
    "(2-3 sentences), opening with something like \"Remember `" .. feature ..
    "`?\", and include a small fenced code block showing how it applies to the " ..
    "changed lines.",
    region_block(diff, filetype),
    "\nAnswer by calling the `remind` tool.",
  }, "\n")

  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "remind",
      "Write a short reminder (one fenced snippet is allowed here).",
      { reminder = { type = "string", description = "2-3 sentence reminder, may include one fenced snippet", }, },
      { "reminder", }),
  }

  make_ai_request(prompt, tools, "remind", function(args)
    if type(args) ~= "table" or type(args.reminder) ~= "string" then
      callback(nil)
      return
    end
    callback({ summary = args.reminder, })
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
