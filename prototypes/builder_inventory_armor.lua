local builder_data = require("shared.builder_data")

local armor = table.deepcopy(data.raw.armor["light-armor"])

armor.name = builder_data.avatar.armor_prototype_name
armor.localised_name = {"item-name.enemy-builder-inventory-armor"}
armor.localised_description = {"item-description.enemy-builder-inventory-armor"}
armor.hidden = true
armor.auto_recycle = false
armor.subgroup = "other"
armor.order = "z[enemy-builder]-a[inventory-armor]"
armor.resistances = {}
armor.equipment_grid = nil
armor.inventory_size_bonus = builder_data.avatar.armor_inventory_bonus
armor.factoriopedia_simulation = nil

data:extend({armor})
