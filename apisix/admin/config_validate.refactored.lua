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
local str_sub      = string.sub
local table_insert = table.insert
local yaml         = require("lyaml")
local tbl_deepcopy = require("apisix.core.table").deepcopy
local core         = require("apisix.core")
local constants    = require("apisix.constants")

local _M = {}

-- 1.5 MiB, same as other Admin API handlers
local MAX_REQ_BODY = 1024 * 1024 * 1.5

-- ============================================================================
-- ResourceRegistry: centralized metadata store with strategy hooks
-- ============================================================================
local ResourceRegistry = {}
local resource_metadatas = {}

function ResourceRegistry.register(key, metadata)
    resource_metadatas[key] = metadata
end

function ResourceRegistry.get(key)
    return resource_metadatas[key]
end

ResourceRegistry.register("routes", {
    checker = require("apisix.admin.routes").checker,
    schema = require("apisix.admin.routes").schema,
})
ResourceRegistry.register("services", {
    checker = require("apisix.admin.services").checker,
    schema = require("apisix.admin.services").schema,
})
ResourceRegistry.register("upstreams", {
    checker = require("apisix.admin.upstreams").checker,
    schema = require("apisix.admin.upstreams").schema,
})
ResourceRegistry.register("credentials", {
    checker = require("apisix.admin.credentials").checker,
    schema = require("apisix.admin.credentials").schema,
})
ResourceRegistry.register("schema", {
    checker = require("apisix.admin.schema").checker,
    schema = require("apisix.admin.schema").schema,
})
ResourceRegistry.register("ssls", {
    checker = require("apisix.admin.ssl").checker,
    schema = require("apisix.admin.ssl").schema,
})
ResourceRegistry.register("plugins", {
    checker = require("apisix.admin.plugins").checker,
    schema = require("apisix.admin.plugins").schema,
})
ResourceRegistry.register("protos", {
    checker = require("apisix.admin.proto").checker,
    schema = require("apisix.admin.proto").schema,
})
ResourceRegistry.register("global_rules", {
    checker = require("apisix.admin.global_rules").checker,
    schema = require("apisix.admin.global_rules").schema,
})
ResourceRegistry.register("stream_routes", {
    checker = require("apisix.admin.stream_routes").checker,
    schema = require("apisix.admin.stream_routes").schema,
})
ResourceRegistry.register("plugin_metadata", {
    checker = require("apisix.admin.plugin_metadata").checker,
    schema = require("apisix.admin.plugin_metadata").schema,
})
ResourceRegistry.register("plugin_configs", {
    checker = require("apisix.admin.plugin_config").checker,
    schema = require("apisix.admin.plugin_configs").schema,
})
ResourceRegistry.register("consumer_groups", {
    checker = require("apisix.admin.consumer_group").checker,
    schema = require("apisix.admin.consumer_group").schema,
})

-- consumers: delegates credential sub-resources to credentials via resolve_target hook
ResourceRegistry.register("consumers", {
    checker = require("apisix.admin.consumers").checker,
    schema = require("apisix.admin.consumers").schema,
    resolve_target = function(item, registry)
        if core.string.find(tostring(item.id or ""), "/credentials/") then
            return registry.get("credentials")
        end
        return nil
    end,
})

-- secrets: extracts secret_type from id via build_checker_opts hook
ResourceRegistry.register("secrets", {
    checker = require("apisix.admin.secrets").checker,
    schema = require("apisix.admin.secrets").schema,
    build_checker_opts = function(item)
        local str_id = tostring(item.id or "")
        local idx = core.string.find(str_id, "/")
        if not idx then
            return nil, "invalid secret id: " .. str_id
        end
        return {
            secret_type = string.sub(str_id, 1, idx - 1),
            skip_references_check = true,
        }
    end,
})

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
-- DuplicateTracker: encapsulates duplicate-detection state per resource type
-- ============================================================================
local DuplicateTracker = {}
DuplicateTracker.__index = DuplicateTracker

function DuplicateTracker.new(resource_key)
    return setmetatable({ key = resource_key, id_set = {} }, DuplicateTracker)
end

function DuplicateTracker:check(item)
    local identifier, identifier_type
    if self.key == "credentials" then
        identifier = item.id or item.username
        identifier_type = item.id and "credential id" or "username"
    else
        identifier = item.id
        identifier_type = "id"
    end

    if not identifier then
        return false
    end

    if self.id_set[identifier] then
        return "duplicate " .. identifier_type .. ": " .. tostring(identifier)
    end
    self.id_set[identifier] = true
    return false
end

-- ============================================================================
-- ErrorReporter: abstracts fail-fast vs. collect-all error modes
-- ============================================================================
local ErrorReporter = {}
ErrorReporter.__index = ErrorReporter

function ErrorReporter.new(collect_all)
    return setmetatable({
        collect_all = collect_all,
        is_valid = true,
        errors = {},
    }, ErrorReporter)
end

function ErrorReporter:add(resource_type, error_msg)
    self.is_valid = false
    table_insert(self.errors, {
        resource_type = resource_type,
        error = tostring(error_msg),
    })
    return self.collect_all
end

function ErrorReporter:add_conf_version_error(conf_version_key, err_type)
    self.is_valid = false
    table_insert(self.errors, {
        resource_type = conf_version_key,
        error = conf_version_key .. " must be a number, got " .. err_type,
    })
    return self.collect_all
end

function ErrorReporter:result()
    return self.is_valid, self.errors
end

-- ============================================================================
-- ItemValidator: stateless single-record validator using registry metadata
-- ============================================================================
local ItemValidator = {}

function ItemValidator.validate(item, registry)
    if not registry then
        return true
    end

    local target = registry
    if registry.resolve_target then
        local resolved = registry.resolve_target(item, ResourceRegistry)
        if resolved then
            target = resolved
        end
    end

    if not target.checker then
        return true
    end

    local opts = { skip_references_check = true }
    if target.build_checker_opts then
        local custom_opts, err = target.build_checker_opts(item)
        if err then
            return false, err
        end
        if custom_opts then
            for k, v in pairs(custom_opts) do
                opts[k] = v
            end
        end
    end

    local item_temp = tbl_deepcopy(item)
    local ok, valid, err = pcall(target.checker, item.id, item_temp, false, target.schema, opts)
    if not ok then
        return false, valid
    end
    if not valid then
        local err_msg = type(err) == "table" and err.error_msg or tostring(err)
        return false, err_msg
    end
    return true
end

-- ============================================================================
-- Main orchestration: validate_configuration
-- ============================================================================
function _M.validate_configuration(req_body, collect_all_errors)
    local reporter = ErrorReporter.new(collect_all_errors)

    for key, conf_version_key in pairs(ALL_RESOURCE_KEYS) do
        local items = req_body[key]

        local new_conf_version = req_body[conf_version_key]
        if new_conf_version and type(new_conf_version) ~= "number" then
            if not reporter:add_conf_version_error(conf_version_key, type(new_conf_version)) then
                return reporter:result()
            end
        end

        if items and #items > 0 then
            local meta = ResourceRegistry.get(key)
            local tracker = DuplicateTracker.new(key)

            for index, item in ipairs(items) do
                local dup_err = tracker:check(item)
                if dup_err then
                    if not reporter:add(key, dup_err) then
                        return reporter:result()
                    end
                end

                local ok, err = ItemValidator.validate(item, meta)
                if not ok then
                    local err_msg = key .. "[" .. index .. "]: " .. tostring(err)
                    if not reporter:add(key, err_msg) then
                        return reporter:result()
                    end
                end
            end
        end
    end

    return reporter:result()
end

-- ============================================================================
-- HTTP handler: validate (called from init.lua and standalone.lua)
-- ============================================================================
function _M.validate()
    local req_body, err = core.request.get_body()
    if err then
        core.log.warn("invalid request body: ", req_body, " err: ", err)
        return core.response.exit(400, {error_msg = "invalid request body: " .. err})
    end

    if not req_body or #req_body <= 0 then
        return core.response.exit(400, {error_msg = "invalid request body: empty request body"})
    end

    local content_type = core.request.header(nil, "content-type") or "application/json"
    local data
    if core.string.has_prefix(content_type, "application/yaml") then
        data = yaml.load(req_body, { all = false })
        if not data or type(data) ~= "table" then
            err = "invalid yaml request body"
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
        for i, item in ipairs(validation_results) do
            validation_results[i].error = tostring(item.error)
        end
        return core.response.exit(400, {
            error_msg = "Configuration validation failed",
            errors = validation_results
        })
    end

    return core.response.exit(200, {})
end

function _M.get_resources()
    return resource_metadatas
end

return _M