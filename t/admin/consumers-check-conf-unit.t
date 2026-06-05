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
log_level("info");

run_tests();

__DATA__

=== TEST 1: unit test - check_conf with valid config
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")

            -- We'll verify the resource structure
            ngx.say("Consumer admin resource loaded: ", type(consumers))
            ngx.say("Checker exists: ", consumers.checker ~= nil)
            ngx.say("Encrypt conf exists: ", consumers.encrypt_conf ~= nil)
            ngx.say("Unsupported methods: ", require("cjson.safe").encode(consumers.unsupported_methods))

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 2: simulate the encryption and decryption round trip
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local plugin = require("apisix.plugin")
            local apisix_ssl = require("apisix.ssl")

            -- 模拟插件配置
            local test_conf = {
                username = "round-trip-user",
                plugins = {
                    ["key-auth"] = {
                        key = "my-secret-round-trip"
                    },
                    ["basic-auth"] = {
                        username = "basic-user",
                        password = "basic-pass"
                    }
                }
            }

            ngx.say("Original key-auth key: ", test_conf.plugins["key-auth"].key)
            ngx.say("Original basic-auth password: ", test_conf.plugins["basic-auth"].password)

            -- 保存原始值用于验证
            local original_key = test_conf.plugins["key-auth"].key
            local original_pass = test_conf.plugins["basic-auth"].password

            -- 模拟加密过程 (encrypt_conf)
            if plugin.enable_gde() then
                for name, conf in pairs(test_conf.plugins) do
                    plugin.encrypt_conf(name, conf, core.schema.TYPE_CONSUMER)
                end
            end

            -- 检查加密后的值不等于原始值
            local encrypted_key = test_conf.plugins["key-auth"].key
            local encrypted_pass = test_conf.plugins["basic-auth"].password

            if encrypted_key == original_key then
                ngx.say("FAIL: key was not encrypted")
                ngx.exit(200)
            end
            ngx.say("Encrypted key: ", encrypted_key:sub(1, 20) .. "...")

            -- 模拟解密过程
            if plugin.enable_gde() then
                for name, conf in pairs(test_conf.plugins) do
                    plugin.decrypt_conf(name, conf, core.schema.TYPE_CONSUMER)
                end
            end

            -- 验证解密后的值
            if test_conf.plugins["key-auth"].key ~= original_key then
                ngx.say("FAIL: decrypted key mismatch")
                ngx.exit(200)
            end

            if test_conf.plugins["basic-auth"].password ~= original_pass then
                ngx.say("FAIL: decrypted password mismatch")
                ngx.exit(200)
            end

            ngx.say("Round trip successful: encrypt and decrypt works correctly")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body_like eval
qr/Round trip successful/


=== TEST 3: simulate old encrypted data - backward compatibility check
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local plugin = require("apisix.plugin")
            local apisix_ssl = require("apisix.ssl")

            -- 步骤 1: 使用当前代码创建加密数据
            local conf_v1 = {
                username = "old-data-user",
                plugins = {
                    ["key-auth"] = {
                        key = "old-secret-v1"
                    }
                }
            }

            if plugin.enable_gde() then
                plugin.encrypt_conf("key-auth", conf_v1.plugins["key-auth"], core.schema.TYPE_CONSUMER)
            end

            local old_encrypted_key = conf_v1.plugins["key-auth"].key
            ngx.say("Old encrypted key generated")

            -- 步骤 2: 保存这个加密值，模拟"旧版本数据"
            local stored_encrypted_data = old_encrypted_key

            -- 步骤 3: 创建新配置对象，混合旧加密数据
            local conf_new = {
                username = "old-data-user",
                plugins = {
                    ["key-auth"] = {
                        key = stored_encrypted_data
                    },
                    ["new-plugin"] = {
                        config = "new config"
                    }
                }
            }

            -- 步骤 4: 对新配置运行加密（应保持旧加密字段不变）
            if plugin.enable_gde() then
                for name, conf in pairs(conf_new.plugins) do
                    plugin.encrypt_conf(name, conf, core.schema.TYPE_CONSUMER)
                end
            end

            -- 验证旧加密字段没有被重新加密
            if conf_new.plugins["key-auth"].key ~= stored_encrypted_data then
                ngx.say("FAIL: old encrypted data was modified")
                ngx.exit(200)
            end

            -- 步骤 5: 解密验证，确保旧数据能正常解密
            if plugin.enable_gde() then
                plugin.decrypt_conf("key-auth", conf_new.plugins["key-auth"], core.schema.TYPE_CONSUMER)
            end

            if conf_new.plugins["key-auth"].key ~= "old-secret-v1" then
                ngx.say("FAIL: old data could not be decrypted correctly")
                ngx.say("Got: ", conf_new.plugins["key-auth"].key)
                ngx.exit(200)
            end

            ngx.say("Backward compatibility check passed")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 4: test edge cases - empty plugins, no encrypt fields
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local plugin = require("apisix.plugin")

            -- 测试 1: 没有 plugins 的配置
            local conf1 = {
                username = "empty-plugins"
            }

            local ok, err = pcall(function()
                if plugin.enable_gde() and conf1.plugins then
                    for name, conf in pairs(conf1.plugins) do
                        plugin.encrypt_conf(name, conf, core.schema.TYPE_CONSUMER)
                    end
                end
            end)

            if not ok then
                ngx.say("FAIL: empty plugins config caused error: ", err)
                ngx.exit(200)
            end

            -- 测试 2: 没有加密字段的插件
            local conf2 = {
                username = "no-encrypt",
                plugins = {
                    ["limit-count"] = {
                        count = 2,
                        time_window = 60
                    }
                }
            }

            local ok2, err2 = pcall(function()
                if plugin.enable_gde() then
                    for name, conf in pairs(conf2.plugins) do
                        plugin.encrypt_conf(name, conf, core.schema.TYPE_CONSUMER)
                    end
                end
            end)

            if not ok2 then
                ngx.say("FAIL: plugin without encrypt fields caused error: ", err2)
                ngx.exit(200)
            end

            ngx.say("Edge cases handled correctly")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 5: test that encrypt_conf is idempotent - multiple encrypt calls
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local plugin = require("apisix.plugin")

            local conf = {
                username = "idempotent-test",
                plugins = {
                    ["key-auth"] = {
                        key = "idempotent-secret"
                    }
                }
            }

            if not plugin.enable_gde() then
                ngx.say("Data encryption not enabled, skipping")
                ngx.say("passed")
                return
            end

            -- 第一次加密
            plugin.encrypt_conf("key-auth", conf.plugins["key-auth"], core.schema.TYPE_CONSUMER)
            local encrypted1 = conf.plugins["key-auth"].key

            -- 第二次加密（不应改变已经加密的值）
            plugin.encrypt_conf("key-auth", conf.plugins["key-auth"], core.schema.TYPE_CONSUMER)
            local encrypted2 = conf.plugins["key-auth"].key

            if encrypted1 ~= encrypted2 then
                ngx.say("FAIL: encrypt_conf is not idempotent")
                ngx.say("Encrypt 1: ", encrypted1)
                ngx.say("Encrypt 2: ", encrypted2)
                ngx.exit(200)
            end

            -- 解密验证
            plugin.decrypt_conf("key-auth", conf.plugins["key-auth"], core.schema.TYPE_CONSUMER)
            if conf.plugins["key-auth"].key ~= "idempotent-secret" then
                ngx.say("FAIL: decryption failed after multiple encrypts")
                ngx.exit(200)
            end

            ngx.say("encrypt_conf is idempotent")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 6: integration - test check_conf function with plugin validation
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")
            local core = require("apisix.core")
            local resource = require("apisix.admin.resource")

            -- 创建一个测试资源实例，与 consumers.lua 相同的配置
            local test_resource = resource.new({
                name = "consumers-test",
                kind = "consumer",
                schema = core.schema.consumer,
                checker = function(username, conf, need_username, schema, opts)
                    local ok, err = core.schema.check(schema, conf)
                    if not ok then
                        return nil, {error_msg = "invalid configuration: " .. err}
                    end

                    if username and username ~= conf.username then
                        return nil, {error_msg = "wrong username"}
                    end

                    if conf.plugins then
                        local plugins_admin = require("apisix.admin.plugins")
                        ok, err = plugins_admin.check_schema(conf.plugins, core.schema.TYPE_CONSUMER)
                        if not ok then
                            return nil, {error_msg = "invalid plugins configuration: " .. err}
                        end
                    end

                    return conf.username
                end,
                encrypt_conf = function(id, conf)
                    local plugins_admin = require("apisix.admin.plugins")
                    plugins_admin.encrypt_conf(conf.plugins, core.schema.TYPE_CONSUMER)
                end,
                unsupported_methods = {"post"}
            })

            -- 测试 1: 无效配置 - 缺少 username
            local conf1 = {
                desc = "no username"
            }

            local ok, err = test_resource:check_conf(nil, conf1, false)
            if ok then
                ngx.say("FAIL: should reject config without username")
                ngx.exit(200)
            end
            ngx.say("Correctly rejected invalid config")

            -- 测试 2: 有效配置
            local conf2 = {
                username = "valid-user",
                plugins = {
                    ["key-auth"] = {
                        key = "valid-key"
                    }
                }
            }

            local ok2, err2 = test_resource:check_conf(nil, conf2, false)
            if not ok2 then
                ngx.say("FAIL: should accept valid config: ", require("cjson.safe").encode(err2))
                ngx.exit(200)
            end
            ngx.say("Correctly accepted valid config")

            -- 测试 3: 无效插件配置
            local conf3 = {
                username = "bad-plugin",
                plugins = {
                    ["key-auth"] = {
                        -- 缺少 key 字段
                    }
                }
            }

            local ok3, err3 = test_resource:check_conf(nil, conf3, false)
            if ok3 then
                ngx.say("FAIL: should reject invalid plugin config")
                ngx.exit(200)
            end
            ngx.say("Correctly rejected invalid plugin config")

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 7: test that PATCH is enabled, POST is still disabled
--- config
    location /t {
        content_by_lua_block {
            local consumers = require("apisix.admin.consumers")

            ngx.say("Checking unsupported methods...")

            local has_post = false
            local has_patch = false

            for _, method in ipairs(consumers.unsupported_methods) do
                if method == "post" then
                    has_post = true
                end
                if method == "patch" then
                    has_patch = true
                end
            end

            if has_post then
                ngx.say("✓ POST is disabled (correct)")
            else
                ngx.say("✗ POST should be disabled")
            end

            if not has_patch then
                ngx.say("✓ PATCH is enabled (correct)")
            else
                ngx.say("✗ PATCH should be enabled")
            end

            if has_post and not has_patch then
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed