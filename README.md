# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

Now, I'm gonna tell you about `claude-cage`. It's a bash script that's gonna keep your files locked down tight and your network traffic under control while lettin' Claude Code do its work. Two modes of operation. Multiple layers of protection. Optional network isolation. Multiple barriers between your precious code and anything that might go wrong. That's how we do this right.

## What This Thing Does

Listen up. `claude-cage` sets up a containment system with OS-level user isolation. Two modes of operation:

**Sync Mode** (default) - Three-layer file isolation:

1. **Source directory** - That's your actual project files
2. **Sync directory** - A synchronized copy maintained by `unison`, with sensitive files excluded
3. **Mounted directory** - Where Claude Code operates, permission-mapped through `bindfs`

Changes sync bidirectionally between source and sync. Excluded files never make it to Claude's environment - they don't exist in the sync directory.

**Direct Mount Mode** - Two-layer isolation for when you got a whole collection:

1. **Source directory** - Your entire directory tree (like `/home/user/Projects/public/`)
2. **Mounted directory** - Direct bindfs mount with permission mapping

No sync. No duplication. Useful when you got yourself a big collection of open-source projects and you ain't gonna copy 20GB just to work on one. But remember - no exclude patterns in this mode. Claude sees everything.

**Network Isolation** (optional) - OS-level restrictions on top of Claude Code's sandbox:

- **Allowlist mode**: Lock it down - only approved connections get through
- **Blocklist mode**: Keep Claude away from your internal infrastructure
- **Defense in depth**: Application sandbox plus OS-level firewall rules

You don't have to use network restrictions. But they're there if you need 'em.

📖 **[Detailed Architecture & Security Model →](docs/configuration.md)**

## ⚠️ Now Listen to Me Very Carefully

**Sync mode uses bidirectional synchronization.** That means what happens in one place happens in the other. **Including deletions.** You understand what I'm tellin' you? You delete somethin' on one side, it's gone on the other. Gone.

**Before you even think about runnin' this in sync mode:**
- ✅ **Commit and push everything to git** - Every last change. I mean it.
- ✅ **Make yourself a backup** - A real one. The kind that'll still be there when you need it.
- ✅ **Test this on somethin' that don't matter first** - Learn how it works before you bet the farm.
- ✅ **Set up your exclude patterns right** - Protect what needs protectin'.

**Direct mount mode is different:** Changes happen directly to your source files. No sync, so no sync-related deletions to worry about. But here's what you gotta understand - also no file exclusion. Claude can see everything in that mounted tree. Every. Single. File. Only use direct mount with directories containing files you're comfortable exposin'.

If you ain't sure about your setup, you test it on somethin' expendable first. That ain't a suggestion.

### ⚠️ Use At Your Own Risk

Look, I'm gonna level with you here. This tool does what it's designed to do - creates isolation layers, manages permissions, keeps your files separated. But at the end of the day, you're lettin' an AI work on your code. That comes with inherent risks, no matter how many cages you build around it.

**The reality:**
- Nobody likes gettin' caged - not you, not me, not an AI. But layers of security? That's just good practice.
- This script is provided as-is. No warranties. No guarantees.
- You're responsible for your data. Back it up. Use version control. Test on expendable projects first.
- If somethin' goes wrong, that's on you. I gave you the tools. How you use 'em is your call.

Consider this your warning. Proceed accordingly.

![Talk to the hand](https://zbateson.github.io/claude-cage/facepalm-lo.png)

## Prerequisites

**Supported Platforms:** Linux (Ubuntu/Debian/Fedora/RHEL/CentOS)

**Note:** This is a Linux-only operation. While `unison` works on macOS, `bindfs` needs FUSE, and that bird don't fly on Mac anymore.

Get your dependencies installed:

```bash
# Ubuntu/Debian
sudo apt install unison bindfs lua inotify-tools

# RHEL/CentOS/Fedora
sudo yum install unison bindfs lua inotify-tools
```

## Quick Start

### 1. Install

**Option 1: Download script only**
```bash
curl -O https://raw.githubusercontent.com/zbateson/claude-cage/main/claude-cage
chmod +x claude-cage
```

**Option 2: Clone repository**
```bash
git clone https://github.com/zbateson/claude-cage.git
cd claude-cage
chmod +x claude-cage
```

**Optional: Install to PATH**
```bash
sudo cp claude-cage /usr/local/bin/
```

### 2. Configure

Create `claude-cage.config` in your project directory:

**Sync mode** (for single projects with secrets to exclude):
```lua
claude_cage {
    project = "myproject",
    source = ".",
    excludeName = { ".env", "node_modules", "dist" },
    belowPath = { ".git" }
}
```

**Important:** If you run claude-cage from within your git repository, add to `.gitignore`:
```
.caged
```

**Direct mount mode** (for large collections without duplication):
```lua
claude_cage {
    project = "public-projects",
    directMount = true
}
```

**Multi-project workspace** (shared parent directory with multiple projects):
```lua
-- claude-cage.config (shared settings)
claude_cage {
    excludeName = { ".env", "node_modules" },
    belowPath = { ".git" }
}
```
```lua
-- backend.claude-cage.config
claude_cage {
    source = "backend"
}
```
Then run: `sudo claude-cage backend`

📖 **[Full Configuration Reference →](docs/configuration.md)**
📖 **[Configuration Examples →](docs/examples.md)**

### 3. Run

**Sync mode:**
```bash
sudo claude-cage                  # Uses project name from config
sudo claude-cage backend          # Uses backend.claude-cage.config (if exists)
```

**Direct mount mode** (specify subdirectory to start in):
```bash
cd ~/Projects/public
sudo claude-cage my-project
```

**Test mode** (verify setup without launching Claude):
```bash
sudo claude-cage --test
```

That's it. Clean and simple.

## Key Features

### File Protection (Sync Mode)

Exclude sensitive files from Claude's view:

```lua
excludePath = { "config/production.yml" }        -- Specific paths from root
excludeName = { ".env", "node_modules", "*.pem" } -- By name anywhere in tree
belowPath = { ".git" }                           -- Path from root + everything below
excludeRegex = { ".*\\.log$" }                   -- Regex patterns
```

**Important:** Files matching exclude patterns are never synced - they literally don't exist in Claude's environment.

⚠️ **Now listen carefully - this is important:**

**Build processes can copy excluded files to non-excluded locations.** If your webpack/bundler copies `.env` to `dist/`, you need to exclude both. [Learn more →](docs/examples.md#protecting-against-build-processes)

**Git history can leak excluded files.** Even if you exclude `.env` today, if it's in your git history, Claude can dig it up with `git show` or `git log`. You got two choices:
1. **Exclude `.git`** (default) - Claude won't have git access, but won't see your history either.
2. **Include `.git`** - Claude can run git commands, but make damn sure you cleaned secrets from your history first. Use BFG Repo Cleaner or `git filter-branch` if you gotta.

**Recommended excludes for most projects:**
```lua
excludeName = {
    ".env",           -- Environment files (anywhere in tree)
    "secrets.json",   -- Secret files (anywhere)
    "*.key", "*.pem", -- Certificate files (anywhere)
    "node_modules",   -- npm/yarn dependencies (anywhere)
    "target",         -- Maven/Cargo build output (anywhere)
    ".venv",          -- Python virtual environment (anywhere)
    "vendor"          -- PHP/Go dependencies (anywhere)
}
belowPath = {
    ".git"            -- Git history at root (Claude can't use git)
}
```

### Network Restrictions (Optional)

You want to add some OS-level network controls on top? Here's how you do it:

**Blocklist mode** - Keep Claude away from your infrastructure:
```lua
networkMode = "blocklist"
blockNetworks = { "192.168.1.0/24" }          -- Block home network
blockIPs = { "169.254.169.254" }              -- Block AWS metadata
allowedIPs = { "127.0.0.1:5432" }             -- Exception for PostgreSQL
```

**Allowlist mode** - Lock it down tight:
```lua
networkMode = "allowlist"
allowedDomains = { "github.com:443", "npmjs.org:443" }
allowedIPs = { "127.0.0.1:5432" }
```

📖 **[Network Security Guide →](docs/network-security.md)**

### User Isolation Modes

Now listen up. You got two ways to run this operation:

**Single-user mode** (default, recommended):
- All your projects share one user (`claude`)
- Login to Claude Code once, you're done
- Keeps it simple, keeps it clean

**Per-project mode**:
- Each project gets its own user (`claude-projectname`)
- Complete isolation between projects
- Gotta login for each new project

```lua
userMode = "single"        -- Default
-- or
userMode = "per-project"   -- Maximum isolation
```

## Defense in Depth

Now I'm gonna tell you somethin' important. You use `claude-cage` alongside Claude Code's sandbox, you got yourself multiple layers of protection:

```
Layer 1: OS User Isolation (claude-cage)
    └─> Layer 2: OS Network Restrictions (iptables)
        └─> Layer 3: Application Sandbox (Claude Code /sandbox)
            └─> Layer 4: Claude AI Safety Training
```

**What this gives you:**
- Claude Code's sandbox got a bug? Linux user permissions still contain it.
- Someone compromises the claude user? They still can't access your excluded files.
- Privilege escalation attempt? Multiple barriers to get through.

That's defense in depth. That's how you do this right.

Enable Claude Code's sandbox for additional protection:
```bash
/sandbox
```

**Benefits:** Network isolation, 84% fewer permission prompts, auto-allow mode for bash commands.

[Learn more about Claude Code's sandbox →](https://code.claude.com/docs/en/sandboxing)

## Common Commands

```bash
# Run in sync mode
sudo claude-cage

# Run in direct mount mode (specify subdirectory)
sudo claude-cage my-project

# Test configuration without launching Claude
sudo claude-cage --test

# Clean up after interrupted session
sudo claude-cage --cleanup

# Disable banner
sudo claude-cage --no-banner
```

## Documentation

You need more details? I got you covered:

- **[Configuration Reference](docs/configuration.md)** - Every config option, explained
- **[Network Security](docs/network-security.md)** - How to lock down the network
- **[Examples & Workflows](docs/examples.md)** - Common patterns, real use cases
- **[Troubleshooting](docs/troubleshooting.md)** - When things go wrong, start here

## Example Configurations

### Node.js Project with Local DB

```lua
claude_cage {
    project = "webapp",
    source = ".",

    excludeName = { ".env", "node_modules", "dist" },
    belowPath = { ".git" },

    networkMode = "blocklist",
    blockIPs = { "127.0.0.1" },
    allowedIPs = { "127.0.0.1:5432" }  -- PostgreSQL only
}
```

### Multi-Project Collection

```lua
claude_cage {
    project = "open-source",
    directMount = true,

    networkMode = "blocklist",
    blockNetworks = { "192.168.1.0/24" }
}
```

### Maximum Security Setup

```lua
claude_cage {
    project = "production",
    userMode = "per-project",

    excludeName = { ".env", "*secret*", "*.key", "*.pem", "credentials.json", "secrets" },
    belowPath = { ".git" },

    networkMode = "allowlist",
    allowedDomains = { "github.com:443" }
}
```

📖 **[More examples →](docs/examples.md)**

## How It Works

**Sync Mode:**
1. Unison watches and syncs `source` ↔ `sync` directories
2. Bindfs mounts sync directory with permission mapping
3. Claude Code runs in the mounted directory
4. Changes sync bidirectionally in real-time

**Direct Mount Mode:**
1. Bindfs directly mounts source directory with permission mapping
2. Claude Code starts in specified subdirectory
3. Changes happen directly to source files

Multiple layers. Each one doin' its job. That's how you keep things under control.

## Troubleshooting Quick Reference

Things ain't workin' right? Here's what you do:

**Dependencies missing?**
```bash
sudo apt install unison bindfs lua inotify-tools
```

**Permission denied?**
```bash
sudo ./claude-cage  # Needs root for bindfs
```

**Files not syncing?**
- Check your exclude patterns - file might be excluded
- Try restartin': `sudo ./claude-cage`

**Network rules not working?**
```bash
sudo ./claude-cage --cleanup
sudo ./claude-cage
```

📖 **[Full troubleshooting guide →](docs/troubleshooting.md)**

## License

BSD 2-Clause

---

*"Put... the bunny... back... in the box."* - Oh wait, wrong README. But you get the idea. Keep your files safe. Use the cage.
