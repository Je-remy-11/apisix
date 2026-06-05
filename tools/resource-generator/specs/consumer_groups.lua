-- APISIX Admin Resource Spec: consumer_groups
-- Demonstrates: plugins_check + delete_checker for consumer references

return {
    name = "consumer_groups",
    kind = "consumer group",
    schema = "core.schema.consumer_group",

    unsupported_methods = {"post"},

    encrypt = {
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "plugins_check"},
    },

    delete_checker = {
        {type = "route_ref", getter = "consumers()",
         ref_field = "group_id", label = "consumer",
         error_tpl = "can not delete this consumer group, consumer [{}] is still using it now"},
    },

    imports = {
        "local consumers = require(\"apisix.consumer\").consumers",
    },
}