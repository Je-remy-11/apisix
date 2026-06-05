-- APISIX Admin Resource Spec: global_rules
-- Demonstrates: plugin conflict detection across global rules + no POST

return {
    name = "global_rules",
    kind = "global rule",
    schema = "core.schema.global_rule",

    unsupported_methods = {"post"},

    encrypt = {
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "plugins_check"},
        {type = "global_rule_plugin_conflict"},
    },
}