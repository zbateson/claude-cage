# Configuration Reference

## Configuration Hierarchy

claude-cage uses a four-tier configuration system that allows system-wide defaults, per-user preferences, project workspace settings, and project-specific overrides.

Configs are loaded in priority order (later overrides earlier):

1. **System config** (optional): `/etc/claude-cage/config`
   - System-wide defaults for all users
   - Requires root to modify

2. **User config** (optional): `~/.config/claude-cage/config`
   - Per-user preferences
   - Overrides system defaults

3. **Local config** (**required**): `./claude-cage.config`
   - Workspace-level settings (directory where claude-cage runs)
   - Must exist to run the script
   - Overrides system and user configs

4. **Project config** (optional): `projectname.claude-cage.config`
   - Project-specific overrides
   - Loaded when project name specified on command line
   - Example: `backend.claude-cage.config` loaded when running `sudo claude-cage backend`
   - Overrides all other configs

**Security note**: The local config is required to prevent accidentally running the script in unintended directories.

### Multi-Project Workspaces

For workspaces containing multiple projects:

1. Create `claude-cage.config` with shared settings (common excludes, network rules)
2. Create project-specific configs if needed to override workspace settings: `backend.claude-cage.config`, `frontend.claude-cage.config`
3. Run with project name: `sudo claude-cage backend`

The project name can come from either:
- Command line argument (takes precedence): `sudo claude-cage backend`
- The `project` field in `claude-cage.config`

### Merge Behavior

- **Simple values** (user, source, sync, etc.): Later configs override earlier ones
- **Arrays** (excludeName, excludePath, excludeRegex, belowPath, network arrays): Values are **merged** across all configs

Example: If system config has `excludePath = ["config/production.yml"]` and local config has `excludePath = ["deploy/secrets.txt"]`, the final excludePath list will be `["config/production.yml", "deploy/secrets.txt"]`.

## Configuration File Syntax

All config files use Lua syntax and must contain a `claude_cage` block:

```lua
claude_cage {
    project = "myproject",
    -- other options...
}
```

## Core Options

### project (required)

Project name used as identifier.

- **Required**: Must be specified either in config file OR on command line
- Command line takes precedence: `sudo claude-cage backend` overrides config
- In sync mode: Used as default for `userAppend` and `sync` directory name
- In direct mount mode: Used as identifier and for per-project username (if userMode = "per-project")

```lua
project = "backend"
```

**Multi-project workspace usage:**

For workspaces with multiple projects in subdirectories, omit `project` from `claude-cage.config` and specify it on the command line:

```bash
sudo claude-cage backend    # Loads backend.claude-cage.config (if exists)
sudo claude-cage frontend   # Loads frontend.claude-cage.config (if exists)
```

This only applies when the local `claude-cage.config` doesn't specify a project name.

### user

Base user account name to run Claude Code as.

- Default: `"claude"`
- In single-user mode: This is the actual username
- In per-project mode: Combined with `userAppend` to create `user-userAppend`

```lua
user = "claude"
```

### userMode

User isolation mode.

- Default: `"single"`
- Options: `"single"` or `"per-project"`

**Single-user mode (recommended):**
- All projects share one user
- Username: `"claude"` (just the base username)
- User home: `/home/claude/`
- Network rules: Shared across all projects
- Claude Code authentication: Login once, works for all projects

**Per-project mode:**
- Each project gets its own user
- Username: `"claude-myproject"` (user + "-" + userAppend)
- User home: `/home/.claude-cage/claude-myproject/`
- Network rules: Project-specific, cleaned up when project exits
- Claude Code authentication: **Requires login for each new project user**

```lua
userMode = "single"
```

### userAppend

Custom suffix for per-project mode.

- Default: Uses `project` value
- Only applies when `userMode = "per-project"`
- Creates username: `user + "-" + userAppend`

```lua
userMode = "per-project"
userAppend = "custom"  -- Creates user "claude-custom"
```

## Mode Selection

### directMount

Enable direct mount mode.

- Default: `false`
- `false`: Sync mode - creates sync directory with unison
- `true`: Direct mount mode - mounts source directly without syncing

```lua
directMount = false  -- Use sync mode (default)
```

## Directory Options

### source

Source directory to sync/mount.

- In sync mode: Must be specified in config file
- In direct mount mode: Defaults to `"."` (current directory) if not set

```lua
source = "my-directory"
```

### sync

Sync directory name (ignored in direct mount mode).

- Default: Auto-generated as `.caged/project-name/sync`
- If not set and `project` is set: `.caged/project/sync`
- If not set and no `project`: `.caged/source/sync`
- Only used in sync mode
- Structure: `.caged/project-name/sync` and `.caged/project-name/excludes-cache`
- Add `.caged` to `.gitignore` if running from within a git repository

```lua
sync = ".caged/myproject/sync"  -- Only needed if you want to override default
```

### mountBase

Base directory under user home where projects get mounted.

- Default: `"caged"`
- Set to `""` to mount directly under user home without a base directory
- Combined with `mounted` to form full path

```lua
mountBase = "caged"  -- Results in /home/claude/caged/<mounted>/
```

### mounted

Final directory name where Claude works.

- Default: Project name
- This is the actual working directory where Claude starts
- Combined with `mountBase` to form the full path

```lua
mounted = "my-app"  -- With mountBase="caged" → /home/claude/caged/my-app/
```

### showBanner

Show ASCII art banner on startup.

- Default: `true`
- Set to `false` to disable, or use `--no-banner` CLI flag

```lua
showBanner = true
```

## File Exclusion Options (Sync Mode Only)

All exclude options are arrays that can contain multiple patterns. They are merged across all config levels.

### excludePath

Ignore exact paths relative to the replica root.

- Use for: Specific files or directories at known locations
- Unison option: `-ignore "Path <item>"`

```lua
excludePath = { "config/production.yml", "deploy/secrets.txt" }
```

### excludeName

Ignore files/folders by name anywhere in the directory tree.

- Use for: Files that appear in multiple locations with the same name
- Supports wildcards (shell-style patterns)
- Unison option: `-ignore "Name <item>"`

```lua
excludeName = { "*.tmp", ".DS_Store", "node_modules" }
```

### excludeRegex

Ignore paths matching regular expressions.

- Use for: Complex pattern matching that wildcards can't handle
- Note: Backslashes must be escaped in Lua strings (`\\`)
- Unison option: `-ignore "Regex <item>"`

```lua
excludeRegex = { ".*\\.log$", "^temp/.*" }
```

### belowPath

Ignore a specific path from the root and everything below (inside) it.

- **Important:** `belowPath` only matches paths from the root, not anywhere in the tree
- Use for: Specific directory trees at known root-level locations (like `.git`)
- For directories that can appear anywhere (like `node_modules`), use `excludeName` instead
- Unison option: `-ignore "BelowPath <item>"`

```lua
belowPath = { ".git" }  -- Only matches .git at root, not subdirs/frontend/.git
```

**Common mistake:** Using `belowPath = { "node_modules" }` only excludes `node_modules` at the root. In monorepos or projects with subdirectories, use `excludeName = { "node_modules" }` to match anywhere.

**Performance note:** When `unison-fsmonitor` is not available, unison falls back to polling mode (checking for changes every second). Large directories can contain thousands of files, making each poll slow. Use `excludeName` to exclude common large directories like `node_modules`, `target`, `.venv` anywhere in the tree.

### Choosing the Right Exclude Type

- **excludePath**: Specific files/directories at known paths from root (e.g., `config/production.yml`)
- **excludeName**: Files/directories by name anywhere in the tree (e.g., `.env`, `node_modules`, `target`)
  - Use wildcards: `*.key`, `application-*.properties`
  - Most common for excluding dependencies and build outputs
- **belowPath**: Specific path from root and everything below it (e.g., `.git`)
  - Only matches at specified path, not anywhere in tree
  - Use `excludeName` for directories that can appear in multiple locations
- **excludeRegex**: Complex patterns that wildcards can't handle

## Network Restriction Options

See [Network Security](network-security.md) for detailed documentation.

### networkMode

Network restriction mode.

- Default: `"disabled"`
- Options: `"disabled"`, `"allowlist"`, or `"blocklist"`

```lua
networkMode = "disabled"
```

### Allowlist Mode Arrays

Only apply when `networkMode = "allowlist"`.

```lua
allowedDomains = { "github.com:443", "npmjs.org" }
allowedIPs = { "1.2.3.4:80,443", "127.0.0.1:5432" }
allowedNetworks = { "10.0.0.0/24:443", "192.168.1.0/24" }
```

### Blocklist Mode Arrays

Only apply when `networkMode = "blocklist"`.

```lua
blockDomains = { "internal.company.com", "vault.company.com:443" }
blockIPs = { "169.254.169.254", "192.168.1.100:5432" }
blockNetworks = { "192.168.1.0/24", "10.0.0.0/8:22,3389" }
```

### Port Specification Format

- No port: `"example.com"` - All ports
- Single port: `"example.com:443"` - Only port 443
- Multiple ports: `"example.com:80,443,8080"` - Only ports 80, 443, and 8080
- Applies to domains, IPs, and networks
- Affects both TCP and UDP protocols

## Complete Configuration Examples

### Sync Mode with Network Restrictions

```lua
claude_cage {
    project = "my-web-app",
    userMode = "single",
    source = "my-directory",

    -- File exclusions
    excludeName = { ".env", "*.tmp", ".DS_Store", "node_modules", "dist" },
    belowPath = { ".git" },

    -- Network restrictions
    networkMode = "blocklist",
    blockNetworks = { "192.168.1.0/24" },
    blockIPs = { "127.0.0.1" },
    allowedIPs = { "127.0.0.1:5432" }  -- Exception for PostgreSQL
}
```

### Direct Mount Mode

```lua
claude_cage {
    project = "public-projects",
    directMount = true,
    source = ".",
    mounted = "public",

    -- Network restrictions (optional)
    networkMode = "blocklist",
    blockIPs = { "169.254.169.254" }  -- Block AWS metadata
}
```

### Per-Project Mode with Allowlist

```lua
claude_cage {
    project = "secure-project",
    userMode = "per-project",
    source = "src",

    excludeName = { ".env", "credentials.json", "secrets" },
    belowPath = { ".git" },

    networkMode = "allowlist",
    allowedDomains = { "github.com:443", "api.company.com:443" },
    allowedIPs = { "10.0.0.50:5432" }
}
```

### Multi-Project Workspace

**claude-cage.config** (shared settings):
```lua
claude_cage {
    -- No project specified - must provide on command line
    -- source will be overridden by project configs

    -- Shared excludes for all projects
    excludeName = { ".env", "node_modules", "dist", ".DS_Store" },
    belowPath = { ".git" },

    -- Shared network restrictions
    networkMode = "blocklist",
    blockIPs = { "127.0.0.1" },
    allowedIPs = { "127.0.0.1:5432" }  -- PostgreSQL for all projects
}
```

**backend.claude-cage.config**:
```lua
claude_cage {
    source = "backend",
    -- Additional backend-specific excludes
    excludeName = { "target", "*.class" }
}
```

**frontend.claude-cage.config**:
```lua
claude_cage {
    source = "frontend",
    -- Frontend dev server allowed
    allowedIPs = { "127.0.0.1:3000" }
}
```

**Usage**:
```bash
sudo claude-cage backend   # Merges claude-cage.config + backend.claude-cage.config
sudo claude-cage frontend  # Merges claude-cage.config + frontend.claude-cage.config
```

## Global Configuration

### System Config

Location: `/etc/claude-cage/config`

Use for system-wide defaults that apply to all users.

```lua
-- /etc/claude-cage/config
claude_cage {
    -- Common excludes for all projects
    excludeName = { ".DS_Store", "*.swp" },
    excludePath = { ".git" },

    -- Default network restrictions
    networkMode = "blocklist",
    blockIPs = { "169.254.169.254" }  -- Block cloud metadata services
}
```

### User Config

Location: `~/.config/claude-cage/config`

Use for personal preferences that apply to all your projects.

```lua
-- ~/.config/claude-cage/config
claude_cage {
    user = "claude",
    userMode = "single",

    -- Your preferred excludes
    excludeName = { "*~", ".*.swp" },

    -- Your network preferences
    networkMode = "blocklist",
    blockNetworks = { "192.168.1.0/24" }
}
```

See `examples/example-system-config` and `examples/example-user-config` for templates.
