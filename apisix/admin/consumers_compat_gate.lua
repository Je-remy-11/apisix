--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local plugin_mod = require("apisix.plugin")
local plugins_encrypt_conf = require("apisix.admin.plugins").encrypt_conf
local plugins_decrypt_conf = plugin_mod.decrypt_conf
local tbl_deepcopy = require("apisix.core.table").deepcopy
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring


local _M = {
    VERSION = "1.0.0",
}


local function decrypt_all_plugin_confs(plugins_conf, schema_type)
    if not plugins_conf then
        return
    end
    for name, conf in pairs(plugins_conf) do
        plugins_decrypt_conf(name, conf, schema_type)
    end
end


function _M.verify_encrypt_decrypt_roundtrip(plugins_conf, schema_type)
    if not plugin_mod.enable_gde() then
        return true, "data_encryption is disabled, roundtrip check skipped"
    end

    schema_type = schema_type or core.schema.TYPE_CONSUMER

    if not plugins_conf then
        return true, "no plugins to check"
    end

    local original = tbl_deepcopy(plugins_conf)

    plugins_encrypt_conf(plugins_conf, schema_type)

    decrypt_all_plugin_confs(plugins_conf, schema_type)

    for name, conf in pairs(plugins_conf) do
        if original[name] then
            local orig_json = core.json.encode(original[name])
            local curr_json = core.json.encode(conf)
            if orig_json ~= curr_json then
                return false, "roundtrip mismatch for plugin [" .. name .. "]: "
                              .. "original=" .. orig_json .. " got=" .. curr_json
            end
        end
    end

    return true, "encrypt->decrypt roundtrip verified"
end


function _M.verify_old_data_compatible(old_etcd_value, expected_plaintext_map,
                                        schema_type)
    if not plugin_mod.enable_gde() then
        return true, "data_encryption is disabled, compatibility check skipped"
    end

    schema_type = schema_type or core.schema.TYPE_CONSUMER

    if not old_etcd_value or not old_etcd_value.plugins then
        return true, "no plugins in old data"
    end

    local decrypted = tbl_deepcopy(old_etcd_value)
    decrypt_all_plugin_confs(decrypted.plugins, schema_type)

    if not expected_plaintext_map then
        return true, "no expected plaintext provided, only decryption verified"
    end

    for plugin_name, expected_fields in pairs(expected_plaintext_map) do
        if not decrypted.plugins or not decrypted.plugins[plugin_name] then
            return false, "plugin [" .. plugin_name .. "] not found in decrypted data"
        end

        local actual_conf = decrypted.plugins[plugin_name]
        for field_name, expected_value in pairs(expected_fields) do
            if actual_conf[field_name] ~= expected_value then
                return false, "field [" .. plugin_name .. "." .. field_name
                              .. "] mismatch: expected [" .. tostring(expected_value)
                              .. "] got [" .. tostring(actual_conf[field_name]) .. "]"
            end
        end
    end

    return true, "old encrypted data is backward compatible"
end


function _M.verify_patch_no_double_encrypt(id, patch_conf, sub_path)
    if not plugin_mod.enable_gde() then
        return true, "data_encryption is disabled, double-encrypt check skipped"
    end

    local key = "/consumers/" .. id
    local res_old, err = core.etcd.get(key)
    if not res_old then
        return false, "failed to get consumer [" .. key .. "]: " .. (err or "unknown")
    end

    if res_old.status ~= 200 then
        return false, "consumer [" .. key .. "] not found, status: "
                      .. res_old.status
    end

    local old_value = res_old.body.node.value
    local old_encrypted_snapshot = {}
    if old_value.plugins then
        for name, conf in pairs(old_value.plugins) do
            old_encrypted_snapshot[name] = core.json.encode(conf)
        end
    end

    local decrypted_old = tbl_deepcopy(old_value)
    decrypt_all_plugin_confs(decrypted_old.plugins, core.schema.TYPE_CONSUMER)

    local merged
    if sub_path and sub_path ~= "" then
        local code, merge_err, node_val = core.table.patch(decrypted_old, sub_path,
                                                            patch_conf)
        if code then
            return false, "patch failed: " .. merge_err
        end
        merged = node_val
    else
        merged = core.table.merge(decrypted_old, patch_conf)
    end

    if not merged.plugins then
        return true, "no plugins after merge, double-encrypt check passed"
    end

    plugins_encrypt_conf(merged.plugins, core.schema.TYPE_CONSUMER)

    for name, conf in pairs(merged.plugins) do
        if old_encrypted_snapshot[name] then
            local was_patched = false
            if not sub_path or sub_path == "" then
                if patch_conf and patch_conf.plugins and patch_conf.plugins[name] then
                    was_patched = true
                end
            else
                if sub_path:find("plugins/" .. name) then
                    was_patched = true
                end
            end

            if not was_patched then
                local decrypt_check = tbl_deepcopy(conf)
                plugins_decrypt_conf(name, decrypt_check, core.schema.TYPE_CONSUMER)

                local old_decrypt_check = core.json.decode(old_encrypted_snapshot[name])
                plugins_decrypt_conf(name, old_decrypt_check, core.schema.TYPE_CONSUMER)

                local check_json = core.json.encode(decrypt_check)
                local old_check_json = core.json.encode(old_decrypt_check)

                if check_json ~= old_check_json then
                    return false, "double-encryption detected for plugin ["
                                  .. name .. "]: decrypted values differ after "
                                  .. "re-encryption. This indicates the field was "
                                  .. "encrypted twice."
                end
            end
        end
    end

    return true, "no double-encryption detected"
end


function _M.verify_schema_evolution_compatible(new_check_conf, old_sample_confs)
    if not old_sample_confs or #old_sample_confs == 0 then
        return true, "no sample configurations provided"
    end

    for i, sample in ipairs(old_sample_confs) do
        local conf_copy = tbl_deepcopy(sample)
        local ok, err = new_check_conf(sample.username, conf_copy, true,
                                        core.schema.consumer)
        if not ok then
            return false, "schema evolution broke backward compatibility for "
                          .. "sample [" .. i .. "]: " .. (err and err.error_msg or "unknown")
        end
    end

    return true, "schema evolution is backward compatible"
end


function _M.run_gate_check(opts)
    opts = opts or {}
    local results = {}
    local all_passed = true

    if opts.verify_roundtrip then
        local ok, msg = _M.verify_encrypt_decrypt_roundtrip(
            opts.verify_roundtrip.plugins_conf,
            opts.verify_roundtrip.schema_type
        )
        results.roundtrip = { passed = ok, message = msg }
        if not ok then all_passed = false end
    end

    if opts.verify_old_data then
        local ok, msg = _M.verify_old_data_compatible(
            opts.verify_old_data.old_etcd_value,
            opts.verify_old_data.expected_plaintext_map,
            opts.verify_old_data.schema_type
        )
        results.old_data_compat = { passed = ok, message = msg }
        if not ok then all_passed = false end
    end

    if opts.verify_patch then
        local ok, msg = _M.verify_patch_no_double_encrypt(
            opts.verify_patch.id,
            opts.verify_patch.patch_conf,
            opts.verify_patch.sub_path
        )
        results.patch_no_double_encrypt = { passed = ok, message = msg }
        if not ok then all_passed = false end
    end

    if opts.verify_schema then
        local ok, msg = _M.verify_schema_evolution_compatible(
            opts.verify_schema.new_check_conf,
            opts.verify_schema.old_sample_confs
        )
        results.schema_evolution = { passed = ok, message = msg }
        if not ok then all_passed = false end
    end

    results.all_passed = all_passed
    return results
end


return _M
