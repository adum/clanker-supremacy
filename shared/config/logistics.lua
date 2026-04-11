return {
  inventory_take_limits = {
    coal = 500,
    ["iron-plate"] = 500,
    stone = 500,
    ["copper-plate"] = 500
  },
  nearby_container_collection = {
    interval_ticks = 5 * 60,
    radius = 24,
    entity_types = {"container", "logistic-container"},
    own_force_only = true,
    max_containers_per_scan = 16,
    minimum_total_items_to_collect = 4
  },
  nearby_machine_refuel = {
    interval_ticks = 3 * 60,
    radius = 24,
    fuel_name = "coal",
    target_fuel_item_count = 20,
    own_force_only = true,
    max_entities_per_scan = 24
  },
  nearby_machine_input_supply = {
    interval_ticks = 4 * 60,
    radius = 24,
    entity_types = {"assembling-machine"},
    target_ingredient_item_count = 20,
    minimum_item_transfer_count = 4,
    own_force_only = true,
    max_entities_per_scan = 12
  },
  nearby_machine_output_collection = {
    interval_ticks = 4 * 60,
    radius = 24,
    entity_types = {"furnace"},
    minimum_total_items_to_collect = 4,
    own_force_only = true,
    max_entities_per_scan = 12
  },
  production_transfer = {
    interval_ticks = 30
  }
}
