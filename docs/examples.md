# Examples and Workflows

## Common Exclude Patterns

### Build Artifacts

```lua
-- Build artifacts at specific paths
excludePath = { "target", "build", "dist", "out" }
```

### Secrets and Credentials

```lua
-- Secrets at specific locations
excludePath = { ".env", "credentials.json", "secrets/" }
```

### IDE and Editor Files

```lua
excludePath = { ".idea", ".vscode" }
```

### Temporary Files

```lua
-- Temporary files by name anywhere in the tree
excludeName = { "*.tmp", "*.swp", ".DS_Store", "*~" }
```

### Large Dependency Folders

```lua
-- Node modules or large dependency folders (ignore entire tree)
belowPath = { "node_modules", "vendor", ".venv" }
```

### Log Files

```lua
-- Log files using regex
excludeRegex = { ".*\\.log$", ".*\\.log\\..*" }
```

### Comprehensive Example

```lua
claude_cage {
    project = "my-app",

    excludePath = {
        "target",
        ".env",
        "src/main/resources/application-local.properties"
    },

    excludeName = {
        "*.tmp",
        ".DS_Store"
    },

    belowPath = {
        "node_modules"
    },

    excludeRegex = {
        ".*\\.log$"
    }
}
```

### Protecting Against Build Processes

Build processes can copy excluded files to different locations. Exclude both the source and the output.

```lua
excludePath = {
    ".env",                    -- Source secret file
    "dist",                    -- Build output that might contain copied secrets
    "build",                   -- Another common build output
    "public/config"            -- Bundled config that might include secrets
}
```

### Docker Project

```lua
excludePath = {
    ".env",
    "secrets/",
    "docker-compose.override.yml"
},

belowPath = {
    "dist",                    -- Exclude entire build output
    ".docker"                  -- Docker build context might copy secrets
}
```

## Workflow Examples

### Sync Mode Workflow

**Scenario:** Working on a web application with sensitive environment files.

1. **Configure your project** (`claude-cage.config`):

```lua
claude_cage {
    project = "my-web-app",
    source = "src",

    excludePath = { ".env", "dist" },
    belowPath = { "node_modules" }
}
```

2. **Run claude-cage**:

```bash
sudo ./claude-cage
```

3. **File flow:**
   - Claude works in `/home/claude/caged/`
   - Changes sync bidirectionally
   - `./src` ↔ `./.caged-my-web-app` ↔ `/home/claude/caged/`
   - Sync directory (`.caged-my-web-app`) is hidden

4. **Make changes with Claude Code**

5. **Changes automatically appear in `./src`**

### Direct Mount Mode Workflow

**Scenario:** You have 50 open-source projects totaling 20GB. You want to work on one project without syncing all 20GB.

1. **Set up for a collection of projects** (`claude-cage.config` in `/home/user/Projects/public/`):

```lua
claude_cage {
    project = "public-projects",
    directMount = true
}
```

2. **Run claude-cage, specify which project to start in**:

```bash
cd ~/Projects/public
sudo claude-cage my-web-app
```

3. **File flow:**
   - Claude starts in `/home/claude/public/my-web-app`
   - Changes happen directly to `~/Projects/public/my-web-app`
   - No sync, no duplication
   - Claude can access other projects in `~/Projects/public/` if needed

4. **Make changes with Claude Code**

5. **Changes are immediately in `~/Projects/public/my-web-app`**

## Configuration Examples by Use Case

### Node.js/JavaScript Project

```lua
claude_cage {
    project = "nodejs-app",
    source = ".",

    excludePath = { ".env", "dist", "build" },
    belowPath = { "node_modules" },
    excludeName = { "*.log" },

    networkMode = "blocklist",
    blockIPs = { "127.0.0.1" },
    allowedIPs = { "127.0.0.1:3000" }  -- Allow dev server
}
```

### Python Project

```lua
claude_cage {
    project = "python-app",
    source = ".",

    excludePath = { ".env", "credentials.json" },
    belowPath = { ".venv", "__pycache__", ".pytest_cache" },
    excludeName = { "*.pyc", "*.pyo" },

    networkMode = "blocklist",
    blockNetworks = { "192.168.1.0/24" }
}
```

### Java/Maven Project

```lua
claude_cage {
    project = "java-app",
    source = ".",

    excludePath = {
        "target",
        "src/main/resources/application-local.properties"
    },
    belowPath = { ".m2/repository" },
    excludeName = { "*.class" }
}
```

### Rust Project

```lua
claude_cage {
    project = "rust-app",
    source = ".",

    belowPath = { "target" },
    excludeName = { "*.rlib", "*.rmeta" }
}
```

### Multi-Language Monorepo

```lua
claude_cage {
    project = "monorepo",
    source = ".",

    excludePath = { ".env", "dist", "build" },

    belowPath = {
        "node_modules",        -- JavaScript
        ".venv",               -- Python
        "target",              -- Rust/Java
        "vendor"               -- PHP/Go
    },

    excludeName = {
        "*.pyc",
        "*.class",
        ".DS_Store"
    }
}
```

### Maximum Security Setup

```lua
claude_cage {
    project = "secure-project",
    userMode = "per-project",
    source = "src",

    -- Aggressive file exclusions
    excludePath = {
        ".env",
        "secrets/",
        "credentials/",
        "config/production.yml"
    },

    excludeName = {
        "*secret*",
        "*credential*",
        "*.key",
        "*.pem"
    },

    -- Strict network allowlist
    networkMode = "allowlist",
    allowedDomains = {
        "github.com:443",
        "api.company.com:443"
    }
}
```

### Development with Local Services

```lua
claude_cage {
    project = "fullstack-app",
    source = ".",

    excludePath = { ".env", "dist" },
    belowPath = { "node_modules" },

    -- Block most localhost, allow specific services
    networkMode = "blocklist",
    blockIPs = { "127.0.0.1" },
    allowedIPs = {
        "127.0.0.1:5432",      -- PostgreSQL
        "127.0.0.1:6379",      -- Redis
        "127.0.0.1:3000"       -- Dev server
    }
}
```

### Working with Multiple Projects

**Single-user mode (recommended):**

```lua
-- Project 1: claude-cage.config
claude_cage {
    project = "frontend",
    source = ".",
    mounted = "frontend"
}

-- Project 2: claude-cage.config
claude_cage {
    project = "backend",
    source = ".",
    mounted = "backend"
}
```

Both projects share the same `claude` user. Login once, works for both.

**Per-project mode:**

```lua
-- Project 1: claude-cage.config
claude_cage {
    project = "frontend",
    userMode = "per-project",  -- Creates user "claude-frontend"
    source = "."
}

-- Project 2: claude-cage.config
claude_cage {
    project = "backend",
    userMode = "per-project",  -- Creates user "claude-backend"
    source = "."
}
```

Each project gets its own user and requires separate Claude Code authentication.

## Testing Your Configuration

### Test Mode

```bash
sudo claude-cage --test
```

This sets up the entire environment but drops you into a bash shell instead of launching Claude Code.

**What to test:**

```bash
# Check working directory
pwd

# List files (verify exclusions)
ls -la

# Test network restrictions
curl -I http://127.0.0.1:80 --connect-timeout 2  # Should be blocked if configured
curl -I https://github.com --connect-timeout 2   # Should work

# Check file permissions
touch test.txt
ls -l test.txt  # Should show your username, not claude

# Exit test mode
exit
```

### Verify Exclusions

After running in test mode or normal mode, check what's in the sync directory:

```bash
# Should NOT contain excluded files
ls -la .caged-myproject/

# Check for secrets
grep -r "API_KEY" .caged-myproject/  # Should find nothing if excluded properly
```

### Test Network Rules

In test mode, verify blocked/allowed connections:

```bash
# Test blocked connections (should fail)
curl -I http://192.168.1.100:5432 --connect-timeout 2

# Test allowed connections (should succeed)
curl -I https://api.anthropic.com --connect-timeout 2

# Test port-specific rules
curl -I https://github.com:443 --connect-timeout 2  # Allowed
curl -I http://github.com:80 --connect-timeout 2   # Blocked (if only 443 allowed)
```

## Migration from Direct Execution

If you're currently running Claude Code directly without isolation:

1. **Create a backup:**
   ```bash
   git add .
   git commit -m "Backup before claude-cage migration"
   ```

2. **Create config:**
   ```lua
   claude_cage {
       project = "my-project",
       source = ".",
       excludePath = { ".env" }
   }
   ```

3. **Test first:**
   ```bash
   sudo claude-cage --test
   ```

4. **Run normally:**
   ```bash
   sudo claude-cage
   ```

5. **Verify changes synced back:**
   ```bash
   git status  # Check what changed in your source directory
   ```
