-- APISIX Admin Resource Spec: plugin_configs
-- Demonstrates: plugins_check + delete_checker for route references

return {
    name = "plugin_configs",
    kind = "plugin config",
    schema = "core.schema.plugin_config",

    unsupported_methods = {"post"},

    encrypt = {
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "plugins_check"},
    },

    delete_checker = {
        {type = "route_ref", getter = "get_routes()",
         ref_field = "plugin_config_id", label = "route",
         error_tpl = "can not delete this plugin config, route [{}] is still using it now"},
    },

    imports = {
        "local get_routes = require(\"apisix.router\").http_routes",
    },
}