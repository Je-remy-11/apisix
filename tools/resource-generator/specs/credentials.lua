-- APISIX Admin Resource Spec: credentials
-- Demonstrates: get_resource_etcd_key custom function, auth-only plugin restriction

return {
    name = "credentials",
    kind = "credential",
    schema = "core.schema.credential",

    unsupported_methods = {"post", "patch"},

    encrypt = {
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "plugins_check_consumer"},
        {type = "credentials_auth_check"},
    },

    imports = {
        "local plugins = require(\"apisix.admin.plugins\")",
        "local plugin = require(\"apisix.plugin\")",
    },

    -- Custom function for building etcd key
    custom_functions = {
        [[
local function get_credential_etcd_key(credential_id, _conf, sub_path, _args)
    if credential_id then
        local uri_segs = core.utils.split_uri(sub_path)
        local consumer_name = uri_segs[1]
        return "/consumers/" .. consumer_name .. "/credentials/" .. credential_id
    end
    return "/consumers/" .. sub_path
end
]],
    },

    get_resource_etcd_key = true,
}