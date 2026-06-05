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

=== TEST 1: PATCH consumer - add desc field (no encryption)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch_test_1",
                    "desc": "original"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/patch_test_1',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "patched"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch_test_1',
                ngx.HTTP_GET
            )
            local json = require("toolkit.json")
            res = json.decode(res)
            ngx.say("desc: ", res.value.desc)
            ngx.say("username: ", res.value.username)
        }
    }
--- response_body
desc: patched
username: patch_test_1



=== TEST 2: PATCH consumer - update encrypted plugin field (no double-encryption)
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
            local etcd = require("apisix.core.etcd")

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch_enc_2",
                    "plugins": {
                        "basic-auth": {
                            "username": "foo",
                            "password": "secret123"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local res_before = assert(etcd.get('/consumers/patch_enc_2'))
            local encrypted_before = res_before.body.node.value.plugins["basic-auth"].password

            local code, body = t('/apisix/admin/consumers/patch_enc_2',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "added by patch"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local res_after = assert(etcd.get('/consumers/patch_enc_2'))
            local encrypted_after = res_after.body.node.value.plugins["basic-auth"].password

            ngx.say("encrypted_same: ", encrypted_before == encrypted_after)

            local code, message, res = t('/apisix/admin/consumers/patch_enc_2',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            ngx.say("password: ", res.value.plugins["basic-auth"].password)
            ngx.say("desc: ", res.value.desc)
        }
    }
--- response_body
encrypted_same: true
password: secret123
desc: added by patch



=== TEST 3: PATCH consumer - change encrypted field value
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
            local etcd = require("apisix.core.etcd")

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch_enc_3",
                    "plugins": {
                        "key-auth": {
                            "key": "old-key-value"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/patch_enc_3',
                ngx.HTTP_PATCH,
                [[{
                    "plugins": {
                        "key-auth": {
                            "key": "new-key-value"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch_enc_3',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            ngx.say("key: ", res.value.plugins["key-auth"].key)

            local res_etcd = assert(etcd.get('/consumers/patch_enc_3'))
            local etcd_key = res_etcd.body.node.value.plugins["key-auth"].key
            ngx.say("etcd_encrypted: ", etcd_key ~= "new-key-value")
        }
    }
--- response_body
key: new-key-value
etcd_encrypted: true



=== TEST 4: PATCH consumer - add new plugin alongside existing encrypted one
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
                    "username": "patch_enc_4",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-key-4"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/patch_enc_4',
                ngx.HTTP_PATCH,
                [[{
                    "plugins": {
                        "basic-auth": {
                            "username": "user4",
                            "password": "pass4"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch_enc_4',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            ngx.say("key-auth key: ", res.value.plugins["key-auth"].key)
            ngx.say("basic-auth password: ", res.value.plugins["basic-auth"].password)
        }
    }
--- response_body
key-auth key: auth-key-4
basic-auth password: pass4



=== TEST 5: PATCH consumer - sub-path update on encrypted field
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
            local etcd = require("apisix.core.etcd")

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch_enc_5",
                    "plugins": {
                        "key-auth": {
                            "key": "original-key-5"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/patch_enc_5/plugins/key-auth/key',
                ngx.HTTP_PATCH,
                '"updated-key-5"'
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/patch_enc_5',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            ngx.say("key: ", res.value.plugins["key-auth"].key)

            local res_etcd = assert(etcd.get('/consumers/patch_enc_5'))
            local etcd_key = res_etcd.body.node.value.plugins["key-auth"].key
            ngx.say("etcd_encrypted: ", etcd_key ~= "updated-key-5")
        }
    }
--- response_body
key: updated-key-5
etcd_encrypted: true



=== TEST 6: PATCH consumer - backward compat: old encrypted data still decrypts
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
            local core = require("apisix.core")
            local etcd = require("apisix.core.etcd")

            local res, err = core.etcd.set("/consumers/compat_test_6", core.json.decode([[{
                "username":"compat_test_6",
                "plugins":{
                    "basic-auth":{
                        "username":"compat_user",
                        "password":"77+NmbYqNfN+oLm0aX5akg=="
                    }
                }
            }]]))
            if not res then
                ngx.say("failed to set: ", err)
                return
            end

            ngx.sleep(0.1)

            local code, body = t('/apisix/admin/consumers/compat_test_6',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "patched on old encrypted data"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local code, message, res = t('/apisix/admin/consumers/compat_test_6',
                ngx.HTTP_GET
            )
            res = json.decode(res)
            ngx.say("password: ", res.value.plugins["basic-auth"].password)
            ngx.say("desc: ", res.value.desc)
        }
    }
--- response_body
password: bar
desc: patched on old encrypted data



=== TEST 7: CI/CD gate check - verify encrypt/decrypt roundtrip
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local gate = require("apisix.admin.consumers_compat_gate")
            local core = require("apisix.core")

            local plugins_conf = {
                ["basic-auth"] = {
                    username = "gateuser",
                    password = "gatepass"
                },
                ["key-auth"] = {
                    key = "gate-key-123"
                }
            }

            local ok, msg = gate.verify_encrypt_decrypt_roundtrip(
                plugins_conf, core.schema.TYPE_CONSUMER
            )
            ngx.say("roundtrip_passed: ", ok)
            ngx.say("message: ", msg)
        }
    }
--- response_body_like
roundtrip_passed: true
message: encrypt->decrypt roundtrip verified



=== TEST 8: CI/CD gate check - verify old data backward compatibility
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local gate = require("apisix.admin.consumers_compat_gate")
            local core = require("apisix.core")

            local old_etcd_value = {
                username = "gate_old_8",
                plugins = {
                    ["basic-auth"] = {
                        username = "olduser",
                        password = "77+NmbYqNfN+oLm0aX5akg=="
                    }
                }
            }

            local expected_plaintext = {
                ["basic-auth"] = {
                    username = "olduser",
                    password = "bar"
                }
            }

            local ok, msg = gate.verify_old_data_compatible(
                old_etcd_value, expected_plaintext, core.schema.TYPE_CONSUMER
            )
            ngx.say("old_data_compat: ", ok)
            ngx.say("message: ", msg)
        }
    }
--- response_body_like
old_data_compat: true
message: old encrypted data is backward compatible



=== TEST 9: CI/CD gate check - verify no double-encryption on PATCH
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local gate = require("apisix.admin.consumers_compat_gate")
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "gate_patch_9",
                    "plugins": {
                        "key-auth": {
                            "key": "gate-key-9"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local ok, msg = gate.verify_patch_no_double_encrypt(
                "gate_patch_9",
                { desc = "patched desc" },
                nil
            )
            ngx.say("no_double_encrypt: ", ok)
            ngx.say("message: ", msg)
        }
    }
--- response_body_like
no_double_encrypt: true
message: no double-encryption detected



=== TEST 10: CI/CD gate check - run full gate check suite
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local gate = require("apisix.admin.consumers_compat_gate")
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local json = require("toolkit.json")

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "gate_full_10",
                    "plugins": {
                        "basic-auth": {
                            "username": "fulluser",
                            "password": "fullpass"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local results = gate.run_gate_check({
                verify_roundtrip = {
                    plugins_conf = {
                        ["basic-auth"] = {
                            username = "rtuser",
                            password = "rtpass"
                        }
                    },
                    schema_type = core.schema.TYPE_CONSUMER
                },
                verify_old_data = {
                    old_etcd_value = {
                        username = "old_10",
                        plugins = {
                            ["basic-auth"] = {
                                username = "olduser10",
                                password = "77+NmbYqNfN+oLm0aX5akg=="
                            }
                        }
                    },
                    expected_plaintext_map = {
                        ["basic-auth"] = {
                            username = "olduser10",
                            password = "bar"
                        }
                    },
                    schema_type = core.schema.TYPE_CONSUMER
                },
                verify_patch = {
                    id = "gate_full_10",
                    patch_conf = { desc = "full gate patch" },
                    sub_path = nil
                }
            })

            ngx.say("all_passed: ", results.all_passed)
            ngx.say("roundtrip: ", results.roundtrip.passed)
            ngx.say("old_data: ", results.old_data_compat.passed)
            ngx.say("patch: ", results.patch_no_double_encrypt.passed)
        }
    }
--- response_body_like
all_passed: true
roundtrip: true
old_data: true
patch: true



=== TEST 11: PATCH consumer - missing username returns 400
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "no username"
                }]]
            )
            ngx.say("code: ", code)
        }
    }
--- response_body
code: 400



=== TEST 12: PATCH consumer - non-existent consumer returns 404
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/consumers/nonexistent_user',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "patching ghost"
                }]]
            )
            ngx.say("code: ", code)
        }
    }
--- response_body
code: 404



=== TEST 13: PATCH consumer - create_time preserved, update_time refreshed
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch_time_13",
                    "desc": "original"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local res1 = assert(etcd.get('/consumers/patch_time_13'))
            local create_before = res1.body.node.value.create_time
            local update_before = res1.body.node.value.update_time

            ngx.sleep(1)

            local code, body = t('/apisix/admin/consumers/patch_time_13',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "patched"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            local res2 = assert(etcd.get('/consumers/patch_time_13'))
            local create_after = res2.body.node.value.create_time
            local update_after = res2.body.node.value.update_time

            ngx.say("create_preserved: ", create_before == create_after)
            ngx.say("update_refreshed: ", update_after > update_before)
        }
    }
--- response_body
create_preserved: true
update_refreshed: true
