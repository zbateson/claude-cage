# Examples and Workflows

## Common Exclude Patterns

### Build Artifacts

```lua
-- Build artifacts by name (matches anywhere in tree)
exclude = { name = { "target", "build", "dist", "out" } }
```

### Secrets and Credentials

```lua
-- Secret files by name (matches anywhere)
exclude = { name = { ".env", "credentials.json", "secrets.json", "secrets" } }
```

### IDE and Editor Files

```lua
exclude = { name = { ".idea", ".vscode" } }
```

### Temporary Files

```lua
-- Temporary files by name anywhere in the tree
exclude = { name = { "*.tmp", "*.swp", ".DS_Store", "*~" } }
```

### Large Dependency Folders

```lua
-- Exclude by name (matches anywhere in the tree)
-- Use exclude.name, not exclude.belowPath, for directories that can appear in subdirectories
exclude = { name = { "node_modules", "vendor", ".venv", "target", "__pycache__" } }
```

### Log Files

```lua
-- Log files using regex
exclude = { regex = { ".*\\.log$", ".*\\.log\\..*" } }
```

### Comprehensive Example

```lua
claude_cage {
    -- project is derived from directory structure

    exclude = {
        path = {
            "src/main/resources/application-local.properties"  -- Specific path from root
        },
        name = {
            ".env",         -- Can appear anywhere
            "target",       -- Build output can appear anywhere
            "*.tmp",
            ".DS_Store",
            "node_modules"  -- Use exclude.name for dirs that can appear anywhere
        },
        belowPath = {
            ".git"  -- Use belowPath for root-level directories only
        },
        regex = {
            ".*\\.log$"
        }
    }
}
```

### The .git Directory Dilemma

**The problem:** Even if you exclude sensitive files like `.env`, if they're in your git history, Claude can access them through git commands.

```bash
# Claude could run these if .git is synced:
git log --all --full-history -- .env
git show HEAD~10:.env
git stash list
git reflog
```

**Your options:**

1. **Exclude `.git`** (default in example configs)
   ```lua
   exclude = { belowPath = { ".git" } }
   ```
   - **Pro:** Git history is completely inaccessible to Claude
   - **Pro:** Faster sync (no git objects to scan)
   - **Con:** Claude cannot run git commands
   - **Use when:** You have any secrets in git history, or you don't need Claude to use git

2. **Include `.git` (Only if history is clean)**
   ```lua
   -- Don't exclude .git
   ```
   - **Pro:** Claude can run `git status`, `git add`, `git commit`, etc.
   - **Con:** Claude can access entire git history
   - **Use when:** You're absolutely certain no secrets are in git history AND you need Claude to use git
   - **Before doing this:** Run `git log --all -p | grep -i "password\|secret\|api_key"` to check for secrets

3. **Clean git history first, then include `.git`**
   ```bash
   # Use git-filter-repo to purge secrets (recommended)
   git filter-repo --path .env --invert-paths
   git filter-repo --path secrets/ --invert-paths

   # Or use BFG Repo Cleaner (alternative)
   bfg --delete-files .env
   bfg --replace-text passwords.txt

   # Clean up after either method
   git reflog expire --expire=now --all
   git gc --prune=now --aggressive
   ```

**Bottom line:** If you're not 100% sure your git history is clean, exclude `.git`. Claude can still work on your code without git access.

### Protecting Against Build Processes

Build processes can copy excluded files to different locations. Exclude both the source and the output.

```lua
exclude = {
    name = {
        ".env",                    -- Source secret file (can appear anywhere)
        "dist",                    -- Build output that might contain copied secrets
        "build"                    -- Another common build output
    },
    path = {
        "public/config"            -- Specific bundled config path
    }
}
```

### Docker Project

```lua
exclude = {
    path = {
        "secrets/",
        "docker-compose.override.yml"
    },
    name = {
        ".env",                    -- Can appear anywhere
        "dist",                    -- Build output (can appear anywhere)
        ".docker"                  -- Docker build context might copy secrets
    }
}
```

## Workflow Examples

### Sync Mode Workflow

**Scenario:** Working on a web application with sensitive environment files.

1. **Configure your project** (`claude-cage.config` in parent directory):

```lua
claude_cage {
    -- project is derived from directory structure
    exclude = {
        name = { ".env", "node_modules", "dist" },
        belowPath = { ".git" }
    }
}
```

2. **Run claude-cage from project subdirectory**:

```bash
cd ~/Projects/my-web-app
sudo claude-cage
```

3. **File flow:**
   - Claude works in `/home/claude/caged/my-web-app/`
   - Changes sync bidirectionally
   - `~/Projects/my-web-app` ↔ `.caged/my-web-app/sync` ↔ `/home/claude/caged/my-web-app/`
   - Sync directory (`.caged/my-web-app/`) is hidden

4. **Make changes with Claude Code**

5. **Changes automatically appear in `~/Projects/my-web-app`**

### Direct Mount Mode Workflow

**Scenario:** You have 50 open-source projects totaling 20GB. You want to work on one project without syncing all 20GB.

1. **Set up for a collection of projects** (`claude-cage.config` in `/home/user/Projects/public/`):

```lua
-- Workspace mode: Claude can access sibling projects
claude_cage {
    directMount = "workspace"
}

-- Or project mode: Claude isolated to one project
claude_cage {
    directMount = "project"
}
```

2. **Run claude-cage, specify which project to work in**:

```bash
cd ~/Projects/public
sudo claude-cage my-web-app
```

3. **File flow (workspace mode):**
   - Mount point: `/home/claude/caged/public/`
   - Claude starts in `/home/claude/caged/public/my-web-app`
   - Changes happen directly to `~/Projects/public/my-web-app`
   - No sync, no duplication
   - Claude can access other projects in the mount via `cd ..`

3. **File flow (project mode):**
   - Mount point: `/home/claude/caged/my-web-app/`
   - Claude starts at mount root (the project directory)
   - Changes happen directly to `~/Projects/public/my-web-app`
   - No sync, no duplication
   - Claude cannot access sibling projects

4. **Make changes with Claude Code**

5. **Changes are immediately in `~/Projects/public/my-web-app`**

## Configuration Examples by Use Case

### Node.js/JavaScript Project

```lua
claude_cage {
    exclude = {
        name = { ".env", "*.log", "node_modules", "dist", "build" },
        belowPath = { ".git" }
    },

    networkMode = "blocklist",
    block = { ips = { "127.0.0.1" } },
    allow = { ips = { "127.0.0.1:3000" } }  -- Allow dev server
}
```

### Python Project

```lua
claude_cage {
    exclude = {
        name = { ".env", "credentials.json", "*.pyc", "*.pyo", ".venv", "__pycache__", ".pytest_cache" },
        belowPath = { ".git" }
    },

    networkMode = "blocklist",
    block = { networks = { "192.168.1.0/24" } }
}
```

### Java/Maven/Spring Boot Project

```lua
claude_cage {
    exclude = {
        -- Wildcards work in exclude.name
        name = {
            "application-*.properties",
            "application-*.yml",
            "*.class",
            "target",
            ".m2"
        },
        belowPath = { ".git" }
    }
}
```

### Rust Project

```lua
claude_cage {
    exclude = {
        name = { "*.rlib", "*.rmeta", "target" },
        belowPath = { ".git" }
    }
}
```

### Multi-Language Monorepo

```lua
claude_cage {
    exclude = {
        name = {
            ".env",
            "*.pyc",
            "*.class",
            ".DS_Store",
            "node_modules",        -- JavaScript
            ".venv",               -- Python
            "target",              -- Rust/Java
            "vendor",              -- PHP/Go
            "dist",                -- Build output
            "build"                -- Build output
        },
        belowPath = { ".git" }
    }
}
```

### Maximum Security Setup

```lua
claude_cage {
    isolationMode = "docker",  -- Container isolation

    -- Aggressive file exclusions
    exclude = {
        path = {
            "secrets/",
            "credentials/",
            "config/production.yml"
        },
        name = {
            ".env",           -- Can appear anywhere
            "*secret*",
            "*credential*",
            "*.key",
            "*.pem"
        }
    },

    -- Strict network allowlist
    networkMode = "allowlist",
    allow = {
        domains = {
            "github.com:443",
            "api.company.com:443"
        }
    }
}
```

### Development with Local Services

```lua
claude_cage {
    exclude = {
        name = { ".env", "node_modules", "dist" },
        belowPath = { ".git" }
    },

    -- Block most localhost, allow specific services
    networkMode = "blocklist",
    block = { ips = { "127.0.0.1" } },
    allow = {
        ips = {
            "127.0.0.1:5432",      -- PostgreSQL
            "127.0.0.1:6379",      -- Redis
            "127.0.0.1:3000"       -- Dev server
        }
    }
}
```

### Working with Multiple Projects

**Multi-project workspace (shared parent directory):**

```lua
-- ~/Projects/claude-cage.config (shared settings)
claude_cage {
    exclude = {
        name = { ".env", "node_modules" },
        belowPath = { ".git" }
    }
}
```

```lua
-- ~/Projects/frontend.claude-cage.config (optional overrides)
claude_cage {
    -- Project-specific excludes merged with shared config
    exclude = { name = { "dist", ".next" } }
}
```

```lua
-- ~/Projects/backend.claude-cage.config (optional overrides)
claude_cage {
    -- Project-specific excludes merged with shared config
    exclude = { name = { "target", "*.class" } }
}
```

Run by cd'ing into project subdirectory:
```bash
cd ~/Projects/frontend && sudo claude-cage  # Project "frontend" derived from directory
cd ~/Projects/backend && sudo claude-cage   # Project "backend" derived from directory
```

**Separate project directories (different locations):**

```lua
-- ~/frontend/claude-cage.config
claude_cage {
    exclude = { name = { ".env", "node_modules" } }
}

-- ~/backend/claude-cage.config
claude_cage {
    exclude = { name = { ".env", "target" } }
}
```

Run `sudo claude-cage` in each directory. Project name derived from directory. Both share the `claude` user in user mode (default).

**Docker isolation:**

Set `isolationMode = "docker"` for container-based isolation without sudo. Requires Docker group membership.

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
ls -la .caged/myproject/sync/

# Check for secrets
grep -r "API_KEY" .caged/myproject/sync/  # Should find nothing if excluded properly
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
       exclude = { name = { ".env" } }
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
