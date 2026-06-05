-- APISIX Admin Resource Spec: protos
-- Demonstrates: proto_compile_check, no PATCH, delete_checker for route/service refs

return {
    name = "protos",
    kind = "proto",
    schema = "core.schema.proto",

    unsupported_methods = {"patch"},

    validations = {
        {type = "schema_check"},
        {type = "proto_compile_check"},
    },

    delete_checker = {
        {type = "route_ref", getter = "get_routes()",
         ref_field = "proto_id", label = "route",
         error_tpl = "can not delete this proto, route [{}] is still using it now"},
        {type = "route_ref", getter = "get_services()",
         ref_field = "proto_id", label = "service",
         error_tpl = "can not delete this proto, service [{}] is still using it now"},
    },

    imports = {
        "local get_routes = require(\"apisix.router\").http_routes",
        "local get_services = require(\"apisix.http.service\").services",
        "local compile_proto = require(\"apisix.plugins.grpc-transcode.proto\").compile_proto",
    },
}