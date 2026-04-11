local util = {}

function util.deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, nested_value in pairs(value) do
    copy[util.deep_copy(key)] = util.deep_copy(nested_value)
  end

  return copy
end

return util
