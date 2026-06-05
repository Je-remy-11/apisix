-- APISIX Admin Resource Spec: upstreams
-- Demonstrates: complex delete_checker with multi-resource scanning

return {
    name = "upstreams",
    kind = "upstream",
    schema = "core.schema.upstream",

    encrypt = {
        upstream = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "delegate", condition = "conf",
         checker = "apisix_upstream.check_upstream_conf", arg = "conf"},
    },

    -- Upstreams has the most complex delete_checker in the codebase:
    -- checks all resource types (routes, services, plugin_configs,
    -- consumers, consumer_groups, global_rules) for references.
    -- The generator uses a built-in template for "upstreams".
    delete_checker = {
        {type = "route_ref", getter = "true", ref_field = "upstream_id",
         label = "upstream", error_tpl = "placeholder"},
    },

    imports = {
        "local config_util = require(\"apisix.core.config_util\")",
        "local get_routes = require(\"apisix.router\").http_routes",
        "local get_services = require(\"apisix.http.service\").services",
        "local get_plugin_configs = require(\"apisix.plugin_config\").plugin_configs",
        "local get_consumers = require(\"apisix.consumer\").consumers",
        "local get_consumer_groups = require(\"apisix.consumer_group\").consumer_groups",
        "local get_global_rules = require(\"apisix.global_rules\").global_rules",
    },
}