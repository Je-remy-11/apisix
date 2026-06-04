# Consumers 模块测试方案

## 一、测试边界设计

### 1.1 单元测试边界
- **Scope**: 只测试 consumers.lua 模块的逻辑，不依赖真实 etcd
- **Mock 覆盖**: 
  - core.schema.check
  - plugins.check_schema
  - core.etcd.get
- **测试场景**: 
  - 基础配置验证
  - group_id 验证的三种场景

### 1.2 集成测试边界
- **Scope**: 完整测试 consumers 模块与真实 etcd 的交互
- **依赖**: 需要真实的 etcd 服务
- **测试场景**: 
  - 完整的 CRUD 流程
  - 与 consumer_group 的关联验证

## 二、Mock 实现方案

### 2.1 核心思路
通过 Lua 的 package 机制，在测试前替换 `core.etcd` 模块的 `get` 函数。

### 2.2 Mock 三种场景

#### 场景 1: 成功获取 group_id
```lua
local function mock_etcd_get_success(key)
    return {
        status = 200,
        body = {
            node = {
                value = {
                    id = "bar",
                    plugins = {}
                }
            }
        }
    }, nil
end
```

#### 场景 2: key 不存在
```lua
local function mock_etcd_get_not_found(key)
    return {
        status = 404
    }, nil
end
```

#### 场景 3: etcd 故障
```lua
local function mock_etcd_get_error(key)
    return nil, "etcd connection failed"
end
```

### 2.3 完整的 Mock 函数替换
见下文 `test_consumers_unit.t` 文件。

## 三、测试用例结构

### 3.1 单元测试文件
`t/admin/test_consumers_unit.t`

### 3.2 集成测试增强
在现有 `t/admin/consumers.t` 基础上增加测试用例。

## 四、使用说明

1. 运行单元测试：
   ```bash
   prove t/admin/test_consumers_unit.t
   ```

2. 运行集成测试：
   ```bash
   prove t/admin/consumers.t
   ```
