#!/bin/bash
# Test network.sh functionality
# Tests domain resolution, IP parsing, iptables rule generation, slirp4netns detection

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Source the network module directly for unit testing
source "$CAGE_DIR/src/network.sh"

# Set up test mode
dry_run=true
verbose=false

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "=== Testing network.sh ==="
echo ""

# ============================================================================
echo "=== Testing parse_ip_port() ==="

echo "Test 1: Parse IP without port"
result=$(parse_ip_port "192.168.1.1")
expected="192.168.1.1|"
if [ "$result" = "$expected" ]; then
    pass "IP without port parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo "Test 2: Parse IP with single port"
result=$(parse_ip_port "192.168.1.1:443")
expected="192.168.1.1|443"
if [ "$result" = "$expected" ]; then
    pass "IP with single port parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo "Test 3: Parse IP with multiple ports"
result=$(parse_ip_port "192.168.1.1:80,443,8080")
expected="192.168.1.1|80,443,8080"
if [ "$result" = "$expected" ]; then
    pass "IP with multiple ports parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo "Test 4: Parse domain without port"
result=$(parse_ip_port "github.com")
expected="github.com|"
if [ "$result" = "$expected" ]; then
    pass "Domain without port parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo "Test 5: Parse domain with port"
result=$(parse_ip_port "github.com:443")
expected="github.com|443"
if [ "$result" = "$expected" ]; then
    pass "Domain with port parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo "Test 6: Parse network CIDR"
result=$(parse_ip_port "10.0.0.0/8")
expected="10.0.0.0/8|"
if [ "$result" = "$expected" ]; then
    pass "Network CIDR parsed correctly"
else
    fail "Expected '$expected', got '$result'"
fi

echo ""

# ============================================================================
echo "=== Testing resolve_domain() ==="

echo "Test 7: Resolve localhost"
result=$(resolve_domain "localhost")
if echo "$result" | grep -qE "^(127\.0\.0\.1|::1)$"; then
    pass "localhost resolves to loopback"
else
    fail "localhost should resolve to 127.0.0.1 or ::1, got '$result'"
fi

echo "Test 8: Invalid domain returns empty"
result=$(resolve_domain "this.domain.definitely.does.not.exist.invalid")
if [ -z "$result" ]; then
    pass "Invalid domain returns empty"
else
    fail "Invalid domain should return empty, got '$result'"
fi

echo ""

# ============================================================================
echo "=== Testing add_iptables_rule() (dry-run) ==="

echo "Test 9: Rule without port"
output=$(add_iptables_rule "ACCEPT" "192.168.1.1" "" "")
expected="[dry-run] iptables -A OUTPUT -d 192.168.1.1 -j ACCEPT"
if [ "$output" = "$expected" ]; then
    pass "Rule without port generated correctly"
else
    fail "Expected '$expected', got '$output'"
fi

echo "Test 10: Rule with single port"
output=$(add_iptables_rule "ACCEPT" "192.168.1.1" "443" "")
if echo "$output" | grep -q "\-\-dport 443"; then
    pass "Rule with single port includes --dport"
else
    fail "Rule should include --dport 443, got '$output'"
fi

echo "Test 11: Rule with multiple ports uses multiport"
output=$(add_iptables_rule "ACCEPT" "192.168.1.1" "80,443" "")
if echo "$output" | grep -q "multiport.*--dports 80,443"; then
    pass "Multiple ports use multiport module"
else
    fail "Multiple ports should use multiport, got '$output'"
fi

echo "Test 12: Insert mode uses -I flag"
output=$(add_iptables_rule "ACCEPT" "192.168.1.1" "" "insert")
if echo "$output" | grep -q "iptables -I OUTPUT"; then
    pass "Insert mode uses -I flag"
else
    fail "Insert mode should use -I flag, got '$output'"
fi

echo "Test 13: DROP action works"
output=$(add_iptables_rule "DROP" "10.0.0.0/8" "" "")
if echo "$output" | grep -q "\-j DROP"; then
    pass "DROP action generated correctly"
else
    fail "DROP action should be in output, got '$output'"
fi

echo "Test 13b: 127.0.0.1 is translated to 10.0.2.2 (slirp4netns host loopback)"
output=$(add_iptables_rule "ACCEPT" "127.0.0.1" "8080" "")
if echo "$output" | grep -q "10.0.2.2"; then
    pass "127.0.0.1 translated to 10.0.2.2"
else
    fail "127.0.0.1 should be translated to 10.0.2.2, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Testing setup_base_iptables() (dry-run) ==="

echo "Test 14: Base rules set default policies"
output=$(setup_base_iptables)
if echo "$output" | grep -q "iptables -P INPUT DROP" && \
   echo "$output" | grep -q "iptables -P OUTPUT DROP" && \
   echo "$output" | grep -q "iptables -P FORWARD DROP"; then
    pass "Base rules set DROP policies"
else
    fail "Base rules should set DROP policies, got '$output'"
fi

echo "Test 15: Base rules allow loopback"
if echo "$output" | grep -q "\-A INPUT -i lo -j ACCEPT" && \
   echo "$output" | grep -q "\-A OUTPUT -o lo -j ACCEPT"; then
    pass "Base rules allow loopback"
else
    fail "Base rules should allow loopback, got '$output'"
fi

echo "Test 16: Base rules allow established connections"
if echo "$output" | grep -q "ESTABLISHED,RELATED"; then
    pass "Base rules allow established connections"
else
    fail "Base rules should allow established, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Testing setup_dns_rules() (dry-run) ==="

echo "Test 17: DNS rules use slirp4netns resolver"
output=$(setup_dns_rules)
if echo "$output" | grep -q "10.0.2.3.*--dport 53"; then
    pass "DNS rules target slirp4netns resolver (10.0.2.3)"
else
    fail "DNS rules should target 10.0.2.3:53, got '$output'"
fi

echo "Test 18: DNS rules allow both UDP and TCP"
if echo "$output" | grep -q "\-p udp" && echo "$output" | grep -q "\-p tcp"; then
    pass "DNS rules allow UDP and TCP"
else
    fail "DNS rules should allow both UDP and TCP, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Testing add_iptables_rules_batch() (dry-run) ==="

echo "Test 19: Batch with pipe-separated IPs"
output=$(add_iptables_rules_batch "ACCEPT" "ips" "192.168.1.1:443|10.0.0.1:80")
if echo "$output" | grep -q "192.168.1.1" && echo "$output" | grep -q "10.0.0.1"; then
    pass "Batch processes multiple IPs"
else
    fail "Batch should process all IPs, got '$output'"
fi

echo "Test 20: Batch with empty config returns silently"
output=$(add_iptables_rules_batch "ACCEPT" "ips" "")
if [ -z "$output" ]; then
    pass "Empty config produces no output"
else
    fail "Empty config should produce no output, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Testing setup_namespace_iptables() (dry-run) ==="

echo "Test 21: Disabled mode skips all rules"
output=$(setup_namespace_iptables "disabled" "" "" "" "" "" "")
if [ -z "$output" ]; then
    pass "Disabled mode produces no output"
else
    fail "Disabled mode should produce no output, got '$output'"
fi

echo "Test 22: Allowlist mode sets up base + DNS + allow rules"
output=$(setup_namespace_iptables "allowlist" "192.168.1.1:443" "" "" "" "" "")
if echo "$output" | grep -q "iptables -P INPUT DROP" && \
   echo "$output" | grep -q "10.0.2.3.*53" && \
   echo "$output" | grep -q "192.168.1.1"; then
    pass "Allowlist mode sets up correct rules"
else
    fail "Allowlist mode should set base+DNS+allow rules, got '$output'"
fi

echo "Test 23: Blocklist mode ends with ACCEPT catch-all"
output=$(setup_namespace_iptables "blocklist" "" "" "" "10.0.0.1" "" "")
if echo "$output" | grep -q "iptables -A OUTPUT -j ACCEPT"; then
    pass "Blocklist mode ends with ACCEPT catch-all"
else
    fail "Blocklist mode should end with ACCEPT, got '$output'"
fi

echo "Test 23b: Blocklist mode uses REJECT (not DROP) for fast failure"
if echo "$output" | grep -q "\-j REJECT"; then
    pass "Blocklist uses REJECT for blocked destinations"
else
    fail "Blocklist should use REJECT not DROP, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Testing dependency checks ==="

echo "Test 24: check_slirp4netns function exists"
if type check_slirp4netns >/dev/null 2>&1; then
    pass "check_slirp4netns function defined"
else
    fail "check_slirp4netns function should be defined"
fi

echo "Test 25: check_iptables function exists"
if type check_iptables >/dev/null 2>&1; then
    pass "check_iptables function defined"
else
    fail "check_iptables function should be defined"
fi

echo "Test 26: run_with_network_namespace function exists"
if type run_with_network_namespace >/dev/null 2>&1; then
    pass "run_with_network_namespace function defined"
else
    fail "run_with_network_namespace function should be defined"
fi

echo "Test 26b: check_userns function exists"
if type check_userns >/dev/null 2>&1; then
    pass "check_userns function defined"
else
    fail "check_userns function should be defined"
fi

echo ""

# ============================================================================
echo "=== Testing run_with_network_namespace() (dry-run) ==="

echo "Test 27: Disabled mode runs command directly"
output=$(run_with_network_namespace "disabled" "" "" "" "" "" "" -- echo "hello")
if [ "$output" = "hello" ]; then
    pass "Disabled mode runs command directly"
else
    fail "Disabled mode should run command directly, got '$output'"
fi

echo "Test 28: Enabled mode shows unshare and slirp4netns"
output=$(run_with_network_namespace "allowlist" "" "" "" "" "" "" -- echo "test" 2>&1)
if echo "$output" | grep -q "unshare" && echo "$output" | grep -q "slirp4netns"; then
    pass "Enabled mode shows unshare and slirp4netns commands"
else
    fail "Enabled mode should show unshare and slirp4netns, got '$output'"
fi

echo ""

# ============================================================================
echo "=== Summary ==="
echo ""
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "=== All network tests passed! ==="
    exit 0
else
    echo "=== Some tests failed ==="
    exit 1
fi
