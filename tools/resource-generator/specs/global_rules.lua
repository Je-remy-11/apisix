--
-- APISIX Admin Resource Spec: global_rules
-- =========================================
-- This spec generates apisix/admin/global_rules.lua
--
-- Run: lua tools/resource-generator/generator.lua \
--          tools/resource-generator/specs/global_rules.lua \
--          apisix/admin/global_rules.lua
--
return {
    resource = {
        name = "global_rules",
        kind = "global rule",
    },

    schema = "global_rule",

    unsupported_methods = { "post" },

    checker = {
        mode = "custom",
        code = [[
            local ok, err = core.schema.check(schema, conf)
            if not ok then
                return nil, {error_msg = "invalid configuration: " .. err}
            end

            local ok, err = schema_plugin(conf.plugins)
            if not ok then
                return nil, {error_msg = err}
            end

            -- Check for plugin conflicts with existing global rules
            if conf.plugins then
                local global_rules = get_global_rules()
                if global_rules then
                    for _, existing_rule in ipairs(global_rules) do
                        -- Skip checking against itself when updating
                        if existing_rule.value and existing_rule.value.id and
                           tostring(existing_rule.value.id) ~= tostring(id) then

                            if existing_rule.value.plugins then
                                -- Check for any overlapping plugins
                                for plugin_name, _ in pairs(conf.plugins) do
                                    if existing_rule.value.plugins[plugin_name] then
                                        return nil, {
                                            error_msg = "plugin '" .. plugin_name ..
                                            "' already exists in global rule with id '" ..
                                            existing_rule.value.id .. "'"
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end

            return true
        ]],
    },

    encrypt_conf = {
        mode = "plugins",
        local_name = "plugins_encrypt_conf",
    },

    delete_checker = nil,

    list_filter_fields = nil,

    extra_imports = {
        { module = "apisix.admin.plugins", as = "schema_plugin" },
        { module = "apisix.admin.plugins", alias = "plugins_encrypt_conf", member = "encrypt_conf" },
    },
}
