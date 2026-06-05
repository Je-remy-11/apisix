--
-- APISIX Admin Resource Spec: consumers
-- ======================================
-- This spec generates apisix/admin/consumers.lua
--
-- Run: lua tools/resource-generator/generator.lua \
--          tools/resource-generator/specs/consumers.lua \
--          apisix/admin/consumers.lua
--
return {
    resource = {
        name = "consumers",
        kind = "consumer",
    },

    schema = "consumer",

    unsupported_methods = { "post", "patch" },

    checker = {
        mode = "composed",

        extra_checks = {
            {
                name = "username_consistency",
                code = [[
                    if id and id ~= conf.username then
                        return nil, {error_msg = "wrong username" }
                    end
                ]],
            },
            {
                name = "plugins_validation",
                requires = {
                    { module = "apisix.admin.plugins", as = "admin_plugins" },
                },
                code = [[
                    if conf.plugins then
                        local ok, err = admin_plugins.check_schema(conf.plugins, core.schema.TYPE_CONSUMER)
                        if not ok then
                            return nil, {error_msg = "invalid plugins configuration: " .. err}
                        end
                    end
                ]],
            },
            {
                name = "group_id_reference",
                code = [[
                    if conf.group_id and not opts.skip_references_check then
                        local key = "/consumer_groups/" .. conf.group_id
                        local res, err = core.etcd.get(key)
                        if not res then
                            return nil, {error_msg = "failed to fetch consumer group info by "
                                             .. "consumer group id [" .. conf.group_id .. "]: "
                                             .. err}
                        end

                        if res.status ~= 200 then
                            return nil, {error_msg = "failed to fetch consumer group info by "
                                             .. "consumer group id [" .. conf.group_id .. "], "
                                             .. "response code: " .. res.status}
                        end
                    end
                ]],
            },
        },

        return_value = "conf.username",
    },

    encrypt_conf = {
        mode = "plugins",
        schema_type = "TYPE_CONSUMER",
        local_name = "plugins_encrypt_conf",
    },

    delete_checker = nil,

    list_filter_fields = nil,

    extra_imports = {
        { module = "apisix.admin.plugins", as = "plugins" },
        { module = "apisix.admin.plugins", alias = "plugins_encrypt_conf", member = "encrypt_conf" },
    },
}
