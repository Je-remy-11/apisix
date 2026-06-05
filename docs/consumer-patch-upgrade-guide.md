# Consumer PATCH 支持升级指南

## 概述

本升级为消费者模块添加了 PATCH 方法支持，同时保持了加密配置的向后兼容性。

## 修改文件

### 1. `apisix/admin/consumers.lua`

**变更**: 从 `unsupported_methods` 中移除了 `"patch"`，保留 `"post"` 仍为禁用状态。

```lua
-- 之前
unsupported_methods = {"post", "patch"}

-- 现在
unsupported_methods = {"post"}
```

## 新增文件

### 2. `t/admin/consumers-encrypt-compatibility.t`

完整的集成测试套件，验证：
- 加密配置的完整 PUT 流程
- PATCH 部分更新时加密字段的安全性
- 旧加密数据的向后兼容性
- 多次 PATCH 操作后的一致性

### 3. `t/admin/consumers-check-conf-unit.t`

单元测试文件，直接测试：
- `check_conf` 函数的验证逻辑
- `encrypt_conf` 的加密解密往返
- 向后兼容性场景
- 幂等性保证

### 4. `utils/check-consumer-encryption-compatibility.sh`

CI/CD 门禁检查脚本，用于：
- 验证配置文件的正确性
- 检查测试文件完整性
- 在流水线中自动运行检查

## CI/CD 集成建议

### 在 Pull Request 检查中

```yaml
# .github/workflows/consumer-compatibility.yml
name: Consumer Encryption Compatibility Check
on:
  pull_request:
    paths:
      - 'apisix/admin/consumers.lua'
      - 'apisix/admin/resource.lua'
      - 'apisix/plugin.lua'
      - 'apisix/admin/plugins.lua'

jobs:
  compatibility-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run compatibility check
        run: |
          chmod +x utils/check-consumer-encryption-compatibility.sh
          ./utils/check-consumer-encryption-compatibility.sh
      - name: Run tests
        run: |
          # Set up test environment and run
          prove -v t/admin/consumers-encrypt-compatibility.t
          prove -v t/admin/consumers-check-conf-unit.t
```

## 测试覆盖的场景

1. **完整 PUT 创建** - 验证加密正常工作
2. **PATCH 更新非加密字段** - 验证加密字段保持不变
3. **PATCH 更新加密字段** - 验证新值被正确加密
4. **PATCH 添加新插件** - 验证新旧插件共存
5. **旧加密数据读取** - 验证向后兼容性
6. **子路径 PATCH** - 验证细粒度更新
7. **多次 PATCH 往返** - 验证数据一致性

## 向后兼容性保证

- ✓ 使用旧版本加密的数据仍可正常解密
- ✓ PATCH 不会重新加密已加密的字段（幂等性）
- ✓ POST 方法仍保持禁用（与之前行为一致）
- ✓ 完整的 PUT 操作行为保持不变

## 验证步骤

升级后，请运行以下命令验证安装：

```bash
# 运行兼容性检查脚本
./utils/check-consumer-encryption-compatibility.sh

# 运行测试（需要测试环境）
prove -v t/admin/consumers-encrypt-compatibility.t
prove -v t/admin/consumers-check-conf-unit.t
```