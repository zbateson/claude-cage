# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

Now, I'm gonna tell you about `claude-cage`. It's a bash script that's gonna keep your files locked down tight and your network traffic under control while lettin' Claude Code do its work. Two modes of operation. Multiple layers of protection. Optional network isolation. Multiple barriers between Claude and your personal files, credentials, and secrets. That's how we do this right.

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

No sync. No duplication. Useful when you got yourself a big collection of open-source projects and you ain't gonna copy 20GB just to work on one. But remember - no exclude patterns in this mode. Claude sees everything in your source directory.

**Network Isolation** (optional) - OS-level restrictions on top of Claude Code's sandbox:

- **Allowlist mode**: Lock it down - only approved connections get through
- **Blocklist mode**: Keep Claude away from your internal infrastructure
- **Defense in depth**: Process sandbox plus user-level firewall rules

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

**Supported Platforms:** Linux (Ubuntu/Debian/Fedora/RHEL/CentOS) and macOS

Get your dependencies installed:

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install unison bindfs lua inotify-tools

# RHEL/CentOS/Fedora
sudo yum install unison bindfs lua inotify-tools
```

**macOS:**
```bash
# Using Homebrew
brew install unison bindfs lua macfuse

# Note: macFUSE may require enabling in System Settings > Privacy & Security
```

**⚠️ macOS Warning:** Now I gotta be straight with you - macOS support ain't been tested yet. The code's there, but nobody's taken it for a spin on a Mac. You're flyin' blind on that one, friend. Use at your own risk and let us know if somethin' goes sideways.

**Claude Code:** If Claude Code ain't installed for the cage user, don't worry - the script'll offer to install it for you using the official installer. Just say yes when it asks and we'll get you set up.

## Quick Start

### 1. Install

Alright, let's get you set up.

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

Create `claude-cage.config` in your project root (or parent directory):

**Config file search:** The script searches for `claude-cage.config` starting from your current directory going up the tree. The directory containing the config becomes your "project boundary."

**Sync mode** (for projects with secrets to exclude):
```lua
claude_cage {
    -- project is derived from directory structure - no need to specify!
    exclude = {
        name = { ".env", "node_modules", "dist" },
        belowPath = { ".git" }
    }
}
```

**Important for sync mode:**
- Add `.caged` to your `.gitignore`
- You must run from a **subdirectory** of the config root (not from the same directory)
- `.caged` is automatically excluded to prevent recursion

**Direct mount - workspace mode** (mount entire directory, access sibling projects):
```lua
claude_cage {
    directMount = "workspace"
}
```

**Direct mount - project mode** (mount only the specified project):
```lua
claude_cage {
    directMount = "project"
}
```

**Multi-project workspace** (config at parent level):
```lua
-- ~/Projects/claude-cage.config (shared settings)
claude_cage {
    exclude = {
        name = { ".env", "node_modules" },
        belowPath = { ".git" }
    }
}
```
Then cd into a project and run: `cd ~/Projects/backend && sudo claude-cage`
The project name "backend" is derived automatically from the directory structure.

📖 **[Full Configuration Reference →](docs/configuration.md)**
📖 **[Configuration Examples →](docs/examples.md)**

### 3. Run

Now we're ready to fly.

**Sync mode** (run from a subdirectory of config root):
```bash
cd ~/Projects/myapp              # cd into project subdirectory
sudo claude-cage                 # Project name derived from directory (myapp)
```

**Direct mount mode** (specify subdirectory to start in):
```bash
cd ~/Projects/public
sudo claude-cage my-project      # Argument is subdirectory to start in
```

**Explicit config location:**
```bash
sudo claude-cage --config /path/to/claude-cage.config
```

**Test mode** (verify setup without launching Claude):
```bash
sudo claude-cage --test
```

**Resume previous conversation**:
```bash
sudo claude-cage --continue      # Resume most recent conversation
sudo claude-cage --resume        # Pick from conversation list
```

That's it. Clean and simple.

## Key Features

### File Protection (Sync Mode)

Exclude sensitive files from Claude's view:

```lua
exclude = {
    path = { "config/production.yml" },        -- Specific paths from root
    name = { ".env", "node_modules", "*.pem" }, -- By name anywhere in tree
    belowPath = { ".git" },                    -- Path from root + everything below
    regex = { ".*\\.log$" }                    -- Regex patterns
}
```

**Important:** Files matching exclude patterns are never synced - they literally don't exist in Claude's environment.

### ⚠️ **Watch Your Build Outputs**

Build processes can leak excluded secrets. You exclude `.env`, but webpack bundles it into `dist/bundle.js` - now Claude can read it there. **Exclude build outputs too** if they might contain secrets.

**Git history can also leak.** Secrets in your commit history? Claude can `git show` them. Either exclude `.git` entirely, or scrub your history first with `git-filter-repo`.

📖 **[More on protecting against build processes →](docs/examples.md#protecting-against-build-processes)**

**Recommended excludes:**
```lua
exclude = {
    name = {
        ".env",           -- Environment files (anywhere in tree)
        "secrets.json",   -- Secret files (anywhere)
        "*.key", "*.pem", -- Certificate files (anywhere)
        "node_modules",   -- npm/yarn dependencies (anywhere)
        "target",         -- Maven/Cargo build output (anywhere)
        ".venv",          -- Python virtual environment (anywhere)
        "vendor"          -- PHP/Go dependencies (anywhere)
    },
    belowPath = {
        ".git"            -- Git history at root (Claude can't use git)
    }
}
```

### State Isolation (Sync Mode)

Sync mode's separate copies mean Claude's work doesn't stomp on yours. If you exclude build directories (`target/`, `dist/`), Claude can build in the cage without overwriting your local artifacts that may contain embedded credentials. You can keep working, testing, and verifying locally while Claude works in parallel. Direct mount shares one reality - Claude's builds replace yours.

### Network Restrictions (Optional)

OS-level network controls on top of Claude Code's sandbox:

```lua
networkMode = "blocklist"                     -- or "allowlist"
block = { networks = { "192.168.1.0/24" } }   -- Keep Claude off your LAN
allow = { ips = { "127.0.0.1:5432" } }        -- Exception for PostgreSQL
```

📖 **[Network Security Guide →](docs/network-security.md)**

### User Isolation Modes

**Single-user mode** (default) - All projects share user `claude`. Login once, you're done.

**Per-project mode** - Each project gets its own user (`claude-projectname`). Complete isolation, but gotta login for each.

```lua
userMode = "per-project"   -- Default is "single"
```

## Defense in Depth

Use `claude-cage` alongside Claude Code's sandbox and you got multiple layers:

```
Layer 1: OS User Isolation (claude-cage)
    └─> Layer 2: OS Network Restrictions (iptables/pf)
        └─> Layer 3: Process Sandbox (Claude Code /sandbox)
```

Bug in the sandbox? Linux permissions still contain it. Compromised claude user? They still can't access your excluded files. That's defense in depth.

📖 **[Claude Code sandbox docs →](https://docs.anthropic.com/en/docs/claude-code/security)**

## Documentation

- **[Configuration Reference](docs/configuration.md)** - Every config option, explained
- **[Network Security](docs/network-security.md)** - How to lock down the network
- **[Examples & Workflows](docs/examples.md)** - Common patterns, real use cases
- **[Troubleshooting](docs/troubleshooting.md)** - When things go wrong, start here

## License

BSD 2-Clause

---

*"Put... the bunny... back... in the box."* - Oh wait, wrong README. But you get the idea. Keep your files safe. Use the cage.
