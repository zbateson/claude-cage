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

3. **Local config** (**required**): `claude-cage.config`
   - Found by searching up the directory tree from current working directory
   - The directory containing this file becomes the "config root"
   - Overrides system and user configs

4. **Project config** (optional): `projectname.claude-cage.config`
   - Project-specific overrides
   - Loaded based on derived project name (first directory component after config root)
   - Example: Running from `~/Projects/backend/src` with config at `~/Projects/claude-cage.config`
     loads `backend.claude-cage.config` if it exists
   - Overrides all other configs

**Config search:** The script searches for `claude-cage.config` starting from your current directory and going up the tree. Use `--config /path/to/config` to specify an explicit location.

**Security note**: A config file is required to prevent accidentally running the script in unintended directories.

### Multi-Project Workspaces

For workspaces containing multiple projects:

1. Create `claude-cage.config` at the parent directory with shared settings
2. Create project-specific configs if needed: `backend.claude-cage.config`, `frontend.claude-cage.config`
3. cd into the project subdirectory and run: `cd backend && sudo claude-cage`

The project name is derived automatically from the directory structure:
- Config at `~/Projects/claude-cage.config`
- Running from `~/Projects/backend/src`
- Project name: `backend` (first directory component after config root)

You can also override the project name:
- Command line argument: `sudo claude-cage backend`
- The `project` field in config file

### Merge Behavior

- **Simple values** (user, source, sync, etc.): Later configs override earlier ones
- **Arrays** (exclude.name, exclude.path, etc., and network arrays): Values are **merged** across all configs

Example: If system config has `exclude = { path = {"config/production.yml"} }` and local config has `exclude = { path = {"deploy/secrets.txt"} }`, the final exclude.path list will be `{"config/production.yml", "deploy/secrets.txt"}`.

## Configuration File Syntax

All config files use Lua syntax and must contain a `claude_cage` block:

```lua
claude_cage {
    -- project is derived from directory structure (optional to specify)
    exclude = {
        name = { ".env", "node_modules" },
        belowPath = { ".git" }
    }
    -- other options...
}
```

## Core Options

### project (optional)

Project name used as identifier.

- **Optional**: Derived from directory structure if not specified
- Derivation: First directory component of path from config root to current directory
- Example: Config at `~/Projects/claude-cage.config`, running from `~/Projects/myapp/src`
  → project = "myapp"
- Command line overrides derived value: `sudo claude-cage backend`
- In sync mode: Used for `sync` directory name and `userAppend` (if per-project mode)
- In direct mount mode: Used as identifier

```lua
project = "backend"  -- Optional: override derived project name
```

**Multi-project workspace usage:**

Create config at parent level, cd into project subdirectory:

```bash
cd ~/Projects/backend    # Project derived as "backend"
sudo claude-cage         # Loads backend.claude-cage.config if exists

cd ~/Projects/frontend   # Project derived as "frontend"
sudo claude-cage         # Loads frontend.claude-cage.config if exists
```

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

### Username Validation

The script automatically validates and sanitizes usernames:

- **Character restrictions**: Only lowercase letters, digits, hyphens, and underscores allowed
- **Starting character**: Must start with a letter or underscore
- **Length limit**: Maximum 32 characters (Linux `useradd` restriction)
- **Trailing characters**: Trailing hyphens/underscores are removed

Invalid characters are replaced with hyphens, and uppercase letters are converted to lowercase. If the username exceeds 32 characters, it will be truncated and a warning displayed.

**Example transformations:**
- `Claude_User` → `claude_user` (lowercase)
- `user@name` → `user-name` (invalid char replaced)
- `claude-my-very-long-project-name-here` → `claude-my-very-long-project-nam` (truncated to 32 chars)

## Mode Selection

### directMount

Mount mode selection.

- Default: `false`
- `false`: Sync mode - creates sync directory with unison, enables file exclusion
- `"workspace"`: Direct mount - mounts entire source directory, Claude can access sibling projects
- `"project"`: Direct mount - mounts only the specified project subdirectory, no sibling access

In direct mount modes, either cd into a project subdirectory or provide a command-line argument specifying the subdirectory to start in.

```lua
directMount = false       -- Sync mode (default)
directMount = "workspace" -- Mount entire source, access siblings
directMount = "project"   -- Mount only the project, isolated
```

**Choosing between modes:**

Beyond file exclusion, sync mode provides **state isolation**. The separate copies mean Claude's builds and generated files don't interfere with yours:

- **Sync mode**: Excluded build directories (`target/`, `dist/`, etc.) stay independent. Claude can build in the cage without overwriting your local build artifacts that may contain embedded credentials or environment-specific config.
- **Direct mount**: Claude works directly on your files. Any builds Claude runs replace your builds. Use this when you don't need exclusions or state separation.

See the README's "State Isolation" section for more details.

## Directory Options

### source

Source directory to sync/mount.

- **Sync mode**: Defaults to the project subdirectory (`config_root/project`)
- **Direct mount workspace**: Defaults to the config root directory
- **Direct mount project**: Defaults to the project subdirectory (`config_root/project`)
- Explicitly set to override the default

```lua
source = "my-directory"  -- Override to use a different subdirectory
```

**Important for sync mode:** You cannot run from the config root directory itself. The script requires you to be in a subdirectory to prevent the `.caged` directory from being synced into itself.

### sync

Sync directory name (ignored in direct mount mode).

- Default: Auto-generated as `.caged/<project>/sync`
- Only used in sync mode
- Structure: `.caged/<project>/sync` and `.caged/<project>/excludes-cache`
- **Important:** Add `.caged` to `.gitignore` if running from within a git repository
- The `.caged` directory is automatically excluded from syncing to prevent recursion

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

All exclude options are grouped under the `exclude` object. Arrays within are merged across all config levels.

**Note:** The `.caged` directory is automatically excluded in sync mode to prevent recursion issues. You don't need to add it to your config.

### exclude

The exclude object contains four types of patterns:

```lua
exclude = {
    path = { "config/production.yml" },     -- Exact paths from root
    name = { ".env", "node_modules" },      -- Names anywhere in tree
    belowPath = { ".git" },                 -- Path + everything below
    regex = { ".*\\.log$" }                 -- Regex patterns
}
```

### exclude.path

Ignore exact paths relative to the replica root.

- Use for: Specific files or directories at known locations
- Unison option: `-ignore "Path <item>"`

```lua
exclude = {
    path = { "config/production.yml", "deploy/secrets.txt" }
}
```

### exclude.name

Ignore files/folders by name anywhere in the directory tree.

- Use for: Files that appear in multiple locations with the same name
- Supports wildcards (shell-style patterns)
- Unison option: `-ignore "Name <item>"`

```lua
exclude = {
    name = { "*.tmp", ".DS_Store", "node_modules" }
}
```

### exclude.regex

Ignore paths matching regular expressions.

- Use for: Complex pattern matching that wildcards can't handle
- Note: Backslashes must be escaped in Lua strings (`\\`)
- Unison option: `-ignore "Regex <item>"`

```lua
exclude = {
    regex = { ".*\\.log$", "^temp/.*" }
}
```

### exclude.belowPath

Ignore a specific path from the root and everything below (inside) it.

- **Important:** `belowPath` only matches paths from the root, not anywhere in the tree
- Use for: Specific directory trees at known root-level locations (like `.git`)
- For directories that can appear anywhere (like `node_modules`), use `exclude.name` instead
- Unison option: `-ignore "BelowPath <item>"`

```lua
exclude = {
    belowPath = { ".git" }  -- Only matches .git at root, not subdirs/frontend/.git
}
```

**Common mistake:** Using `exclude = { belowPath = { "node_modules" } }` only excludes `node_modules` at the root. In monorepos or projects with subdirectories, use `exclude = { name = { "node_modules" } }` to match anywhere.

**Performance note:** When `unison-fsmonitor` is not available, unison falls back to polling mode (checking for changes every second). Large directories can contain thousands of files, making each poll slow. Use `exclude.name` to exclude common large directories like `node_modules`, `target`, `.venv` anywhere in the tree.

### Choosing the Right Exclude Type

- **exclude.path**: Specific files/directories at known paths from root (e.g., `config/production.yml`)
- **exclude.name**: Files/directories by name anywhere in the tree (e.g., `.env`, `node_modules`, `target`)
  - Use wildcards: `*.key`, `application-*.properties`
  - Most common for excluding dependencies and build outputs
- **exclude.belowPath**: Specific path from root and everything below it (e.g., `.git`)
  - Only matches at specified path, not anywhere in tree
  - Use `exclude.name` for directories that can appear in multiple locations
- **exclude.regex**: Complex patterns that wildcards can't handle

## Network Restriction Options

See [Network Security](network-security.md) for detailed documentation.

### networkMode

Network restriction mode.

- Default: `"disabled"`
- Options: `"disabled"`, `"allowlist"`, or `"blocklist"`

```lua
networkMode = "disabled"
```

### Allow Object

Used in allowlist mode (required) or blocklist mode (for exceptions).

```lua
allow = {
    domains = { "github.com:443", "npmjs.org" },
    ips = { "1.2.3.4:80,443", "127.0.0.1:5432" },
    networks = { "10.0.0.0/24:443", "192.168.1.0/24" }
}
```

### Block Object

Only applies when `networkMode = "blocklist"`.

```lua
block = {
    domains = { "internal.company.com", "vault.company.com:443" },
    ips = { "169.254.169.254", "192.168.1.100:5432" },
    networks = { "192.168.1.0/24", "10.0.0.0/8:22,3389" }
}
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
    -- File exclusions
    exclude = {
        name = { ".env", "*.tmp", ".DS_Store", "node_modules", "dist" },
        belowPath = { ".git" }
    },

    -- Network restrictions
    networkMode = "blocklist",
    block = {
        networks = { "192.168.1.0/24" },
        ips = { "127.0.0.1" }
    },
    allow = { ips = { "127.0.0.1:5432" } }  -- Exception for PostgreSQL
}
```

### Direct Mount - Workspace Mode

Mount entire directory, Claude can access sibling projects:

```lua
claude_cage {
    directMount = "workspace",

    -- Network restrictions (optional)
    networkMode = "blocklist",
    block = { ips = { "169.254.169.254" } }  -- Block AWS metadata
}
```

### Direct Mount - Project Mode

Mount only the specified project, no sibling access:

```lua
claude_cage {
    directMount = "project",

    -- Network restrictions (optional)
    networkMode = "blocklist",
    block = { ips = { "169.254.169.254" } }  -- Block AWS metadata
}
```

### Per-Project Mode with Allowlist

```lua
claude_cage {
    userMode = "per-project",

    exclude = {
        name = { ".env", "credentials.json", "secrets" },
        belowPath = { ".git" }
    },

    networkMode = "allowlist",
    allow = {
        domains = { "github.com:443", "api.company.com:443" },
        ips = { "10.0.0.50:5432" }
    }
}
```

### Multi-Project Workspace

**~/Projects/claude-cage.config** (shared settings):
```lua
claude_cage {
    -- Project derived from directory structure when you cd into subdirectory

    -- Shared excludes for all projects
    exclude = {
        name = { ".env", "node_modules", "dist", ".DS_Store" },
        belowPath = { ".git" }
    },

    -- Shared network restrictions
    networkMode = "blocklist",
    block = { ips = { "127.0.0.1" } },
    allow = { ips = { "127.0.0.1:5432" } }  -- PostgreSQL for all projects
}
```

**backend.claude-cage.config** (optional project-specific overrides):
```lua
claude_cage {
    -- Additional backend-specific excludes (merged with shared config)
    exclude = {
        name = { "target", "*.class" }
    }
}
```

**frontend.claude-cage.config** (optional project-specific overrides):
```lua
claude_cage {
    -- Frontend dev server allowed
    allow = { ips = { "127.0.0.1:3000" } }
}
```

**Usage**:
```bash
cd ~/Projects/backend && sudo claude-cage   # Project "backend" derived from directory
cd ~/Projects/frontend && sudo claude-cage  # Project "frontend" derived from directory
```

## Global Configuration

### System Config

Location: `/etc/claude-cage/config`

Use for system-wide defaults that apply to all users.

```lua
-- /etc/claude-cage/config
claude_cage {
    -- Common excludes for all projects
    exclude = {
        name = { ".DS_Store", "*.swp" },
        belowPath = { ".git" }
    },

    -- Default network restrictions
    networkMode = "blocklist",
    block = { ips = { "169.254.169.254" } }  -- Block cloud metadata services
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
    exclude = {
        name = { "*~", ".*.swp" }
    },

    -- Your network preferences
    networkMode = "blocklist",
    block = { networks = { "192.168.1.0/24" } }
}
```

See `examples/example-system-config` and `examples/example-user-config` for templates.

### Claude Code Settings

Location: `~/.config/claude-cage/claude-settings.json`

This file is synced to the caged user's `~/.claude/settings.json` when claude-cage runs. It allows you to configure Claude Code's behavior, including sandbox settings, without needing to manually set them up for each caged user.

The file is only synced if the source is newer than the destination, so manual changes made within the cage are preserved until you update your config.

**Defense in depth:** While Unix permissions should already protect your home directory from the caged user, adding a sandbox deny rule provides a second layer of protection:

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": false
  },
  "permissions": {
    "deny": [
      "Read(/home/YOUR_USERNAME/**)"
    ],
    "allow": [
      "WebSearch",
      "WebFetch"
    ]
  }
}
```

See `claude-settings.json.example` for a template to copy to `~/.config/claude-cage/claude-settings.json`.
