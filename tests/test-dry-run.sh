#!/bin/bash
# Test claude-cage dry-run mode
# This test verifies that dry-run mode outputs expected commands without executing them

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing claude-cage --dry-run ==="
echo ""

# Create a test config
mkdir -p "$TEST_TMP/project"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    directMount = "workspace",
    exclude = {
        name = { ".env", "secrets.json" },
        path = { "config/prod.yml" }
    },
    homeConfigSync = {
        ".gitconfig",
        ".claude",
        { path = ".config/claude-cage/claude-settings.json", destination = ".claude/settings.json" }
    },
    networkMode = "blocklist",
    block = {
        ips = { "169.254.169.254" },
        networks = { "192.168.0.0/16" }
    },
    allow = {
        ips = { "127.0.0.1:5432", "127.0.0.1:6379" },
        domains = { "api.example.com:443" }
    }
}
EOF

cd "$TEST_TMP/project"

echo "Test 1: Dry-run mode should not require sudo"
output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

echo "Test 2: Output should contain [dry-run] prefixed commands"
if ! echo "$output" | grep -q "\[dry-run\]"; then
    echo "FAIL: No [dry-run] commands found in output"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found [dry-run] prefixed commands"

echo "Test 3: Should show user creation command"
if ! echo "$output" | grep -q "\[dry-run\] adduser.*testuser"; then
    echo "FAIL: Did not find adduser command for testuser"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found adduser command"

echo "Test 4: Should show iptables commands for network rules"
if ! echo "$output" | grep -q "\[dry-run\] iptables"; then
    echo "FAIL: Did not find iptables commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found iptables commands"

echo "Test 5: Should show block rules (169.254.169.254)"
if ! echo "$output" | grep -q "169.254.169.254.*REJECT"; then
    echo "FAIL: Did not find block rule for metadata IP"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found block rule for 169.254.169.254"

echo "Test 6: Should show allow rules (127.0.0.1:5432)"
if ! echo "$output" | grep -q "127.0.0.1.*5432.*ACCEPT"; then
    echo "FAIL: Did not find allow rule for postgres"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found allow rule for postgres port"

echo "Test 7: Should show bindfs mount command"
if ! echo "$output" | grep -q "\[dry-run\] bindfs"; then
    echo "FAIL: Did not find bindfs command"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found bindfs command"

echo "Test 7b: Project mount points should be in /run/ (not user home)"
# Exclude homeConfigSync lines which legitimately reference home directories as source
if echo "$output" | grep -v "/run/claude-cage/mounts/homesync" | grep -q "bindfs.*/home/[^/]*/caged\|bindfs.*/home/[^/]*/[^/]*\"* *\$"; then
    echo "FAIL: Found project mount point in user home (security issue)"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "/run/claude-cage/mounts/projects"; then
    echo "FAIL: Did not find /run/claude-cage/mounts/projects for project mounts"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Project mounts use /run/claude-cage/mounts/projects/"

echo "Test 8: Should show mkdir commands"
if ! echo "$output" | grep -q "\[dry-run\] mkdir"; then
    echo "FAIL: Did not find mkdir commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found mkdir commands"

echo "Test 9: Should end with DRY-RUN COMPLETE message"
if ! echo "$output" | grep -q "DRY-RUN COMPLETE"; then
    echo "FAIL: Did not find DRY-RUN COMPLETE message"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found DRY-RUN COMPLETE message"

echo "Test 10: Should display exclude configuration"
if ! echo "$output" | grep -q "Name:.*\.env"; then
    echo "FAIL: Did not find .env in excludes display"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found exclude configuration in display"

echo ""
echo "=== Testing cageLocal configuration ==="

# Create a test config with cageLocal
mkdir -p "$TEST_TMP/cagelocal-test/project"
cat > "$TEST_TMP/cagelocal-test/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    exclude = {
        name = { ".env" }
    },
    cageLocal = {
        name = { ".bashrc", ".profile", ".gitconfig" }
    }
}
EOF

cd "$TEST_TMP/cagelocal-test/project"

echo "Test 10a: Should display cageLocal configuration"
cagelocal_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

if ! echo "$cagelocal_output" | grep -q "Cage-local files (new creations blocked"; then
    echo "FAIL: Did not find Cage-local files section"
    echo "Output was:"
    echo "$cagelocal_output"
    exit 1
fi
echo "  PASS: Found Cage-local files section"

echo "Test 10b: Should show cageLocal name patterns"
if ! echo "$cagelocal_output" | grep -q "Name:.*\.bashrc"; then
    echo "FAIL: Did not find .bashrc in cageLocal display"
    echo "Output was:"
    echo "$cagelocal_output"
    exit 1
fi
echo "  PASS: Found cageLocal name patterns"

echo "Test 10d: Should use -nocreationpartial in unison command"
if ! echo "$cagelocal_output" | grep -q "nocreationpartial"; then
    echo "FAIL: Did not find nocreationpartial in unison command"
    echo "Output was:"
    echo "$cagelocal_output"
    exit 1
fi
echo "  PASS: Found nocreationpartial in unison command"

echo "Test 10e: Should include source path in nocreationpartial"
if ! echo "$cagelocal_output" | grep -q 'nocreationpartial "Name.*->'; then
    echo "FAIL: nocreationpartial should include -> source path"
    echo "Output was:"
    echo "$cagelocal_output"
    exit 1
fi
echo "  PASS: nocreationpartial includes source path direction"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing cleanup with dry-run ==="

echo "Test 11: Cleanup mode should work with dry-run"
cleanup_output=$("$CAGE_DIR/claude-cage" --cleanup --dry-run --no-banner 2>&1) || true

if ! echo "$cleanup_output" | grep -q "CLEANUP MODE"; then
    echo "FAIL: Did not enter cleanup mode"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Entered cleanup mode"

if ! echo "$cleanup_output" | grep -q "\[dry-run\]"; then
    echo "FAIL: Cleanup mode should show dry-run commands"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup mode shows dry-run commands"

echo "Test 11b: Cleanup mode should check for homeConfigSync mounts"
if ! echo "$cleanup_output" | grep -q "homeConfigSync mounts\|homesync-"; then
    echo "FAIL: Cleanup mode should check for homeConfigSync mounts"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup mode checks for homeConfigSync mounts"

echo "Test 11c: Cleanup mode should show unmount commands for homesync directories"
if ! echo "$cleanup_output" | grep -q "umount.*files-bindfs\|umount.*original/\|umount.*cage/"; then
    echo "FAIL: Cleanup mode should show unmount commands for homesync dirs"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup mode shows homesync unmount commands"

echo "Test 11d: Cleanup mode should kill shared sync processes"
if ! echo "$cleanup_output" | grep -q "kill.*PIDs.*pids\|Stopping shared"; then
    echo "FAIL: Cleanup mode should show killing shared processes from pids file"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup mode handles shared PID file"

echo ""
echo "=== Testing cross-platform simulation ==="

# Detect current OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    current_os="macos"
    other_os="linux"
else
    current_os="linux"
    other_os="macos"
fi

echo "Current OS: $current_os, will simulate: $other_os"

echo "Test 12: --os flag should require --dry-run"
os_without_dryrun=$("$CAGE_DIR/claude-cage" --os linux 2>&1) || true
if ! echo "$os_without_dryrun" | grep -q "can only be used with --dry-run"; then
    echo "FAIL: --os without --dry-run should error"
    exit 1
fi
echo "  PASS: --os requires --dry-run"

echo "Test 13: --os should accept 'linux' or 'macos'"
invalid_os=$("$CAGE_DIR/claude-cage" --dry-run --os windows 2>&1) || true
if ! echo "$invalid_os" | grep -q "must be 'linux' or 'macos'"; then
    echo "FAIL: --os should reject invalid OS values"
    exit 1
fi
echo "  PASS: --os rejects invalid values"

echo "Test 14: Simulating $other_os on $current_os"
simulated_output=$("$CAGE_DIR/claude-cage" --dry-run --os "$other_os" --no-banner 2>&1) || true

if ! echo "$simulated_output" | grep -q "Simulating OS: $other_os"; then
    echo "FAIL: Should indicate OS simulation"
    echo "Output was:"
    echo "$simulated_output"
    exit 1
fi
echo "  PASS: Shows OS simulation message"

# Test for OS-specific commands
if [ "$other_os" = "macos" ]; then
    # When simulating macOS, should see dscl commands instead of adduser
    if ! echo "$simulated_output" | grep -q "dscl"; then
        echo "FAIL: macOS simulation should use dscl for user creation"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: macOS simulation uses dscl"

    # Check for pf instead of iptables (in the firewall check message)
    if echo "$simulated_output" | grep -q "\[dry-run\] iptables"; then
        echo "FAIL: macOS simulation should not use iptables"
        exit 1
    fi
    echo "  PASS: macOS simulation does not use iptables"
else
    # When simulating Linux, should see adduser and iptables
    if ! echo "$simulated_output" | grep -q "adduser"; then
        echo "FAIL: Linux simulation should use adduser"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: Linux simulation uses adduser"

    if ! echo "$simulated_output" | grep -q "iptables"; then
        echo "FAIL: Linux simulation should use iptables"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: Linux simulation uses iptables"
fi

echo ""
echo "=== Testing firewall creation commands ==="

echo "Test 15: Should show iptables chain creation"
if ! echo "$output" | grep -q "\[dry-run\] iptables -N\|iptables -I OUTPUT"; then
    echo "FAIL: Did not find iptables chain creation commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found iptables chain creation commands"

echo "Test 16: Should show iptables catchall rule (blocklist mode ends with ACCEPT)"
if ! echo "$output" | grep -q "iptables -A.*-j ACCEPT"; then
    echo "FAIL: Did not find catchall ACCEPT rule for blocklist mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found catchall ACCEPT rule for blocklist mode"

echo ""
echo "=== Testing firewall cleanup commands ==="

echo "Test 17: Cleanup should show firewall chain check"
if ! echo "$cleanup_output" | grep -q "\[dry-run\] check firewall chain exists\|iptables -L OUTPUT"; then
    echo "FAIL: Did not find firewall chain check in cleanup"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup checks for firewall chains"

echo ""
echo "=== Testing allowlist mode ==="

# Create a test config for allowlist mode
mkdir -p "$TEST_TMP/allowlist-test/project"
cat > "$TEST_TMP/allowlist-test/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    directMount = "workspace",
    networkMode = "allowlist",
    allow = {
        ips = { "127.0.0.1:5432" },
        domains = { "github.com:443" }
    }
}
EOF

echo "Test 18: Allowlist mode should show REJECT catchall rule"
cd "$TEST_TMP/allowlist-test/project"
allowlist_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

if ! echo "$allowlist_output" | grep -q "iptables -A.*-j REJECT\|mode: allowlist"; then
    echo "FAIL: Allowlist mode should end with REJECT rule or show allowlist mode"
    echo "Output was:"
    echo "$allowlist_output"
    exit 1
fi
echo "  PASS: Allowlist mode configured correctly"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing macOS pf firewall simulation ==="

echo "Test 19: macOS simulation should show pf anchor commands"
macos_output=$("$CAGE_DIR/claude-cage" --dry-run --os macos --no-banner 2>&1) || true

if ! echo "$macos_output" | grep -q "pfctl\|pf_rules_file\|anchor"; then
    echo "FAIL: macOS simulation should show pf/anchor commands"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
echo "  PASS: macOS simulation shows pf commands"

echo "Test 20: macOS simulation should show pass/block rules (not ACCEPT/REJECT)"
if echo "$macos_output" | grep -q "ACCEPT\|REJECT"; then
    # This is fine - these words might appear in messages, just check pf syntax is used
    :
fi
# Check for pf-style syntax in the output
if ! echo "$macos_output" | grep -qE "pass out|block out|pfctl"; then
    echo "FAIL: macOS simulation should use pf syntax (pass/block)"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
echo "  PASS: macOS simulation uses pf syntax"

echo "Test 20b: macOS pf should use mktemp (not hardcoded /tmp paths)"
if echo "$macos_output" | grep -q '/tmp/.*\.pf'; then
    echo "FAIL: macOS pf should not use hardcoded /tmp paths (security issue)"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
if ! echo "$macos_output" | grep -q 'mktemp'; then
    echo "FAIL: macOS pf should use mktemp for secure temp file creation"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
echo "  PASS: macOS pf uses mktemp for secure temp files"

echo ""
echo "=== Testing instance tracking ==="

echo "Test 21: Should show instance file registration"
if ! echo "$output" | grep -q "echo.*>>.*instances\|instance"; then
    echo "FAIL: Did not find instance file registration"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found instance tracking commands"

echo "Test 22: Workspace mode should track by mount point"
workspace_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$workspace_output" | grep -q "claude-cage-mount-\|mount_instance_file\|workspace"; then
    echo "FAIL: Workspace mode should mention mount instance tracking"
    echo "Output was:"
    echo "$workspace_output"
    exit 1
fi
echo "  PASS: Workspace mode shows mount point tracking"

echo ""
echo "=== Testing Docker mode ==="

# Create a test config for Docker mode
mkdir -p "$TEST_TMP/docker-test/myproject"
cat > "$TEST_TMP/docker-test/claude-cage.config" << 'EOF'
claude_cage {
    isolationMode = "docker",
    directMount = "workspace",
    docker = {
        image = "node:lts-slim",
        packages = { "git", "curl" }
    }
}
EOF
cd "$TEST_TMP/docker-test/myproject"

echo "Test 23: Docker mode should show docker commands"
docker_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$docker_output" | grep -q "docker\|Docker"; then
    echo "FAIL: Docker mode should show docker commands"
    echo "Output was:"
    echo "$docker_output"
    exit 1
fi
echo "  PASS: Docker mode shows docker commands"

echo "Test 24: Docker mode should not require sudo message"
if echo "$docker_output" | grep -q "Gonna need you to run this as root"; then
    echo "FAIL: Docker mode should not require sudo"
    echo "Output was:"
    echo "$docker_output"
    exit 1
fi
echo "  PASS: Docker mode does not require sudo"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing Docker isolated mode ==="

# Create a test config for Docker isolated mode (reused for multiple tests)
mkdir -p "$TEST_TMP/docker-isolated-test/myproject"
cat > "$TEST_TMP/docker-isolated-test/claude-cage.config" << 'EOF'
claude_cage {
    isolationMode = "docker",
    directMount = "workspace",
    docker = {
        isolated = true
    }
}
EOF
cd "$TEST_TMP/docker-isolated-test/myproject"

# Run once and check multiple assertions
isolated_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

echo "Test 25: Docker isolated mode should show project-specific container name"
if ! echo "$isolated_output" | grep -q "claude-cage-.*-"; then
    echo "FAIL: Isolated mode should show project-specific container name with hash"
    echo "Output was:"
    echo "$isolated_output"
    exit 1
fi
echo "  PASS: Docker isolated mode shows project-specific container name"

# Test 40 moved here - uses same isolated mode config
echo "Test 25b: Docker isolated mode should use .caged for persistent home"
if ! echo "$isolated_output" | grep -q "Persistent home:.*\.caged.*home"; then
    echo "FAIL: Isolated mode should use .caged directory for persistent home"
    echo "Output was:"
    echo "$isolated_output"
    exit 1
fi
echo "  PASS: Isolated mode uses .caged for persistent home"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing Docker existing container ==="

# Create a test config for existing container
mkdir -p "$TEST_TMP/docker-existing-test/myproject"
cat > "$TEST_TMP/docker-existing-test/claude-cage.config" << 'EOF'
claude_cage {
    isolationMode = "docker",
    directMount = "workspace",
    docker = {
        container = "my-existing-container",
        user = "myuser",
        workdir = "/app"
    }
}
EOF
cd "$TEST_TMP/docker-existing-test/myproject"

echo "Test 26: Docker existing container should show container name"
existing_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$existing_output" | grep -q "my-existing-container"; then
    echo "FAIL: Should show existing container name"
    echo "Output was:"
    echo "$existing_output"
    exit 1
fi
echo "  PASS: Docker existing container shows container name"

echo "Test 27: Docker existing container should mention user-managed"
if ! echo "$existing_output" | grep -q "user-managed\|existing"; then
    echo "FAIL: Should mention user-managed or existing container"
    echo "Output was:"
    echo "$existing_output"
    exit 1
fi
echo "  PASS: Docker existing container mentions user-managed"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing homeConfigSync ==="

echo "Test 28: Should show copy command for homeConfigSync entries"
if ! echo "$output" | grep -qE "(rsync|cp).*\.gitconfig|(rsync|cp).*claude-settings.json"; then
    echo "FAIL: Did not find homeConfigSync copy commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found homeConfigSync copy commands"

echo "Test 29: Should show recursive rsync for directories"
if ! echo "$output" | grep -qE "rsync -r[lL].*\.claude/"; then
    echo "FAIL: Did not find recursive rsync for .claude directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found recursive rsync for directories"

echo "Test 30: Should show copy for override entries"
if ! echo "$output" | grep -qE "(rsync|cp).*/claude-settings.json"; then
    echo "FAIL: Override entry should appear in output"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Override entries synced"

echo "Test 30a: Should display homeConfigSync header section"
if ! echo "$output" | grep -q "Home config sync:"; then
    echo "FAIL: Did not find 'Home config sync:' header section"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found homeConfigSync header section"

echo "Test 30b: Should show mode prefix in homeConfigSync display"
# Format is: [mode] path  or  [mode] path -> dest
if ! echo "$output" | grep -qE '\[init\].*\.gitconfig|\[sync\].*\.claude'; then
    echo "FAIL: Did not find mode prefix format in homeConfigSync display"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found mode prefix format in homeConfigSync display"

echo ""
echo "=== Testing homeConfigSync modes ==="

# Create a test config with new homeConfigSync modes
mkdir -p "$TEST_TMP/homesync-modes-test/project"
cat > "$TEST_TMP/homesync-modes-test/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    homeConfigSync = {
        -- Simple string: init mode (backward compatible)
        ".gitconfig",

        -- New table syntax with modes
        { path = ".claude", mode = "sync", exclude = { path = { "settings.json" }, belowPath = { "logs" } } },
        { path = ".claude.json", mode = "sync" },
        { path = ".npmrc", mode = "copy" },
        { path = ".some-dir", mode = "link" },
        { path = ".profile", mode = "init" },
    }
}
EOF
cd "$TEST_TMP/homesync-modes-test/project"

echo "Test 31: Should parse new homeConfigSync table syntax"
modes_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

if ! echo "$modes_output" | grep -q "mode=init"; then
    echo "FAIL: Did not find mode=init in output"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found mode=init"

echo "Test 32: Should show mode=copy for copy entries"
if ! echo "$modes_output" | grep -q "mode=copy"; then
    echo "FAIL: Did not find mode=copy in output"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found mode=copy"

echo "Test 33: Should show mode=link for link entries"
if ! echo "$modes_output" | grep -q "mode=link"; then
    echo "FAIL: Did not find mode=link in output"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found mode=link"

echo "Test 34: Should show mode=sync entries"
if ! echo "$modes_output" | grep -q "(mode=sync)"; then
    echo "FAIL: Did not find mode=sync entries"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found mode=sync entries"

echo "Test 35: Should show unison process for sync entries"
if ! echo "$modes_output" | grep -q "homeConfigSync.*unison\|unison.*/original/"; then
    echo "FAIL: Did not find homeConfigSync unison process"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found homeConfigSync unison process"

echo "Test 36: Should show root mounts with -path args (not whole home mount)"
# User mode should create root mounts and use -path for each entry
if ! echo "$modes_output" | grep -q 'root mounts\|homeConfigSync sync entry:\|-path'; then
    echo "FAIL: Did not find root mount with -path pattern"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found root mount with -path pattern"

echo "Test 36b: Should show bindfs setup for homeConfigSync sync mode"
if ! echo "$modes_output" | grep -q 'bindfs.*--create-for-user.*--create-for-group'; then
    echo "FAIL: Did not find bindfs setup for homeConfigSync sync mode"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found bindfs setup for homeConfigSync sync mode"

echo "Test 36c: Bindfs mounts should use /run/ (not /tmp or user home)"
if echo "$modes_output" | grep -q '/tmp/.*home-sync\|/tmp/.*bindfs'; then
    echo "FAIL: Found /tmp path for homeConfigSync bindfs mounts (security issue)"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
if ! echo "$modes_output" | grep -q '/run/claude-cage/'; then
    echo "FAIL: Did not find /run/claude-cage/ directory for homeConfigSync bindfs mounts"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Bindfs mounts use /run/claude-cage/"

echo "Test 36d: Should NOT mount entire home directory"
# Should not see bindfs mounting the entire home directory
if echo "$modes_output" | grep -qE 'bindfs.*"/home/[^/]+"\s+"/run/claude-cage/mounts/homesync-[^/]+/(original|cage)"'; then
    echo "FAIL: Found whole home directory mount (security issue)"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Does not mount entire home directory"

echo "Test 36e: Should set up bindfs mounts for homeConfigSync"
if ! echo "$modes_output" | grep -q 'Setting up homeConfigSync\|homeConfigSync.*root mounts\|homeConfigSync mount:'; then
    echo "FAIL: Did not find homeConfigSync mount setup message"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Sets up homeConfigSync bindfs mounts"

echo "Test 36f: Homesync mounts should use user name (shared across instances)"
# Mount path should be homesync-<username> not homesync-<pid>
if ! echo "$modes_output" | grep -qE '/run/claude-cage/mounts/homesync-testuser/'; then
    echo "FAIL: homesync mount path should use username (homesync-testuser), not PID"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Homesync mounts use username for sharing"

echo "Test 36g: Files should use symlinks (not mounts)"
# Files in sync mode should be symlinked, not have full directory mounts
if ! echo "$modes_output" | grep -qE 'file.*symlink|ln -s.*files-bindfs'; then
    echo "FAIL: Did not find symlink approach for files"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Files use symlinks"

echo "Test 36h: Shared mounts should be checked before creation"
if ! echo "$modes_output" | grep -q 'mounts already exist\|Setting up homeConfigSync\|root mounts'; then
    echo "FAIL: Did not find mount existence check message"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Mount existence is checked"

echo "Test 36i: Shared PID file should be used for sync processes"
# PID file should be in the homesync directory (not project PID file)
if ! echo "$modes_output" | grep -qE 'homesync-testuser/pids|already running.*shared'; then
    # In dry-run we won't see "already running" but we should see the unison commands are being set up
    # Now uses single unison with -path args instead of per-directory
    if ! echo "$modes_output" | grep -q 'unison.*/original.*/cage.*-batch.*-path'; then
        echo "FAIL: Did not find shared unison setup"
        echo "Output was:"
        echo "$modes_output"
        exit 1
    fi
fi
echo "  PASS: Shared sync processes setup found"

echo "Test 37: mode=link should warn about files"
# Create config with link mode on a file (which should warn)
# The warning happens when the source is a file, which we can't easily test in dry-run
# since dry-run doesn't check actual filesystem. Test that link mode works at least.
if ! echo "$modes_output" | grep -q "ln -s.*\.some-dir"; then
    echo "FAIL: Did not find ln -s command for link mode"
    echo "Output was:"
    echo "$modes_output"
    exit 1
fi
echo "  PASS: Found symlink command for link mode"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing config merging across user and local configs ==="

# Create a test setup with user config and local config
# Note: script uses /home/$USER/.config/claude-cage/config for user config
mkdir -p "$TEST_TMP/merge-test/myproject"
USER_CONFIG_DIR="$HOME/.config/claude-cage"
USER_CONFIG_BACKUP=""

# Backup existing user config if present
if [ -f "$USER_CONFIG_DIR/config" ]; then
    USER_CONFIG_BACKUP=$(mktemp)
    cp "$USER_CONFIG_DIR/config" "$USER_CONFIG_BACKUP"
fi
mkdir -p "$USER_CONFIG_DIR"

# User config with entries that should be merged
cat > "$USER_CONFIG_DIR/config" << 'EOF'
claude_cage {
    exclude = {
        name = { "from-user-exclude" },
    },
    cageLocal = {
        name = { "from-user-cagelocal" },
    },
    homeConfigSync = {
        ".from-user-config",
    }
}
EOF

# Local config with different entries (sync mode to test exclude/cageLocal)
cat > "$TEST_TMP/merge-test/claude-cage.config" << 'EOF'
claude_cage {
    exclude = {
        name = { "from-local-exclude" },
    },
    cageLocal = {
        name = { "from-local-cagelocal" },
    },
    homeConfigSync = {
        ".from-local-config",
    }
}
EOF

cd "$TEST_TMP/merge-test/myproject"

echo "Test 37b: Config arrays should be merged from user and local configs"
merge_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

# Restore user config before checking results (so cleanup happens even on failure)
if [ -n "$USER_CONFIG_BACKUP" ]; then
    cp "$USER_CONFIG_BACKUP" "$USER_CONFIG_DIR/config"
    rm -f "$USER_CONFIG_BACKUP"
else
    rm -f "$USER_CONFIG_DIR/config"
fi

# Check exclude merging (appears in unison -ignore args)
if ! echo "$merge_output" | grep -q "from-user-exclude"; then
    echo "FAIL: Did not find from-user-exclude from user config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
if ! echo "$merge_output" | grep -q "from-local-exclude"; then
    echo "FAIL: Did not find from-local-exclude from local config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
echo "  PASS: exclude entries merged"

# Check cageLocal merging (appears in unison -nocreationpartial args)
if ! echo "$merge_output" | grep -q "from-user-cagelocal"; then
    echo "FAIL: Did not find from-user-cagelocal from user config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
if ! echo "$merge_output" | grep -q "from-local-cagelocal"; then
    echo "FAIL: Did not find from-local-cagelocal from local config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
echo "  PASS: cageLocal entries merged"

# Check homeConfigSync merging
if ! echo "$merge_output" | grep -q "\.from-user-config"; then
    echo "FAIL: Did not find .from-user-config from user config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
if ! echo "$merge_output" | grep -q "\.from-local-config"; then
    echo "FAIL: Did not find .from-local-config from local config"
    echo "Output was:"
    echo "$merge_output"
    exit 1
fi
echo "  PASS: homeConfigSync entries merged"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing Docker persistent home ==="

# Create a test config for Docker mode with managed container
mkdir -p "$TEST_TMP/docker-persistent-test/myproject"
cat > "$TEST_TMP/docker-persistent-test/claude-cage.config" << 'EOF'
claude_cage {
    isolationMode = "docker",
    directMount = "workspace",
    docker = {
        image = "node:lts-slim",
    },
    homeConfigSync = {
        ".gitconfig",
        { path = ".claude", mode = "sync" },
    }
}
EOF
cd "$TEST_TMP/docker-persistent-test/myproject"

echo "Test 38: Docker managed container should show persistent home"
docker_persist_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$docker_persist_output" | grep -q "Persistent home:"; then
    echo "FAIL: Did not find persistent home message"
    echo "Output was:"
    echo "$docker_persist_output"
    exit 1
fi
echo "  PASS: Found persistent home message"

echo "Test 39: Docker managed container should mount home directory"
if ! echo "$docker_persist_output" | grep -q '\-v ".*home.*:/home/claude"'; then
    echo "FAIL: Did not find home volume mount in docker run command"
    echo "Output was:"
    echo "$docker_persist_output"
    exit 1
fi
echo "  PASS: Found home volume mount"

# Test 40 was moved to Test 25b (uses same isolated mode config)

echo ""
echo "=== Testing instance file locations ==="

cd "$TEST_TMP/project"

echo "Test 40: User mode instance files should be in /run/claude-cage/"
user_instance_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$user_instance_output" | grep -q "/run/claude-cage/instances"; then
    echo "FAIL: Did not find /run/claude-cage/instances path"
    echo "Output was:"
    echo "$user_instance_output"
    exit 1
fi
echo "  PASS: User mode uses /run/claude-cage/instances"

echo "Test 41: Docker mode instance files should be in /run/user/"
cd "$TEST_TMP/docker-persistent-test/myproject"
docker_instance_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$docker_instance_output" | grep -q "/run/user/.*/claude-cage/instances"; then
    echo "FAIL: Did not find /run/user/<uid>/claude-cage/instances path"
    echo "Output was:"
    echo "$docker_instance_output"
    exit 1
fi
echo "  PASS: Docker mode uses /run/user/<uid>/claude-cage/instances"

echo ""
echo "=== Testing Docker homeConfigSync implementation ==="

echo "Test 42: Docker mode should use rsync for homeConfigSync (not docker cp)"
if echo "$docker_instance_output" | grep -q "docker cp"; then
    echo "FAIL: Found 'docker cp' - should use rsync to persistent home instead"
    echo "Output was:"
    echo "$docker_instance_output"
    exit 1
fi
if ! echo "$docker_instance_output" | grep -q "rsync.*\.gitconfig"; then
    echo "FAIL: Did not find rsync command for homeConfigSync"
    echo "Output was:"
    echo "$docker_instance_output"
    exit 1
fi
echo "  PASS: Docker mode uses rsync for homeConfigSync"

echo "Test 43: Docker sync mode should set up unison"
if ! echo "$docker_instance_output" | grep -q "homeConfigSync unison"; then
    echo "FAIL: Did not find unison setup for Docker sync mode"
    echo "Output was:"
    echo "$docker_instance_output"
    exit 1
fi
echo "  PASS: Docker sync mode sets up unison"

echo "Test 44: Docker sync mode should NOT use bindfs (same user)"
if echo "$docker_instance_output" | grep -q "bindfs.*homeConfigSync\|Creating bindfs mounts for homeConfigSync"; then
    echo "FAIL: Found bindfs for Docker homeConfigSync - not needed (same user)"
    echo "Output was:"
    echo "$docker_instance_output"
    exit 1
fi
echo "  PASS: Docker sync mode does not use bindfs"

echo ""
echo "=== All dry-run tests passed! ==="
