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

=== TEST 1: create consumer_group first, then create consumer with group_id (success)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, err = t('/apisix/admin/consumer_groups/test_group',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("create consumer_group failed: ", err)
                return
            end

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "group_id": "test_group",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-one"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 2: create consumer with non-existent group_id (failure)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "tom",
                    "group_id": "nonexistent_group",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-two"
                        }
                    }
                }]]
            )
            ngx.status = code
            if code >= 300 then
                ngx.say("rejected as expected")
            else
                ngx.say("unexpected success")
            end
        }
    }
--- error_code: 400



=== TEST 3: verify consumer with group_id stored correctly
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers/jack',
                ngx.HTTP_GET
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("get consumer failed")
                return
            end

            local json = require("toolkit.json")
            local res = json.decode(body)
            if res.value and res.value.group_id == "test_group" then
                ngx.say("passed")
            else
                ngx.say("group_id not found or mismatch")
            end
        }
    }
--- response_body
passed



=== TEST 4: delete consumer_group that is still referenced by a consumer (failure)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumer_groups/test_group',
                ngx.HTTP_DELETE
            )
            ngx.status = code
            if code >= 300 then
                ngx.say("rejected as expected")
            else
                ngx.say("unexpected success")
            end
        }
    }
--- error_code: 400



=== TEST 5: delete consumer, then delete consumer_group (success)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, err = t('/apisix/admin/consumers/jack',
                ngx.HTTP_DELETE
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("delete consumer failed: ", err)
                return
            end

            local code, err = t('/apisix/admin/consumer_groups/test_group',
                ngx.HTTP_DELETE
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("delete consumer_group failed: ", err)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 6: create consumer without group_id (success, no etcd call)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "alice",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-alice"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 7: update consumer to add group_id referencing existing consumer_group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, err = t('/apisix/admin/consumer_groups/group_alpha',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "limit-count": {
                            "count": 10,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("create consumer_group failed: ", err)
                return
            end

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "alice",
                    "group_id": "group_alpha",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-alice"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 8: update consumer to change group_id to non-existent group (failure)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "alice",
                    "group_id": "nonexistent_group_2",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-alice"
                        }
                    }
                }]]
            )
            ngx.status = code
            if code >= 300 then
                ngx.say("rejected as expected")
            else
                ngx.say("unexpected success")
            end
        }
    }
--- error_code: 400



=== TEST 9: cleanup - delete consumer and consumer_group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, err = t('/apisix/admin/consumers/alice',
                ngx.HTTP_DELETE
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("delete consumer failed: ", err)
                return
            end

            local code, err = t('/apisix/admin/consumer_groups/group_alpha',
                ngx.HTTP_DELETE
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("delete consumer_group failed: ", err)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed
