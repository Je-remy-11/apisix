--
-- APISIX Admin Resource Spec: consumer_groups
-- ============================================
-- This spec generates apisix/admin/consumer_group.lua
--
-- Run: lua tools/resource-generator/generator.lua \
--          tools/resource-generator/specs/consumer_groups.lua \
--          apisix/admin/consumer_group.lua
--
return {
    resource = {
        name = "consumer_groups",
        kind = "consumer group",
    },

    schema = "consumer_group",

    unsupported_methods = { "post" },

    checker = {
        mode = "composed",

        extra_checks = {
            {
                name = "plugins_validation",
                requires = {
                    { module = "apisix.admin.plugins", as = "schema_plugin" },
                },
                code = [[
                    local ok, err = schema_plugin(conf.plugins)
                    if not ok then
                        return nil, {error_msg = err}
                    end
                ]],
            },
        },

        return_value = "true",
    },

    encrypt_conf = {
        mode = "plugins",
        local_name = "plugins_encrypt_conf",
    },

    delete_checker = {
        mode = "builtin_reference",
        reference_resource = "consumers",
        reference_field = "group_id",
        get_function = "consumers",
        error_msg_template = "can not delete this consumer group, consumer [{ref_id}] is still using it now",
    },

    list_filter_fields = nil,

    extra_imports = {
        { module = "apisix.consumer", member = "consumers" },
        { module = "apisix.admin.plugins", as = "schema_plugin" },
        { module = "apisix.admin.plugins", alias = "plugins_encrypt_conf", member = "encrypt_conf" },
    },
}
