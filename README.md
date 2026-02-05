# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

You're lettin' an AI agent loose on your codebase. That's a lot of trust. Maybe more than you should be givin' out.

**claude-cage** locks things down with multiple layers of security. Your filesystem, your network, your sensitive files—protected. The sandbox runs locally, not on some third-party cloud. Your secrets stay home while your code does the traveling.

## Three Layers of Protection

1. **File Exclusion** — Sensitive files aren't copied into the sandbox. Not blocked from reading—*never there in the first place*. No `.env`, no credentials, no git history of secrets.

2. **Filesystem Isolation** — The sandbox can't see your home directory, SSH keys, or AWS credentials. Claude works in a clean room.

3. **Network Filtering** — Control what Claude can reach. Allowlist mode for lockdown. Blocklist mode to block your internal infrastructure. No sudo required.

## What You Get

- **Auto-sync on push** — Claude's commits flow back to your source branch automatically
- **Parallel agents** — One agent per branch, each with isolated cache directories
- **Runs locally** — The sandbox runs on your machine. No third-party cloud sandbox access to your filesystem.
- **Flexible** — Bubblewrap or Docker on Linux/WSL 2, Docker on macOS

## How It Works

**Three repositories, one purpose:**

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│     SOURCE      │ ───> │  INTERMEDIARY   │ ───> │  WORK (Sandbox) │
│  (your repo)    │      │  (sanitized)    │      │  (Claude's copy)│
└─────────────────┘      └─────────────────┘      └─────────────────┘
        │                        │                        │
        │   Secrets excluded     │    Fresh git clone     │
        │   via git archive      │    on 'claude' branch  │
        │                        │                        │
        │<─────────────────────────────────────────────────
                    Claude pushes → patches applied to source
```

1. **Source** - Your actual project with full git history
2. **Intermediary** - Fresh git repo with excluded files stripped out. No history of your secrets.
3. **Work** - Where Claude operates inside the sandbox. Pushes sync back to source.

**Note:** All non-excluded files from your working tree are copied to the intermediary. For large repos, consider running from a subdirectory or using sparse checkout (see [Working with Large Repos](#working-with-large-repos)).

**Git hooks make it work:**

| Hook | Location | What It Does |
|------|----------|--------------|
| `post-receive` | Intermediary | When Claude pushes, generates patches and applies them to the original branch |
| `post-commit` | Source | When you commit, syncs changes to intermediary for Claude to pull |
| `pre-commit` | Source | **Blocks commits that mix excluded and non-excluded files** |

That last one's important. If you try to commit both `.env` and `app.js` together, the hook stops you. Why? Because we can't create a clean patch from a commit that contains secrets. Keep 'em separate.

**Plus optional network isolation** - Allowlist or blocklist mode using iptables. No sudo required.

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
    exclude = { ".env", "secrets/**", "application-*.properties" }
}
```

Run it:

```bash
cd ~/myproject
claude-cage
```

## ⚠️ Now Listen to Me Very Carefully

**This tool syncs changes back to your source repo.** When Claude commits and pushes, those changes come back to the branch you started on. You understand what I'm tellin' you?

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

First time you run `claude-cage`, it'll walk you through creatin' a config file. Or create `.claude-cage` in your project root yourself:

```lua
claude_cage {
    -- Command to run inside the sandbox (can include arguments)
    launch = "claude",  -- or "claude --dangerously-skip-permissions", "aider", etc.

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

    -- Allow sandboxing non-git directories (mounts directly, no sync)
    allowNonGit = true,

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
    },

    -- Block commits with force-added gitignored files (default: true)
    -- Override inside sandbox with: CLAUDE_CAGE_ALLOW_IGNORED=1 git commit
    git = { blockForceAdd = true },
}
```

**Note:** The `additionalMounts` for Claude Code files are required for Claude to run inside the sandbox. Put these in your user config (`~/.config/claude-cage/config`) so they apply to all projects.

**Tip:** The `launch` command can include arguments (e.g., `launch = "claude --dangerously-skip-permissions"`), or you can pass them on the command line. CLI arguments are appended to the launch command.

**Config layering:** Configs are loaded and merged in order:

1. `/etc/claude-cage.conf` (system)
2. `~/.config/claude-cage/config` (user)
3. `includeIf` matches (directory-scoped configs declared in system/user config)
4. `.claude-cage` at git root (project)

Arrays like `exclude` and `additionalMounts` combine across all levels. Scalars like `mode` override (closer configs win).

**Directory-scoped config (`includeIf`):** Got a directory full of projects that share config? Use `includeIf` in your user config instead of scatterin' hidden files around:

```lua
-- ~/.config/claude-cage/config
claude_cage {
    includeIf = {
        { dir = "~/Projects/public", config = "~/Projects/public/claude-cage.config" },
        { dir = "~/Projects/private", config = "~/Projects/private/claude-cage.config" },
    }
}
```

When your CWD is under `~/Projects/public/`, the matching config is loaded. Use a visible filename like `claude-cage.config` so it's easy to spot. Same merge rules apply—arrays combine, scalars override.

**More options:** See [`.claude-cage.example`](.claude-cage.example) for project-level settings and [`examples/`](examples/) for system and user config examples including `includeIf`.


## Usage

```bash
# Basic usage - launches claude inside the sandbox
claude-cage

# Pass arguments through to claude (--continue, --resume, etc.)
claude-cage --continue
claude-cage --resume

# Drop into a shell inside the sandbox (instead of launching claude)
claude-cage --test

# Direct mount - skip git sync, mount source directly
claude-cage --direct-mount

# Preview what would happen (no changes)
claude-cage --dry-run

# Verbose output
claude-cage --verbose

# Manually merge Claude's changes (if autoMerge is off)
claude-cage git-merge

# Clean up cached branches for this project
claude-cage clean                    # Interactive - pick which branch to remove
claude-cage clean --branch main      # Remove specific branch cache
claude-cage clean-all                # Remove all branch caches for this project
```

**Note:** Arguments that aren't recognized by claude-cage are passed through to the launch command. So `claude-cage --resume` runs `claude --resume` inside the sandbox.

**Cleanup:** The `clean` and `clean-all` commands remove cached work/intermediary directories and `.caged/` symlinks. You'll be warned if a branch has uncommitted changes, and asked to confirm before deletion.

## Network Filtering

Network filtering uses iptables to control what Claude can reach. Works in both modes:

- **bwrap mode** — Uses slirp4netns to create an isolated network namespace. No sudo required.
- **Docker mode** — Configures iptables inside the container, then drops privileges before running your command.

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

Prefer Docker, or on macOS where bwrap isn't available:

```lua
claude_cage {
    mode = "docker",
    exclude = { ".env" }
}
```

Network filtering works in Docker mode too—uses iptables with privilege drop after setup.

## Direct Mount Mode

Not every project needs the full git sync workflow. Maybe you're working on open source with no secrets to hide. Maybe you just want to sandbox a directory and protect your network.

**Direct mount** skips the intermediary clone and mounts your source directly:

```bash
# One-off direct mount
claude-cage --direct-mount

# Or set it in config
claude_cage {
    directMount = true
}
```

**What you still get:**
- Filesystem isolation (Claude can't see your home directory, SSH keys, etc.)
- Network filtering (allowlist/blocklist mode)
- Additional mounts you configure

**What you skip:**
- The intermediary/work directory clone
- Git sync and hooks
- File exclusion (everything is mounted directly)

### Use Case: Open Source Projects

Got a directory full of open source projects? No secrets, no problem:

```lua
-- ~/.config/claude-cage/config (user-level)
claude_cage {
    directMount = true,
    networkMode = "allowlist",
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" }
    }
}
```

Claude gets the files, the network is locked down, and your private stuff stays private.

### Use Case: Hybrid Mode

Want git workflow for your main project but also let Claude browse your other repos? Use `isolated = true` with `additionalMounts`:

```lua
claude_cage {
    -- Git sync for this project only
    isolated = true,
    autoMerge = true,

    -- But mount the whole open source directory read-only
    additionalMounts = {
        { source = "~/projects/open-source", mode = "ro" }
    }
}
```

Now you get:
- Full git workflow with parallel agents on your main project
- Read-only access to reference code from other projects
- Claude can look but not touch the other repos

## Parallel Agents

Want multiple Claude instances workin' on different features? Each branch gets its own isolated sandbox:

```bash
# Terminal 1: Agent working on feature-a
git checkout -b feature-a
claude-cage

# Terminal 2: Agent working on feature-b
git checkout -b feature-b
claude-cage
```

**Commits go back to the branch you started on.** Switch branches in your source repo all you want—Claude's work still lands on the original branch.

Each branch maintains separate cache directories (`~/.cache/claude-cage/branches/<branch>/`), so agents can't interfere with each other.

**Multi-project visibility:** If you have multiple projects on the same branch, they can see each other inside the sandbox. Useful for monorepos or related projects. Set `isolated = true` in your config to disable this and only mount the single project.

## Working with Large Repos

**By default, claude-cage copies your entire working tree** (minus excluded files) into the sandbox. For a small project, no big deal. For a massive monorepo? That's a lot of files, a lot of disk space, and a lot of wait time.

Two ways to focus the work:

### Run from a Subdirectory

Just `cd` into the part you care about and run `claude-cage` from there:

```bash
cd ~/massive-monorepo/services/auth
claude-cage
```

Claude only sees `services/auth/`. Your commits sync back to the main repo on the branch you started on. Clean and simple.

### Sparse Checkout

For even more control, use git's sparse checkout to pick exactly what files Claude can see:

```bash
# Clone without checking out files
git clone --no-checkout git@github.com:company/huge-repo.git
cd huge-repo

# Enable sparse checkout
git sparse-checkout init --cone
git sparse-checkout set src/frontend tests/frontend

# Now checkout
git checkout main

# Run claude-cage - only sees frontend code
claude-cage
```

Both approaches work seamlessly. Hooks install at the repo root. Commits sync correctly. Claude works in a focused sandbox without the noise of unrelated code.

**Why this matters:**
- Faster cage setup (less files to copy)
- Smaller context for Claude to reason about
- Keep Claude away from parts of the codebase you don't want touched

## File Locations

**On your machine:**
```
~/.cache/claude-cage/
└── branches/<branch>/
    ├── intermediary/<project-path>/  # Sanitized repo (git origin)
    └── work/<project-path>/          # Claude's working copy

your-project/
├── .claude-cage            # Your config
├── .caged/                 # Optional symlinks (createCagedDir=true)
│   └── <branch>/           # Shortcuts to work/ and intermediary/ in cache
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

## Failed Patch Recovery

Sometimes patches fail to apply—merge conflicts happen. No sweat. Failed patches are saved to `claude-cage-failed-patches/<branch>/` in your project.

Next time you run `claude-cage`, you'll get an interactive prompt:

```
Hold up. You've got failed patches waitin' to be applied:

  main: 2 patch(es)
  feature/login: 1 patch(es)

What do you wanna do?
  1) Apply patches one-by-one
  2) Delete all pending patches
  3) Continue without applyin'
  q) Quit
```

If there's a conflict during apply, you get a shell to resolve it manually.

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
