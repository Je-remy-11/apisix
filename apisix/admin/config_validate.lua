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


--- Resource Handlers (Strategy Pattern)
local ResourceHandlers = {}


--- Default Resource Handler
local DefaultHandler = {}
DefaultHandler.__index = DefaultHandler

function DefaultHandler.new()
    local self = setmetatable({}, DefaultHandler)
    return self
end

function DefaultHandler:get_identifier(item)
    return item.id, "id"
end

function DefaultHandler:extract_check_options(item, resource_type)
    return { skip_references_check = true }
end

function DefaultHandler:check_conf(checker, schema, item, resource_type)
    if not checker then
        return true
    end
    local options = self:extract_check_options(item, resource_type)
    return checker(item.id, item, false, schema, options)
end


--- Consumers Resource Handler
local ConsumersHandler = setmetatable({}, { __index = DefaultHandler })
ConsumersHandler.__index = ConsumersHandler

function ConsumersHandler.new()
    local self = setmetatable(DefaultHandler.new(), ConsumersHandler)
    return self
end

function ConsumersHandler:get_identifier(item)
    if item.id then
        return item.id, "credential id"
    end
    if item.username then
        return item.username, "username"
    end
    return nil, nil
end

function ConsumersHandler:check_conf(checker, schema, item, resource_type)
    if not checker then
        return true
    end
    local str_id = tostring(item.id or "")
    if core.string.find(str_id, "/credentials/") then
        local credential_checker = resources.credentials.checker
        local credential_schema = resources.credentials.schema
        return credential_checker(item.id, item, false, credential_schema, {
            skip_references_check = true,
        })
    end
    return DefaultHandler.check_conf(self, checker, schema, item, resource_type)
end


--- Secrets Resource Handler
local SecretsHandler = setmetatable({}, { __index = DefaultHandler })
SecretsHandler.__index = SecretsHandler

function SecretsHandler.new()
    local self = setmetatable(DefaultHandler.new(), SecretsHandler)
    return self
end

function SecretsHandler:extract_check_options(item, resource_type)
    local options = { skip_references_check = true }
    local str_id = tostring(item.id or "")
    local idx = str_find(str_id, "/")
    if not idx then
        options._invalid_secret = true
        return options
    end
    options.secret_type = str_sub(str_id, 1, idx - 1)
    return options
end

function SecretsHandler:check_conf(checker, schema, item, resource_type)
    if not checker then
        return true
    end
    local options = self:extract_check_options(item, resource_type)
    if options._invalid_secret then
        return false, {
            error_msg = "invalid secret id: " .. (tostring(item.id) or "")
        }
    end
    return checker(item.id, item, false, schema, options)
end


--- Register Resource Handlers
ResourceHandlers["consumers"] = ConsumersHandler.new()
ResourceHandlers["secrets"] = SecretsHandler.new()


local function get_resource_handler(resource_type)
    return ResourceHandlers[resource_type] or DefaultHandler.new()
end


--- Duplicate Detector Module
local DuplicateDetector = {}
DuplicateDetector.__index = DuplicateDetector

function DuplicateDetector.new()
    local self = setmetatable({}, DuplicateDetector)
    self.id_sets = {}
    return self
end

function DuplicateDetector:check_duplicate(resource_type, item)
    local handler = get_resource_handler(resource_type)
    local identifier, identifier_type = handler:get_identifier(item)
    
    if not identifier then
        return false
    end
    
    if not self.id_sets[resource_type] then
        self.id_sets[resource_type] = {}
    end
    
    local id_set = self.id_sets[resource_type]
    if id_set[identifier] then
        return true, "found duplicate " .. identifier_type .. " " .. identifier .. " in " .. resource_type
    end
    id_set[identifier] = true
    return false
end


--- Error Collector Module
local ErrorCollector = {}
ErrorCollector.__index = ErrorCollector

function ErrorCollector.new(collect_all_errors)
    local self = setmetatable({}, ErrorCollector)
    self.collect_all = collect_all_errors
    self.results = {}
    self.is_valid = true
    return self
end

function ErrorCollector:add_error(resource_type, resource_id, index, error_msg)
    self.is_valid = false
    if self.collect_all then
        table_insert(self.results, {
            resource_type = resource_type,
            resource_id = resource_id,
            index = index,
            error = error_msg
        })
        return false, nil
    else
        return false, error_msg
    end
end

function ErrorCollector:add_conf_version_error(conf_version_key, got_type)
    self.is_valid = false
    if self.collect_all then
        table_insert(self.results, {
            resource_type = str_sub(conf_version_key, 1, -#CONF_VERSION_KEY_SUFFIX - 1),
            error = conf_version_key .. " must be a number, got " .. got_type
        })
        return false, nil
    else
        return false, conf_version_key .. " must be a number"
    end
end

function ErrorCollector:get_results()
    if self.collect_all then
        return self.is_valid, self.results
    end
    return self.is_valid, nil
end


--- Validator Module
local Validator = {}
Validator.__index = Validator

function Validator.new(req_body, collect_all_errors)
    local self = setmetatable({}, Validator)
    self.req_body = req_body
    self.error_collector = ErrorCollector.new(collect_all_errors)
    self.duplicate_detector = DuplicateDetector.new()
    return self
end

function Validator:validate_conf_version(resource_type, conf_version_key)
    local new_conf_version = self.req_body[conf_version_key]
    if new_conf_version and type(new_conf_version) ~= "number" then
        return self.error_collector:add_conf_version_error(conf_version_key, type(new_conf_version))
    end
    return true
end

function Validator:validate_item(resource_type, item, index)
    local resource = resources[resource_type] or {}
    local item_schema = resource.schema
    local item_checker = resource.checker
    local handler = get_resource_handler(resource_type)
    
    local item_temp = tbl_deepcopy(item)
    local ok, valid, err = pcall(function()
        return handler:check_conf(item_checker, item_schema, item_temp, resource_type)
    end)
    
    if not ok then
        err = valid
        valid = false
    end
    
    if not valid then
        local err_msg = type(err) == "table" and err.error_msg or tostring(err)
        local identifier, _ = handler:get_identifier(item)
        local resource_id = identifier or ""
        return self.error_collector:add_error(resource_type, resource_id, index - 1, err_msg)
    end
    
    return true
end

function Validator:validate_duplicate(resource_type, item, index)
    local duplicated, dup_err = self.duplicate_detector:check_duplicate(resource_type, item)
    if duplicated then
        local handler = get_resource_handler(resource_type)
        local identifier, _ = handler:get_identifier(item)
        local resource_id = identifier or ""
        return self.error_collector:add_error(resource_type, resource_id, index - 1, dup_err)
    end
    return true
end

function Validator:validate_resource(resource_type, conf_version_key)
    if not self:validate_conf_version(resource_type, conf_version_key) then
        if not self.error_collector.collect_all then
            return false
        end
    end
    
    local items = self.req_body[resource_type]
    if not items or #items <= 0 then
        return true
    end
    
    for index, item in ipairs(items) do
        if not self:validate_item(resource_type, item, index) then
            if not self.error_collector.collect_all then
                return false
            end
        end
        
        if not self:validate_duplicate(resource_type, item, index) then
            if not self.error_collector.collect_all then
                return false
            end
        end
    end
    
    return true
end

function Validator:validate_all()
    for resource_type, conf_version_key in pairs(ALL_RESOURCE_KEYS) do
        if not self:validate_resource(resource_type, conf_version_key) then
            if not self.error_collector.collect_all then
                break
            end
        end
    end
    return self.error_collector:get_results()
end


--- Main validation function
function _M.validate_configuration(req_body, collect_all_errors)
    local validator = Validator.new(req_body, collect_all_errors)
    return validator:validate_all()
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


function _M.get_resource_handler(resource_type)
    return get_resource_handler(resource_type)
end


return _M
