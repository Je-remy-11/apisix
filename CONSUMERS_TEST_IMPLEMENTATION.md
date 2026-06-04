# Consumers 模块测试方案完整实现

## 问题回答

### 1. 单元测试和集成测试的边界设计

#### 单元测试边界
- **隔离范围**: 只测试 `consumers.lua` 模块的逻辑
- **Mock 依赖**:
  - `core.schema.check` - 模拟 schema 验证
  - `plugins.check_schema` - 模拟插件验证
  - `core.etcd.get` - 模拟 etcd 查询（关键）
- **测试目标**: 验证 `check_conf` 函数在各种场景下的逻辑正确性

#### 集成测试边界
- **依赖范围**: 需要真实的 etcd 服务
- **测试目标**: 验证完整的 CRUD 流程，特别是与 consumer_group 的关联
- **文件位置**: `t/admin/consumers.t`（已增强）

---

### 2. Mock core.etcd.get 的完整实现

#### 三种场景的 Mock 函数

```lua
-- 场景 1: 成功获取 group_id
local function mock_etcd_get_success(key)
    return {
        status = 200,
        body = {
            node = {
                value = {
                    id = key:match("/consumer_groups/(.+)"),
                    plugins = {}
                }
            }
        }
    }, nil
end

-- 场景 2: key 不存在
local function mock_etcd_get_not_found(key)
    return {
        status = 404
    }, nil
end

-- 场景 3: etcd 故障
local function mock_etcd_get_error(key)
    return nil, "etcd connection failed"
end
```

#### 在测试中应用 Mock

```lua
-- 保存原始模块
local original_core = package.loaded["apisix.core"]

-- 应用 mock
package.loaded["apisix.core"] = {
    schema = {
        check = function() return true, nil end,
        TYPE_CONSUMER = "consumer",
        consumer = {}
    },
    etcd = {
        get = mock_etcd_get_success  -- 或其他 mock 函数
    }
}

-- 加载测试模块
require("apisix.admin.consumers")

-- 测试完成后恢复
package.loaded["apisix.core"] = original_core
```

---

## 创建的文件

### 1. 测试方案文档
- **文件**: `CONSUMERS_TEST_PLAN.md`
- **内容**: 详细的测试边界设计和方案说明

### 2. 单元测试文件
- **文件**: `t/admin/test_consumers_unit.t`
- **内容**: 
  - 7 个完整的测试用例
  - 覆盖所有三种 etcd 场景
  - 测试 skip_references_check 选项
  - 测试 username 验证

### 3. Mock 辅助库
- **文件**: `t/lib/mock_etcd.lua`
- **内容**:
  - 预制的 mock 函数
  - 方便的 apply/restore 工具
  - 可追踪调用的 mock

### 4. 增强的集成测试
- **文件**: `t/admin/consumers.t`（已更新）
- **新增测试**:
  - TEST 12: 带有效 group_id 的 consumer 创建
  - TEST 13: 带不存在 group_id 的创建（应失败）
  - TEST 14: 更新 consumer 时添加/修改 group_id

---

## 使用方法

### 运行单元测试
```bash
prove t/admin/test_consumers_unit.t
```

### 运行集成测试
```bash
prove t/admin/consumers.t
```

### 使用 mock 库
```lua
local mock_etcd = require("lib.mock_etcd")

-- 应用成功场景 mock
local original = mock_etcd.apply_mock(mock_etcd.mock_etcd_get_success)

-- ... 执行测试 ...

-- 恢复
mock_etcd.restore_core(original)
```

---

## 测试场景覆盖清单

| 场景 | 单元测试 | 集成测试 |
|------|---------|---------|
| 基础配置验证 | ✓ TEST 1 | ✓ TEST 1 |
| group_id 成功获取 | ✓ TEST 2 | ✓ TEST 12 |
| group_id 不存在 | ✓ TEST 3 | ✓ TEST 13 |
| etcd 故障 | ✓ TEST 4 | - |
| skip_references_check | ✓ TEST 5 | - |
| username 不匹配 | ✓ TEST 6 | - |
| 完整模块 mock | ✓ TEST 7 | - |
| 更新 group_id | - | ✓ TEST 14 |

---

## 关键代码片段

### check_conf 函数逻辑（consumers.lua:23-58）
```lua
local function check_conf(username, conf, need_username, schema, opts)
    opts = opts or {}
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    if username and username ~= conf.username then
        return nil, {error_msg = "wrong username"}
    end

    if conf.plugins then
        ok, err = plugins.check_schema(conf.plugins, core.schema.TYPE_CONSUMER)
        if not ok then
            return nil, {error_msg = "invalid plugins configuration: " .. err}
        end
    end

    if conf.group_id and not opts.skip_references_check then
        local key = "/consumer_groups/" .. conf.group_id
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch consumer group info by "
                            .. "consumer group id [" .. conf.group_id .. "]: "
                            .. err}
        end

        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch consumer group info by "
                            .. "consumer group id [" .. conf.group_id .. "], "
                            .. "response code: " .. res.status}
        end
    end

    return conf.username
end
```

### Mock 追踪调用示例
```lua
local mock_etcd = require("lib.mock_etcd")
local mock_fn, calls = mock_etcd.mock_etcd_get_track()

-- 使用 mock_fn
mock_fn("/consumer_groups/test")

-- 检查调用
assert(#calls == 1)
assert(calls[1] == "/consumer_groups/test")
```
