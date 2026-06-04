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

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: check_conf - no group_id, no etcd call needed
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")

            local conf = {
                username = "jack",
                desc = "test consumer",
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
passed



=== TEST 2: check_conf - group_id with etcd success (status 200)
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group1" then
                    return {status = 200, body = {node = {value = {id = "group1"}}}}, nil
                end
                return nil, "not found"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {},
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
passed



=== TEST 3: check_conf - group_id with etcd key not found (status 404)
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/nonexistent" then
                    return {status = 404, body = {}}, nil
                end
                return nil, "unexpected key"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "nonexistent",
                plugins = {},
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
failed: failed to fetch consumer group info by consumer group id [nonexistent], response code: 404



=== TEST 4: check_conf - group_id with etcd failure (connection refused)
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                return nil, "connection refused"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {},
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
failed: failed to fetch consumer group info by consumer group id [group1]: connection refused



=== TEST 5: check_conf - group_id with skip_references_check bypasses etcd
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local etcd_called = false
            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                etcd_called = true
                return nil, "should not be called"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {},
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer, {
                skip_references_check = true,
            })
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                if etcd_called then
                    ngx.say("failed: etcd.get was called when skip_references_check=true")
                else
                    ngx.say("passed")
                end
            end
        }
    }
--- response_body
passed



=== TEST 6: check_conf - wrong username
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")

            local conf = {
                username = "jack",
                desc = "test consumer",
            }

            local ok, err = consumers.checker("not_jack", conf, true, core.schema.consumer)
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
failed: wrong username



=== TEST 7: check_conf - invalid schema (missing required username)
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")

            local conf = {
                desc = "test consumer without username",
            }

            local ok, err = consumers.checker(nil, conf, true, core.schema.consumer)
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body_like
failed: invalid configuration:



=== TEST 8: check_conf - group_id with etcd returning non-200 status (e.g. 500)
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group1" then
                    return {status = 500, body = {}}, nil
                end
                return nil, "unexpected key"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {},
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
failed: failed to fetch consumer group info by consumer group id [group1], response code: 500



=== TEST 9: check_conf - group_id with valid plugins and etcd success
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local original_etcd_get = core.etcd.get
            core.etcd.get = function(key)
                if key == "/consumer_groups/group1" then
                    return {
                        status = 200,
                        body = {
                            node = {
                                value = {
                                    id = "group1",
                                    plugins = {
                                        ["limit-count"] = {
                                            count = 2,
                                            time_window = 60,
                                            rejected_code = 503,
                                            key = "remote_addr",
                                        }
                                    }
                                }
                            }
                        }
                    }, nil
                end
                return nil, "not found"
            end

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {
                    ["key-auth"] = {
                        key = "auth-key"
                    }
                },
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            core.etcd.get = original_etcd_get

            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body
passed



=== TEST 10: check_conf - group_id with invalid plugins schema
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")

            local consumers = require("apisix.admin.consumers")
            local conf = {
                username = "jack",
                group_id = "group1",
                plugins = {
                    ["key-auth"] = {
                        key = 12345
                    }
                },
            }

            local ok, err = consumers.checker("jack", conf, true, core.schema.consumer)
            if not ok then
                ngx.say("failed: ", err.error_msg)
            else
                ngx.say("passed")
            end
        }
    }
--- response_body_like
failed: invalid plugins configuration:
