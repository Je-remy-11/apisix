-- APISIX Admin Resource Spec: plugin_metadata
-- Demonstrates: no_id, no POST/PATCH, dynamic plugin loading,
--               inject_metadata_schema helper, custom encrypt_conf

return {
    name = "plugin_metadata",
    kind = "plugin_metadata",
    schema = "core.schema.plugin_metadata",
    no_id = true,

    unsupported_methods = {"post", "patch"},

    -- stanzas inserted before check_conf
    local_stanzas = {
        [[
local injected_mark = "injected metadata_schema"

local function validate_plugin(name)
    local pkg_name = "apisix.plugins." .. name
    local ok, plugin_object = pcall(require, pkg_name)
    if ok then
        return true, plugin_object
    end
    pkg_name = "apisix.stream.plugins." .. name
    return pcall(require, pkg_name)
end

local function inject_metadata_schema(plugin_object)
    if not plugin_object.metadata_schema then
        plugin_object.metadata_schema = {
            type = "object",
            ['$comment'] = injected_mark,
            properties = {},
        }
    end
end
]],
    },

    validations = {
        {type = "plugin_metadata_check"},
    },
}