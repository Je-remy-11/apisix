-- APISIX Admin Resource Spec: routes (Lua DSL version)
--
-- This Lua table format is the native DSL. It is equivalent to the YAML spec
-- in specs/routes.yaml but avoids the YAML parser dependency.
--
-- Usage: resty generator.lua spec/routes.lua --output-dir ./apisix/admin

return {
    name = "routes",
    kind = "route",
    schema = "core.schema.route",

    -- Route-level options
    unsupported_methods = {},
    list_filter_fields = {
        service_id = true,
        upstream_id = true,
    },

    -- Extra imports
    imports = {
        "local expr = require(\"resty.expr.v1\")",
        "local jp = require(\"jsonpath\")",
    },

    -- Encryption configuration
    encrypt = {
        upstream = true,
        plugins = true,
    },

    -- Validation steps executed in order in check_conf()
    validations = {
        -- Step 1: JSON Schema validation
        {type = "schema_check"},

        -- Step 2: Mutual exclusion checks
        {type = "assert_not_both", fields = {"host", "hosts"},
         msg = "only one of host or hosts is allowed"},
        {type = "assert_not_both", fields = {"remote_addr", "remote_addrs"},
         msg = "only one of remote_addr or remote_addrs is allowed"},

        -- Step 3: Upstream config validation
        {type = "delegate", condition = "conf.upstream",
         checker = "apisix_upstream.check_upstream_conf", arg = "upstream_val"},

        -- Step 4: etcd reference checks
        {type = "etcd_ref", field = "upstream_id", prefix = "/upstreams/",
         label = "upstream"},
        {type = "etcd_ref", field = "service_id", prefix = "/services/",
         label = "service info"},
        {type = "etcd_ref", field = "plugin_config_id", prefix = "/plugin_configs/",
         label = "plugin config"},

        -- Step 5: Plugin schema validation
        {type = "plugins_check"},

        -- Step 6-8: Inline Lua for complex expressions
        {type = "inline", condition = "conf.vars", code = [[
            local ok, err = expr.new(conf.vars)
            if not ok then
                return nil, {error_msg = "failed to validate the 'vars' expression: " .. err}
            end
        ]]},
        {type = "inline", condition = "conf.filter_func", code = [[
            local func, err = loadstring("return " .. conf.filter_func)
            if not func then
                return nil, {error_msg = "failed to load 'filter_func' string: " .. err}
            end
            if type(func()) ~= "function" then
                return nil, {error_msg = "'filter_func' should be a function"}
            end
        ]]},
        {type = "inline", condition = "conf.script", code = [[
            local obj, err = loadstring(conf.script)
            if not obj then
                return nil, {error_msg = "failed to load 'script' string: " .. err}
            end
            if type(obj()) ~= "table" then
                return nil, {error_msg = "'script' should be a Lua object"}
            end
        ]]},
    },

    -- Pre-deletion checks: verify no route/stream_route references this service
    delete_checker = {
        {type = "route_ref", getter = "get_routes()",
         ref_field = "service_id", label = "route",
         error_tpl = "can not delete this service directly, route [{}] is still using it now"},
        {type = "route_ref", getter = "get_stream_routes()",
         ref_field = "service_id", label = "stream_route",
         error_tpl = "can not delete this service directly, stream_route [{}] is still using it now"},
    },
}