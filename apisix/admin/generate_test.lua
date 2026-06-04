--
-- Test Resource Generator
--

local resource_generator = require("apisix.admin.resource_generator")

local consumers_def = {
    name = "consumers",
    kind = "consumer",
    schema = "core.schema.consumer",
    return_id_field = "username",
    imports = {
        { name = "core", path = "apisix.core" },
        { name = "plugins", path = "apisix.admin.plugins" },
    },
    custom_imports = {
        "local plugins_encrypt_conf = require(\"apisix.admin.plugins\").encrypt_conf"
    },
    check_conf = {
        { type = "schema" },
        { 
            type = "id_consistency", 
            id_var = "id", 
            conf_field = "username" 
        },
        { 
            type = "plugins", 
            module = "plugins", 
            schema_type = "core.schema.TYPE_CONSUMER" 
        },
        { 
            type = "reference_check", 
            field = "group_id", 
            resource = "consumer_groups", 
            resource_desc = "consumer group" 
        },
    },
    encrypt_conf = {
        "plugins_encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)"
    },
    unsupported_methods = { "post", "patch" },
}

local code = resource_generator.generate(consumers_def)
print("=== Generated consumers.lua ===")
print(code)
