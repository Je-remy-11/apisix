-- APISIX Admin Resource Spec: services
-- Demonstrates: delegate + etcd_ref + delete_checker across routes

return {
    name = "services",
    kind = "service",
    schema = "core.schema.service",

    encrypt = {
        upstream = true,
        plugins = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "delegate", condition = "conf.upstream",
         checker = "apisix_upstream.check_upstream_conf", arg = "upstream_val"},
        {type = "etcd_ref", field = "upstream_id", prefix = "/upstreams/",
         label = "upstream"},
        {type = "plugins_check"},
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

    delete_checker = {
        {type = "route_ref", getter = "get_routes()",
         ref_field = "service_id", label = "route",
         error_tpl = "can not delete this service directly, route [{}] is still using it now"},
        {type = "route_ref", getter = "get_stream_routes()",
         ref_field = "service_id", label = "stream_route",
         error_tpl = "can not delete this service directly, stream_route [{}] is still using it now"},
    },

    imports = {
        "local get_routes = require(\"apisix.router\").http_routes",
        "local get_stream_routes = require(\"apisix.router\").stream_routes",
    },
}