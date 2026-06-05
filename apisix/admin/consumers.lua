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
local plugins = require("apisix.admin.plugins")
local plugins_encrypt_conf = plugins.encrypt_conf
local plugins_decrypt_conf = require("apisix.plugin").decrypt_conf
local resource = require("apisix.admin.resource")
local utils = require("apisix.admin.utils")
local tbl_deepcopy = require("apisix.core.table").deepcopy
local type = type
local pairs = pairs


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


local function decrypt_conf_fields(conf)
    if not conf or not conf.plugins then
        return
    end

    for name, plugin_conf in pairs(conf.plugins) do
        plugins_decrypt_conf(name, plugin_conf, core.schema.TYPE_CONSUMER)
    end
end


local consumer_resource = resource.new({
    name = "consumers",
    kind = "consumer",
    schema = core.schema.consumer,
    checker = check_conf,
    encrypt_conf = encrypt_conf,
    unsupported_methods = {"post"}
})


function consumer_resource:patch(id, conf, sub_path, args)
    if not id then
        return 400, {error_msg = "missing consumer username"}
    end

    local key = "/consumers/" .. id

    if conf == nil then
        return 400, {error_msg = "missing new configuration"}
    end

    if not sub_path or sub_path == "" then
        if type(conf) ~= "table" then
            return 400, {error_msg = "invalid configuration"}
        end
    end

    local res_old, err = core.etcd.get(key)
    if not res_old then
        core.log.error("failed to get consumer [", key, "] in etcd: ", err)
        return 503, {error_msg = err}
    end

    if res_old.status ~= 200 then
        return res_old.status, res_old.body
    end
    core.log.info("key: ", key, " old value: ",
                  core.json.delay_encode(res_old, true))

    local node_value = res_old.body.node.value
    local modified_index = res_old.body.node.modifiedIndex

    decrypt_conf_fields(node_value)

    if sub_path and sub_path ~= "" then
        local code, err, node_val = core.table.patch(node_value, sub_path, conf)
        node_value = node_val
        if code then
            return code, {error_msg = err}
        end
        utils.inject_timestamp(node_value, nil, true)
    else
        node_value = core.table.merge(node_value, conf)
        utils.inject_timestamp(node_value, nil, conf)
    end

    core.log.info("new conf: ", core.json.delay_encode(node_value, true))

    local conf_for_check = tbl_deepcopy(node_value)
    local ok, err = check_conf(id, conf_for_check, true,
                               core.schema.consumer)
    if not ok then
        return 400, err
    end

    encrypt_conf(id, node_value)

    local ttl = nil
    if args then
        ttl = args.ttl
    end

    local res, err = core.etcd.atomic_set(key, node_value, ttl,
                                          modified_index)
    if not res then
        core.log.error("failed to set new consumer [", key,
                       "] to etcd: ", err)
        return 503, {error_msg = err}
    end

    return res.status, res.body
end


return consumer_resource
