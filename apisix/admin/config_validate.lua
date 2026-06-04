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

local type            = type
local pairs           = pairs
local ipairs          = ipairs
local tostring        = tostring
local pcall           = pcall
local xpcall          = xpcall
local next            = next
local setmetatable    = setmetatable
local getmetatable    = getmetatable
local str_find        = string.find
local str_sub         = string.sub
local table_concat    = table.concat
local table_insert    = table.insert
local debug_traceback = debug.traceback
local yaml            = require("lyaml")
local core            = require("apisix.core")
local tbl_deepcopy    = require("apisix.core.table").deepcopy
local constants       = require("apisix.constants")

local _M = {}

local MAX_REQ_BODY = 1024 * 1024 * 1.5
local SAFE_COPY_MAX_DEPTH = 48
local SAFE_COPY_MAX_NODES = 2048
local SHALLOW_COPY_FIELDS = {
    plugins = true,
    upstream = true,
    nodes = true,
    routes = true,
    script = true,
    metadata = true,
    labels = true,
    vars = true,
    filter_func = true,
    checks = true,
    tls = true,
}

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


local function get_resource_id(item, key)
    if type(item) ~= "table" then
        return ""
    end

    if key == "consumers" then
        return item.id or item.username or ""
    end

    return item.id or ""
end


local function get_resource_label(resource_type, resource_id, index)
    local label = resource_type or "configuration"
    if index ~= nil then
        label = label .. "[" .. index .. "]"
    end
    if resource_id and resource_id ~= "" then
        label = label .. "(" .. resource_id .. ")"
    end
    return label
end


local function format_error_message(entry)
    local label = get_resource_label(entry.resource_type, entry.resource_id, entry.index)
    if entry.stage and entry.stage ~= "validation" then
        return label .. " " .. entry.stage .. " error: " .. tostring(entry.error)
    end
    return label .. ": " .. tostring(entry.error)
end


local function build_validation_error(resource_type, item, index, err_msg, stage, extra)
    local entry = {
        resource_type = resource_type,
        resource_id = get_resource_id(item, resource_type),
        error = tostring(err_msg),
        stage = stage or "validation",
    }

    if index ~= nil then
        entry.index = index - 1
    end

    if extra then
        for key, value in pairs(extra) do
            entry[key] = value
        end
    end

    return entry
end


local function shallow_clone(orig)
    if type(orig) ~= "table" then
        return orig
    end

    local copy = {}
    for key, value in pairs(orig) do
        copy[key] = value
    end

    local mt = getmetatable(orig)
    if mt ~= nil then
        setmetatable(copy, mt)
    end

    return copy
end


local function inspect_table_shape(value, seen, depth, stats)
    if type(value) ~= "table" or seen[value] then
        return
    end

    seen[value] = true
    stats.nodes = stats.nodes + 1
    if depth > stats.max_depth then
        stats.max_depth = depth
    end

    if stats.nodes > SAFE_COPY_MAX_NODES or depth > SAFE_COPY_MAX_DEPTH then
        stats.risky = true
        return
    end

    for _, child in pairs(value) do
        if type(child) == "table" then
            inspect_table_shape(child, seen, depth + 1, stats)
            if stats.risky then
                return
            end
        end
    end
end


local function summarize_table_shape(item)
    local stats = {
        nodes = 0,
        max_depth = 0,
        risky = false,
    }
    inspect_table_shape(item, {}, 1, stats)
    return stats
end


local function collect_shallow_paths(item)
    local paths = {}

    for key, value in pairs(item) do
        if type(value) == "table" and SHALLOW_COPY_FIELDS[key] then
            paths[#paths + 1] = "self." .. tostring(key)
        end
    end

    return paths
end


local function log_copy_mode(resource_type, item, index, copy_meta)
    if not copy_meta or copy_meta.mode == "deep" then
        return
    end

    local label = get_resource_label(resource_type, get_resource_id(item, resource_type), index - 1)
    local shallow_paths = copy_meta.shallow_paths and next(copy_meta.shallow_paths)
        and table_concat(copy_meta.shallow_paths, ",") or ""

    core.log.warn("config validate uses ", copy_meta.mode,
                  " copy for ", label,
                  ", nodes: ", copy_meta.nodes or 0,
                  ", depth: ", copy_meta.max_depth or 0,
                  ", shallow_paths: ", shallow_paths,
                  ", reason: ", copy_meta.reason or "")
end


local function safe_copy_item(item)
    if type(item) ~= "table" then
        return item, { mode = "none" }
    end

    local ok, stats_or_err = pcall(summarize_table_shape, item)
    if not ok then
        return shallow_clone(item), {
            mode = "shallow",
            reason = tostring(stats_or_err),
        }
    end

    local stats = stats_or_err
    local shallow_paths
    if stats.risky then
        shallow_paths = collect_shallow_paths(item)
    end

    local copy_opts
    local mode = "deep"
    if shallow_paths and #shallow_paths > 0 then
        copy_opts = {
            shallows = shallow_paths,
        }
        mode = "shallow_paths"
    elseif stats.risky then
        return shallow_clone(item), {
            mode = "shallow",
            reason = "copy threshold exceeded",
            nodes = stats.nodes,
            max_depth = stats.max_depth,
        }
    end

    local ok_copy, copied_or_err = pcall(tbl_deepcopy, item, copy_opts)
    if not ok_copy then
        return shallow_clone(item), {
            mode = "shallow",
            reason = tostring(copied_or_err),
            nodes = stats.nodes,
            max_depth = stats.max_depth,
        }
    end

    return copied_or_err, {
        mode = mode,
        nodes = stats.nodes,
        max_depth = stats.max_depth,
        shallow_paths = shallow_paths,
    }
end


local function check_duplicate(item, key, id_set)
    local identifier
    local identifier_type

    if key == "consumers" then
        if item.id then
            identifier = item.id
            identifier_type = "credential id"
        elseif item.username then
            identifier = item.username
            identifier_type = "username"
        else
            return true, "consumer entry is missing username or credential id; duplicate check cannot identify this record"
        end
    else
        identifier = item.id
        identifier_type = "id"
    end

    if not identifier then
        return false
    end

    if id_set[identifier] then
        return true, "found duplicate " .. identifier_type .. " " .. identifier .. " in " .. key
    end

    id_set[identifier] = true
    return false
end


local function check_conf(checker, schema, item, typ)
    if not checker then
        return true
    end

    local str_id = tostring(item.id)
    if typ == "consumers" and core.string.find(str_id, "/credentials/") then
        local credential_checker = resources.credentials.checker
        local credential_schema = resources.credentials.schema
        return credential_checker(item.id, item, false, credential_schema, {
            skip_references_check = true,
        })
    end

    local secret_type
    if typ == "secrets" then
        local idx = str_find(str_id or "", "/")
        if not idx then
            return false, {
                error_msg = "invalid secret id: " .. (str_id or "")
            }
        end
        secret_type = str_sub(str_id, 1, idx - 1)
    end

    return checker(item.id, item, false, schema, {
        secret_type = secret_type,
        skip_references_check = true,
    })
end


local function run_checker(checker, schema, item, typ)
    local ok, valid, err = xpcall(function()
        return check_conf(checker, schema, item, typ)
    end, function(runtime_err)
        local err_msg
        if type(runtime_err) == "table" then
            err_msg = runtime_err.error_msg or tostring(runtime_err)
        else
            err_msg = tostring(runtime_err)
        end

        return {
            error_msg = err_msg,
            traceback = debug_traceback(err_msg, 2),
            runtime_error = true,
        }
    end)

    if not ok then
        return false, valid
    end

    return valid, err
end


local function handle_validation_error(entry, collect_all_errors, validation_results)
    if not collect_all_errors then
        return false, format_error_message(entry)
    end

    table_insert(validation_results, entry)
    return true
end


function _M.validate_configuration(req_body, collect_all_errors)
    local is_valid = true
    local validation_results = {}

    for key, conf_version_key in pairs(ALL_RESOURCE_KEYS) do
        local items = req_body[key]
        local resource = resources[key] or {}

        local new_conf_version = req_body[conf_version_key]
        if new_conf_version and type(new_conf_version) ~= "number" then
            local entry = {
                resource_type = key,
                stage = "conf_version",
                error = conf_version_key .. " must be a number, got " .. type(new_conf_version)
            }

            if not collect_all_errors then
                return false, format_error_message(entry)
            end

            is_valid = false
            table_insert(validation_results, entry)
        end

        if items and #items > 0 then
            local item_schema = resource.schema
            local item_checker = resource.checker
            local id_set = {}

            for index, item in ipairs(items) do
                local item_temp, copy_meta = safe_copy_item(item)
                log_copy_mode(key, item, index, copy_meta)

                local valid, err = run_checker(item_checker, item_schema, item_temp, key)
                if not valid then
                    local err_msg = type(err) == "table" and err.error_msg or tostring(err)
                    local extra = {}

                    if type(err) == "table" and err.traceback then
                        extra.traceback = err.traceback
                    end
                    if type(err) == "table" and err.runtime_error then
                        extra.runtime_error = true
                    end
                    if copy_meta and copy_meta.mode ~= "deep" and copy_meta.mode ~= "none" then
                        extra.copy_mode = copy_meta.mode
                        if copy_meta.shallow_paths and #copy_meta.shallow_paths > 0 then
                            extra.shallow_copy_paths = copy_meta.shallow_paths
                        end
                    end

                    local stage = extra.runtime_error and "checker_runtime" or "checker"
                    local entry = build_validation_error(key, item, index, err_msg, stage, extra)

                    if entry.traceback then
                        core.log.error("config validate checker runtime error for ",
                                       get_resource_label(key, entry.resource_id, entry.index),
                                       ": ", entry.error, "\n", entry.traceback)
                    end

                    if not collect_all_errors then
                        return false, format_error_message(entry)
                    end

                    is_valid = false
                    table_insert(validation_results, entry)
                end

                local duplicated, dup_err = check_duplicate(item, key, id_set)
                if duplicated then
                    local entry = build_validation_error(key, item, index, dup_err, "duplicate")

                    if not collect_all_errors then
                        return false, format_error_message(entry)
                    end

                    is_valid = false
                    table_insert(validation_results, entry)
                end
            end
        end
    end

    if collect_all_errors then
        return is_valid, validation_results
    end

    return is_valid, nil
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
            if item.traceback and type(item.traceback) ~= "string" then
                validation_results[i].traceback = tostring(item.traceback)
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
