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
local setmetatable = setmetatable
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


------------------------------------------------------------------------
-- ErrorCollector
-- Encapsulates error collection with configurable fail-fast / collect-all mode.
--
--   fail-fast  : add() returns (false, error_msg) on first error so the
--                caller can return immediately.
--   collect-all: add() always returns true; errors are accumulated in
--                self.results for batch reporting.
------------------------------------------------------------------------
local ErrorCollector = {}
ErrorCollector.__index = ErrorCollector

function ErrorCollector.new(collect_all)
    return setmetatable({
        collect_all = collect_all,
        valid = true,
        results = {},
    }, ErrorCollector)
end

function ErrorCollector:add(resource_type, resource_id, index, error_msg)
    if not self.collect_all then
        return false, error_msg
    end
    self.valid = false
    table_insert(self.results, {
        resource_type = resource_type,
        resource_id = resource_id or "",
        index = index,
        error = error_msg,
    })
    return true
end

function ErrorCollector:result()
    if self.collect_all then
        return self.valid, self.results
    end
    return self.valid, nil
end


------------------------------------------------------------------------
-- ResourceDescriptor
-- Metadata-driven resource type descriptor with pluggable strategy hooks.
--
-- Strategy hooks (all optional; sensible defaults are provided):
--
--   resolve_checker(res, item)
--       -> checker_fn, schema
--       Determines which checker function and schema to use for a given item.
--       Default: returns res.checker, res.schema.
--       Override example: consumers with /credentials/ IDs redirect to
--       the credentials checker and schema.
--
--   build_checker_opts(item)
--       -> opts_table  |  nil, error_msg
--       Builds the options table passed to the checker function.
--       Default: { skip_references_check = true }.
--       Override example: secrets extracts secret_type from the item ID
--       and includes it in the opts; returns nil + error if the ID format
--       is invalid.
--
--   get_identifier(item)
--       -> identifier_value
--       Extracts the unique identifier from an item for duplicate detection
--       and error reporting.
--       Default: item.id.
--       Override example: consumers uses item.id or item.username.
--
--   get_identifier_type(item)
--       -> type_label_string
--       Returns a human-readable label for the identifier type, used in
--       duplicate error messages.
--       Default: "id".
--       Override example: consumers returns "credential id" or "username".
------------------------------------------------------------------------
local ResourceDescriptor = {}
ResourceDescriptor.__index = ResourceDescriptor

local function default_get_identifier(item)
    return item.id
end

local function default_get_identifier_type()
    return "id"
end

local function default_resolve_checker(res)
    return res.checker, res.schema
end

local function default_build_checker_opts()
    return { skip_references_check = true }
end

function ResourceDescriptor.new(opts)
    local res = opts.resource or {}
    return setmetatable({
        key = opts.key,
        resource = res,
        conf_version_key = opts.conf_version_key,
        get_identifier = opts.get_identifier or default_get_identifier,
        get_identifier_type = opts.get_identifier_type or default_get_identifier_type,
        resolve_checker = opts.resolve_checker or default_resolve_checker,
        build_checker_opts = opts.build_checker_opts or default_build_checker_opts,
    }, ResourceDescriptor)
end

function ResourceDescriptor:validate_item(item)
    local checker, schema = self.resolve_checker(self.resource, item)
    if not checker then
        return true
    end

    local opts, opts_err = self.build_checker_opts(item)
    if not opts then
        return false, opts_err
    end

    local item_temp = tbl_deepcopy(item)
    local ok, valid, err = pcall(checker, item.id, item_temp, false, schema, opts)
    if not ok then
        err = valid
        valid = false
    end
    if not valid then
        local err_msg = type(err) == "table" and err.error_msg or tostring(err)
        return false, err_msg
    end
    return true
end

function ResourceDescriptor:check_duplicate(item, id_set)
    local identifier = self.get_identifier(item)
    if not identifier then
        return false
    end
    local identifier_type = self.get_identifier_type(item)
    if id_set[identifier] then
        return true, "found duplicate " .. identifier_type .. " "
                      .. identifier .. " in " .. self.key
    end
    id_set[identifier] = true
    return false
end


------------------------------------------------------------------------
-- ResourceRegistry
-- Central registry mapping resource keys to ResourceDescriptor instances.
-- Built once at module load time from constants.HTTP_ETCD_DIRECTORY and
-- constants.STREAM_ETCD_DIRECTORY.
--
-- To add a new resource type with custom validation behaviour, insert a
-- new entry in the build_registry loop below with the desired strategy
-- overrides — no changes to validate_configuration are needed.
------------------------------------------------------------------------
local registry = {}

do
    local function build_registry()
        local seen = {}
        for dir in pairs(constants.HTTP_ETCD_DIRECTORY) do
            seen[dir] = true
        end
        for dir in pairs(constants.STREAM_ETCD_DIRECTORY) do
            seen[dir] = true
        end

        for dir in pairs(seen) do
            local key = str_sub(dir, 2)
            local conf_version_key = key .. CONF_VERSION_KEY_SUFFIX
            local res = resources[key] or {}

            local opts = {
                key = key,
                resource = res,
                conf_version_key = conf_version_key,
            }

            if key == "secrets" then
                opts.build_checker_opts = function(item)
                    local str_id = tostring(item.id)
                    local idx = str_find(str_id or "", "/")
                    if not idx then
                        return nil, "invalid secret id: " .. (str_id or "")
                    end
                    local secret_type = str_sub(str_id, 1, idx - 1)
                    return { secret_type = secret_type, skip_references_check = true }
                end
            elseif key == "consumers" then
                opts.get_identifier = function(item)
                    return item.id or item.username
                end
                opts.get_identifier_type = function(item)
                    return item.id and "credential id" or "username"
                end
                opts.resolve_checker = function(res, item)
                    local str_id = tostring(item.id or "")
                    if core.string.find(str_id, "/credentials/") then
                        return resources.credentials.checker,
                               resources.credentials.schema
                    end
                    return res.checker, res.schema
                end
                opts.build_checker_opts = function()
                    return { skip_references_check = true }
                end
            end

            registry[key] = ResourceDescriptor.new(opts)
        end
    end

    build_registry()
end

local ALL_RESOURCE_KEYS = {}
for key, descriptor in pairs(registry) do
    ALL_RESOURCE_KEYS[key] = descriptor.conf_version_key
end


------------------------------------------------------------------------
-- Core validation orchestrator
------------------------------------------------------------------------
function _M.validate_configuration(req_body, collect_all_errors)
    local collector = ErrorCollector.new(collect_all_errors)

    for key, descriptor in pairs(registry) do
        local items = req_body[key]
        local conf_version_key = descriptor.conf_version_key

        local new_conf_version = req_body[conf_version_key]
        if new_conf_version and type(new_conf_version) ~= "number" then
            local continued, err = collector:add(
                key, nil, nil,
                conf_version_key .. " must be a number, got " .. type(new_conf_version)
            )
            if not continued then
                return false, conf_version_key .. " must be a number"
            end
        end

        if items and #items > 0 then
            local id_set = {}

            for index, item in ipairs(items) do
                local ok, err = descriptor:validate_item(item)
                if not ok then
                    local resource_id = descriptor.get_identifier(item) or ""
                    local continued = collector:add(key, resource_id, index - 1, err)
                    if not continued then
                        return false, err
                    end
                end

                local duplicated, dup_err = descriptor:check_duplicate(item, id_set)
                if duplicated then
                    local resource_id = descriptor.get_identifier(item) or ""
                    local continued = collector:add(key, resource_id, index - 1, dup_err)
                    if not continued then
                        return false, dup_err
                    end
                end
            end
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
