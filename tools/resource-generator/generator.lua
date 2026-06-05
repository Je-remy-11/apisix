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

--- APISIX Admin Resource Code Generator
--
-- Reads a resource DSL spec (YAML or Lua table) and generates a complete
-- `apisix/admin/<name>.lua` module that follows the `resource.new()` pattern.
--
-- Usage (CLI):
--   resty generator.lua specs/routes.yaml [--stdout] [--output-dir ./apisix/admin]
--
-- Usage (library):
--   local gen = require("tools.resource-generator.generator")
--   local code = gen.generate(spec_table)
--   gen.write_file("apisix/admin/routes.lua", code)

local lyaml = require("lyaml")
local cjson = require("cjson.safe")
local ipairs = ipairs
local pairs = pairs
local type = type
local tostring = tostring
local table_insert = table.insert
local table_concat = table.concat
local io_open = io.open
local io_stderr = io.stderr
local os_exit = os.exit

local _M = {}

-- Default Apache license header
local LICENSE_HEADER = [[
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
]]

-- Mapping of validation step types to Lua code generators
local VALIDATION_GENERATORS = {}


--- Generate schema_check step
-- Always runs `core.schema.check(schema, conf)` first.
VALIDATION_GENERATORS.schema_check = function(_step)
    return [[
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end
]]
end


--- Generate assert_not_both step
-- Rejects the config if two mutually-exclusive fields are both present.
VALIDATION_GENERATORS.assert_not_both = function(step)
    local fields = step.fields
    if #fields ~= 2 then
        error("assert_not_both requires exactly 2 fields")
    end
    return string.format([[
    if conf.%s and conf.%s then
        return nil, {error_msg = "%s"}
    end
]], fields[1], fields[2], step.msg or "only one of " .. fields[1] .. " or " .. fields[2] .. " is allowed")
end


--- Generate assert_if step
-- Rejects the config if a given condition is true.
VALIDATION_GENERATORS.assert_if = function(step)
    return string.format([[
    if %s then
        return nil, {error_msg = "%s"}
    end
]], step.condition, step.msg or "assertion failed")
end


--- Generate delegate step
-- Delegates to an external checker function (e.g. apisix_upstream.check_upstream_conf).
-- The `on` field specifies what to pass as argument.
VALIDATION_GENERATORS.delegate = function(step)
    if not step.condition then
        -- unconditional: always call the checker
        return string.format([[
    local ok, err = %s(%s)
    if not ok then
        return nil, {error_msg = err}
    end
]], step.checker, step.arg or "conf")
    end
    return string.format([[
    local %s_val = %s
    if %s_val then
        local ok, err = %s(%s_val)
        if not ok then
            return nil, {error_msg = err}
        end
    end
]], step.field or "delegate_arg", step.condition, step.field or "delegate_arg",
   step.checker, step.field or "delegate_arg")
end


--- Generate etcd_ref step
-- Checks that a referenced resource (by ID) exists in etcd.
-- e.g. upstream_id -> GET /upstreams/{id}
VALIDATION_GENERATORS.etcd_ref = function(step)
    local label = step.label or step.field
    return string.format([[
    local %s = conf.%s
    if %s and not opts.skip_references_check then
        local key = "%s" .. %s
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch %s info by "
                                     .. "%s id [" .. %s .. "]: "
                                     .. err}
        end
        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch %s info by "
                                     .. "%s id [" .. %s .. "], "
                                     .. "response code: " .. res.status}
        end
    end
]],
    step.field, step.field, step.field, step.prefix, step.field,
    label, step.field, step.field,
    label, step.field, step.field)
end


--- Generate plugins_check step
-- Validates plugin configurations via schema_plugin().
VALIDATION_GENERATORS.plugins_check = function(_step)
    return [[
    if conf.plugins then
        local ok, err = schema_plugin(conf.plugins)
        if not ok then
            return nil, {error_msg = err}
        end
    end
]]
end


--- Generate plugins_check with consumer type
VALIDATION_GENERATORS.plugins_check_consumer = function(_step)
    return [[
    if conf.plugins then
        local ok, err = schema_plugin(conf.plugins, core.schema.TYPE_CONSUMER)
        if not ok then
            return nil, {error_msg = "invalid plugins configuration: " .. err}
        end
    end
]]
end


--- Generate inline step
-- Embeds raw Lua code directly into the check_conf body.
-- If a `condition` is given, wraps the code in `if <condition> then ... end`.
VALIDATION_GENERATORS.inline = function(step)
    if step.condition then
        return string.format([[
    if %s then
%s
    end
]], step.condition, _indent(step.code, 4))
    end
    return step.code
end


--- Generate identity_return step
-- Used by consumers/plugin_metadata where check_conf returns a value
-- different from true/false (e.g., returns the username).
VALIDATION_GENERATORS.identity_return = function(step)
    return string.format([[
    return %s
]], step.return_value or "true")
end


--- Generate custom field validation
-- e.g., username must match the resource id
VALIDATION_GENERATORS.username_match = function(_step)
    return [[
    if id and id ~= conf.username then
        return nil, {error_msg = "wrong username" }
    end
]]
end


--- Generate etcd protocol reference check (for stream_routes)
VALIDATION_GENERATORS.etcd_protocol_ref = function(step)
    return string.format([[
    if conf.protocol and conf.protocol.superior_id and not opts.skip_references_check then
        local superior_id = conf.protocol.superior_id
        local key = "%s" .. superior_id
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch stream routes[" .. superior_id .. "]: "
                                     .. err}
        end
        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch stream routes[" .. superior_id
                                     .. "], response code: " .. res.status}
        end
        local superior_route = res.body.node.value
        if type(superior_route) == "string" then
            superior_route = core.json.decode(superior_route)
        end
        if superior_route and superior_route.protocol
           and superior_route.protocol.name ~= conf.protocol.name then
            return nil, {error_msg = "protocol mismatch: subordinate protocol ["
                                     .. conf.protocol.name .. "] does not match superior protocol ["
                                     .. superior_route.protocol.name .. "]"}
        end
    end
]], step.prefix or "/stream_routes/")
end


--- Generate stream route checker call
VALIDATION_GENERATORS.stream_route_checker = function(_step)
    return [[
    local ok, err = stream_route_checker(conf, true)
    if not ok then
        return nil, {error_msg = err}
    end
]]
end


--- Generate ssl check delegate
VALIDATION_GENERATORS.ssl_check = function(_step)
    return [[
    local ok, err = apisix_ssl.check_ssl_conf(false, conf)
    if not ok then
        return nil, {error_msg = err}
    end
]]
end


--- Generate secrets dynamic checker
VALIDATION_GENERATORS.secrets_check = function(_step)
    return [[
    opts = opts or {}
    if not opts.secret_type then
        return nil, {error_msg = "missing secret type"}
    end
    local ok, secret_manager = pcall(require, "apisix.secret." .. opts.secret_type)
    if not ok then
        return false, {error_msg = "invalid secret manager: " .. opts.secret_type}
    end
    local ok, err = core.schema.check(secret_manager.schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end
]]
end


--- Generate global_rules plugin conflict check
VALIDATION_GENERATORS.global_rule_plugin_conflict = function(_step)
    return [[
    if conf.plugins then
        local global_rules = get_global_rules()
        if global_rules then
            for _, existing_rule in ipairs(global_rules) do
                if existing_rule.value and existing_rule.value.id and
                   tostring(existing_rule.value.id) ~= tostring(id) then
                    if existing_rule.value.plugins then
                        for plugin_name, _ in pairs(conf.plugins) do
                            if existing_rule.value.plugins[plugin_name] then
                                return nil, {
                                    error_msg = "plugin '" .. plugin_name ..
                                    "' already exists in global rule with id '" ..
                                    existing_rule.value.id .. "'"
                                }
                            end
                        end
                    end
                end
            end
        end
    end
]]
end


--- Generate upstream_id in plugins check (for traffic-split plugin)
VALIDATION_GENERATORS.upstream_in_plugins_check = function(_step)
    return [[
    if conf.plugins and conf.plugins["traffic-split"]
        and conf.plugins["traffic-split"].rules then
        for _, rule in ipairs(conf.plugins["traffic-split"].rules) do
            local plugin_upstreams = rule.weighted_upstreams
            if plugin_upstreams then
                for _, plugin_upstream in ipairs(plugin_upstreams) do
                    if plugin_upstream.upstream_id then
                        local up_key = "/upstreams/" .. plugin_upstream.upstream_id
                        local up_res, up_err = core.etcd.get(up_key)
                        if not up_res then
                            return nil, {error_msg = "failed to fetch upstream info by "
                                                     .. "upstream id [" .. plugin_upstream.upstream_id .. "]: "
                                                     .. up_err}
                        end
                        if up_res.status ~= 200 then
                            return nil, {error_msg = "failed to fetch upstream info by "
                                                     .. "upstream id [" .. plugin_upstream.upstream_id .. "], "
                                                     .. "response code: " .. up_res.status}
                        end
                    end
                end
            end
        end
    end
]]
end


--- Generate credentials auth-type-only plugin check
VALIDATION_GENERATORS.credentials_auth_check = function(_step)
    return [[
    if conf.plugins then
        for name, _ in pairs(conf.plugins) do
            local plugin_obj = plugin.get(name)
            if not plugin_obj then
                return nil, {error_msg = "unknown plugin " .. name}
            end
            if plugin_obj.type ~= "auth" then
                return nil, {error_msg = "only supports auth type plugins in consumer credential"}
            end
        end
    end
]]
end


--- Generate proto compilation check
VALIDATION_GENERATORS.proto_compile_check = function(_step)
    return [[
    local ok, err = compile_proto(conf.content)
    if not ok then
        return nil, {error_msg = "invalid content: " .. err}
    end
]]
end


--- Generate plugin_metadata dynamic schema check
VALIDATION_GENERATORS.plugin_metadata_check = function(_step)
    return [[
    if not id then
        return nil, {error_msg = "missing plugin name"}
    end
    local ok, plugin_object = validate_plugin(id)
    if not ok then
        return nil, {error_msg = "invalid plugin name"}
    end
    inject_metadata_schema(plugin_object)
    local schema = plugin_object.metadata_schema
    local ok, err
    if schema['$comment'] == injected_mark
      or not plugin_object.check_schema
    then
        ok, err = core.schema.check(schema, conf)
    else
        ok, err = plugin_object.check_schema(conf, core.schema.TYPE_METADATA)
    end
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end
]]
end


-- Helper: indent multi-line code
local function _indent(code, spaces)
    local prefix = string.rep(" ", spaces)
    local lines = {}
    for line in code:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            table_insert(lines, prefix .. line)
        else
            table_insert(lines, "")
        end
    end
    return table_concat(lines, "\n")
end


-- Helper: generate the module name from spec name
-- e.g., "plugin_configs" -> "apisix.admin.plugin_config"
local function _module_path(name)
    return "apisix.admin." .. name:gsub("/", ".")
end


-- Helper: generate the return value for check_conf
-- Most resources return `true`, but some return `id`, `username`, or `plugin_name`.
-- Resources with `no_id` like consumers return a specific value.
-- Resources like secrets return `true` via the checker.
local function _check_conf_return(spec)
    if spec.no_id then
        -- consumers return conf.username, plugin_metadata returns plugin_name
        if spec.name == "consumers" then
            return "conf.username"
        elseif spec.name == "plugin_metadata" then
            return "id"
        end
    end
    return "true"
end


--- Build the `check_conf` function body from a list of validation steps.
-- @param spec - the full resource spec table
-- @return string - Lua source code for the check_conf function
local function _build_check_conf(spec)
    local steps = spec.validations
    if not steps or #steps == 0 then
        -- default: just schema check + return
        return string.format([[
local function check_conf(id, conf, need_id, schema, opts)
    opts = opts or {}
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end
    return %s
end
]], _check_conf_return(spec))
    end

    local lines = {
        "local function check_conf(id, conf, need_id, schema, opts)",
        "    opts = opts or {}",
    }

    for _, step in ipairs(steps) do
        local generator = VALIDATION_GENERATORS[step.type]
        if not generator then
            error("unknown validation type: " .. tostring(step.type))
        end
        local snippet = generator(step)
        for snippet_line in snippet:gmatch("([^\n]*)\n?") do
            if snippet_line ~= "" then
                table_insert(lines, "    " .. snippet_line)
            end
        end
    end

    -- add the return statement
    table_insert(lines, "    return " .. _check_conf_return(spec))
    table_insert(lines, "end")
    table_insert(lines, "")

    return table_concat(lines, "\n")
end


--- Build the `encrypt_conf` function body.
-- @param spec - the full resource spec table
-- @return string - Lua source code for the encrypt_conf function
local function _build_encrypt_conf(spec)
    local parts = {}
    if spec.encrypt then
        if spec.encrypt.upstream then
            table_insert(parts, "    apisix_upstream.encrypt_conf(conf.upstream)")
        end
        if spec.encrypt.plugins then
            if spec.name == "consumers" or spec.name == "credentials" then
                table_insert(parts, "    plugins_encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)")
            else
                table_insert(parts, "    plugins_encrypt_conf(conf.plugins)")
            end
        end
        if spec.encrypt.custom then
            table_insert(parts, _indent(spec.encrypt.custom, 4))
        end
    end
    -- plugin_metadata has special encrypt_conf
    if spec.name == "plugin_metadata" then
        return [[
local function encrypt_conf(id, conf)
    if not id then
        core.log.info("missing plugin name")
        return
    end
    local ok, plugin_object = validate_plugin(id)
    if not ok then
        core.log.info("invalid plugin name")
        return
    end
    inject_metadata_schema(plugin_object)
    local schema = plugin_object.metadata_schema
    if schema['$comment'] ~= injected_mark and plugin_object.check_schema then
        plugin_encrypt_conf(id, conf, core.schema.TYPE_METADATA)
    end
end
]]
    end
    if #parts == 0 then
        return ""
    end
    return "local function encrypt_conf(id, conf)\n" .. table_concat(parts, "\n") .. "\nend\n"
end


--- Build the `delete_checker` function body.
-- @param spec - the full resource spec table
-- @return string - Lua source code for the delete_checker function
local function _build_delete_checker(spec)
    local checks = spec.delete_checker
    if not checks or #checks == 0 then
        return ""
    end

    if spec.name == "upstreams" then
        -- special case: upstreams has a complex multi-resource delete checker
        -- that uses helper functions
        return [[
local function up_id_in_plugins(plugins, up_id)
    if plugins and plugins["traffic-split"]
        and plugins["traffic-split"].rules then
        for _, rule in ipairs(plugins["traffic-split"].rules) do
            local plugin_upstreams = rule.weighted_upstreams
            for _, plugin_upstream in ipairs(plugin_upstreams) do
                if plugin_upstream.upstream_id
                    and tostring(plugin_upstream.upstream_id) == up_id then
                     return true
                end
            end
        end
        return false
    end
end

local function check_resources_reference(resources, up_id,
                                         only_check_plugin, resources_name)
    if resources then
        for _, resource in config_util.iterate_values(resources) do
            if resource and resource.value then
                if up_id_in_plugins(resource.value.plugins, up_id) then
                    return {error_msg = "can not delete this upstream,"
                                        .. " plugin in "
                                        .. resources_name .. " ["
                                        .. resource.value.id
                                        .. "] is still using it now"}
                end
                if not only_check_plugin and resource.value.upstream_id
                    and tostring(resource.value.upstream_id) == up_id then
                     return {error_msg = "can not delete this upstream, "
                                         .. resources_name .. " [" .. resource.value.id
                                         .. "] is still using it now"}
                end
            end
        end
    end
end

local function delete_checker(id)
    local routes = get_routes()
    local err_msg = check_resources_reference(routes, id, false, "route")
    if err_msg then
        return 400, err_msg
    end
    local services, services_ver = get_services()
    core.log.info("services: ", core.json.delay_encode(services, true))
    core.log.info("services_ver: ", services_ver)
    local err_msg = check_resources_reference(services, id, false, "service")
    if err_msg then
        return 400, err_msg
    end
    local plugin_configs = get_plugin_configs()
    local err_msg = check_resources_reference(plugin_configs, id, true, "plugin_config")
    if err_msg then
        return 400, err_msg
    end
    local consumers = get_consumers()
    local err_msg = check_resources_reference(consumers, id, true, "consumer")
    if err_msg then
        return 400, err_msg
    end
    local consumer_groups = get_consumer_groups()
    local err_msg = check_resources_reference(consumer_groups, id, true, "consumer_group")
    if err_msg then
        return 400, err_msg
    end
    local global_rules = get_global_rules()
    err_msg = check_resources_reference(global_rules, id, true, "global_rules")
    if err_msg then
        return 400, err_msg
    end
    return nil, nil
end
]]
    end

    -- Generic delete checker: iterate over specified resources and check field match
    local lines = {
        "local function delete_checker(id)",
    }
    for _, check in ipairs(checks) do
        if check.type == "route_ref" then
            -- Check if any resource in a list references the given ID
            local error_tpl = check.error_tpl
                or string.format("can not delete this %%s directly, %s [%%%%s] is still using it now",
                                 check.label or "resource")
            table_insert(lines, string.format([[
    local %s_list, %s_ver = %s
    if %s_ver and %s_list then
        for _, item in ipairs(%s_list) do
            if type(item) == "table" and item.value
               and item.value.%s
               and tostring(item.value.%s) == id then
                return 400, {error_msg = "%s"}
            end
        end
    end
]], check.label or "resource",
    check.label or "resource", check.getter,
    check.label or "resource", check.label or "resource",
    check.label or "resource", check.ref_field, check.ref_field,
    error_tpl:gsub("{}", "' .. item.value.id .. '")))
        elseif check.type == "inline" then
            table_insert(lines, _indent(check.code, 4))
        end
    end
    table_insert(lines, "    return nil, nil")
    table_insert(lines, "end")
    table_insert(lines, "")
    return table_concat(lines, "\n")
end


--- Build the imports section
-- @param spec - the full resource spec table
-- @return string - Lua require statements
local function _build_imports(spec)
    local lines = {}
    local standard_imports = {
        "local core = require(\"apisix.core\")",
        "local resource = require(\"apisix.admin.resource\")",
    }

    for _, imp in ipairs(standard_imports) do
        table_insert(lines, imp)
    end

    -- Add spec-specific imports
    if spec.imports then
        for _, imp in ipairs(spec.imports) do
            table_insert(lines, imp)
        end
    end

    -- Auto-add imports based on validation types and features used
    local validation_types = {}
    if spec.validations then
        for _, step in ipairs(spec.validations) do
            validation_types[step.type] = true
        end
    end

    -- Resources with upstream need apisix_upstream
    if validation_types["delegate"] or (spec.encrypt and spec.encrypt.upstream) then
        table_insert(lines, "local apisix_upstream = require(\"apisix.upstream\")")
    end

    -- Resources with plugins need plugins module
    if validation_types["plugins_check"] or validation_types["plugins_check_consumer"]
       or (spec.encrypt and spec.encrypt.plugins) then
        if spec.name == "plugin_metadata" then
            table_insert(lines, "local plugin_encrypt_conf = require(\"apisix.plugin\").encrypt_conf")
        else
            table_insert(lines, "local schema_plugin = require(\"apisix.admin.plugins\").check_schema")
            table_insert(lines, "local plugins_encrypt_conf = require(\"apisix.admin.plugins\").encrypt_conf")
        end
    end

    -- Delete checker imports
    if spec.delete_checker and #spec.delete_checker > 0 then
        if spec.name == "services" then
            table_insert(lines, "local get_routes = require(\"apisix.router\").http_routes")
            table_insert(lines, "local get_stream_routes = require(\"apisix.router\").stream_routes")
        elseif spec.name == "upstreams" then
            table_insert(lines, "local config_util = require(\"apisix.core.config_util\")")
            table_insert(lines, "local get_routes = require(\"apisix.router\").http_routes")
            table_insert(lines, "local get_services = require(\"apisix.http.service\").services")
            table_insert(lines, "local get_plugin_configs = require(\"apisix.plugin_config\").plugin_configs")
            table_insert(lines, "local get_consumers = require(\"apisix.consumer\").consumers")
            table_insert(lines, "local get_consumer_groups = require(\"apisix.consumer_group\").consumer_groups")
            table_insert(lines, "local get_global_rules = require(\"apisix.global_rules\").global_rules")
        elseif spec.name == "plugin_configs" then
            table_insert(lines, "local get_routes = require(\"apisix.router\").http_routes")
        elseif spec.name == "consumer_groups" then
            table_insert(lines, "local consumers = require(\"apisix.consumer\").consumers")
        elseif spec.name == "stream_routes" then
            table_insert(lines, "local stream_route_checker = require(\"apisix.stream.router.ip_port\").stream_route_checker")
        end
    end

    -- SSL-specific
    if spec.name == "ssls" then
        table_insert(lines, "local apisix_ssl = require(\"apisix.ssl\")")
    end

    -- Plugin metadata specific
    if spec.name == "plugin_metadata" then
        table_insert(lines, "local plugin_encrypt_conf = require(\"apisix.plugin\").encrypt_conf")
    end

    -- Credentials specific
    if spec.name == "credentials" then
        table_insert(lines, "local plugins = require(\"apisix.admin.plugins\")")
        table_insert(lines, "local plugin = require(\"apisix.plugin\")")
    end

    -- Proto specific
    if spec.name == "protos" then
        table_insert(lines, "local get_routes = require(\"apisix.router\").http_routes")
        table_insert(lines, "local get_services = require(\"apisix.http.service\").services")
        table_insert(lines, "local compile_proto = require(\"apisix.plugins.grpc-transcode.proto\").compile_proto")
    end

    -- Global rules specific
    if spec.name == "global_rules" then
        -- has get_global_rules inside the module itself
    end

    -- Secrets specific
    if spec.name == "secrets" then
        table_insert(lines, "local pcall = pcall")
    end

    -- Lua standard library aliases (commonly used)
    local has_tostring = false
    local has_ipairs = false
    local has_type = false
    local has_pairs = false
    local has_loadstring = false

    if spec.validations then
        for _, step in ipairs(spec.validations) do
            if step.type == "inline" and step.code then
                if step.code:find("tostring") then has_tostring = true end
                if step.code:find("ipairs") then has_ipairs = true end
                if step.code:find("type(") then has_type = true end
                if step.code:find("pairs") then has_pairs = true end
                if step.code:find("loadstring") then has_loadstring = true end
            end
        end
    end

    if spec.delete_checker then
        has_ipairs = true
        has_tostring = true
    end

    if has_tostring then table_insert(lines, "local tostring = tostring") end
    if has_ipairs then table_insert(lines, "local ipairs = ipairs") end
    if has_type then table_insert(lines, "local type = type") end
    if has_pairs then table_insert(lines, "local pairs = pairs") end
    if has_loadstring then table_insert(lines, "local loadstring = loadstring") end

    table_insert(lines, "")
    return table_concat(lines, "\n")
end


--- Build the resource.new() call at the end of the module.
-- @param spec - the full resource spec table
-- @return string - Lua source code for the return statement
local function _build_resource_call(spec)
    local fields = {
        string.format("    name = \"%s\"", spec.name),
        string.format("    kind = \"%s\"", spec.kind),
    }

    if spec.schema then
        table_insert(fields, string.format("    schema = %s", spec.schema))
    end

    table_insert(fields, "    checker = check_conf")

    if spec.name ~= "plugin_metadata" and spec.name ~= "secrets"
       and spec.name ~= "credentials" then
        local has_encrypt = spec.encrypt and (spec.encrypt.upstream or spec.encrypt.plugins or spec.encrypt.custom)
        if has_encrypt then
            table_insert(fields, "    encrypt_conf = encrypt_conf")
        end
    elseif spec.name == "plugin_metadata" or spec.name == "credentials" then
        table_insert(fields, "    encrypt_conf = encrypt_conf")
    end

    if spec.delete_checker and #spec.delete_checker > 0 then
        table_insert(fields, "    delete_checker = delete_checker")
    end

    if spec.unsupported_methods and #spec.unsupported_methods > 0 then
        local methods_str = "{" .. table_concat(
            spec.unsupported_methods, ", "
        ) .. "}"
        table_insert(fields, string.format("    unsupported_methods = %s", methods_str))
    end

    if spec.list_filter_fields and next(spec.list_filter_fields) then
        local parts = {}
        for k, v in pairs(spec.list_filter_fields) do
            table_insert(parts, string.format("%s = %s", k, tostring(v)))
        end
        table_insert(fields, "    list_filter_fields = {\n        " .. table_concat(parts, ",\n        ") .. ",\n    }")
    end

    if spec.get_resource_etcd_key then
        table_insert(fields, "    get_resource_etcd_key = get_resource_etcd_key")
    end

    return "return resource.new({\n" .. table_concat(fields, ",\n") .. ",\n})\n"
end


--- Generate the complete Lua module source code.
-- @param spec - the resource specification table (parsed from YAML or Lua)
-- @return string - complete Lua module source code
function _M.generate(spec)
    -- Validate required fields
    if not spec.name then error("spec requires 'name' field") end
    if not spec.kind then error("spec requires 'kind' field") end

    local parts = {}

    -- License header
    table_insert(parts, LICENSE_HEADER)

    -- Module doc comment
    table_insert(parts, string.format("--- Auto-generated admin API module for %s.\n-- @module %s\n-- @see resource.new\n",
                                       spec.kind, _module_path(spec.name)))

    -- Imports
    table_insert(parts, _build_imports(spec))

    -- Local helper stanzas (e.g., for secrets, plugin_metadata)
    if spec.local_stanzas then
        for _, stanza in ipairs(spec.local_stanzas) do
            table_insert(parts, stanza)
            table_insert(parts, "")
        end
    end

    -- check_conf
    table_insert(parts, _build_check_conf(spec))

    -- encrypt_conf
    local enc = _build_encrypt_conf(spec)
    if enc ~= "" then
        table_insert(parts, enc)
    end

    -- delete_checker
    local del = _build_delete_checker(spec)
    if del ~= "" then
        table_insert(parts, del)
    end

    -- Custom functions (e.g., credentials.get_credential_etcd_key, global_rules helpers)
    if spec.custom_functions then
        for _, fn in ipairs(spec.custom_functions) do
            table_insert(parts, fn)
            table_insert(parts, "")
        end
    end

    -- resource.new() call
    table_insert(parts, _build_resource_call(spec))

    return table_concat(parts, "\n")
end


--- Parse a YAML spec file and return the spec table.
-- @param filepath - path to the YAML file
-- @return table - parsed spec
function _M.parse_yaml(filepath)
    local f, err = io_open(filepath, "r")
    if not f then
        error("cannot open file: " .. tostring(err))
    end
    local content = f:read("*a")
    f:close()
    local ok, spec = pcall(lyaml.load, content)
    if not ok then
        error("YAML parse error: " .. tostring(spec))
    end
    return spec
end


--- Parse a Lua spec file (returns the table via dofile).
-- @param filepath - path to the Lua spec file
-- @return table - parsed spec
function _M.parse_lua(filepath)
    local ok, spec = pcall(dofile, filepath)
    if not ok then
        error("Lua spec load error: " .. tostring(spec))
    end
    return spec
end


--- Write generated source code to a file.
-- @param filepath - output file path
-- @param code - source code string
function _M.write_file(filepath, code)
    local f, err = io_open(filepath, "w")
    if not f then
        error("cannot write file: " .. tostring(err))
    end
    f:write(code)
    f:close()
end


--- CLI entry point
function _M.run_cli(args)
    if #args < 1 then
        io_stderr:write("Usage: resty generator.lua <spec-file> [--stdout] [--output-dir <dir>]\n")
        os_exit(1)
    end

    local spec_file = args[1]
    local stdout_mode = false
    local output_dir = nil

    for i = 2, #args do
        if args[i] == "--stdout" then
            stdout_mode = true
        elseif args[i] == "--output-dir" and i + 1 <= #args then
            output_dir = args[i + 1]
        end
    end

    -- Detect spec format by extension
    local spec
    if spec_file:match("%.yaml$") or spec_file:match("%.yml$") then
        spec = _M.parse_yaml(spec_file)
    else
        spec = _M.parse_lua(spec_file)
    end

    local code = _M.generate(spec)

    if stdout_mode then
        io.write(code)
        return
    end

    local out_path
    if output_dir then
        out_path = output_dir .. "/" .. spec.name .. ".lua"
    else
        out_path = spec_file:gsub("/specs/", "/") .. ".lua"
        if out_path == spec_file .. ".lua" then
            out_path = spec.name .. ".lua"
        end
    end
    _M.write_file(out_path, code)
    io_stderr:write("Generated: " .. out_path .. "\n")
end


return _M