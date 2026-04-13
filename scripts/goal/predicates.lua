local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")

local predicates = {}

function predicates.merge_required_items(requirements_a, requirements_b)
  local by_name = {}

  local function add_requirements(requirements)
    for _, requirement in ipairs(requirements or {}) do
      by_name[requirement.name] = (by_name[requirement.name] or 0) + (requirement.count or 0)
    end
  end

  add_requirements(requirements_a)
  add_requirements(requirements_b)

  local merged = {}
  for name, count in pairs(by_name) do
    merged[#merged + 1] = {
      name = name,
      count = count
    }
  end

  table.sort(merged, function(left, right)
    return left.name < right.name
  end)

  return merged
end

function predicates.get_pattern(builder_data, pattern_name)
  return builder_data.site_patterns and builder_data.site_patterns[pattern_name] or nil
end

function predicates.get_milestone(builder_data, milestone_name)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.name == milestone_name then
      return milestone
    end
  end

  return nil
end

local function unlock_requirements_met(builder_state, unlock, get_resource_site_counts)
  if not unlock then
    return true
  end

  local site_counts = get_resource_site_counts and get_resource_site_counts() or {}
  for pattern_name, minimum_count in pairs(unlock.minimum_site_counts or {}) do
    if (site_counts[pattern_name] or 0) < minimum_count then
      return false
    end
  end

  for _, milestone_name in ipairs(unlock.required_completed_milestones or {}) do
    if not (builder_state and builder_state.completed_scaling_milestones and builder_state.completed_scaling_milestones[milestone_name]) then
      return false
    end
  end

  return true
end

function predicates.list_component_names(builder_data)
  local names = {}

  for pattern_name in pairs(builder_data.site_patterns or {}) do
    names[#names + 1] = pattern_name
  end

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    names[#names + 1] = milestone.name
  end

  names[#names + 1] = "firearm_magazine_site"
  names[#names + 1] = "steel_smelting_site"
  table.sort(names)
  return names
end

function predicates.get_component_spec(builder_data, component_name)
  local pattern = predicates.get_pattern(builder_data, component_name)
  if pattern and (pattern.tasks or pattern.build_task) then
    local tasks = {}
    for _, task in ipairs(pattern.tasks or {}) do
      tasks[#tasks + 1] = common.deep_copy(task)
    end
    if #tasks == 0 and pattern.build_task then
      tasks[1] = common.deep_copy(pattern.build_task)
    end
    return {
      id = component_name,
      display_name = pattern.display_name or common.humanize_identifier(component_name),
      required_items = common.deep_copy(pattern.required_items or {}),
      tasks = tasks
    }
  end

  local milestone = predicates.get_milestone(builder_data, component_name)
  if milestone and (milestone.tasks or milestone.task) then
    local tasks = {}
    for _, task in ipairs(milestone.tasks or {}) do
      tasks[#tasks + 1] = common.deep_copy(task)
    end
    if #tasks == 0 and milestone.task then
      tasks[1] = common.deep_copy(milestone.task)
    end
    return {
      id = component_name,
      display_name = milestone.display_name or common.humanize_identifier(component_name),
      required_items = common.deep_copy(milestone.required_items or {}),
      tasks = tasks
    }
  end

  if component_name == "firearm_magazine_site" then
    local assembler_milestone = predicates.get_milestone(builder_data, "firearm-magazine-assembler")
    local defense_milestone = predicates.get_milestone(builder_data, "firearm-magazine-defense")
    if assembler_milestone and defense_milestone then
      return {
        id = component_name,
        display_name = "Firearm Magazine Site",
        required_items = predicates.merge_required_items(assembler_milestone.required_items, defense_milestone.required_items),
        tasks = {
          common.deep_copy(assembler_milestone.task),
          common.deep_copy(defense_milestone.task)
        }
      }
    end
  end

  if component_name == "steel_smelting_site" then
    local iron_pattern = predicates.get_pattern(builder_data, "iron_smelting")
    local steel_pattern = predicates.get_pattern(builder_data, "steel_smelting")
    if iron_pattern and iron_pattern.build_task and steel_pattern and steel_pattern.build_task then
      return {
        id = component_name,
        display_name = "Steel Smelting Site",
        required_items = predicates.merge_required_items(iron_pattern.required_items, steel_pattern.required_items),
        tasks = {
          common.deep_copy(iron_pattern.build_task),
          common.deep_copy(steel_pattern.build_task)
        }
      }
    end
  end

  return nil
end

function predicates.get_unlock_blockers(builder_data, snapshot, pattern_name)
  local blockers = {}
  local unlock = builder_data.scaling and builder_data.scaling.pattern_unlocks and builder_data.scaling.pattern_unlocks[pattern_name]
  if not unlock then
    return blockers
  end

  for dependency_name, minimum_count in pairs(unlock.minimum_site_counts or {}) do
    local current_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[dependency_name]) or 0
    if current_count < minimum_count then
      blockers[#blockers + 1] = instances.make_blocker(
        "site-count-at-least",
        "need " .. common.humanize_identifier(dependency_name) .. " sites " .. current_count .. "/" .. minimum_count,
        {
          pattern_name = dependency_name,
          current_count = current_count,
          target_count = minimum_count
        }
      )
    end
  end

  for _, milestone_name in ipairs(unlock.required_completed_milestones or {}) do
    if not snapshot.completed_scaling_milestones[milestone_name] then
      local milestone = predicates.get_milestone(builder_data, milestone_name)
      blockers[#blockers + 1] = instances.make_blocker(
        "goal-completed",
        "waiting for milestone " .. (milestone and milestone.display_name or common.humanize_identifier(milestone_name)),
        {milestone_name = milestone_name}
      )
    end
  end

  return blockers
end

function predicates.get_recipe(builder_data, item_name)
  return builder_data.crafting and builder_data.crafting.recipes and builder_data.crafting.recipes[item_name] or nil
end

function predicates.milestone_thresholds_met(entity, get_item_count, milestone)
  for _, threshold in ipairs((milestone and milestone.inventory_thresholds) or {}) do
    if get_item_count(entity, threshold.name) < threshold.count then
      return false
    end
  end

  return true
end

function predicates.resolve_craft_action(entity, item_name, target_count, get_item_count, get_recipe_fn)
  local current_count = get_item_count(entity, item_name)
  if current_count >= target_count then
    return nil
  end

  local missing_count = target_count - current_count
  local recipe = get_recipe_fn(item_name)
  if not recipe then
    return {
      kind = "collect-ingredient",
      item_name = item_name,
      count = missing_count
    }
  end

  local result_count = recipe.result_count or 1
  local craft_runs = math.ceil(missing_count / result_count)

  for _, ingredient in ipairs(recipe.ingredients or {}) do
    local ingredient_action = predicates.resolve_craft_action(
      entity,
      ingredient.name,
      ingredient.count * craft_runs,
      get_item_count,
      get_recipe_fn
    )
    if ingredient_action then
      return ingredient_action
    end
  end

  return {
    kind = "craft",
    item_name = item_name,
    count = craft_runs * result_count,
    craft_runs = craft_runs,
    recipe = recipe,
    result_count = result_count
  }
end

function predicates.resolve_required_items(entity, required_items, get_item_count, get_recipe_fn)
  for _, requirement in ipairs(required_items or {}) do
    local action = predicates.resolve_craft_action(entity, requirement.name, requirement.count, get_item_count, get_recipe_fn)
    if action then
      return action
    end
  end

  return nil
end

function predicates.should_pursue_milestone(builder_data, builder_state, milestone, get_item_count_fn, get_recipe_fn)
  if not (builder_state and milestone) then
    return false
  end

  local active_task = builder_state.scaling_active_task
  if active_task and active_task.completed_scaling_milestone_name == milestone.name then
    return true
  end

  if predicates.resolve_required_items(builder_state.entity, milestone.required_items, get_item_count_fn, get_recipe_fn) == nil then
    return true
  end

  if predicates.milestone_thresholds_met(builder_state.entity, get_item_count_fn, milestone) then
    return true
  end

  if milestone.pursue_proactively == true then
    return true
  end

  return builder_data.scaling and builder_data.scaling.pursue_milestones_proactively == true
end

function predicates.is_milestone_unlocked(builder_state, milestone, get_resource_site_counts)
  return unlock_requirements_met(builder_state, milestone and milestone.unlock, get_resource_site_counts)
end

return predicates
