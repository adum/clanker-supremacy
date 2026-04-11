local storage_helpers = {}

function storage_helpers.ensure_production_sites()
  if storage.production_sites == nil then
    storage.production_sites = {}
  end

  return storage.production_sites
end

function storage_helpers.ensure_resource_sites()
  if storage.resource_sites == nil then
    storage.resource_sites = {}
  end

  return storage.resource_sites
end

return storage_helpers
