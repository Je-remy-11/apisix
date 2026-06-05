-- APISIX Admin Resource Spec: consumers (Lua DSL version)
-- Demonstrates:
--   1. no_id = true (consumers use username as identity)
--   2. unsupported_methods
--   3. Custom username matching (id must equal conf.username)
--   4. etcd_ref for group_id with consumer_group reference check
--   5. plugins_check_consumer (plugin validation)

return {
    name = "consumers",
    kind = "consumer",
    schema = "core.schema.consumer",
    no_id = true,

    unsupported_methods = {"post", "patch"},

    encrypt = {
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "username_match"},
        {type = "plugins_check_consumer"},
        {type = "etcd_ref", field = "group_id", prefix = "/consumer_groups/",
         label = "consumer group info"},
    },
}