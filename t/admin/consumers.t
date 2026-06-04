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

=== TEST 1: add consumer with username
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"jack",
                     "desc": "new consumer"
                }]],
                [[{
                    "value": {
                        "username": "jack",
                        "desc": "new consumer"
                    },
                    "key": "/apisix/consumers/jack"
                }]]
                )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: update consumer with username and plugins
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")
            local res = assert(etcd.get('/consumers/jack'))
            local prev_create_time = res.body.node.value.create_time
            assert(prev_create_time ~= nil, "create_time is nil")
            local update_time = res.body.node.value.update_time
            assert(update_time ~= nil, "update_time is nil")
            ngx.sleep(1)

            local code, body = t('/apisix/admin/consumers',
                 ngx.HTTP_PUT,
                 [[{
                    "username": "jack",
                    "desc": "new consumer",
                    "plugins": {
                            "key-auth": {
                                "key": "auth-one"
                            }
                        }
                }]],
                [[{
                    "value": {
                        "username": "jack",
                        "desc": "new consumer",
                        "plugins": {
                            "key-auth": {
                                "key": "4y+JvURBE6ZwRbbgaryrhg=="
                            }
                        }
                    },
                    "key": "/apisix/consumers/jack"
                }]]
                )

            ngx.status = code
            ngx.say(body)

            local res = assert(etcd.get('/consumers/jack'))
            local create_time = res.body.node.value.create_time
            assert(prev_create_time == create_time, "create_time mismatched")
            local update_time = res.body.node.value.update_time
            assert(update_time ~= nil, "update_time is nil")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: get consumer
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers/jack',
                 ngx.HTTP_GET,
                 nil,
                [[{
                    "value": {
                        "username": "jack",
                        "desc": "new consumer",
                        "plugins": {
                            "key-auth": {
                                "key": "auth-one"
                            }
                        }
                    },
                    "key": "/apisix/consumers/jack"
                }]]
                )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: delete consumer
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(0.3)
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers/jack',
                 ngx.HTTP_DELETE
            )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 5: delete consumer(id: not_found)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code = t('/apisix/admin/consumers/not_found',
                 ngx.HTTP_DELETE,
                 nil
            )
            ngx.say("[delete] code: ", code)
        }
    }
--- request
GET /t
--- response_body
[delete] code: 404



=== TEST 6: missing username
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                 ngx.HTTP_PUT,
                 [[{
                     "id":"jack"
                }]],
                [[{
                    "value": {
                        "id": "jack"
                    }
                }]]
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body
{"error_msg":"invalid configuration: property \"username\" is required"}



=== TEST 7: consumer username allows '-' in it
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                 ngx.HTTP_PUT,
                 [[{
                     "username":"Jack-and-Rose_123"
                }]]
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 201



=== TEST 8: add consumer with labels
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"jack",
                     "desc": "new consumer",
                     "labels": {
                         "build":"16",
                         "env":"production",
                         "version":"v2"
                     }
                }]],
                [[{
                    "value": {
                        "username": "jack",
                        "desc": "new consumer",
                        "labels": {
                            "build":"16",
                            "env":"production",
                            "version":"v2"
                        }
                    },
                    "key": "/apisix/consumers/jack"
                }]]
                )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 9: invalid format of label value: set consumer
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                 ngx.HTTP_PUT,
                 [[{
                     "username":"jack",
                     "desc": "new consumer",
                     "labels": {
                        "env": ["production", "release"]
                     }
                }]]
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body
{"error_msg":"invalid configuration: property \"labels\" validation failed: failed to validate env (matching \".*\"): wrong type: expected string, got table"}



=== TEST 10: post consumers
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                 ngx.HTTP_POST,
                 ""
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 405
--- response_body
{"error_msg":"not supported `POST` method for consumer"}



=== TEST 11: add consumer with create_time and update_time(pony)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"pony",
                     "desc": "new consumer",
                     "create_time": 1602883670,
                     "update_time": 1602893670
                }]],
                [[{
                    "value": {
                        "username": "pony",
                        "desc": "new consumer",
                        "create_time": 1602883670,
                        "update_time": 1602893670
                    },
                    "key": "/apisix/consumers/pony"
                }]]
                )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body eval
qr/\{"error_msg":"the property is forbidden:.*"\}/


=== TEST 12: add consumer with valid group_id
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            -- First, create a consumer group
            local code, body = t('/apisix/admin/consumer_groups/my_group',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "response-rewrite": {
                            "body": "hello"
                        }
                    }
                }]]
            )
            if code > 300 then
                ngx.log(ngx.ERR, body)
                ngx.status = code
                ngx.say("Failed to create consumer group")
                return
            end

            -- Then, create a consumer with this group_id
            local code2, body2 = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "consumer_with_group",
                    "group_id": "my_group"
                }]]
            )

            ngx.status = code2
            ngx.say("Consumer with valid group_id result: ", body2)

            -- Cleanup
            t('/apisix/admin/consumers/consumer_with_group', ngx.HTTP_DELETE)
            t('/apisix/admin/consumer_groups/my_group', ngx.HTTP_DELETE)
        }
    }
--- request
GET /t
--- error_code: 201


=== TEST 13: add consumer with non-existent group_id (should fail)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            -- Try to create a consumer with non-existent group_id
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "consumer_with_invalid_group",
                    "group_id": "non_existent_group"
                }]]
            )

            ngx.status = code
            ngx.say("Consumer with invalid group_id result: ", body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body_like: failed to fetch consumer group info by consumer group id \[non_existent_group\]


=== TEST 14: update consumer to add/change group_id
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            -- First, create consumer without group
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "consumer_update_group"
                }]]
            )
            if code > 300 then
                ngx.say("Failed to create initial consumer")
                return
            end

            -- Create a consumer group
            local code2, body2 = t('/apisix/admin/consumer_groups/update_test_group',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {}
                }]]
            )

            -- Update consumer with group_id
            local code3, body3 = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "consumer_update_group",
                    "group_id": "update_test_group"
                }]]
            )

            ngx.status = code3
            ngx.say("Update consumer with group_id result: ", code3)

            -- Cleanup
            t('/apisix/admin/consumers/consumer_update_group', ngx.HTTP_DELETE)
            t('/apisix/admin/consumer_groups/update_test_group', ngx.HTTP_DELETE)
        }
    }
--- request
GET /t
--- error_code: 200
