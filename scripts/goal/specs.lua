local common = require("scripts.goal.common")

local specs = {}

local function build_bootstrap_task_specs(builder_data)
  local children = {}
  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap or nil

  for index, task in ipairs((bootstrap_plan and bootstrap_plan.tasks) or {}) do
    children[#children + 1] = {
      id = "bootstrap-task-" .. tostring(index),
      title = task.id and common.humanize_identifier(task.id) or common.humanize_identifier(task.pattern_name or task.resource_name or task.type),
      kind = "action"
    }
  end

  return children
end

function specs.build(builder_data)
  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap or nil

  return {
    root = {
      id = "root",
      title = "Operate Builder",
      kind = "selector",
      children = {"manual", "paused", "bootstrap", "scaling", "build-out"}
    },
    manual = {
      id = "manual",
      title = "Manual Goal",
      kind = "sequence"
    },
    paused = {
      id = "paused",
      title = "Paused",
      kind = "sequence"
    },
    bootstrap = {
      id = "bootstrap",
      title = bootstrap_plan and (bootstrap_plan.display_name or "Bootstrap Base") or "Bootstrap Base",
      kind = "sequence",
      children = build_bootstrap_task_specs(builder_data)
    },
    scaling = {
      id = "scaling",
      title = "Scale Production",
      kind = "selector"
    },
    build_out = {
      id = "build-out",
      title = "Build Out",
      kind = "selector"
    }
  }
end

return specs
