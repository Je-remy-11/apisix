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


local _M = {}


local originals = {}


function _M.mock_get(mock_fn)
    if not originals.get then
        originals.get = core.etcd.get
    end
    core.etcd.get = mock_fn
end


function _M.mock_get_success(key)
    _M.mock_get(function(ekey)
        ngx.log(ngx.INFO, "mock etcd.get success for key: ", ekey)
        return {status = 200}, nil
    end)
end


function _M.mock_get_not_found(key)
    _M.mock_get(function(ekey)
        ngx.log(ngx.INFO, "mock etcd.get not_found for key: ", ekey)
        return {status = 404}, nil
    end)
end


function _M.mock_get_error(key, err_msg)
    err_msg = err_msg or "connection refused"
    _M.mock_get(function(ekey)
        ngx.log(ngx.INFO, "mock etcd.get error for key: ", ekey)
        return nil, err_msg
    end)
end


function _M.mock_get_with_recorder()
    local calls = {}
    _M.mock_get(function(ekey)
        ngx.log(ngx.INFO, "mock etcd.get recorder for key: ", ekey)
        table.insert(calls, ekey)
        return {status = 200}, nil
    end)
    return calls
end


function _M.restore()
    if originals.get then
        core.etcd.get = originals.get
        originals.get = nil
    end
end


function _M.mock_set(mock_fn)
    if not originals.set then
        originals.set = core.etcd.set
    end
    core.etcd.set = mock_fn
end


function _M.restore_all()
    if originals.get then
        core.etcd.get = originals.get
        originals.get = nil
    end
    if originals.set then
        core.etcd.set = originals.set
        originals.set = nil
    end
end


return _M