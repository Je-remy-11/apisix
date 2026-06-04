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

local _M = {}

-- Mock 1: Successful etcd.get
function _M.mock_etcd_get_success(key)
    return {
        status = 200,
        body = {
            node = {
                value = {
                    id = key:match("/consumer_groups/(.+)") or "test_group",
                    plugins = {}
                }
            }
        }
    }, nil
end

-- Mock 2: Key not found
function _M.mock_etcd_get_not_found(key)
    return {
        status = 404
    }, nil
end

-- Mock 3: Etcd error
function _M.mock_etcd_get_error(key)
    return nil, "etcd connection failed: " .. key
end

-- Mock 4: Custom status code
function _M.mock_etcd_get_custom_status(status_code)
    return function(key)
        return {
            status = status_code
        }, nil
    end
end

-- Mock 5: Track calls
function _M.mock_etcd_get_track()
    local calls = {}
    local mock_fn = function(key)
        table.insert(calls, key)
        return {status = 200}, nil
    end
    return mock_fn, calls
end

-- Helper: Apply mock to package.loaded
function _M.apply_mock(mock_get_fn)
    local original_core = package.loaded["apisix.core"]
    
    -- Create a mock core
    local mock_core = {
        schema = original_core and original_core.schema or {
            check = function() return true, nil end,
            TYPE_CONSUMER = "consumer",
            consumer = {}
        },
        etcd = {
            get = mock_get_fn,
            set = function() return {status = 200}, nil end,
            delete = function() return {status = 200}, nil end
        }
    }
    
    -- Save original and replace
    package.loaded["apisix.core"] = mock_core
    return original_core
end

-- Helper: Restore original core
function _M.restore_core(original_core)
    package.loaded["apisix.core"] = original_core
end

return _M
