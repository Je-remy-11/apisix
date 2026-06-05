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
});

run_tests;

__DATA__

=== TEST 1: PATCH consumer - update desc only, verify encrypted plugins survive
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-1",
                    "desc": "original",
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-1",
                            "password": "s3cret!"
                        },
                        "key-auth": {
                            "key": "my-key-1"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- PATCH only the desc field
            local code, body = t('/apisix/admin/consumers/patch-test-1',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "updated-via-patch"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH desc failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- GET and verify
            local code, message, res = t('/apisix/admin/consumers/patch-test-1',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            ngx.say("desc: ", res.value.desc)
            ngx.say("password: ", res.value.plugins["basic-auth"].password)
            ngx.say("key: ", res.value.plugins["key-auth"].key)

            -- Verify in etcd: password should be encrypted (not the plaintext "s3cret!")
            local etcd = require("apisix.core.etcd")
            local res = assert(etcd.get('/consumers/patch-test-1'))
            local etcd_password = res.body.node.value.plugins["basic-auth"].password
            local etcd_key = res.body.node.value.plugins["key-auth"].key
            ngx.say("etcd password encrypted: ",
                    etcd_password ~= "s3cret!")
            ngx.say("etcd key encrypted: ",
                    etcd_key ~= "my-key-1")
        }
    }
--- response_body
desc: updated-via-patch
password: s3cret!
key: my-key-1
etcd password encrypted: true
etcd key encrypted: true



=== TEST 2: PATCH consumer - update plugin password only
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-2",
                    "desc": "password rotation test",
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-2",
                            "password": "old-password"
                        },
                        "key-auth": {
                            "key": "stable-key"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- PATCH to update password only, keep key-auth intact
            local code, body = t('/apisix/admin/consumers/patch-test-2',
                ngx.HTTP_PATCH,
                [[{
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-2",
                            "password": "rotated-password"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH password failed: ", body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch-test-2',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            ngx.say("password: ", res.value.plugins["basic-auth"].password)
            ngx.say("key: ", res.value.plugins["key-auth"].key)
        }
    }
--- response_body
password: rotated-password
key: stable-key



=== TEST 3: PATCH consumer - sub-path update on plugins
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-3",
                    "desc": "sub-path test",
                    "plugins": {
                        "key-auth": {
                            "key": "original-key"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- PATCH sub-path: update key-auth/key
            local code, body = t('/apisix/admin/consumers/patch-test-3/plugins/key-auth/key',
                ngx.HTTP_PATCH,
                [["sub-path-updated-key"]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH sub-path failed: ", body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch-test-3',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            ngx.say("key: ", res.value.plugins["key-auth"].key)
        }
    }
--- response_body
key: sub-path-updated-key



=== TEST 4: PATCH consumer - no double encryption in etcd
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-4",
                    "desc": "no-double-encrypt",
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-4",
                            "password": "first-password"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- Read etcd directly to capture first encrypted value
            local etcd = require("apisix.core.etcd")
            local res = assert(etcd.get('/consumers/patch-test-4'))
            local first_encrypted = res.body.node.value.plugins["basic-auth"].password
            ngx.say("first encrypted length: ", #first_encrypted)

            -- PATCH desc only -- plugins unchanged
            local code, body = t('/apisix/admin/consumers/patch-test-4',
                ngx.HTTP_PATCH,
                [[{"desc": "updated-desc"}]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- Capture second encrypted value
            local res = assert(etcd.get('/consumers/patch-test-4'))
            local second_encrypted = res.body.node.value.plugins["basic-auth"].password
            ngx.say("second encrypted length: ", #second_encrypted)

            -- Verify: after PATCH desc, the encrypted password was re-encrypted
            -- (different ciphertext due to AES-CBC random IV), but its
            -- decrypted value should still be the original plaintext.
            -- Double encryption would make the value much longer or unreadable.
            ngx.say("re-encrypted differs: ", first_encrypted ~= second_encrypted)

            -- Verify admin API still returns correct plaintext
            local code, message, res = t('/apisix/admin/consumers/patch-test-4',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end
            ngx.say("password: ", res.value.plugins["basic-auth"].password)
        }
    }
--- response_body
first encrypted length: 24
second encrypted length: 24
re-encrypted differs: true
password: first-password



=== TEST 5: PATCH consumer - add plugin to existing consumer
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-5",
                    "desc": "add-plugin-test",
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-5",
                            "password": "ba-password"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- PATCH to add key-auth while preserving basic-auth
            local code, body = t('/apisix/admin/consumers/patch-test-5',
                ngx.HTTP_PATCH,
                [[{
                    "plugins": {
                        "key-auth": {
                            "key": "added-key"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH add plugin failed: ", body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch-test-5',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            ngx.say("basic-auth password: ", res.value.plugins["basic-auth"].password)
            ngx.say("key-auth key: ", res.value.plugins["key-auth"].key)
        }
    }
--- response_body
basic-auth password: ba-password
key-auth key: added-key



=== TEST 6: PATCH consumer - wrong username rejected
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-6",
                    "plugins": {
                        "key-auth": {
                            "key": "some-key"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            -- PATCH with mismatched username should be rejected
            local code, body = t('/apisix/admin/consumers/patch-test-6',
                ngx.HTTP_PATCH,
                [[{
                    "username": "wrong-username"
                }]]
            )

            ngx.say("code: ", code)
        }
    }
--- response_body
code: 400



=== TEST 7: PATCH consumer - non-existent returns 404
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers/non-existent-patch',
                ngx.HTTP_PATCH,
                [[{"desc": "should-not-exist"}]]
            )

            ngx.say("code: ", code)
        }
    }
--- response_body
code: 404



=== TEST 8: PATCH consumer - encryption disabled, basic PATCH still works
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: false
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-test-8",
                    "desc": "no-encrypt",
                    "plugins": {
                        "basic-auth": {
                            "username": "patch-test-8",
                            "password": "plain-pass"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PUT failed: ", body)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/patch-test-8',
                ngx.HTTP_PATCH,
                [[{"desc": "no-encrypt-updated"}]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("PATCH failed: ", body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch-test-8',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            ngx.say("desc: ", res.value.desc)
            ngx.say("password: ", res.value.plugins["basic-auth"].password)
        }
    }
--- response_body
desc: no-encrypt-updated
password: plain-pass



=== TEST 9: Cleanup test consumers
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local consumers = {"patch-test-1", "patch-test-2", "patch-test-3",
                               "patch-test-4", "patch-test-5", "patch-test-6", "patch-test-8"}
            for i, name in ipairs(consumers) do
                local code, body = t('/apisix/admin/consumers/' .. name,
                    ngx.HTTP_DELETE)
                -- 200 or 404 are both acceptable
            end
            ngx.say("done")
        }
    }
--- response_body
done