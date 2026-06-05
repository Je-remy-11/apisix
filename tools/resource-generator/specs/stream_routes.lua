-- APISIX Admin Resource Spec: stream_routes
-- Demonstrates: etcd_ref[upstream, service] + protocol parent reference + route_ref delete_checker

return {
    name = "stream_routes",
    kind = "stream route",
    schema = "core.schema.stream_route",

    unsupported_methods = {"patch"},

    list_filter_fields = {
        service_id = true,
        upstream_id = true,
    },

    validations = {
        {type = "schema_check"},
        {type = "etcd_ref", field = "upstream_id", prefix = "/upstreams/",
         label = "upstream"},
        {type = "etcd_ref", field = "service_id", prefix = "/services/",
         label = "service info"},
        {type = "etcd_protocol_ref", prefix = "/stream_routes/"},
        {type = "stream_route_checker"},
    },

    delete_checker = {
        {type = "inline", code = [[
    local key = "/stream_routes"
    local res, err = core.etcd.get(key, {prefix = true})
    if not res then
        return nil, {error_msg = "failed to fetch stream routes: " .. err}
    end
    if res.status ~= 200 then
        return nil, {error_msg = "failed to fetch stream routes, response code: " .. res.status}
    end
    local nodes = res.body.list
    if not nodes then
        if res.body.node and res.body.node.nodes then
            nodes = res.body.node.nodes
        end
    end
    if not nodes then
        return true
    end
    for _, item in ipairs(nodes) do
        local route = item.value
        if type(route) == "string" then
            route = core.json.decode(route)
        end
        if route and route.protocol and tostring(route.protocol.superior_id) == id then
            return 400, {error_msg = "can not delete this stream route directly, stream route ["
                                     .. route.id .. "] is still using it as superior_id"}
        end
    end
    return true
]]},
    },

    imports = {
        "local stream_route_checker = require(\"apisix.stream.router.ip_port\").stream_route_checker",
    },
}