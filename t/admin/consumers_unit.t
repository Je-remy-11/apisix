#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level("info");

run_tests;

__DATA__

=== TEST 1: check_conf with group_id (etcd success)
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")
            
            -- Mock core.etcd.get
            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group_ok" then
                    return { status = 200 }
                end
                return original_etcd_get(key)
            end
            
            local conf = {
                username = "jack",
                group_id = "group_ok"
            }
            
            -- Call checker (which is the check_conf function)
            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer, {})
            
            -- Restore Mock
            core.etcd.get = original_etcd_get
            
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed: ", ok)
            end
        }
    }
--- request
GET /t
--- response_body
passed: jack



=== TEST 2: check_conf with group_id (etcd not found)
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")
            
            -- Mock core.etcd.get
            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group_not_found" then
                    return { status = 404 }
                end
                return original_etcd_get(key)
            end
            
            local conf = {
                username = "jack",
                group_id = "group_not_found"
            }
            
            -- Call checker
            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer, {})
            
            -- Restore Mock
            core.etcd.get = original_etcd_get
            
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed: ", ok)
            end
        }
    }
--- request
GET /t
--- response_body
failed: failed to fetch consumer group info by consumer group id [group_not_found], response code: 404



=== TEST 3: check_conf with group_id (etcd failure)
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")
            
            -- Mock core.etcd.get
            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group_error" then
                    return nil, "connection refused"
                end
                return original_etcd_get(key)
            end
            
            local conf = {
                username = "jack",
                group_id = "group_error"
            }
            
            -- Call checker
            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer, {})
            
            -- Restore Mock
            core.etcd.get = original_etcd_get
            
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed: ", ok)
            end
        }
    }
--- request
GET /t
--- response_body
failed: failed to fetch consumer group info by consumer group id [group_error]: connection refused
