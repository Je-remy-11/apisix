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

=== TEST 1: not unwanted data, PUT
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"jack"
                }]]
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            res.value.create_time = nil
            res.value.update_time = nil
            ngx.say(json.encode(res))
        }
    }
--- response_body
{"key":"/apisix/consumers/jack","value":{"username":"jack"}}



=== TEST 2: not unwanted data, GET
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/apisix/admin/consumers/jack',
                ngx.HTTP_GET
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            assert(res.createdIndex ~= nil)
            res.createdIndex = nil
            assert(res.modifiedIndex ~= nil)
            res.modifiedIndex = nil
            assert(res.value.create_time ~= nil)
            res.value.create_time = nil
            assert(res.value.update_time ~= nil)
            res.value.update_time = nil
            ngx.say(json.encode(res))
        }
    }
--- response_body
{"key":"/apisix/consumers/jack","value":{"username":"jack"}}



=== TEST 3: not unwanted data, DELETE
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/apisix/admin/consumers/jack',
                ngx.HTTP_DELETE
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            ngx.say(json.encode(res))
        }
    }
--- response_body
{"deleted":"1","key":"/apisix/consumers/jack"}



=== TEST 4: list empty resources
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/apisix/admin/consumers',
                ngx.HTTP_GET
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            ngx.say(json.encode(res))
        }
    }
--- response_body
{"list":[],"total":0}



=== TEST 5: mismatched username, PUT
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/apisix/admin/consumers/jack1',
                ngx.HTTP_PUT,
                [[{
                     "username":"jack"
                }]]
            )

            ngx.print(message)
        }
    }
--- response_body
{"error_msg":"wrong username"}



=== TEST 6: check_conf unit with mocked group fetch success
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local ok, err = consumers.checker(nil, {
                username = "jack",
                group_id = "company_a"
            }, false, consumers.schema, {
                etcd_get = function(key)
                    assert(key == "/consumer_groups/company_a")
                    return {status = 200}
                end
            })

            if not ok then
                ngx.say(err.error_msg)
                return
            end

            ngx.say(ok)
        }
    }
--- response_body
jack



=== TEST 7: check_conf unit with mocked missing group
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local ok, err = consumers.checker(nil, {
                username = "jack",
                group_id = "company_a"
            }, false, consumers.schema, {
                etcd_get = function(key)
                    assert(key == "/consumer_groups/company_a")
                    return {status = 404}
                end
            })

            assert(not ok)
            ngx.say(err.error_msg)
        }
    }
--- response_body
failed to fetch consumer group info by consumer group id [company_a], response code: 404



=== TEST 8: check_conf unit with mocked etcd failure
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local ok, err = consumers.checker(nil, {
                username = "jack",
                group_id = "company_a"
            }, false, consumers.schema, {
                etcd_get = function(key)
                    assert(key == "/consumer_groups/company_a")
                    return nil, "mocked etcd failure"
                end
            })

            assert(not ok)
            ngx.say(err.error_msg)
        }
    }
--- response_body
failed to fetch consumer group info by consumer group id [company_a]: mocked etcd failure



=== TEST 9: resource check_conf uses injected group fetcher
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local old_etcd_get = consumers.group_id_etcd_get

            consumers.group_id_etcd_get = function(key)
                assert(key == "/consumer_groups/company_a")
                return nil, "mocked etcd failure"
            end

            local ok, err = consumers:check_conf(nil, {
                username = "jack",
                group_id = "company_a"
            }, false)

            consumers.group_id_etcd_get = old_etcd_get

            assert(not ok)
            ngx.say(err.error_msg)
        }
    }
--- response_body
failed to fetch consumer group info by consumer group id [company_a]: mocked etcd failure
