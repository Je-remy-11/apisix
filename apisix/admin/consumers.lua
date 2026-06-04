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
local plugins_encrypt_conf = require("apisix.admin.plugins").encrypt_conf
local resource = require("apisix.admin.resource")


local consumers


local function get_group_id_etcd_get(opts)
    if opts and opts.etcd_get then
        return opts.etcd_get
    end

    if consumers and consumers.group_id_etcd_get then
        return consumers.group_id_etcd_get
    end

    return core.etcd.get
end


local function check_group_id(group_id, opts)
    opts = opts or {}
    if not group_id or opts.skip_references_check then
        return true
    end

    local key = "/consumer_groups/" .. group_id
    local res, err = get_group_id_etcd_get(opts)(key)
    if not res then
        return nil, {error_msg = "failed to fetch consumer group info by "
                                 .. "consumer group id [" .. group_id .. "]: "
                                 .. err}
    end

    if res.status ~= 200 then
        return nil, {error_msg = "failed to fetch consumer group info by "
                                 .. "consumer group id [" .. group_id .. "], "
                                 .. "response code: " .. res.status}
    end

    return true
end


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

    ok, err = check_group_id(conf.group_id, opts)
    if not ok then
        return nil, err
    end

    return conf.username
end


local function encrypt_conf(id, conf)
    plugins_encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)
end


consumers = resource.new({
    name = "consumers",
    kind = "consumer",
    schema = core.schema.consumer,
    checker = check_conf,
    encrypt_conf = encrypt_conf,
    unsupported_methods = {"post", "patch"}
})

consumers.check_group_id = check_group_id
consumers.group_id_etcd_get = nil

return consumers
