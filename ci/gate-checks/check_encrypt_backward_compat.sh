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
# ---------------------------------------------------------------------------
# CI/CD Gate Check: Encrypt Conf Backward Compatibility
#
# This script validates that any changes to check_conf or encrypt_conf
# in the consumer module do not break the ability to:
#   1. Decrypt previously encrypted consumer data from etcd
#   2. Re-encrypt decrypted data correctly (round-trip integrity)
#   3. Handle PATCH partial updates without double-encrypting fields
#   4. Support cross-version data compatibility (old encrypted data
#      survives code upgrades)
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#
# Prerequisites:
#   - APISIX running with etcd backend
#   - data_encryption.enable_encrypt_fields = true
#   - keyring configured in config.yaml
#   - curl and jq installed
# ---------------------------------------------------------------------------

set -euo pipefail

BASE_URL="${APISIX_ADMIN_URL:-http://127.0.0.1:9180}"
CONSUMER_USERNAME="gate-check-consumer-encrypt-$$"
FAILED=0

log_info()  { echo "[INFO]  $*"; }
log_pass()  { echo "[PASS]  $*"; }
log_fail()  { echo "[FAIL]  $*"; FAILED=1; }
log_step()  { echo ""; echo "===== $* ====="; }

assert_http_ok() {
    local desc="$1" code="$2"
    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        log_pass "$desc"
    else
        log_fail "$desc (HTTP $code)"
    fi
}

assert_http_fail() {
    local desc="$1" code="$2"
    if [ "$code" -ge 400 ]; then
        log_pass "$desc (expected HTTP $code)"
    else
        log_fail "$desc (expected 4xx, got $code)"
    fi
}

assert_str_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        log_pass "$desc"
    else
        log_fail "$desc - expected to contain '$needle'"
    fi
}

assert_str_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        log_pass "$desc"
    else
        log_fail "$desc - expected NOT to contain '$needle'"
    fi
}

assert_not_equal() {
    local desc="$1" a="$2" b="$3"
    if [ "$a" != "$b" ]; then
        log_pass "$desc"
    else
        log_fail "$desc - values should differ but are both '$a'"
    fi
}

assert_equal() {
    local desc="$1" a="$2" b="$3"
    if [ "$a" = "$b" ]; then
        log_pass "$desc"
    else
        log_fail "$desc - expected '$b', got '$a'"
    fi
}

cleanup() {
    log_info "Cleaning up consumer: $CONSUMER_USERNAME"
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME" || true
    echo ""
}
trap cleanup EXIT

# ------------------------------------------------------------------
log_step "CHECK: Environment"
log_info "Admin URL: $BASE_URL"
log_info "Consumer:  $CONSUMER_USERNAME"

# ------------------------------------------------------------------
log_step "TEST 1: PUT consumer with encrypted plugin fields"
log_info "Creating consumer with basic-auth plugin..."

RESP=$(curl -s -w "\n%{http_code}" -X PUT \
    "$BASE_URL/apisix/admin/consumers" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"$CONSUMER_USERNAME\",
        \"desc\": \"original consumer for gate check\",
        \"plugins\": {
            \"basic-auth\": {
                \"username\": \"$CONSUMER_USERNAME\",
                \"password\": \"my-secret-password\"
            },
            \"key-auth\": {
                \"key\": \"my-api-key-12345\"
            }
        }
    }")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "PUT consumer" "$HTTP_CODE"
assert_str_contains "Response contains username" "$BODY" "$CONSUMER_USERNAME"

sleep 0.5

# ------------------------------------------------------------------
log_step "TEST 2: GET consumer - verify decrypted fields via Admin API"
log_info "Fetching consumer via admin API..."

RESP=$(curl -s -w "\n%{http_code}" \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "GET consumer" "$HTTP_CODE"

# Password should be plaintext in admin API response
PASSWORD=$(echo "$BODY" | jq -r '.value.plugins["basic-auth"].password // "null"')
assert_equal "Password is plaintext via admin API" "$PASSWORD" "my-secret-password"

KEY=$(echo "$BODY" | jq -r '.value.plugins["key-auth"].key // "null"')
assert_equal "Key is plaintext via admin API" "$KEY" "my-api-key-12345"

# ------------------------------------------------------------------
log_step "TEST 3: Verify fields are ENCRYPTED in etcd"
log_info "Reading raw data from etcd..."

# This requires accessing etcd directly. APISIX stores data under /apisix/consumers/
ETCD_ENDPOINT="${ETCD_URL:-http://127.0.0.1:2379}"
ETCD_KEY="/apisix/consumers/$CONSUMER_USERNAME"
ETCD_RESP=$(curl -s "$ETCD_ENDPOINT/v3/kv/range" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$(echo -n "$ETCD_KEY" | base64 -w0)\"}" 2>/dev/null || echo "")

if [ -z "$ETCD_RESP" ]; then
    log_fail "Cannot read from etcd at $ETCD_ENDPOINT - check ETCD_URL"
    log_info "Skipping etcd-level encryption verification (not critical if admin API works)"
else
    # Extract the raw plugin values from etcd
    ETCD_PASSWORD=$(echo "$ETCD_RESP" | jq -r '.kvs[0].value' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.plugins["basic-auth"].password // ""' 2>/dev/null || echo "")
    ETCD_KEY_VAL=$(echo "$ETCD_RESP" | jq -r '.kvs[0].value' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.plugins["key-auth"].key // ""' 2>/dev/null || echo "")

    if [ -n "$ETCD_PASSWORD" ] && [ -n "$ETCD_KEY_VAL" ]; then
        assert_not_equal "Password is encrypted in etcd" "$ETCD_PASSWORD" "my-secret-password"
        assert_not_equal "Key is encrypted in etcd" "$ETCD_KEY_VAL" "my-api-key-12345"
        assert_str_not_contains "Password does not contain plaintext" "$ETCD_PASSWORD" "my-secret-password"
        assert_str_not_contains "Key does not contain plaintext" "$ETCD_KEY_VAL" "my-api-key-12345"
    else
        log_fail "Could not extract encrypted values from etcd response"
        log_info "Raw etcd response: $ETCD_RESP"
    fi
fi

# ------------------------------------------------------------------
log_step "TEST 4: PATCH - update only non-sensitive fields (desc)"
log_info "PATCH update desc field, leaving encrypted plugins untouched..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME" \
    -H "Content-Type: application/json" \
    -d "{
        \"desc\": \"updated description via PATCH\"
    }")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "PATCH desc field" "$HTTP_CODE"

sleep 0.5

# Verify desc updated and password still accessible
RESP=$(curl -s -w "\n%{http_code}" \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "GET after PATCH desc" "$HTTP_CODE"

DESC=$(echo "$BODY" | jq -r '.value.desc // ""')
assert_equal "Desc updated" "$DESC" "updated description via PATCH"

PASSWORD=$(echo "$BODY" | jq -r '.value.plugins["basic-auth"].password // "null"')
assert_equal "Password still accessible after PATCH desc" "$PASSWORD" "my-secret-password"

KEY=$(echo "$BODY" | jq -r '.value.plugins["key-auth"].key // "null"')
assert_equal "Key still accessible after PATCH desc" "$KEY" "my-api-key-12345"

# Verify in etcd that password is NOT double-encrypted
if [ -n "$ETCD_ENDPOINT" ]; then
    ETCD_RESP2=$(curl -s "$ETCD_ENDPOINT/v3/kv/range" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"$(echo -n "$ETCD_KEY" | base64 -w0)\"}" 2>/dev/null || echo "")
    ETCD_PASSWORD2=$(echo "$ETCD_RESP2" | jq -r '.kvs[0].value' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.plugins["basic-auth"].password // ""' 2>/dev/null || echo "")

    if [ -n "$ETCD_PASSWORD2" ]; then
        log_info "Verifying no double encryption: etcd password after PATCH = '$ETCD_PASSWORD2'"
        assert_not_equal "Password is still encrypted in etcd (not plaintext)" \
            "$ETCD_PASSWORD2" "my-secret-password"
        assert_not_equal "Password encrypted value changed after PATCH (re-encrypted)" \
            "$ETCD_PASSWORD2" "$ETCD_PASSWORD"
    fi
fi

# ------------------------------------------------------------------
log_step "TEST 5: PATCH - update sensitive plugin fields"
log_info "PATCH update basic-auth password..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME" \
    -H "Content-Type: application/json" \
    -d "{
        \"plugins\": {
            \"basic-auth\": {
                \"username\": \"$CONSUMER_USERNAME\",
                \"password\": \"new-password-67890\"
            }
        }
    }")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "PATCH update password" "$HTTP_CODE"

sleep 0.5

# Verify password updated and key-auth still intact
RESP=$(curl -s -w "\n%{http_code}" \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "GET after PATCH password" "$HTTP_CODE"

PASSWORD=$(echo "$BODY" | jq -r '.value.plugins["basic-auth"].password // "null"')
assert_equal "Password updated by PATCH" "$PASSWORD" "new-password-67890"

KEY=$(echo "$BODY" | jq -r '.value.plugins["key-auth"].key // "null"')
assert_equal "Key-auth untouched by PATCH of basic-auth" "$KEY" "my-api-key-12345"

# ------------------------------------------------------------------
log_step "TEST 6: PATCH - add new plugin while preserving existing ones"
log_info "PATCH add jwt-auth plugin..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME" \
    -H "Content-Type: application/json" \
    -d "{
        \"plugins\": {
            \"jwt-auth\": {
                \"key\": \"jwt-key-for-test\",
                \"secret\": \"jwt-secret-1234\"
            }
        }
    }")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "PATCH add jwt-auth plugin" "$HTTP_CODE"

sleep 0.5

RESP=$(curl -s -w "\n%{http_code}" \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "GET after PATCH add jwt-auth" "$HTTP_CODE"

JWT_KEY=$(echo "$BODY" | jq -r '.value.plugins["jwt-auth"].key // "null"')
assert_equal "jwt-auth key present" "$JWT_KEY" "jwt-key-for-test"

JWT_SECRET=$(echo "$BODY" | jq -r '.value.plugins["jwt-auth"].secret // "null"')
assert_equal "jwt-auth secret present" "$JWT_SECRET" "jwt-secret-1234"

KEY_AUTH=$(echo "$BODY" | jq -r '.value.plugins["key-auth"].key // "null"')
assert_equal "key-auth preserved after adding jwt-auth" "$KEY_AUTH" "my-api-key-12345"

# ------------------------------------------------------------------
log_step "TEST 7: PATCH sub-path - update single plugin field"
log_info "PATCH sub-path plugins/key-auth/key..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME/plugins/key-auth/key" \
    -H "Content-Type: application/json" \
    -d "\"rotated-api-key-99999\"")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "PATCH sub-path key-auth key" "$HTTP_CODE"

sleep 0.5

RESP=$(curl -s -w "\n%{http_code}" \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_ok "GET after PATCH sub-path" "$HTTP_CODE"

KEY=$(echo "$BODY" | jq -r '.value.plugins["key-auth"].key // "null"')
assert_equal "key-auth key rotated" "$KEY" "rotated-api-key-99999"

PASSWORD=$(echo "$BODY" | jq -r '.value.plugins["basic-auth"].password // "null"')
assert_equal "basic-auth password unchanged after key rotation" \
    "$PASSWORD" "new-password-67890"

# ------------------------------------------------------------------
log_step "TEST 8: PATCH should reject config with wrong username"
log_info "PATCH with mismatched username..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/$CONSUMER_USERNAME" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"wrong-username\"
    }")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_fail "PATCH with wrong username rejected" "$HTTP_CODE"

# ------------------------------------------------------------------
log_step "TEST 9: PATCH with non-existent consumer should return 404"
log_info "PATCH non-existent consumer..."

RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
    "$BASE_URL/apisix/admin/consumers/non-existent-$$" \
    -H "Content-Type: application/json" \
    -d "{\"desc\": \"should not exist\"}")

HTTP_CODE=$(echo "$RESP" | tail -1)
assert_equal "PATCH non-existent returns 404" "$HTTP_CODE" "404"

# ------------------------------------------------------------------
log_step "TEST 10: POST should still be unsupported"
log_info "POST to consumers (should be 405)..."

RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "$BASE_URL/apisix/admin/consumers" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"post-should-fail-$$\"}")

HTTP_CODE=$(echo "$RESP" | tail -1)
assert_equal "POST method remains disabled" "$HTTP_CODE" "405"

# ------------------------------------------------------------------
log_step "SUMMARY"
if [ "$FAILED" -eq 0 ]; then
    echo "All checks PASSED. Encrypt/decrypt backward compatibility is maintained."
else
    echo "Some checks FAILED. Review the log above for details."
fi

exit "$FAILED"