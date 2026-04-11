local function assert_valid(condition, message)
  if not condition then
    error("shared.builder_data validation failed: " .. message, 2)
  end
end

local function validate_patterns(builder_data)
  local site_patterns = builder_data.site_patterns or {}
  for pattern_name, pattern in pairs(site_patterns) do
    assert_valid(type(pattern.display_name) == "string", "site_patterns." .. pattern_name .. ".display_name must be a string")
    assert_valid(type(pattern.build_task) == "table", "site_patterns." .. pattern_name .. ".build_task must be a table")
    assert_valid(type(pattern.build_task.type) == "string", "site_patterns." .. pattern_name .. ".build_task.type must be a string")
  end
end

local function validate_scaling(builder_data)
  local site_patterns = builder_data.site_patterns or {}
  local scaling = builder_data.scaling or {}
  for _, pattern_name in ipairs(scaling.cycle_pattern_names or {}) do
    assert_valid(site_patterns[pattern_name] ~= nil, "scaling.cycle_pattern_names references unknown pattern '" .. pattern_name .. "'")
  end

  local seen_milestones = {}
  for _, milestone in ipairs(scaling.production_milestones or {}) do
    assert_valid(type(milestone.name) == "string", "scaling.production_milestones entries must have a string name")
    assert_valid(seen_milestones[milestone.name] == nil, "duplicate scaling milestone '" .. milestone.name .. "'")
    seen_milestones[milestone.name] = true
    assert_valid(type(milestone.display_name) == "string", "scaling milestone '" .. milestone.name .. "' must have a display_name")
    assert_valid(type(milestone.task) == "table", "scaling milestone '" .. milestone.name .. "' must have a task")
    assert_valid(type(milestone.task.type) == "string", "scaling milestone '" .. milestone.name .. "' task must have a type")
  end
end

local function validate_plans(builder_data)
  for plan_name, plan in pairs(builder_data.plans or {}) do
    assert_valid(type(plan.display_name) == "string", "plan '" .. plan_name .. "' must have a display_name")
    assert_valid(type(plan.tasks) == "table" and #plan.tasks > 0, "plan '" .. plan_name .. "' must define at least one task")

    for index, task in ipairs(plan.tasks) do
      assert_valid(type(task.type) == "string", "plan '" .. plan_name .. "' task #" .. index .. " must have a type")
    end
  end
end

return function(builder_data)
  assert_valid(type(builder_data.force_name) == "string", "force_name must be a string")
  assert_valid(type(builder_data.force) == "table", "force must be a table")
  assert_valid(type(builder_data.avatar) == "table", "avatar must be a table")
  assert_valid(type(builder_data.ui) == "table", "ui must be a table")
  assert_valid(type(builder_data.logistics) == "table", "logistics must be a table")
  assert_valid(type(builder_data.crafting) == "table", "crafting must be a table")
  assert_valid(type(builder_data.world_item_sources) == "table", "world_item_sources must be a table")
  assert_valid(type(builder_data.site_patterns) == "table", "site_patterns must be a table")
  assert_valid(type(builder_data.scaling) == "table", "scaling must be a table")
  assert_valid(type(builder_data.plans) == "table", "plans must be a table")

  validate_patterns(builder_data)
  validate_scaling(builder_data)
  validate_plans(builder_data)

  return builder_data
end
