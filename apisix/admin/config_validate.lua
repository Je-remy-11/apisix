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

--- Batch configuration validation module.
-- Validates APISIX declarative configurations (routes, services, consumers, etc.)
-- including resource-level JSON Schema and plugin check_schema() advanced validation.
-- Used by both standalone mode and etcd mode via POST /apisix/admin/configs/validate.

local type         = type
local pairs        = pairs
local ipairs       = ipairs
local tostring     = tostring
local pcall        = pcall
local str_find     = string.find
local str_sub      = string.sub
local table_insert = table.insert
local yaml         = require("lyaml")
local core         = require("apisix.core")
local tbl_deepcopy = require("apisix.core.table").deepcopy
local constants    = require("apisix.constants")

local _M = {}

-- 1.5 MiB, same as other Admin API handlers
local MAX_REQ_BODY = 1024 * 1024 * 1.5

local resources = {
    routes          = require("apisix.admin.routes"),
    services        = require("apisix.admin.services"),
    upstreams       = require("apisix.admin.upstreams"),
    consumers       = require("apisix.admin.consumers"),
    credentials     = require("apisix.admin.credentials"),
    schema          = require("apisix.admin.schema"),
    ssls            = require("apisix.admin.ssl"),
    plugins         = require("apisix.admin.plugins"),
    protos          = require("apisix.admin.proto"),
    global_rules    = require("apisix.admin.global_rules"),
    stream_routes   = require("apisix.admin.stream_routes"),
    plugin_metadata = require("apisix.admin.plugin_metadata"),
    plugin_configs  = require("apisix.admin.plugin_config"),
    consumer_groups = require("apisix.admin.consumer_group"),
    secrets         = require("apisix.admin.secrets"),
}

local CONF_VERSION_KEY_SUFFIX = "_conf_version"
local ALL_RESOURCE_KEYS = {}
for dir in pairs(constants.HTTP_ETCD_DIRECTORY) do
    local key = str_sub(dir, 2)
    ALL_RESOURCE_KEYS[key] = key .. CONF_VERSION_KEY_SUFFIX
end
for dir in pairs(constants.STREAM_ETCD_DIRECTORY) do
    local key = str_sub(dir, 2)
    ALL_RESOURCE_KEYS[key] = key .. CONF_VERSION_KEY_SUFFIX
end


-- ============================================================================
-- Decoupled Components
-- ============================================================================

-- 1. Error Collector: Handles fail-fast vs collect-all modes
local ErrorCollector = {}
function ErrorCollector:new(collect_all)
    return setmetatable({
        collect_all = collect_all,
        errors = {},
        is_valid = true
    }, { __index = self })
end

function ErrorCollector:report(err_obj)
    self.is_valid = false
    table_insert(self.errors, err_obj)
    return self.collect_all -- returns true if we should continue checking
end

function ErrorCollector:get_result()
    if self.collect_all then
        return self.is_valid, self.errors
    end
    if not self.is_valid then
        return false, self.errors[1].error
    end
    return true, nil
end

-- 2. Strategy Pattern for Resource Validation
local default_strategy = {
    get_identifier = function(item)
        return item.id, "id"
    end,
    check_item = function(item, schema, checker)
        if not checker then return true end
        return checker(item.id, item, false, schema, {
            skip_references_check = true,
        })
    end
}

local resource_strategies = setmetatable({
    consumers = {
        get_identifier = function(item)
            return item.id or item.username, item.id and "credential id" or "username"
        end,
        check_item = function(item, schema, checker)
            if not checker then return true end
            local str_id = tostring(item.id)
            if core.string.find(str_id, "/credentials/") then
                local cred_checker = resources.credentials.checker
                local cred_schema = resources.credentials.schema
                return cred_checker(item.id, item, false, cred_schema, {
                    skip_references_check = true,
                })
            end
            return checker(item.id, item, false, schema, {
                skip_references_check = true,
            })
        end
    },
    secrets = {
        get_identifier = default_strategy.get_identifier,
        check_item = function(item, schema, checker)
            if not checker then return true end
            local str_id = tostring(item.id)
            local idx = str_find(str_id or "", "/")
            if not idx then
                return false, { error_msg = "invalid secret id: " .. (str_id or "") }
            end
            local secret_type = str_sub(str_id, 1, idx - 1)
            return checker(item.id, item, false, schema, {
                secret_type = secret_type,
                skip_references_check = true,
            })
        end
    }
}, {
    __index = function() return default_strategy end
})

-- 3. Single Record Validator & Duplicate Detector
local function validate_item(item, typ, resource, index, id_set, error_collector)
    local strategy = resource_strategies[typ]
    local item_temp = tbl_deepcopy(item)
    
    -- Check config
    local ok, valid, err = pcall(strategy.check_item, item_temp, resource.schema, resource.checker)
    if not ok then
        err = valid
        valid = false
    end

    local identifier = strategy.get_identifier(item) or ""
    
    if not valid then
        local err_msg = type(err) == "table" and err.error_msg or tostring(err)
        local should_continue = error_collector:report({
            resource_type = typ,
            resource_id = identifier,
            index = index - 1,
            error = err_msg
        })
        if not should_continue then return false end
    end

    -- Check duplicate
    local ident, ident_type = strategy.get_identifier(item)
    if ident then
        if id_set[ident] then
            local dup_err = "found duplicate " .. ident_type .. " " .. ident .. " in " .. typ
            local should_continue = error_collector:report({
                resource_type = typ,
                resource_id = identifier,
                index = index - 1,
                error = dup_err
            })
            if not should_continue then return false end
        else
            id_set[ident] = true
        end
    end

    return true
end

function _M.validate_configuration(req_body, collect_all_errors)
    local error_collector = ErrorCollector:new(collect_all_errors)

    for key, conf_version_key in pairs(ALL_RESOURCE_KEYS) do
        local new_conf_version = req_body[conf_version_key]
        if new_conf_version and type(new_conf_version) ~= "number" then
            local should_continue = error_collector:report({
                resource_type = key,
                error = conf_version_key .. " must be a number, got " .. type(new_conf_version)
            })
            if not should_continue then
                return error_collector:get_result()
            end
        end

        local items = req_body[key]
        if items and #items > 0 then
            local resource = resources[key] or {}
            local id_set = {}
            for index, item in ipairs(items) do
                local ok = validate_item(item, key, resource, index, id_set, error_collector)
                if not ok then
                    return error_collector:get_result()
                end
            end
        end
    end

    return error_collector:get_result()
end


function _M.validate()
    local content_type = core.request.header(nil, "content-type") or "application/json"
    local req_body, err = core.request.get_body(MAX_REQ_BODY)
    if err then
        return core.response.exit(400, {error_msg = "invalid request body: " .. err})
    end

    if not req_body or #req_body <= 0 then
        return core.response.exit(400, {error_msg = "invalid request body: empty request body"})
    end

    local data
    if core.string.has_prefix(content_type, "application/yaml") then
        local ok, result = pcall(yaml.load, req_body, { all = false })
        if not ok or type(result) ~= "table" then
            err = "invalid yaml request body"
        else
            data = result
        end
    else
        data, err = core.json.decode(req_body)
    end

    if err then
        core.log.warn("invalid request body: ", req_body, " err: ", err)
        return core.response.exit(400, {error_msg = "invalid request body: " .. err})
    end

    local ok, valid, validation_results = pcall(_M.validate_configuration, data, true)
    if not ok then
        core.log.warn("unexpected error during validation: ", tostring(valid))
        return core.response.exit(400, {
            error_msg = "Configuration validation failed",
            errors = {{error = tostring(valid)}}
        })
    end
    if not valid then
        -- Ensure all error values in validation_results are JSON-serializable
        for i, item in ipairs(validation_results) do
            if type(item.error) ~= "string" then
                validation_results[i].error = tostring(item.error)
            end
        end
        return core.response.exit(400, {
            error_msg = "Configuration validation failed",
            errors = validation_results
        })
    end

    return core.response.exit(200, {})
end


function _M.get_all_resource_keys()
    return ALL_RESOURCE_KEYS
end


function _M.get_resources()
    return resources
end


return _M
