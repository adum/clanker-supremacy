local production = require("scripts.world.production")
local queries = require("scripts.world.queries")
local sites = require("scripts.world.sites")
local storage_helpers = require("scripts.world.storage")

local world_model = {}

function world_model.ensure_production_sites(_ctx)
  return storage_helpers.ensure_production_sites()
end

function world_model.ensure_resource_sites(_ctx)
  return storage_helpers.ensure_resource_sites()
end

function world_model.get_site_pattern(pattern_name, ctx)
  return sites.get_site_pattern(pattern_name, ctx)
end

function world_model.find_machine_site_near_resource_sites(builder_state, task, ctx)
  return queries.find_machine_site_near_resource_sites(builder_state, task, ctx)
end

function world_model.find_layout_site_near_machine(builder_state, task, ctx)
  return queries.find_layout_site_near_machine(builder_state, task, ctx)
end

function world_model.find_output_belt_line_site(builder_state, task, ctx)
  return queries.find_output_belt_line_site(builder_state, task, ctx)
end

function world_model.find_assembly_block_site(builder_state, task, ctx)
  return queries.find_assembly_block_site(builder_state, task, ctx)
end

function world_model.find_assembly_input_route_site(builder_state, task, ctx)
  return queries.find_assembly_input_route_site(builder_state, task, ctx)
end

function world_model.register_smelting_site(task, miner, downstream_machine, output_container, ctx)
  return production.register_smelting_site(task, miner, downstream_machine, output_container, ctx)
end

function world_model.register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
  return production.register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
end

function world_model.register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
  return production.register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
end

function world_model.register_output_belt_site(task, output_machine, output_inserter, belt_entities, hub_position, ctx)
  return production.register_output_belt_site(task, output_machine, output_inserter, belt_entities, hub_position, ctx)
end

function world_model.register_assembly_block_site(task, anchor_entity, root_assembler, placed_layout_entities, ctx)
  return production.register_assembly_block_site(task, anchor_entity, root_assembler, placed_layout_entities, ctx)
end

function world_model.register_assembly_input_route(task, assembly_site, route_id, belt_entities, source_site, ctx)
  return production.register_assembly_input_route(task, assembly_site, route_id, belt_entities, source_site, ctx)
end

function world_model.process_production_sites(tick, ctx)
  return production.process_production_sites(tick, ctx)
end

function world_model.get_site_collect_inventory(site, ctx)
  return sites.get_site_collect_inventory(site, ctx)
end

function world_model.get_site_collect_position(site, ctx)
  return sites.get_site_collect_position(site, ctx)
end

function world_model.get_site_allowed_items(site, ctx)
  return sites.get_site_allowed_items(site, ctx)
end

function world_model.get_site_collect_count(site, item_name, ctx)
  return sites.get_site_collect_count(site, item_name, ctx)
end

function world_model.cleanup_resource_sites(_ctx)
  return sites.cleanup_resource_sites()
end

function world_model.get_resource_site_counts(_ctx)
  return sites.get_resource_site_counts()
end

function world_model.register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
  return sites.register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
end

function world_model.discover_resource_sites(builder_state, ctx, options)
  return sites.discover_resource_sites(builder_state, ctx, options)
end

function world_model.find_resource_site(surface, force, origin, task, ctx)
  return queries.find_resource_site(surface, force, origin, task, ctx)
end

function world_model.find_nearest_resource(surface, origin, task, ctx)
  return queries.find_nearest_resource(surface, origin, task, ctx)
end

return world_model
