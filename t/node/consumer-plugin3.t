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
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: add consumer with csrf plugin (data encryption enabled)
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local json = require("toolkit.json")
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "key-auth": {
                            "key": "key-a"
                        },
                        "csrf": {
                            "key": "userkey",
                            "expires": 1000000000
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

            local code, message, res = t('/apisix/admin/consumers/jack',
                ngx.HTTP_GET
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end
            local consumer = json.decode(res)
            ngx.say(consumer.value.plugins["csrf"].key)

            local etcd = require("apisix.core.etcd")
            local res = assert(etcd.get('/consumers/jack'))
            ngx.say(res.body.node.value.plugins["csrf"].key)
        }
    }
--- request
GET /t
--- response_body
userkey
mt39FazQccyMqt4ctoRV7w==
--- no_error_log
[error]



=== TEST 2: add route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "key-auth": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: invalid request - no csrf token
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- request
POST /hello
--- more_headers
apikey: key-a
--- error_code: 401
--- response_body
{"error_msg":"no csrf token in headers"}



=== TEST 4: valid request - with csrf token
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- request
POST /hello
--- more_headers
apikey: key-a
apisix-csrf-token: eyJyYW5kb20iOjAuNDI5ODYzMTk3MTYxMzksInNpZ24iOiI0ODRlMDY4NTkxMWQ5NmJhMDc5YzQ1ZGI0OTE2NmZkYjQ0ODhjODVkNWQ0NmE1Y2FhM2UwMmFhZDliNjE5OTQ2IiwiZXhwaXJlcyI6MjY0MzExOTYyNH0=
Cookie: apisix-csrf-token=eyJyYW5kb20iOjAuNDI5ODYzMTk3MTYxMzksInNpZ24iOiI0ODRlMDY4NTkxMWQ5NmJhMDc5YzQ1ZGI0OTE2NmZkYjQ0ODhjODVkNWQ0NmE1Y2FhM2UwMmFhZDliNjE5OTQ2IiwiZXhwaXJlcyI6MjY0MzExOTYyNH0=
--- response_body
hello world
--- no_error_log
[error]



=== TEST 5: patch consumer keeps encrypted fields stable
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local json = require("toolkit.json")
            local etcd = require("apisix.core.etcd")

            t('/apisix/admin/consumers/patch-jack', ngx.HTTP_DELETE)

            local code, body = t('/apisix/admin/routes/11',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/patch-auth",
                    "plugins": {
                        "key-auth": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "patch-jack",
                    "desc": "before-patch",
                    "plugins": {
                        "key-auth": {
                            "key": "patch-key"
                        },
                        "basic-auth": {
                            "username": "patch-jack",
                            "password": "patch-pass"
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

            local res = assert(etcd.get('/consumers/patch-jack'))
            local old_key = res.body.node.value.plugins["key-auth"].key
            local old_password = res.body.node.value.plugins["basic-auth"].password

            code, body = t('/apisix/admin/consumers/patch-jack',
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

            code, body, res = t('/apisix/admin/consumers/patch-jack', ngx.HTTP_GET)
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local consumer = json.decode(res)
            ngx.say(consumer.value.desc)
            ngx.say(consumer.value.plugins["key-auth"].key)
            ngx.say(consumer.value.plugins["basic-auth"].password)

            res = assert(etcd.get('/consumers/patch-jack'))
            ngx.say(old_key == res.body.node.value.plugins["key-auth"].key)
            ngx.say(old_password == res.body.node.value.plugins["basic-auth"].password)

            code, _, body = t('/patch-auth', ngx.HTTP_GET, nil, nil, {
                apikey = "patch-key"
            })
            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
patched
patch-key
patch-pass
true
true
hello world
--- no_error_log
[error]



=== TEST 6: patch consumer rewrites legacy ciphertext with current keyring head
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - qeddd145sfvddff3
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local aes = require("resty.aes")
            local t = require("lib.test_admin").test
            local json = require("toolkit.json")
            local core = require("apisix.core")
            local etcd = require("apisix.core.etcd")

            local function encrypt_with_key(value, key)
                local cipher = assert(aes:new(key, nil, aes.cipher(128, "cbc"), {iv = key}))
                return ngx.encode_base64(assert(cipher:encrypt(value)))
            end

            local current_key = "qeddd145sfvddff3"
            local previous_key = "edd1c9f0985e76a2"
            local previous_encrypted_auth = encrypt_with_key("legacy-key", previous_key)
            local previous_encrypted_password = encrypt_with_key("legacy-pass", previous_key)
            local current_encrypted_auth = encrypt_with_key("legacy-key", current_key)
            local current_encrypted_password = encrypt_with_key("legacy-pass", current_key)

            t('/apisix/admin/consumers/patch-legacy', ngx.HTTP_DELETE)

            local code, body = t('/apisix/admin/routes/12',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/legacy-patch-auth",
                    "plugins": {
                        "key-auth": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            assert(core.etcd.set('/consumers/patch-legacy', {
                username = 'patch-legacy',
                desc = 'before-patch',
                plugins = {
                    ['key-auth'] = {
                        key = previous_encrypted_auth
                    },
                    ['basic-auth'] = {
                        username = 'patch-legacy',
                        password = previous_encrypted_password
                    }
                }
            }))

            ngx.sleep(0.1)

            code, body = t('/apisix/admin/consumers/patch-legacy',
                ngx.HTTP_PATCH,
                [[{
                    "desc": "legacy-patched"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            ngx.sleep(0.1)

            code, body, res = t('/apisix/admin/consumers/patch-legacy', ngx.HTTP_GET)
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local consumer = json.decode(res)
            ngx.say(consumer.value.desc)
            ngx.say(consumer.value.plugins["key-auth"].key)
            ngx.say(consumer.value.plugins["basic-auth"].password)

            res = assert(etcd.get('/consumers/patch-legacy'))
            ngx.say(res.body.node.value.plugins["key-auth"].key == current_encrypted_auth)
            ngx.say(res.body.node.value.plugins["basic-auth"].password == current_encrypted_password)

            code, _, body = t('/legacy-patch-auth', ngx.HTTP_GET, nil, nil, {
                apikey = "legacy-key"
            })
            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
legacy-patched
legacy-key
legacy-pass
true
true
hello world
--- no_error_log
[error]
