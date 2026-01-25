# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

Now, I'm gonna tell you about `claude-cage`. It's a bash script that's gonna keep your files locked down tight and your network traffic under control while lettin' Claude Code do its work. Three layers of file protection. Optional network isolation. Multiple barriers between your precious code and anything that might go wrong. That's how we do this right.

## What This Thing Does

Listen up. `claude-cage` sets up a containment system - multiple layers of protection workin' together:

**File Isolation** - Three levels of security, each one watchin' the other:

1. **Source directory** - That's your actual project files. Your life's work. The thing you came here to protect.
2. **Sync directory** - A perfect copy, maintained by `unison`. Like a mirror, but better.
3. **Mounted directory** - Where Claude Code operates. Permission-mapped through `bindfs`. Controlled. Contained.

Every change Claude makes gets synced back to your source. But only the changes you allow. The rest? They stay on the outside where they belong.

**Network Isolation** (optional) - OS-level restrictions on top of Claude Code's sandbox:

- **Allowlist mode**: Lock it down - only approved connections get through
- **Blocklist mode**: Keep Claude away from your internal infrastructure
- **Defense in depth**: Application sandbox plus OS-level firewall rules
- Works through iptables - kernel-level enforcement that can't be bypassed from userspace

You don't have to use network restrictions. But they're there if you need 'em.

## ⚠️ Now Listen to Me Very Carefully

**This tool uses bidirectional synchronization.** That means what happens in one place happens in the other. **Including deletions.** You understand what I'm tellin' you? You delete somethin' on one side, it's gone on the other. Gone.

**Before you even think about runnin' this:**
- ✅ **Commit and push everything to git** - Every last change. I mean it.
- ✅ **Make yourself a backup** - A real one. The kind that'll still be there when you need it.
- ✅ **Test this on somethin' that don't matter first** - Learn how it works before you bet the farm.
- ✅ **Set up your exclude patterns right** - Protect what needs protectin'.

**Here's what unison's gonna do:**
- Synchronize every modification you make, both ways
- **Delete files** if they get deleted on either side
- Propagate changes the second they happen in watch mode

If you ain't sure about your setup, you test it on somethin' expendable first. That ain't a suggestion.

## Prerequisites

**Supported Platforms:** Linux (Ubuntu/Debian/Fedora/RHEL/CentOS)

**Note:** This is a Linux-only operation. While `unison` works on macOS, `bindfs` needs FUSE, and that bird don't fly on Mac anymore. Homebrew shut that down back in 2021.

Get your dependencies installed:

```bash
# Ubuntu/Debian
sudo apt install unison bindfs lua inotify-tools

# RHEL/CentOS
sudo yum install unison bindfs lua inotify-tools
```

## Installation

### Option 1: Download Script Only

If you just want the script - no fuss, no extras:

```bash
# Download the script
curl -O https://raw.githubusercontent.com/zbateson/claude-cage/main/claude-cage

# Make it executable
chmod +x claude-cage
```

Then you can install it to your PATH if you want. See below.

### Option 2: Clone Repository

1. Clone or download this whole repository
2. Make the script executable:
   ```bash
   chmod +x claude-cage
   ```

### Installing to PATH (Optional)

To make `claude-cage` available from anywhere on your system:

**System-wide:**
```bash
sudo cp claude-cage /usr/local/bin/
```

After that, you can run it like this:
```bash
sudo claude-cage
```

**Note:** The `claude-cage.config` file's gotta be in the directory where you run the command. That's non-negotiable.

## Configuration

### Configuration Hierarchy

This system's got three tiers. Each one can override the one before it:

1. **System config** (optional): `/etc/claude-cage/config`
   - System-wide defaults for everybody
   - Requires root access to modify

2. **User config** (optional): `~/.config/claude-cage/config`
   - Your personal preferences
   - Overrides system defaults

3. **Local config** (**required**): `./claude-cage.config`
   - Project-specific settings
   - **Has to exist** in the directory where you run this
   - Overrides everything else

**Security:** The local config requirement? That's there so you don't accidentally run this thing in the wrong place and mess up somethin' important.

### Global Configs (Optional)

- **System config**: `/etc/claude-cage/config` - defaults for all users
- **User config**: `~/.config/claude-cage/config` - personal preferences

Check `examples/example-system-config` and `examples/example-user-config` for templates.

### Local Config (Required)

Create `claude-cage.config` in your project directory. Here's how:

```lua
claude_cage {
    -- Project name (recommended - sets defaults for other options)
    project = "myproject",

    -- User to run Claude Code as (default: "claude")
    -- user = "claude",

    -- User isolation mode (default: "single" - RECOMMENDED)
    -- Options: "single" or "per-project"
    -- Single-user mode shares one user across all projects (easier authentication)
    -- Per-project mode creates separate users per project (requires login per user)
    -- userMode = "single",

    -- Optional: Custom suffix for per-project mode
    -- Only applies when userMode = "per-project"
    -- If not set, uses project name
    -- userAppend = "myproject",

    -- Source directory under current directory to allow reading from
    -- If not provided, source must be provided as a command-line argument
    source = "my-directory",

    -- Sync directory for unison to sync source with
    -- If empty, uses syncPrepend + project (or source if no project)
    -- sync = "claude-myproject",

    -- Prefix for auto-generated sync directory name
    -- syncPrepend = "claude-",

    -- Files/folders that Claude should not have access to and should not be synced
    excludePath = { "target", "dist", ".env" },
    excludeName = { "*.tmp", ".DS_Store" },
    excludeRegex = { ".*\\.log$" },
    belowPath = { "node_modules" },

    -- Mounted directory name created under the user's home directory
    -- Default: "claude" (not based on source/project)
    -- mounted = "claude"
}
```

### Configuration Options

- **project**: Project name (**required**)
  - Automatically used as default for `userAppend` and `sync`
  - Example: `project = "backend"` creates sync dir `"claude-backend"`
- **user**: Base user account name to run Claude Code as (default: `"claude"`)
- **userMode**: User isolation mode (default: `"single"`)
  - Options: `"single"` or `"per-project"`
  - **Single-user mode** (RECOMMENDED, default): All projects share one user
    - Username: `"claude"` (just the base username)
    - User home: `/home/claude/` (standard location)
    - Network rules: Shared across all projects, persist until last instance exits
    - Claude Code authentication: Login once, works for all projects
    - Use when: Most situations (simpler, easier to manage)
  - **Per-project mode**: Each project gets its own user
    - Username: `"claude-myproject"` (user + "-" + userAppend or project)
    - User home: `/home/.claude-cage/claude-myproject/`
    - Network rules: Project-specific, cleaned up when the project exits
    - Claude Code authentication: **Requires login for each new project user** (see caveats below)
    - Use when: Different projects need different security policies
  - Users are automatically deleted when claude-cage exits (unless they existed before)
- **userAppend**: (Optional) Custom suffix for per-project mode (default: uses `project` name)
  - Only applies when `userMode = "per-project"`
  - Example: `userAppend = "custom"` creates user `"claude-custom"` instead of `"claude-myproject"`
- **source**: Source directory to sync (can be overridden via command-line)
- **sync**: Sync directory name (default: auto-generated from `project` or `source`)
  - If not set and `project` is set: `syncPrepend + project`
  - If not set and no `project`: `syncPrepend + source`
- **syncPrepend**: Prefix for auto-generated sync directory (default: `"claude-"`)
- **mounted**: Directory name under `/home/<user>/` where files will be mounted (default: `"claude"`)
  - Note: Default is `"claude"`, NOT the source directory name
- **showBanner**: Show ASCII art banner on startup (default: `true`)
  - Set to `false` to disable, or use `--no-banner` CLI flag

**Network Restriction Options** (optional - defense in depth):

- **networkMode**: Network isolation mode (default: `"disabled"`)
  - Options: `"disabled"`, `"allowlist"`, or `"blocklist"`
  - `"disabled"`: No OS-level network restrictions (relies on Claude Code's sandbox)
  - `"allowlist"`: Only allow specific connections (deny everything else)
  - `"blocklist"`: Block specific connections (allow everything else)
  - Note: In single-user mode, network rules are shared across all projects and persist until the last instance exits. In per-project mode, each project gets its own network rules.

**Allowlist Mode Options** (only apply when `networkMode = "allowlist"`):

- **allowedDomains**: Array of domains to allow (e.g., `["github.com:443", "npmjs.org"]`)
  - Format: `"domain:port"` or `"domain:port1,port2"` or just `"domain"` (all ports)
  - Claude's required domains are always allowed: `api.anthropic.com`, `claude.ai`, `statsig.anthropic.com`, `sentry.io`
- **allowedIPs**: Array of IP addresses to allow (e.g., `["127.0.0.1:5432", "1.2.3.4"]`)
  - Format: `"ip:port"` or `"ip:port1,port2"` or just `"ip"` (all ports)
- **allowedNetworks**: Array of IP ranges to allow (e.g., `["192.168.1.0/24:443", "10.0.0.0/8"]`)
  - Format: `"network/cidr:port"` or `"network/cidr"` (all ports)

**Blocklist Mode Options** (only apply when `networkMode = "blocklist"`):

- **blockDomains**: Array of domains to block (e.g., `["internal.company.com", "twitter.com:443"]`)
  - Format: Same as `allowedDomains`
- **blockIPs**: Array of IP addresses to block (e.g., `["169.254.169.254", "192.168.1.100:22"]`)
  - Format: Same as `allowedIPs`
- **blockNetworks**: Array of IP ranges to block (e.g., `["127.0.0.1", "192.168.0.0/16", "10.0.0.0/8"]`)
  - Format: Same as `allowedNetworks`

**Blocklist Exceptions:**
- In blocklist mode, you can use `allowedDomains`, `allowedIPs`, and `allowedNetworks` to create exceptions
- Exceptions are processed first, then blocks are applied
- Example: Block all localhost except PostgreSQL on port 5432
  ```lua
  networkMode = "blocklist",
  blockIPs = { "127.0.0.1" },
  allowedIPs = { "127.0.0.1:5432" }  -- Exception
  ```

**Port Specification:**
- No port specified: `"example.com"` - All ports allowed/blocked
- Single port: `"example.com:443"` - Only port 443
- Multiple ports: `"example.com:80,443,8080"` - Only ports 80, 443, and 8080
- Applies to both TCP and UDP protocols

See "Network Restriction Options (Optional - Defense in Depth)" section below for detailed examples and usage.

**Exclude Options** (all optional, all important):

- **excludePath**: Ignore exact paths (e.g., `["target", ".env"]`)
- **excludeName**: Ignore by name anywhere (e.g., `["*.tmp", "node_modules"]`)
- **excludeRegex**: Ignore by regex pattern (e.g., `[".*\\.log$"]`)
- **belowPath**: Ignore entire directory trees (e.g., `["build/"]` ignores everything below 'build')

#### ⚠️ Important: Build Processes Can Copy Excluded Files

Listen carefully. **Excluded files don't get synced** - they literally don't exist in Claude's view. But that protection only works if the files **stay** excluded.

**The problem:** Build processes, bundlers, and deployment scripts can **transform or embed** excluded files into different files:

```
You exclude:     config/secrets.json (using excludePath)
Build reads it:  webpack reads config/secrets.json
Build writes:    webpack bundles it into dist/app.bundle.js
Claude sees:     dist/app.bundle.js (different name, different location - not excluded!)
```

Or even worse:

```
You exclude:     .env
Build process:   Reads .env, inlines values into dist/config.js as:
                 export const API_KEY = "secret123"
Claude sees:     dist/config.js (secrets are now embedded in code!)
```

**What you need to do:**
1. **Audit your build processes** - Look at webpack configs, Docker builds, deployment scripts
2. **Check what gets copied** - Does your bundler copy `.env` files? Does your build include credentials?
3. **Exclude the output too** - If builds copy secrets to `dist/`, exclude `dist/` as well
4. **Test it** - Run your build on the source side, check what appears in the sync directory

**Common gotchas:**
- Webpack copying `.env` files to output directory
- Docker builds that `COPY` everything including secrets
- Test fixtures that duplicate sensitive files
- Build scripts that concatenate config files
- CI/CD configs embedded in build artifacts

**The rule:** If a file can end up in a non-excluded location through any automated process, that location needs to be excluded too. Or that process needs to be prevented from running.

See "Common Exclude Patterns" section below for examples of how to keep the bad stuff out.

#### Network Restriction Options (Optional - Defense in Depth)

claude-cage can add OS-level network restrictions on top of Claude Code's application-level sandbox. This provides defense in depth - if one layer fails, the other still protects you.

**Three modes:**

- **`networkMode = "disabled"`** (default) - No OS-level network restrictions
- **`networkMode = "allowlist"`** - Only allow specific IPs/domains (deny everything else)
- **`networkMode = "blocklist"`** - Block specific IPs/domains (allow everything else)

**Allowlist Mode** - Lock it down tight:

```lua
claude_cage {
    networkMode = "allowlist",

    -- These domains are ALWAYS allowed in allowlist mode:
    -- api.anthropic.com, claude.ai, statsig.anthropic.com, sentry.io

    -- Add additional domains Claude can connect to
    allowedDomains = {
        "github.com:443",              -- Only HTTPS
        "registry.npmjs.org:443",      -- Only HTTPS
        "pypi.org"                     -- All ports
    },

    -- Specific IPs with optional port restrictions
    allowedIPs = {
        "1.2.3.4:80,443",              -- Only HTTP and HTTPS
        "127.0.0.1:5432",              -- Localhost PostgreSQL only
        "5.6.7.8"                      -- All ports
    },

    -- IP ranges with optional port restrictions
    allowedNetworks = {
        "10.0.0.0/24:443",             -- Internal network, HTTPS only
        "192.168.1.0/24"               -- All ports
    },
}
```

**Blocklist Mode** - Keep Claude away from your internal infrastructure:

```lua
claude_cage {
    networkMode = "blocklist",

    -- Block internal networks (all ports or specific ports)
    blockNetworks = {
        "192.168.1.0/24",              -- Entire home network, all ports
        "10.0.0.0/8:22,3389"           -- Corporate network, SSH and RDP only
    },

    -- Block specific sensitive servers
    blockIPs = {
        "169.254.169.254",             -- AWS metadata service, all ports
        "192.168.1.100:5432",          -- Production database port only
        "192.168.1.101:22"             -- Block SSH to production server
    },

    -- Block internal domains
    blockDomains = {
        "internal.company.com",        -- All ports
        "vault.company.com:443",       -- HTTPS only
        "admin.local:80,443"           -- HTTP and HTTPS
    }
}
```

**Blocklist Exceptions** - Allow specific connections even when blocked:

You can use `allowedDomains`, `allowedIPs`, and `allowedNetworks` in blocklist mode to create exceptions. This is useful when you want to block an entire network but allow specific services.

```lua
claude_cage {
    networkMode = "blocklist",

    -- Block all localhost connections
    blockIPs = { "127.0.0.1" },

    -- Except allow PostgreSQL on port 5432
    allowedIPs = { "127.0.0.1:5432" },
}
```

Another example - block a private network but allow specific development servers:

```lua
claude_cage {
    networkMode = "blocklist",

    -- Block entire corporate network
    blockNetworks = { "192.168.0.0/16" },

    -- But allow specific development servers
    allowedIPs = {
        "192.168.1.50:3000",           -- Dev server 1
        "192.168.1.51:8080"            -- Dev server 2
    }
}
```

Exceptions are processed first (as ACCEPT rules), then block rules are applied. This follows iptables rule ordering.

**Port Specification:**

You can optionally specify ports for fine-grained control:

- **No port** - `"1.2.3.4"` - All ports (TCP and UDP)
- **Single port** - `"1.2.3.4:443"` - Only port 443
- **Multiple ports** - `"1.2.3.4:80,443,8080"` - Only ports 80, 443, and 8080

Port restrictions apply to both TCP and UDP protocols.

**Common port numbers:**
- `80` - HTTP
- `443` - HTTPS
- `22` - SSH
- `3389` - RDP (Remote Desktop)
- `5432` - PostgreSQL
- `3306` - MySQL
- `27017` - MongoDB

**When to use each mode:**

- **disabled**: You're already using Claude Code's sandbox and trust it completely
- **allowlist**: Maximum security - you want complete control over every connection
- **blocklist**: Practical security - let Claude access the internet but protect specific internal resources

**Important notes:**

- Allowlist mode will break WebFetch, package managers, and git unless you explicitly allow those domains
- Blocklist mode is more usable - Claude can still access docs, packages, and APIs
- Both modes provide defense in depth alongside Claude Code's sandbox
- Network restrictions apply to the entire `claude` user, not just one instance
- Port restrictions work with IPs, domains, and networks

See "Defense in Depth" section below for how this works with Claude Code's sandbox.

### Config Merging

- **Simple values** (user, source, etc.): Later configs override earlier ones
- **Arrays** (all exclude options): Values get **merged** across all config levels

Example: System config has `excludePath = [".git"]` and local config has `excludePath = ["secrets.txt"]`. Final result? Both get excluded: `[".git", "secrets.txt"]`.

### Single-User vs Per-Project Mode

Now listen up. This thing's got two ways to run, and you gotta pick the one that makes sense for your operation.

**Single-User Mode** (default - `userMode = "single"`):
- One user for all your projects: `claude`
- Home directory where it belongs: `/home/claude/`
- Network rules shared and **cumulative** across everything you're runnin'
  - First project sets up its rules
  - Second project adds its rules to the existing chain
  - Both projects get access to the union of all rules
  - Rules stick around till the last instance shuts down
- **Here's the important part**: Login to Claude Code once, you're done. Works for every project.
- Simple. Clean. Efficient.
- Use this when: You ain't got a reason not to

**Per-Project Mode** (`userMode = "per-project"`):
- Each project gets its own user: `claude-projectname`
- Home directories tucked away in `/home/.claude-cage/`
- Each project's got its own isolated network restrictions
- Clean slate when you exit - user and rules get wiped
- Use this when: You need different security rules for different projects

#### Network Rules in Single-User Mode

Here's how network restrictions work when you're runnin' multiple projects in single-user mode:

**Cumulative Rules:**
- All network rules from all running projects get combined into one shared chain
- Example:
  - Project 1 starts with allowlist: `["github.com"]`
  - Project 2 starts with allowlist: `["npmjs.org"]`
  - Result: Both projects can access `github.com` AND `npmjs.org`
- In allowlist mode: Each project adds to the list of allowed connections
- In blocklist mode: Each project adds to the list of blocked connections
- This makes sense - they're all runnin' as the same user anyway

**Important:**
- The first project to start sets the `networkMode` (allowlist or blocklist)
- Subsequent projects should use the same mode - mixin' modes don't make sense
- Rules persist until the last instance exits
- When all instances shut down, the chain gets cleaned up

#### ⚠️ Now Here's What You Need to Understand About Per-Project Mode

**The authentication situation:**
- Every new project user needs its own Claude Code login. Every. Single. One.
- Claude Code ties authentication to the user account - that's just how it is
- Config syncing don't solve this. You still gotta authenticate.
- You got ten projects? That's ten logins. Gets old real fast.

**When you'd use per-project mode anyway:**
- You need hard network isolation - completely different allowlist/blocklist for each project
- Security-sensitive work that needs completely separate environments
- You're willin' to deal with the login hassle for that extra layer of protection

**Example configurations:**

Single-user (default):
```lua
claude_cage {
    project = "backend",  -- Uses user "claude" for all projects
}
```

Per-project mode:
```lua
claude_cage {
    project = "backend",
    userMode = "per-project",  -- Creates user "claude-backend"
}
```

Custom suffix in per-project mode:
```lua
claude_cage {
    project = "backend",
    userMode = "per-project",
    userAppend = "prod",  -- Creates user "claude-prod" instead of "claude-backend"
}
```

## Usage

### First Run

First time you run this, if the user don't exist, you'll see this:

```
User 'claude' does not exist.
Create user 'claude'? [y/N]
```

The user gets created with `--disabled-password` and `/bin/bash` shell - no password login, but can still run processes through `su`. That's how we launch Claude Code. Controlled access.

**Claude Code Configuration Sync:**

If you have Claude Code configured on your account (logged in, with settings, chat history, etc.), claude-cage automatically sets up bidirectional synchronization of your `~/.claude` directory:

- Your authentication and settings are available to the caged user
- No need to log in again
- Chat history syncs between both users
- Any settings changes or conversations sync back to your original user
- Uses unison watch mode for real-time synchronization

This means you can use Claude Code in the cage with all your existing configuration, and everything stays synchronized.

### Basic Usage

Run from the directory with your `claude-cage.config`:

```bash
sudo claude-cage
```

### Override Source Directory

You can override the source directory from the config. Useful if you're runnin' claude-cage from a directory that's got access to multiple projects, but you only want to open one:

```bash
cd public
sudo claude-cage mail-mime-parser
```

### Test Mode

Test mode sets up the entire environment but switches you to an interactive bash shell instead of launching Claude Code. Perfect for verifying your configuration, testing network restrictions, or debugging issues:

```bash
sudo claude-cage --test
```

This will:
- Create the user (if needed)
- Set up file synchronization with unison
- Apply network restrictions
- Mount the directory with bindfs
- Drop you into a bash shell as the configured user

When you're done testing, type `exit` to trigger cleanup (unmount, network rule cleanup, optional user deletion).

You can combine `--test` with a source directory override:

```bash
sudo claude-cage --test my-project
```

### Cleanup Mode

If the cleanup process didn't run properly (e.g., the script was killed unexpectedly), you can manually clean up with:

```bash
sudo claude-cage --cleanup
```

This will:
- Stop processes tracked in `claude-cage.pid` file
- Unmount any bindfs mounts for the configured user
- Remove iptables rules created by claude-cage
- Prompt whether to delete the user account

This is useful when:
- The script was interrupted and cleanup didn't run
- You want to manually tear down the environment
- You're switching projects and want to clean up the old user

**Note:** claude-cage creates `claude-cage.pid` and `claude-cage.instances` files in the working directory to track processes and running instances. Multiple instances can run simultaneously - they will share the same unison/bindfs processes. Cleanup only happens when the last instance exits.

### Excluded Files Check

When you run `claude-cage`, it checks if any files in the sync directory match your exclude patterns. Security sweep. Standard procedure.

This matters when:
- You change your exclude configuration between runs
- Files were previously synced but shouldn't be anymore

If excluded files are found, you'll see this:
```
WARNING: Found files/directories in sync directory that are now excluded:
  - claude-my-directory/target
  - claude-my-directory/.env

These files may have been created in a previous run with different exclude settings.
They should be removed from the sync directory before continuing.

Remove these files? [y/N]
```

Choose `y` to remove 'em automatically, or `N` to exit and handle it yourself. Your call.

## Recommended: Use Sandbox Mode

For additional security and fewer permission prompts, enable Claude Code's sandbox mode:

```bash
/sandbox
```

Sandbox mode gives you:
- **Network isolation**: Claude can only connect to approved servers
- **84% fewer permission prompts** (based on Anthropic's internal usage)
- **Auto-allow mode**: Bash commands run automatically inside the sandbox

Learn more: [https://code.claude.com/docs/en/sandboxing](https://code.claude.com/docs/en/sandboxing)

## Defense in Depth: claude-cage + Sandbox Mode

Here's what you gotta understand about security - you don't rely on one lock. You use multiple locks. Each one watchin' the other's back.

### How claude-cage Isolation Works

**claude-cage provides OS-level user isolation** that's fundamentally different from application-level sandboxing:

1. **Separate Linux User Account**
   - Claude runs as a different user (`claude`) with its own UID/GID
   - Even if Claude Code has a bug or escapes its sandbox, it's still constrained by Linux kernel permissions
   - Can't access files owned by other users unless explicitly granted
   - The OS kernel itself enforces the isolation - that's hardware-level security

2. **File Exclusion at Sync Level**
   - Files matching your exclude patterns **never get synced** to the working directory
   - They literally don't exist in Claude's view - can't be read, can't be written, can't be accidentally leaked
   - Source of truth stays in your directory; Claude works on a filtered copy

3. **Permission Mapping**
   - Files created by the `claude` user automatically appear as owned by you in the source
   - No permission issues, no ownership conflicts
   - Everything just works when files sync back

4. **Independent of Claude Code**
   - Works regardless of what software runs inside
   - Isolation persists even if Claude Code is buggy or compromised
   - You control the isolation mechanism at the OS level

### Claude Code's Sandbox

**Claude Code's sandbox (bubblewrap on Linux)** provides application-level isolation:

- Filesystem restrictions within the working directory
- Network isolation through proxy + domain allowlisting
- Process isolation for spawned commands
- 84% fewer permission prompts

### Using Both Together (Recommended)

The smart move? Use **both layers**:

```
Layer 1: OS User Isolation (claude-cage)
    └─> Layer 2: Application Sandbox (Claude Code)
        └─> Layer 3: Claude AI Safety Training
```

**What this gives you:**
- If Claude Code's sandbox has a bug → Linux user permissions still contain it
- If someone compromises the claude user → They still can't access excluded files (they were never synced)
- If there's a privilege escalation attempt → Multiple barriers to get through
- Each layer is independent - failure of one doesn't compromise the others

**Real talk:** Defense in depth ain't paranoia. It's insurance. And when you're lettin' an AI modify your code, you want all the insurance you can get.

## How It Works

Here's the play-by-play:

1. **Unison** runs in watch mode, continuously syncing `source` ↔ `sync` directories
2. **Unison** also syncs `~/.claude` (if it exists) between your user and the cage user
   - Your Claude Code authentication, settings, and history stay synchronized
   - No need to log in again inside the cage
   - Changes sync bidirectionally in real-time
3. **Bindfs** mounts the sync directory with permission mapping:
   - Files created by the Claude user appear as owned by you
   - Ensures proper permissions when files sync back to source
4. **Claude Code** runs in the mounted directory, working on your files
5. **All changes sync bidirectionally** in real-time

Multiple layers. Each one doin' its job. That's how you keep things under control.

## Example Workflow

1. Configure your project:
   ```lua
   claude_cage {
       source = "my-web-app",
       excludePath = { ".env", "dist" },
       belowPath = { "node_modules" }
   }
   ```

2. Run claude-cage:
   ```bash
   sudo ./claude-cage
   ```

3. If you're already logged into Claude Code on your account:
   - Your `~/.claude` config automatically syncs to the cage user
   - No need to log in again
   - Your chat history and settings are available

4. Claude Code starts in `/home/claude/my-web-app`
5. Make your changes with Claude Code
6. File changes automatically appear in `./my-web-app`
7. Settings changes and chat history sync back to your `~/.claude`

Simple. Effective. Controlled.

## Common Exclude Patterns

Here's what you need to know about keepin' things out:

```lua
-- Build artifacts at specific paths
-- Useful so Claude can build its own versions without messin' with yours
excludePath = { "target", "build", "dist", "out" }

-- Secrets at specific locations
-- This is important. Real important.
excludePath = { ".env", "credentials.json" }

-- IDE files at specific locations
excludePath = { ".idea", ".vscode" }

-- Temporary files by name anywhere in the tree
excludeName = { "*.tmp", "*.swp", ".DS_Store" }

-- Node modules or large dependency folders (ignore entire tree)
belowPath = { "node_modules", "vendor" }

-- Log files using regex
excludeRegex = { ".*\\.log$", ".*\\.log\\..*" }

-- Comprehensive example combining multiple types
-- This is how you do it right
excludePath = {
    "target",
    ".env",
    "src/main/resources/application-local.properties"
}
excludeName = {
    "*.tmp",
    ".DS_Store"
}
belowPath = {
    "node_modules"
}
excludeRegex = {
    ".*\\.log$"
}

-- Protecting against build processes that copy secrets
-- If your webpack/bundler copies .env to dist/, you need to exclude BOTH
excludePath = {
    ".env",                    -- Source secret file
    "dist",                    -- Build output that might contain copied secrets
    "build",                   -- Another common build output
    "public/config"            -- Bundled config that might include secrets
}

-- Docker project with secrets
excludePath = {
    ".env",
    "secrets/",
    "docker-compose.override.yml"
}
belowPath = {
    "dist",                    -- Exclude entire build output
    ".docker"                  -- Docker build context might copy secrets
}
```

### Choosing the Right Exclude Type

- Use **excludePath** for specific files/directories at known locations
- Use **excludeName** for files that appear in multiple places with the same name
- Use **belowPath** for entire directory trees (more efficient than excludePath)
- Use **excludeRegex** for complex patterns that wildcards can't handle

Each tool for its purpose. Use 'em right.

## Troubleshooting

**Error: lua is required but not installed**
```bash
sudo apt install lua
```

**Error: No file monitoring helper program found (from unison)**
- This means inotify-tools is not installed
- Unison's watch mode requires inotify to efficiently monitor file changes
- Install it with:
```bash
sudo apt install inotify-tools
```

**Error: source directory does not exist**
- Check that the source directory exists in the current directory
- Or provide the correct path as a command-line argument

**Permission issues**
- Ensure you run with `sudo`
- This thing needs root access for bindfs mounting. That's just how it is.

## License

BSD 2-Clause

---

*"Put... the bunny... back... in the box."* - Oh wait, wrong README. But you get the idea. Keep your files safe. Use the cage.
