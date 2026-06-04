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

local function resolve_default_resource_id(item)
    return item.id or ""
end


local function resolve_consumer_resource_id(item)
    return item.id or item.username or ""
end


local function resolve_default_duplicate_identifier(item)
    return item.id, "id"
end


local function resolve_consumer_duplicate_identifier(item)
    if item.id then
        return item.id, "credential id"
    end

    return item.username, "username"
end


local function build_default_validation_plan(registration)
    return {
        checker = registration.checker,
        schema = registration.schema,
        opts = {
            skip_references_check = true,
        },
    }
end


local function build_consumer_validation_plan(registration, item)
    local item_id = item.id
    if item_id and str_find(tostring(item_id), "/credentials/", 1, true) then
        return {
            checker = resources.credentials.checker,
            schema = resources.credentials.schema,
            opts = {
                skip_references_check = true,
            },
        }
    end

    return build_default_validation_plan(registration)
end


local function build_secret_validation_plan(registration, item)
    local plan = build_default_validation_plan(registration)
    local raw_id = item.id
    local str_id = raw_id and tostring(raw_id) or ""
    local idx = str_find(str_id, "/", 1, true)

    if not idx then
        return nil, {
            error_msg = "invalid secret id: " .. str_id
        }
    end

    plan.opts.secret_type = str_sub(str_id, 1, idx - 1)
    return plan
end


local DEFAULT_RESOURCE_METADATA = {
    resolve_resource_id = resolve_default_resource_id,
    resolve_duplicate_identifier = resolve_default_duplicate_identifier,
    build_validation_plan = build_default_validation_plan,
}


local RESOURCE_VALIDATION_METADATA = {
    consumers = {
        resolve_resource_id = resolve_consumer_resource_id,
        resolve_duplicate_identifier = resolve_consumer_duplicate_identifier,
        build_validation_plan = build_consumer_validation_plan,
    },
    secrets = {
        build_validation_plan = build_secret_validation_plan,
    },
}


local function build_resource_registration(key, conf_version_key)
    local resource = resources[key] or {}
    local metadata = RESOURCE_VALIDATION_METADATA[key] or {}

    return {
        key = key,
        conf_version_key = conf_version_key,
        checker = resource.checker,
        schema = resource.schema,
        resolve_resource_id = metadata.resolve_resource_id or DEFAULT_RESOURCE_METADATA.resolve_resource_id,
        resolve_duplicate_identifier = metadata.resolve_duplicate_identifier
            or DEFAULT_RESOURCE_METADATA.resolve_duplicate_identifier,
        build_validation_plan = metadata.build_validation_plan
            or DEFAULT_RESOURCE_METADATA.build_validation_plan,
    }
end


local function build_resource_registry()
    local registry = {}

    for key, conf_version_key in pairs(ALL_RESOURCE_KEYS) do
        registry[key] = build_resource_registration(key, conf_version_key)
    end

    return registry
end


local RESOURCE_REGISTRY = build_resource_registry()


local function normalize_error(err)
    if type(err) == "table" then
        return err.error_msg or tostring(err)
    end

    return tostring(err)
end


local function new_error_collector(collect_all_errors)
    local collector = {
        collect_all_errors = collect_all_errors,
        is_valid = true,
        errors = {},
    }

    function collector:add(entry, fail_fast_error)
        local err_msg = normalize_error(entry.error)
        if not self.collect_all_errors then
            return false, fail_fast_error or err_msg
        end

        self.is_valid = false
        entry.error = err_msg
        table_insert(self.errors, entry)
        return true
    end

    function collector:result()
        if self.collect_all_errors then
            return self.is_valid, self.errors
        end

        return self.is_valid, nil
    end

    return collector
end


local function create_duplicate_detector(registration)
    local seen = {}

    return function(item)
        local identifier, identifier_type = registration.resolve_duplicate_identifier(item)
        if not identifier then
            return false
        end

        if seen[identifier] then
            return true, "found duplicate " .. identifier_type .. " " .. identifier
                .. " in " .. registration.key
        end

        seen[identifier] = true
        return false
    end
end


local function run_single_record_validation(registration, item)
    local plan, err = registration.build_validation_plan(registration, item)
    if not plan then
        return false, err
    end

    if not plan.checker then
        return true
    end

    return plan.checker(item.id, item, false, plan.schema, plan.opts)
end


local function validate_conf_version(registration, req_body, collector)
    local new_conf_version = req_body[registration.conf_version_key]
    if new_conf_version and type(new_conf_version) ~= "number" then
        return collector:add({
            resource_type = registration.key,
            error = registration.conf_version_key .. " must be a number, got " .. type(new_conf_version)
        }, registration.conf_version_key .. " must be a number")
    end

    return true
end


local function validate_resource_items(registration, items, collector)
    if not items or #items == 0 then
        return true
    end

    local detect_duplicate = create_duplicate_detector(registration)

    for index, item in ipairs(items) do
        local item_temp = tbl_deepcopy(item)
        local ok, valid, err = pcall(run_single_record_validation, registration, item_temp)
        if not ok then
            err = valid
            valid = false
        end

        if not valid then
            local continue, fail_fast_error = collector:add({
                resource_type = registration.key,
                resource_id = registration.resolve_resource_id(item),
                index = index - 1,
                error = err,
            })
            if not continue then
                return false, fail_fast_error
            end
        end

        local duplicated, dup_err = detect_duplicate(item)
        if duplicated then
            local continue, fail_fast_error = collector:add({
                resource_type = registration.key,
                resource_id = registration.resolve_resource_id(item),
                index = index - 1,
                error = dup_err,
            })
            if not continue then
                return false, fail_fast_error
            end
        end
    end

    return true
end


function _M.validate_configuration(req_body, collect_all_errors)
    local collector = new_error_collector(collect_all_errors)

    for key in pairs(ALL_RESOURCE_KEYS) do
        local registration = RESOURCE_REGISTRY[key]
        local continue, err = validate_conf_version(registration, req_body, collector)
        if not continue then
            return false, err
        end

        continue, err = validate_resource_items(registration, req_body[key], collector)
        if not continue then
            return false, err
        end
    end

    return collector:result()
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
        validation_results = validation_results or {}
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


function _M.get_resource_registry()
    return RESOURCE_REGISTRY
end


return _M
