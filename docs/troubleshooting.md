# Troubleshooting

## Installation Issues

### lua not installed

**Error:**
```
Now listen carefully. We got a problem here.
I need lua installed on this bird.
Can't do nothin' without it.
```

**Solution:**
```bash
# Ubuntu/Debian
sudo apt install lua

# RHEL/CentOS/Fedora
sudo yum install lua
```

### inotify-tools not installed

**Error:**
```
Hold on now. We got a problem here.
Unison needs inotify-tools for file monitoring.
Without it, this bird ain't gonna watch your files properly.
```

**Solution:**
```bash
# Ubuntu/Debian
sudo apt install inotify-tools

# RHEL/CentOS/Fedora
sudo yum install inotify-tools
```

### unison or bindfs not installed

The script doesn't check for these upfront. If they're missing, you'll see errors when the script tries to use them.

**Solution:**

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install unison bindfs

# RHEL/CentOS/Fedora
sudo yum install unison bindfs
```

**macOS:**
```bash
# Using Homebrew
brew install unison bindfs macfuse

# Note: macFUSE requires approval in System Settings
# Go to: System Settings > Privacy & Security
# Look for "System software from developer 'Benjamin Fleischer' was blocked"
# Click "Allow" and restart your Mac
```

### No file monitoring helper program found

**Error from unison:**
```
No file monitoring helper program found
```

**Cause:** `unison-fsmonitor` binary is not installed. Unison's watch mode requires this separate helper program to efficiently monitor file changes.

**Impact:** claude-cage automatically falls back to polling mode (checking every 1 second) when `unison-fsmonitor` is not found. This works fine but is less efficient than watch mode.

**Solutions:**

1. **Use polling mode (automatic fallback):**
   - claude-cage detects the missing binary and uses `-repeat 1` instead
   - Changes are detected every second (still very responsive)
   - **Important:** Exclude large directories with `exclude.name` to keep polling fast
   ```lua
   exclude = { name = { "node_modules", "target", ".venv", "vendor" } }
   ```

2. **Install unison-fsmonitor (optimal performance):**

   The Debian/Ubuntu `unison` package doesn't include `unison-fsmonitor`. You need to either:

   - **Build from source:**
     ```bash
     # Install OCaml compiler and dependencies
     sudo apt install ocaml opam make

     # Get unison source
     git clone https://github.com/bcpierce00/unison.git
     cd unison

     # Build (creates both unison and unison-fsmonitor)
     make

     # Install binaries
     sudo cp src/unison /usr/local/bin/
     sudo cp src/unison-fsmonitor /usr/local/bin/
     ```

   - **Find a package that includes it** (may be available in other repos)

3. **Verify installation:**
   ```bash
   which unison-fsmonitor
   # Should show: /usr/local/bin/unison-fsmonitor (or similar)
   ```

**Performance comparison:**
- **Watch mode** (with unison-fsmonitor): Instant change detection, no polling overhead
- **Polling mode** (without unison-fsmonitor): 1 second latency, scans entire source tree every second

For most development workflows, polling mode works fine. Use `exclude.name` to exclude large directories anywhere in the tree and keep it responsive.

## Configuration Errors

### No claude-cage.config found

**Error:**
```
Hold on now. I'm lookin' for a file called 'claude-cage.config' and it ain't here.
Searched from /path/to/current/dir all the way up to /.
```

**Cause:** The required config file doesn't exist anywhere in the directory tree above your current location.

**Solution:**
Create a `claude-cage.config` file in your project directory or a parent directory:

```lua
claude_cage {
    -- Minimal config - project derived from directory structure
    exclude = { name = { ".env" } }
}
```

### source directory does not exist

**Error:**
```
Error: source directory 'src' does not exist
```

**Cause:** The source directory specified in your config doesn't exist.

**Solution:**
- In sync mode: Verify the source directory exists relative to where you're running claude-cage
- In direct mount mode: Ensure you're in the correct directory and the subdirectory exists

```bash
# Check current directory
pwd

# List directories
ls -la

# Fix config or create directory
mkdir src  # Or update source in config
```

### Invalid configuration syntax

**Error:**
```
lua: ./claude-cage.config:5: syntax error
```

**Cause:** Lua syntax error in config file.

**Solution:**
- Check for missing commas between array items
- Ensure strings are quoted: `"value"` not `value`
- Arrays use curly braces: `{ "item1", "item2" }`
- Comments use double dash: `-- comment`

```lua
-- WRONG (square brackets, missing commas)
exclude = { name = [ "target" "dist" ] }

-- CORRECT (curly braces, commas between items)
exclude = { name = { "target", "dist" } }
```

## Permission Issues

### Permission denied when running claude-cage

**Error:**
```
Gonna need you to run this as root. Use sudo, Bay-BEE!
```

**Cause:** Script requires root privileges for bindfs mounting.

**Solution:**
```bash
sudo ./claude-cage
```

### Cannot create user

**Error:**
```
Error: Failed to create user 'claude'
```

**Cause:** Insufficient permissions or user already exists with conflicts.

**Solution:**
```bash
# Check if user already exists
id claude

# If exists, either use it or delete and recreate
sudo userdel -r claude
```

### Bindfs mount failed

**Error:**
```
Error: Failed to mount directory
```

**Cause:** Previous mount still active or permission issues.

**Solution:**
```bash
# Check existing mounts
mount | grep bindfs

# Unmount if necessary
sudo umount /home/claude/caged/myproject

# Or use cleanup mode
sudo ./claude-cage --cleanup
```

## Sync Issues (Sync Mode)

### Files not syncing

**Problem:** Changes in source don't appear in Claude's view, or vice versa.

**Diagnosis:**
```bash
# Check if unison is running
ps aux | grep unison

# Check bindfs mount
mount | grep bindfs

# Look at unison logs
tail -f /tmp/unison.log  # If logging enabled
```

**Solutions:**

1. **Restart claude-cage:**
   ```bash
   # Exit current session (Ctrl+C)
   sudo ./claude-cage
   ```

2. **Check exclude patterns:**
   - File might be excluded by your config
   - Verify exclude.path, exclude.name, exclude.regex, exclude.belowPath

3. **Check file permissions:**
   ```bash
   ls -la your-source-directory/
   ls -la .caged/your-project/sync/
   ```

### Excluded files still appearing

**Problem:** Files that should be excluded are visible in Claude's environment.

**Diagnosis:**
```bash
# Check what's in sync directory
ls -la .caged/myproject/sync/

# Verify exclude patterns in config
cat claude-cage.config
```

**Solution:**

1. **Files were synced before exclusion rules were added:**
   ```bash
   # claude-cage will prompt you to remove them
   sudo ./claude-cage
   # Answer 'y' when prompted about excluded files
   ```

2. **Exclude pattern doesn't match:**
   ```lua
   -- Use the right exclude type
   exclude = {
       path = { "config/prod.yml" },     -- Exact path from root
       name = { ".env", "*.log" },       -- By name anywhere in tree
       belowPath = { ".git", "secrets" }, -- Entire directory trees at root
       regex = { ".*\\.log$" }            -- Regex (escape backslashes)
   }
   ```

### Unison conflicts

**Problem:** Unison reports conflicts between source and sync directories.

**Error:**
```
Conflict: file changed on both sides
```

**Solution:**

1. **Choose which version to keep:**
   - Unison will prompt you interactively
   - Choose source (your original) or sync (Claude's version)

2. **Prevent conflicts:**
   - Don't edit files in both source and sync at the same time
   - Let Claude work in its environment, you work in source
   - Unison will sync changes automatically

3. **Reset sync directory:**
   ```bash
   # Remove sync directory and let claude-cage recreate it
   rm -rf .caged/myproject
   sudo ./claude-cage
   ```

## Network Issues

### Network restrictions not working

**Problem:** Connections that should be blocked are succeeding.

**Diagnosis:**
```bash
# Check iptables rules
sudo iptables -L -n | grep claude

# Test connection as claude user
sudo -u claude curl -I http://127.0.0.1:80
```

**Solutions:**

1. **Verify networkMode is set:**
   ```lua
   networkMode = "blocklist"  -- or "allowlist"
   ```

2. **Check rules are applied:**
   ```bash
   # Should see OUTPUT chain rules for user claude
   sudo iptables -L OUTPUT -n -v
   ```

3. **Cleanup and restart:**
   ```bash
   sudo ./claude-cage --cleanup
   sudo ./claude-cage
   ```

### Cannot connect to allowed domains

**Problem:** In allowlist mode, connections to allowed domains fail.

**Diagnosis:**
```bash
# Test as claude user in test mode
sudo ./claude-cage --test

# Try connection
curl -I https://github.com:443
```

**Solutions:**

1. **Check domain resolution:**
   ```bash
   # Domains are resolved to IPs
   getent hosts github.com
   ```

2. **Verify port specification:**
   ```lua
   -- Wrong: Missing port
   allowedDomains = { "github.com" }  -- Allows all ports

   -- Right: Specific port
   allowedDomains = { "github.com:443" }  -- HTTPS only
   ```

### DNS resolution fails

**Problem:** Domains can't be resolved to IPs for network rules.

**Error:**
```
Warning: Could not resolve domain 'example.com'
```

**Solution:**
```bash
# Check DNS is working
nslookup example.com

# Check /etc/resolv.conf
cat /etc/resolv.conf

# Try with explicit DNS
ping 8.8.8.8  # Google DNS
```

## Claude Code Issues

### Authentication required for every project

**Problem:** Claude Code asks for login every time you run claude-cage.

**Cause:** Using per-project mode, which creates a new user for each project.

**Solution:**

Switch to single-user mode:
```lua
-- Change from
userMode = "per-project"

-- To
userMode = "single"  -- Or just remove this line (single is default)
```

### Claude Code won't start

**Problem:** claude-cage runs but Claude Code doesn't launch.

**Diagnosis:**
```bash
# Check if process started
ps aux | grep claude

# Run in test mode
sudo ./claude-cage --test
# Try launching claude manually
claude
```

**Solutions:**

1. **Claude Code not installed:**
   ```bash
   # Install Claude Code
   curl -fsSL https://claude.ai/install.sh | sh
   ```

2. **Path issues:**
   ```bash
   # Check if claude is in PATH for the claude user
   sudo -u claude which claude
   ```

3. **Permission issues:**
   ```bash
   # Ensure claude user can access Claude Code
   sudo -u claude claude --version
   ```

## File System Issues

### Disk space errors

**Error:**
```
No space left on device
```

**Cause:** Sync directory is filling up disk space.

**Solution:**

1. **Check disk usage:**
   ```bash
   df -h
   du -sh .caged/*/sync
   ```

2. **Add more exclusions:**
   ```lua
   exclude = { name = { "node_modules", "target", "dist" } }
   ```

3. **Switch to direct mount mode:**
   ```lua
   -- Workspace mode: access sibling projects
   directMount = "workspace"  -- No sync, no duplication

   -- Or project mode: isolated to one project
   directMount = "project"  -- No sync, no duplication
   ```

### Permission mismatch in source

**Problem:** Files synced back to source have wrong owner/permissions.

**Cause:** Bindfs permission mapping issue.

**Solution:**

1. **Check bindfs options:**
   ```bash
   # Should map claude user to your user
   mount | grep bindfs
   ```

2. **Fix ownership:**
   ```bash
   # Take ownership of files
   sudo chown -R $USER:$USER source-directory/
   ```

## Cleanup Issues

### Mount points still active after exit

**Problem:** Bindfs mounts remain after claude-cage exits.

**Diagnosis:**
```bash
mount | grep bindfs
```

**Solution:**
```bash
# Use cleanup mode
sudo ./claude-cage --cleanup

# Or manually unmount
sudo umount /home/claude/caged/myproject
```

### iptables rules not cleaned up

**Problem:** Network rules remain after exit.

**Diagnosis:**
```bash
sudo iptables -L OUTPUT -n | grep claude
```

**Solution:**
```bash
# Use cleanup mode
sudo ./claude-cage --cleanup

# Or manually remove rules
sudo iptables -D OUTPUT -m owner --uid-owner claude -j REJECT
```

## Getting Help

If you're still stuck:

1. **Run in test mode to diagnose:**
   ```bash
   sudo ./claude-cage --test
   ```

2. **Check the logs:**
   - Unison output (stdout)
   - System logs: `sudo journalctl -xe`

3. **File an issue:**
   - https://github.com/zbateson/claude-cage/issues
   - Include your config (redact secrets!)
   - Include error messages
   - Include output from test mode
