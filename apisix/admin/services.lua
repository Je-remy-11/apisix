--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local get_routes = require("apisix.router").http_routes
local get_stream_routes = require("apisix.router").stream_routes
local resource_codegen = require("apisix.admin.resource_codegen")
local tostring = tostring
local ipairs = ipairs
local type = type


local function delete_checker(id)
    local routes, routes_ver = get_routes()
    core.log.info("routes: ", core.json.delay_encode(routes, true))
    core.log.info("routes_ver: ", routes_ver)
    if routes_ver and routes then
        for _, route in ipairs(routes) do
            if type(route) == "table" and route.value
               and route.value.service_id
               and tostring(route.value.service_id) == id then
                return 400, {error_msg = "can not delete this service directly,"
                                         .. " route [" .. route.value.id
                                         .. "] is still using it now"}
            end
        end
    end

    local stream_routes, stream_routes_ver = get_stream_routes()
    core.log.info("stream_routes: ", core.json.delay_encode(stream_routes, true))
    core.log.info("stream_routes_ver: ", stream_routes_ver)
    if stream_routes_ver and stream_routes then
        for _, route in ipairs(stream_routes) do
            if type(route) == "table" and route.value
               and route.value.service_id
               and tostring(route.value.service_id) == id then
                return 400, {error_msg = "can not delete this service directly,"
                                         .. " stream_route [" .. route.value.id
                                         .. "] is still using it now"}
            end
        end
    end

    return nil, nil
end


return resource_codegen.new({
    name = "services",
    kind = "service",
    schema = core.schema.service,
    checker = {
        steps = {
            {
                use = "schema",
            },
            {
                use = "upstream_conf",
                field = "upstream",
            },
            {
                use = "reference_exists",
                field = "upstream_id",
                key = "/upstreams/${value}",
                skip_option = "skip_references_check",
                fetch_error = "failed to fetch upstream info by upstream id [${value}]: ${err}",
                status_error = "failed to fetch upstream info by upstream id [${value}], response code: ${status}",
            },
            {
                use = "plugins_schema",
                field = "plugins",
                error_prefix = "",
            },
            {
                use = "script_lua_object",
                field = "script",
            },
        },
        success = true,
    },
    encrypt_conf = {
        steps = {
            {
                use = "upstream_encrypt",
                field = "upstream",
            },
            {
                use = "plugins_encrypt",
                field = "plugins",
            },
        },
    },
    delete_checker = delete_checker,
})
