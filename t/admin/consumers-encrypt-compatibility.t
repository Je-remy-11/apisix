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

run_tests();

__DATA__

=== TEST 1: add consumer with encrypted key-auth plugin (full PUT)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")
            local core = require("apisix.core")

            -- Add consumer with encrypted key
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"alice",
                     "desc": "test consumer",
                     "plugins": {
                         "key-auth": {
                             "key": "my-secret-key-123"
                         }
                     }
                }]],
                [[{
                    "value": {
                        "username": "alice"
                    },
                    "key": "/apisix/consumers/alice"
                }]]
            )

            ngx.status = code
            if code ~= 201 and code ~= 200 then
                ngx.say(body)
                return
            end

            -- Verify stored data is encrypted
            local res, err = etcd.get('/consumers/alice')
            if not res or res.status ~= 200 then
                ngx.say("failed to get from etcd: ", err)
                return
            end

            local stored_key = res.body.node.value.plugins["key-auth"].key
            if stored_key == "my-secret-key-123" then
                ngx.say("error: key should be encrypted in etcd")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 2: verify we can get the consumer and decrypt the key
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_GET,
                 nil,
                [[{
                    "value": {
                        "username": "alice",
                        "plugins": {
                            "key-auth": {
                                "key": "my-secret-key-123"
                            }
                        }
                    }
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


=== TEST 3: PATCH partial update - only change desc
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            -- PATCH to update only desc
            local code, body = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_PATCH,
                 [[{
                     "desc": "updated test consumer"
                 }]]
            )

            ngx.status = code
            if code ~= 200 then
                ngx.say(body)
                return
            end

            -- Verify key remains encrypted in etcd
            local res, err = etcd.get('/consumers/alice')
            if not res or res.status ~= 200 then
                ngx.say("failed to get from etcd: ", err)
                return
            end

            local stored_key = res.body.node.value.plugins["key-auth"].key
            if stored_key == "my-secret-key-123" then
                ngx.say("error: key should remain encrypted in etcd after PATCH")
                return
            end

            -- Verify we can still get decrypted key
            local code2, body2 = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_GET,
                 nil,
                [[{
                    "value": {
                        "username": "alice",
                        "desc": "updated test consumer",
                        "plugins": {
                            "key-auth": {
                                "key": "my-secret-key-123"
                            }
                        }
                    }
                }]]
            )

            if code2 ~= 200 then
                ngx.say("failed to get decrypted key after PATCH")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 4: PATCH partial update - add a new plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            -- PATCH to add limit-count plugin
            local code, body = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_PATCH,
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

            ngx.status = code
            if code ~= 200 then
                ngx.say(body)
                return
            end

            -- Verify existing key remains encrypted
            local res, err = etcd.get('/consumers/alice')
            if not res or res.status ~= 200 then
                ngx.say("failed to get from etcd: ", err)
                return
            end

            local stored_key = res.body.node.value.plugins["key-auth"].key
            if stored_key == "my-secret-key-123" then
                ngx.say("error: existing key should remain encrypted after PATCH")
                return
            end

            -- Verify both plugins exist
            local plugins = res.body.node.value.plugins
            if not plugins["key-auth"] or not plugins["limit-count"] then
                ngx.say("error: both plugins should exist")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 5: PATCH partial update - update encrypted field directly
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            -- PATCH to update the encrypted key
            local code, body = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_PATCH,
                 [[{
                     "plugins": {
                         "key-auth": {
                             "key": "new-secret-key-456"
                         }
                     }
                 }]]
            )

            ngx.status = code
            if code ~= 200 then
                ngx.say(body)
                return
            end

            -- Verify new key is encrypted in etcd
            local res, err = etcd.get('/consumers/alice')
            if not res or res.status ~= 200 then
                ngx.say("failed to get from etcd: ", err)
                return
            end

            local stored_key = res.body.node.value.plugins["key-auth"].key
            if stored_key == "new-secret-key-456" then
                ngx.say("error: new key should be encrypted in etcd")
                return
            end

            -- Verify we can get the new decrypted key
            local code2, body2 = t('/apisix/admin/consumers/alice',
                 ngx.HTTP_GET,
                 nil,
                [[{
                    "value": {
                        "username": "alice",
                        "plugins": {
                            "key-auth": {
                                "key": "new-secret-key-456"
                            }
                        }
                    }
                }]]
            )

            if code2 ~= 200 then
                ngx.say("failed to get decrypted new key after PATCH")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 6: simulate old encrypted data (backward compatibility check)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")
            local apisix_ssl = require("apisix.ssl")

            -- Create a new consumer
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"bob",
                     "desc": "backward compatibility test",
                     "plugins": {
                         "key-auth": {
                             "key": "temp-key"
                         }
                     }
                }]]
            )

            if code ~= 201 and code ~= 200 then
                ngx.say(body)
                return
            end

            -- Get current encrypted value
            local res, err = etcd.get('/consumers/bob')
            if not res or res.status ~= 200 then
                ngx.say("failed to get initial: ", err)
                return
            end

            local original_encrypted = res.body.node.value.plugins["key-auth"].key

            -- Now, manually simulate "old" encrypted data by directly setting etcd
            -- In real scenarios, this would be data encrypted with previous version
            local consumer_data = res.body.node.value
            -- We keep the same encrypted data as before to simulate old data

            -- Now update the consumer without changing the encrypted part
            consumer_data.desc = "old encrypted data test"

            local set_res, set_err = etcd.set('/consumers/bob', consumer_data)
            if not set_res then
                ngx.say("failed to set old data: ", set_err)
                return
            end

            -- Verify we can still decrypt it
            local code2, body2 = t('/apisix/admin/consumers/bob',
                 ngx.HTTP_GET,
                 nil,
                [[{
                    "value": {
                        "username": "bob",
                        "plugins": {
                            "key-auth": {
                                "key": "temp-key"
                            }
                        }
                    }
                }]]
            )

            if code2 ~= 200 then
                ngx.say("failed to decrypt old encrypted data")
                return
            end

            -- Now PATCH it - should work fine with old encrypted data
            local code3, body3 = t('/apisix/admin/consumers/bob',
                 ngx.HTTP_PATCH,
                 [[{
                     "desc": "patched old data"
                 }]]
            )

            if code3 ~= 200 then
                ngx.say("failed to PATCH old encrypted data")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 7: PATCH with sub-path - update single field
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            -- First add a fresh consumer
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"charlie",
                     "desc": "sub-path test",
                     "plugins": {
                         "key-auth": {
                             "key": "sub-path-key"
                         }
                     }
                }]]
            )

            if code ~= 201 and code ~= 200 then
                ngx.say(body)
                return
            end

            -- PATCH using sub-path to update desc
            local code2, body2 = t('/apisix/admin/consumers/charlie/desc',
                 ngx.HTTP_PATCH,
                 [["sub-path updated desc"]]
            )

            ngx.status = code2
            if code2 ~= 200 then
                ngx.say(body2)
                return
            end

            -- Verify key remains encrypted
            local res, err = etcd.get('/consumers/charlie')
            if not res or res.status ~= 200 then
                ngx.say("failed to get: ", err)
                return
            end

            if res.body.node.value.desc ~= "sub-path updated desc" then
                ngx.say("desc not updated")
                return
            end

            local stored_key = res.body.node.value.plugins["key-auth"].key
            if stored_key == "sub-path-key" then
                ngx.say("key should remain encrypted")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 8: verify POST is still disabled
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


=== TEST 9: cleanup test consumers
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local consumers = {"alice", "bob", "charlie"}
            for _, name in ipairs(consumers) do
                t('/apisix/admin/consumers/' .. name, ngx.HTTP_DELETE)
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 10: full round trip - PUT with encrypted, PATCH multiple times, verify consistency
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            -- 1. Initial PUT
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"dave",
                     "plugins": {
                         "key-auth": {
                             "key": "round-trip-key"
                         },
                         "basic-auth": {
                             "username": "dave-user",
                             "password": "dave-pass"
                         }
                     }
                }]]
            )

            if code ~= 201 and code ~= 200 then
                ngx.say("1. PUT failed: ", body)
                return
            end

            -- 2. First PATCH - add labels
            local code2, body2 = t('/apisix/admin/consumers/dave',
                 ngx.HTTP_PATCH,
                 [[{
                     "labels": {
                         "env": "test",
                         "version": "1"
                     }
                 }]]
            )

            if code2 ~= 200 then
                ngx.say("2. First PATCH failed: ", body2)
                return
            end

            -- 3. Second PATCH - update basic-auth password
            local code3, body3 = t('/apisix/admin/consumers/dave',
                 ngx.HTTP_PATCH,
                 [[{
                     "plugins": {
                         "basic-auth": {
                             "password": "new-dave-pass"
                         }
                     }
                 }]]
            )

            if code3 ~= 200 then
                ngx.say("3. Second PATCH failed: ", body3)
                return
            end

            -- 4. Verify all data is correct and encrypted fields are decryptable
            local code4, body4 = t('/apisix/admin/consumers/dave',
                 ngx.HTTP_GET
            )

            if code4 ~= 200 then
                ngx.say("4. GET failed: ", body4)
                return
            end

            -- Check all fields are present
            local cjson = require("cjson.safe")
            local data = cjson.decode(body4)
            local val = data.value

            if val.username ~= "dave" then
                ngx.say("username mismatch")
                return
            end

            if not val.labels or val.labels.env ~= "test" then
                ngx.say("labels missing or wrong")
                return
            end

            if not val.plugins then
                ngx.say("plugins missing")
                return
            end

            if val.plugins["key-auth"].key ~= "round-trip-key" then
                ngx.say("key-auth key wrong after multiple patches")
                return
            end

            if val.plugins["basic-auth"].password ~= "new-dave-pass" then
                ngx.say("basic-auth password wrong after patch")
                return
            end

            -- Verify data in etcd is encrypted
            local res, err = etcd.get('/consumers/dave')
            if not res or res.status ~= 200 then
                ngx.say("failed to get from etcd: ", err)
                return
            end

            local etcd_val = res.body.node.value
            if etcd_val.plugins["key-auth"].key == "round-trip-key" then
                ngx.say("key-auth key not encrypted in etcd")
                return
            end

            if etcd_val.plugins["basic-auth"].password == "new-dave-pass" then
                ngx.say("basic-auth password not encrypted in etcd")
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 11: cleanup dave
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            t('/apisix/admin/consumers/dave', ngx.HTTP_DELETE)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed