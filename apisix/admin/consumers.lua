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
local core    = require("apisix.core")
local plugin  = require("apisix.plugin")
local plugins = require("apisix.admin.plugins")
local utils   = require("apisix.admin.utils")
local plugins_encrypt_conf = require("apisix.admin.plugins").encrypt_conf
local resource = require("apisix.admin.resource")
local pairs   = pairs
local type    = type


local function check_conf(username, conf, need_username, schema, opts)
    opts = opts or {}
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    if username and username ~= conf.username then
        return nil, {error_msg = "wrong username" }
    end

    if conf.plugins then
        ok, err = plugins.check_schema(conf.plugins, core.schema.TYPE_CONSUMER)
        if not ok then
            return nil, {error_msg = "invalid plugins configuration: " .. err}
        end
    end

    if conf.group_id and not opts.skip_references_check then
        local key = "/consumer_groups/" .. conf.group_id
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch consumer group info by "
                                     .. "consumer group id [" .. conf.group_id .. "]: "
                                     .. err}
        end

        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch consumer group info by "
                                     .. "consumer group id [" .. conf.group_id .. "], "
                                     .. "response code: " .. res.status}
        end
    end

    return conf.username
end


local function encrypt_conf(id, conf)
    plugins_encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)
end


local function decrypt_consumer_plugins(conf)
    if not conf or not conf.plugins then
        return
    end

    for name, plugin_conf in pairs(conf.plugins) do
        plugin.decrypt_conf(name, plugin_conf, core.schema.TYPE_CONSUMER)
    end
end


local consumers = resource.new({
    name = "consumers",
    kind = "consumer",
    schema = core.schema.consumer,
    checker = check_conf,
    encrypt_conf = encrypt_conf,
    unsupported_methods = {"post"}
})


function consumers:patch(id, conf, sub_path, args)
    if not id then
        return 400, {error_msg = "missing " .. self.kind .. " id"}
    end

    if conf == nil then
        return 400, {error_msg = "missing new configuration"}
    end

    if (not sub_path or sub_path == "") and type(conf) ~= "table" then
        return 400, {error_msg = "invalid configuration"}
    end

    local key = "/" .. self.name .. "/" .. id
    local res_old, err = core.etcd.get(key)
    if not res_old then
        core.log.error("failed to get ", self.kind, " [", key, "] in etcd: ", err)
        return 503, {error_msg = err}
    end

    if res_old.status ~= 200 then
        return res_old.status, res_old.body
    end

    local node_value = res_old.body.node.value
    local modified_index = res_old.body.node.modifiedIndex
    decrypt_consumer_plugins(node_value)

    if sub_path and sub_path ~= "" then
        local code, patch_err, node_val = core.table.patch(node_value, sub_path, conf)
        node_value = node_val
        if code then
            return code, {error_msg = patch_err}
        end
        utils.inject_timestamp(node_value, nil, true)
    else
        node_value = core.table.merge(node_value, conf)
        utils.inject_timestamp(node_value, nil, conf)
    end

    local ok, check_err = self:check_conf(id, node_value, true, nil, true)
    if not ok then
        return 400, check_err
    end

    local ttl = nil
    if args then
        ttl = args.ttl
    end

    local res, set_err = core.etcd.atomic_set(key, node_value, ttl, modified_index)
    if not res then
        core.log.error("failed to set new ", self.kind, "[", key, "] to etcd: ", set_err)
        return 503, {error_msg = set_err}
    end

    return res.status, res.body
end


return consumers
