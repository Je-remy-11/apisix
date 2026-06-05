--
-- APISIX Admin Resource Spec: plugin_metadata
-- ============================================
-- This spec generates apisix/admin/plugin_metadata.lua
--
-- Run: lua tools/resource-generator/generator.lua \
--          tools/resource-generator/specs/plugin_metadata.lua \
--          apisix/admin/plugin_metadata.lua
--
return {
    resource = {
        name = "plugin_metadata",
        kind = "plugin_metadata",
    },

    schema = "plugin_metadata",

    unsupported_methods = { "post", "patch" },

    checker = {
        mode = "custom",
        code = [[
            local plugin_name = conf.name or conf._meta_name
            if not plugin_name then
                return nil, {error_msg = "missing plugin name"}
            end

            local plugin_object = require("apisix.plugins." .. plugin_name)
            if not plugin_object then
                return nil, {error_msg = "unknown plugin: " .. plugin_name}
            end

            if plugin_object.check_schema then
                local ok, err = plugin_object.check_schema(conf, core.schema.TYPE_METADATA)
                if not ok then
                    return nil, {error_msg = err}
                end
            end

            return true
        ]],
    },

    encrypt_conf = {
        mode = "custom",
        code = [[
            local plugin_name = conf.name or conf._meta_name
            if plugin_name then
                local plugin_object = require("apisix.plugins." .. plugin_name)
                if plugin_object then
                    plugin_encrypt_conf(plugin_name, conf, core.schema.TYPE_METADATA)
                end
            end
        ]],
    },

    delete_checker = nil,

    list_filter_fields = nil,

    extra_imports = {
        { module = "apisix.admin.plugins", alias = "plugin_encrypt_conf", member = "encrypt_conf" },
    },
}
