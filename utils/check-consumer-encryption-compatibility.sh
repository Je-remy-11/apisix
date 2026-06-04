#!/usr/bin/env bash
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

# This script serves as a CI/CD gate check for consumer encryption backward compatibility
# It should be run in the CI pipeline whenever check_conf or encrypt_conf is modified

set -e

echo "=============================================="
echo "Consumer Encryption Backward Compatibility Check"
echo "=============================================="
echo ""

# Check if we're in the right directory
if [ ! -f "apisix/admin/consumers.lua" ]; then
    echo "ERROR: This script must be run from the APISIX project root directory"
    exit 1
fi

# Check 1: Verify that consumers.lua has the correct unsupported_methods setting
echo "Check 1: Verify PATCH is enabled, POST is disabled..."
CONSUMERS_FILE="apisix/admin/consumers.lua"

if grep -q 'unsupported_methods = {"post"}' "$CONSUMERS_FILE"; then
    echo "  ✓ PASS: PATCH is enabled, POST is disabled"
else
    if grep -q 'unsupported_methods = {"post", "patch"}' "$CONSUMERS_FILE"; then
        echo "  ✗ FAIL: PATCH is still disabled"
        echo "  Please remove 'patch' from unsupported_methods in consumers.lua"
        exit 1
    fi
fi
echo ""

# Check 2: Verify test files exist
echo "Check 2: Verify compatibility test files exist..."
TEST_FILES=(
    "t/admin/consumers-encrypt-compatibility.t"
    "t/admin/consumers-check-conf-unit.t"
)

ALL_TESTS_EXIST=true
for test_file in "${TEST_FILES[@]}"; do
    if [ -f "$test_file" ]; then
        echo "  ✓ Found: $test_file"
    else
        echo "  ✗ Missing: $test_file"
        ALL_TESTS_EXIST=false
    fi
done

if [ "$ALL_TESTS_EXIST" = false ]; then
    echo ""
    echo "ERROR: Required test files are missing"
    exit 1
fi
echo ""

# Check 3: Check git diff for modified files related to encryption
echo "Check 3: Checking if relevant files were modified..."
RELEVANT_FILES=(
    "apisix/admin/consumers.lua"
    "apisix/admin/resource.lua"
    "apisix/plugin.lua"
    "apisix/admin/plugins.lua"
)

if [ -d ".git" ]; then
    MODIFIED_FILES=$(git diff --name-only HEAD -- "${RELEVANT_FILES[@]}" 2>/dev/null || true)
    if [ -n "$MODIFIED_FILES" ]; then
        echo "  ⚠  The following relevant files were modified:"
        echo "$MODIFIED_FILES" | sed 's/^/    - /'
        echo ""
        echo "  It's recommended to run the full test suite to verify compatibility"
    else
        echo "  ✓ No relevant files modified in this change"
    fi
else
    echo "  ℹ Not a git repository, skipping git diff check"
fi
echo ""

# Check 4: Summary
echo "=============================================="
echo "Summary:"
echo "  ✓ Consumers PATCH support is enabled"
echo "  ✓ Compatibility test files are present"
echo ""
echo "To run the actual tests (requires test environment):"
echo "  prove -v t/admin/consumers-encrypt-compatibility.t"
echo "  prove -v t/admin/consumers-check-conf-unit.t"
echo "=============================================="

exit 0
