--- @class learning.TeachSession [Hashino/learning.nvim] the pure state machine
--- behind an active-recall drill. it holds ONLY state and decides transitions —
--- every side effect (the verify call, generating an example, restoring the
--- buffer, closing the window) is performed by the caller on the `action` this
--- returns. keeping it pure makes the whole drill exhaustively testable without a
--- model: feed it events, assert the action and the state.
---
--- lifecycle: `learning` opens a drill, calls `:submit()` when the learner asks
--- to be checked, runs `ai.verify`, then feeds the boolean to `:result(ok)`.
--- `:give_up()` / `:dismiss()` end it. the scaffold escalates the shown example
--- as failed attempts accumulate (analogous → related → solution); there is no
--- failure cap — the learner may keep trying past the solution.
---@field feature string the feature being drilled
---@field attempts integer failed submits so far
---@field phase "analogous"|"related"|"solution" the example currently shown
---@field state "learning"|"mastered"|"abandoned"
---@field related_after integer failed attempts before escalating to "related"
---@field solution_after integer failed attempts before escalating to "solution"
local TeachSession = {}
TeachSession.__index = TeachSession

--- starts a drill for `feature`. `related_after`/`solution_after` are the failed-
--- attempt counts at which the example escalates.
---@param feature string
---@param related_after integer
---@param solution_after integer
---@return learning.TeachSession
function TeachSession.new(feature, related_after, solution_after)
  return setmetatable({
    feature = feature,
    attempts = 0,
    phase = "analogous",
    state = "learning",
    related_after = related_after,
    solution_after = solution_after,
  }, TeachSession)
end

--- whether the drill is still awaiting the learner.
---@return boolean
function TeachSession:is_active()
  return self.state == "learning"
end

--- the example phase appropriate for the current number of failed attempts.
---@return "analogous"|"related"|"solution"
local function phase_for(self)
  if self.attempts >= self.solution_after then return "solution" end
  if self.attempts >= self.related_after then return "related" end
  return "analogous"
end

--- the learner submitted an attempt: the caller should now run `ai.verify` and
--- feed the result to `:result()`. returns the action to perform meanwhile (a
--- no-op once the drill has ended).
---@return { kind: "verify" }|{ kind: "none" }
function TeachSession:submit()
  if self.state ~= "learning" then return { kind = "none", } end
  return { kind = "verify", }
end

--- feeds the verify verdict (did the latest attempt use the feature?). on success
--- the drill is mastered; on failure the attempt is counted and, when that pushes
--- the scaffold to a new rung, a fresh example is requested — otherwise the
--- learner is simply asked to try again.
---@param ok boolean
---@return { kind: "mastered" }|{ kind: "example", phase: string }|{ kind: "retry" }|{ kind: "none" }
function TeachSession:result(ok)
  if self.state ~= "learning" then return { kind = "none", } end

  if ok then
    self.state = "mastered"
    return { kind = "mastered", }
  end

  self.attempts = self.attempts + 1
  local p = phase_for(self)
  if p ~= self.phase then
    self.phase = p
    return { kind = "example", phase = p, }
  end
  return { kind = "retry", }
end

--- the learner gave up: end the drill and restore the buffer to its pre-drill state.
---@return { kind: "restore" }|{ kind: "none" }
function TeachSession:give_up()
  if self.state ~= "learning" then return { kind = "none", } end
  self.state = "abandoned"
  return { kind = "restore", }
end

--- the learner dismissed: end the drill but leave whatever they have written.
---@return { kind: "close" }|{ kind: "none" }
function TeachSession:dismiss()
  if self.state ~= "learning" then return { kind = "none", } end
  self.state = "abandoned"
  return { kind = "close", }
end

return TeachSession
