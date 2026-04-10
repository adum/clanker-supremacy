local builder_data = require("shared.builder_data")

local firearm_magazine_assembler = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-1"])

firearm_magazine_assembler.name = builder_data.prototypes.firearm_magazine_assembler_name
firearm_magazine_assembler.localised_name = {"entity-name.assembling-machine-1"}
firearm_magazine_assembler.localised_description = {"entity-description.enemy-builder-firearm-magazine-assembler"}
firearm_magazine_assembler.fixed_recipe = "firearm-magazine"
firearm_magazine_assembler.disabled_when_recipe_not_researched = false

if firearm_magazine_assembler.minable then
  firearm_magazine_assembler.minable.result = "assembling-machine-1"
end

data:extend({firearm_magazine_assembler})
