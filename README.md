# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

Now I'm gonna tell you about `claude-cage`. It's a bash script that's gonna keep your files locked down tight and your network traffic under control while lettin' Claude Code do its work. Two modes of operation. Multiple layers of protection. Optional network isolation. Multiple barriers between Claude and your personal files, credentials, and secrets. That's how we do this right.

## What This Thing Does

Listen up. `claude-cage` creates a sanitized copy of your project usin' git, then runs Claude Code inside a bwrap sandbox. Here's how it works:

**Three-Repository Model:**

1. **Source** - Your actual project with full git history
2. **Intermediary** (`~/.cache/claude-cage/...`) - Fresh git repo with excluded files stripped out. No history of your secrets.
3. **Work** (`~/.cache/claude-cage/...`) - Where Claude operates. Pushes go to intermediary, then sync back to source.

Your `.env` files, credentials, and secrets? They never make it into the cage. Not in the files. Not in the git history. Claude don't even know they exist.

**Network Isolation** (optional) - Keep Claude's network access under control:

- **Allowlist mode**: Only approved connections get through
- **Blocklist mode**: Block specific destinations (like your internal infrastructure)
- Uses slirp4netns for unprivileged network namespaces

## Quick Start

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install bubblewrap slirp4netns

# Install claude-cage
curl -L https://github.com/zbateson/claude-cage/releases/latest/download/claude-cage -o ~/.local/bin/claude-cage && chmod +x ~/.local/bin/claude-cage

# Or clone and build
git clone https://github.com/zbateson/claude-cage.git && cd claude-cage && make
```

Create a config in your project:

```lua
-- ~/myproject/.claude-cage
claude_cage {
    exclude = { ".env", "secrets/**", ".git/config" }
}
```

Run it:

```bash
cd ~/myproject
claude-cage
```

## ⚠️ Now Listen to Me Very Carefully

**This tool syncs changes back to your source repo.** When Claude commits and pushes, those changes come home. You understand what I'm tellin' you?

**Before you run this:**
- ✅ **Commit and push everything to git** - That's your backup right there
- ✅ **Check out a new branch** - Keep Claude's work separate from yours
- ✅ **Set up your exclude patterns right** - Protect what needs protectin'
- ✅ **Test on somethin' expendable first** - Learn how it works before you bet the farm

### ⚠️ Use At Your Own Risk

Look, I'm gonna level with you. This tool does what it's designed to do - strips out your secrets, locks down the sandbox, syncs changes back. But you're still lettin' an AI work on your code.

**The reality:**
- This script is provided as-is. No warranties. No guarantees.
- You're responsible for your data. Back it up. Use version control.
- If somethin' goes wrong, that's on you. I gave you the tools.

Consider yourself warned.

![Talk to the hand](https://zbateson.github.io/claude-cage/facepalm-lo.png)

## Prerequisites

**Platform:** Linux or Windows (WSL 2). macOS requires Docker mode.

**Dependencies:**
```bash
# Ubuntu/Debian
sudo apt install bubblewrap

# For network filtering (optional)
sudo apt install slirp4netns

# Fedora/RHEL
sudo dnf install bubblewrap slirp4netns
```

**Kernel Requirements** (for network filtering):
```bash
# Check if unprivileged user namespaces are enabled
cat /proc/sys/kernel/unprivileged_userns_clone  # Should be 1

# If blocked by AppArmor (Ubuntu 23.10+):
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

## Configuration

Create `.claude-cage` in your project root:

```lua
claude_cage {
    -- Files to exclude (never enter the cage)
    exclude = {
        ".env",
        ".env.*",
        "secrets/**",
        "*.pem",
        "*.key",
    },

    -- Sandbox mode: "bwrap" or "docker"
    mode = "bwrap",

    -- Auto-sync commits back to source
    autoMerge = true,

    -- Required mounts for Claude Code to work inside the sandbox
    additionalMounts = {
        "~/.local/bin/claude",   -- Claude Code binary
        "~/.claude",             -- Claude config directory
        "~/.claude.json",        -- Claude auth/settings
        "~/.gitconfig",          -- Git config (for commits)
    },

    -- Network filtering (optional)
    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" }
    }
}
```

**Note:** The `additionalMounts` for Claude Code files are required for Claude to run inside the sandbox. Put these in your user config (`~/.config/claude-cage/config`) so they apply to all projects.


## Usage

```bash
# Basic usage - creates cage and shows info
./claude-cage

# Drop into sandbox shell for testing
./claude-cage --test

# Preview what would happen (no changes)
./claude-cage --dry-run

# Verbose output
./claude-cage --verbose

# Manually merge Claude's changes
./claude-cage git-merge
```

## How It Works

```
Source Project                    ~/.cache/.../intermediary        ~/.cache/.../work
(your actual repo)                (sanitized, fresh git)           (Claude's workspace)
       │                                   │                              │
       │  git ls-files + tar               │     git clone                │
       │  (excludes applied)               │                              │
       └──────────────────────────────────>│──────────────────────────────>
                                           │                              │
                                           │<────── git push ─────────────┤
                                           │     (Claude commits)         │
                                           │                              │
       │<──── format-patch/git-am ─────────┤                              │
       │     (auto-sync if enabled)        │                              │
```

**Key points:**
- Excluded files are stripped at archive time - no history leaks
- Fresh git init means no trace of secrets in any commit
- Changes sync back via git patches when `autoMerge = true`
- The bwrap sandbox can't see your home directory, SSH keys, or AWS credentials

## Network Filtering

When you enable network filtering, claude-cage uses slirp4netns to create an isolated network namespace, then configures iptables rules inside it. Runs as your regular user.

**Allowlist mode** - Block everything except what you specify:
```lua
networkMode = "allowlist",
allow = {
    domains = { "github.com:443", "registry.npmjs.org:443" },
    networks = { "10.0.0.0/8" }
}
```

**Blocklist mode** - Allow everything except what you block:
```lua
networkMode = "blocklist",
block = {
    domains = { "internal.company.com" },
    ips = { "169.254.169.254" }  -- AWS metadata endpoint
}
```


## Docker Mode

Don't have bwrap? Use Docker instead:

```lua
claude_cage {
    mode = "docker",
    exclude = { ".env" }
}
```

Note: Network filtering in Docker mode uses a different approach (coming soon).

## File Locations

**On your machine:**
```
~/.cache/claude-cage/
└── branches/<branch>/
    ├── intermediary/<project-path>/  # Sanitized repo (git origin)
    └── work/<project-path>/          # Claude's working copy

your-project/
├── .claude-cage            # Your config
└── .git/hooks/             # Hooks added when autoMerge=true
    ├── pre-commit          # Prevents mixing excluded/included files
    └── post-commit         # Syncs your commits to intermediary
```

**Inside the sandbox:**
```
/home/you/your-project/           # Working directory (same path as yours)
/run/home/you/your-project/       # Git origin for pushing
/tmp/claude-cage/pipe             # Hook communication pipe
```

## Troubleshooting

**"Unprivileged user namespaces are not available"**
```bash
# Ubuntu 23.10+ blocks this by default
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

**"slirp4netns not found"**
```bash
sudo apt install slirp4netns
```

**DNS not working inside sandbox**

The sandbox uses slirp4netns DNS at 10.0.2.3. If you're filtering network access, make sure DNS is allowed (it's automatic in allowlist mode).


## Contributing

Contributions welcome. Just remember - commit messages gotta have that Con Air energy.

## License

BSD 2-Clause. See [LICENSE](LICENSE) for details.

---

*"Put... the bunny... back... in the box."* - Oh wait, wrong README. But you get the idea. Keep your files safe. Use the cage.
