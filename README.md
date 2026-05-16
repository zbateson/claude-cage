# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

You're lettin' an AI agent loose on your codebase. That's a lot of trust. Maybe more than you should be givin' out.

**claude-cage** puts Claude to work inside a sandbox. It uses git to clone your project — strippin' out your secrets along the way — and hands Claude that sanitized copy to work on. When Claude makes commits and pushes, those changes sync right back to your real repo. The whole thing runs on your machine, no third-party cloud involved. Your secrets stay home while your code does the travelin'.

But a git clone ain't the whole story. The sandbox also locks down your filesystem and network.

**[Quick Start](#quick-start)** · [Three Layers](#three-layers-of-protection) · [What You Get](#what-you-get) · [How It Works](#how-it-works) · [Prerequisites](#prerequisites) · [Configuration](#configuration) · [Usage](#usage) · [Sessions](#sessions) · [Sync Architecture](#sync-architecture) · [Network Filtering](#network-filtering) · [Docker Mode](#docker-mode) · [Direct Mount](#direct-mount-mode) · [Large Repos](#working-with-large-repos) · [File Locations](#file-locations) · [Recovering Session Work](#recovering-session-work) · [Troubleshooting](#troubleshooting)

## Three Layers of Protection

1. **File Exclusion** — Your sensitive files don't get copied into the sandbox. They're not blocked from readin' — they were *never there in the first place*. No `.env`, no credentials, no git history of secrets.

2. **Filesystem Isolation** — The sandbox can't see your home directory, SSH keys, or AWS credentials. Claude's workin' in a clean room with no windows.

3. **Network Filtering** — You decide what Claude can reach. Lock it down with allowlist mode, or block your internal infrastructure with blocklist mode.

## What You Get

- **Real commit history** — Claude sees your actual git log (configurable depth), not some blank slate with no memory
- **Auto-sync on push** — Claude's commits land on your source repo automatically. Non-active branches by default, active branch if you're feelin' brave.
- **Session management** — Run multiple sessions at once, each in its own workspace. No steppin' on each other's toes.
- **Runs locally** — Everythin' stays on your machine. No third-party cloud touchin' your filesystem.
- **Flexible** — Bubblewrap or Docker on Linux/WSL 2, Docker on macOS

## How It Works

**Three repositories. One purpose. Keep your stuff safe:**

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│     SOURCE      │ ───> │  INTERMEDIARY   │ ───> │  WORK (Sandbox) │
│  (your repo)    │      │  (sanitized)    │      │  (Claude's copy)│
└─────────────────┘      └─────────────────┘      └─────────────────┘
        │                        │                        │
        │   Secrets excluded     │    git clone           │
        │   via fast-export      │    (same branch name)  │
        │   (real commit history)│                        │
        │<─────────────────────────────────────────────────
                    Claude pushes → patches applied to source
```

1. **Source** — Your actual project. The real deal, full git history and all.
2. **Intermediary** — A persistent bare repo with real commit history (configurable depth, default 50). Your excluded files get stripped out durin' `git fast-export` — no secrets touchin' the object store.
3. **Work** — This is Claude's playground inside the sandbox. When Claude pushes, changes sync right back to source.

The intermediary sticks around in `~/.cache/`, shared across all your sessions. It only gets rebuilt when your exclude patterns change — otherwise it's ready to go.

**Git hooks do the heavy liftin':**

| Hook | Location | What It Does |
|------|----------|--------------|
| `post-receive` | Intermediary | When Claude pushes, generates patches and applies them to source |
| `pre-receive` | Intermediary | Guards against branch name collisions with source branches |
| `post-commit` | Source | When you commit, syncs changes to intermediary for Claude to pull |
| `post-merge` | Source | Syncs merge commits (fast-forward and non-fast-forward) |
| `pre-commit` | Work | Blocks commits containing force-added gitignored files (configurable) |
| `pre-merge-commit` | Work | Blocks merges in scoped cages (merges need the full tree) |

**And network isolation if you want it** — Allowlist or blocklist mode usin' iptables. No sudo required.

## Quick Start

```bash
# Install dependencies (Ubuntu/Debian/WSL 2, bwrap mode)
sudo apt install git lua5.4 bubblewrap iptables slirp4netns

# Or use Docker mode instead (macOS/Linux/WSL 2)
# Just need: git, lua, docker, and claude-cage itself

# Install claude-cage
curl -L https://github.com/zbateson/claude-cage/releases/latest/download/claude-cage -o ~/.local/bin/claude-cage && chmod +x ~/.local/bin/claude-cage

# Or clone and build
git clone https://github.com/zbateson/claude-cage.git && cd claude-cage && make
```

Run it:

```bash
cd ~/myproject
claude-cage
```

First time you run it, it'll walk you through settin' up a config. No sweat.

## Now Listen to Me Very Carefully

**This tool syncs changes back to your source repo.** When Claude commits and pushes, those changes come back to the branch you started on. You understand what I'm tellin' you?

**Before you run this:**
- **Commit and push everything to git** — That's your backup right there
- **Check out a new branch** — Keep Claude's work separate from yours
- **Set up your exclude patterns right** — Protect what needs protectin'
- **Test on somethin' expendable first** — Learn how it works before you bet the farm

### Use At Your Own Risk

Look, I'm gonna level with you. This tool does what it's designed to do — strips out your secrets, locks down the sandbox, syncs changes back. But you're still lettin' an AI work on your code.

**The reality:**
- This script is provided as-is. No warranties. No guarantees.
- You're responsible for your data. Back it up. Use version control.
- If somethin' goes wrong, that's on you. I gave you the tools.

Consider yourself warned.

![Talk to the hand](https://zbateson.github.io/claude-cage/facepalm-lo.png)

## Prerequisites

**Platform:** Linux or Windows (WSL 2). macOS? You're gonna need Docker mode.

**Dependencies (bwrap mode):**
```bash
# Ubuntu/Debian/WSL 2
sudo apt install git lua5.4 bubblewrap iptables

# For network filtering (optional)
sudo apt install slirp4netns

# Fedora/RHEL
sudo dnf install git lua bubblewrap iptables slirp4netns
```

**Dependencies (Docker mode):**
```bash
# git, lua, and Docker
sudo apt install git lua5.4
# Install Docker: https://docs.docker.com/get-docker/
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

    -- Gitignored files to carry in/out of the cage (copied at startup/exit)
    -- Git-tracked files are skipped automatically — set it globally and it just works
    carry = { "CLAUDE.md", ".cursorrules" },

    -- Sandbox mode: "bwrap" or "docker"
    mode = "bwrap",

    -- Auto-sync non-active branches back to source in real-time
    autoSync = true,
    -- EXPERIMENTAL: Also sync to active branch (stash/apply/pop)
    -- syncActiveBranch = false,
    -- Copy uncommitted source files into the cage at startup (or use --with-dirty)
    -- bringDirty = false,

    -- Allow sandboxing non-git directories (mounts directly, no sync)
    allowNonGit = true,

    -- Required mounts for Claude Code to work inside the sandbox
    additionalMounts = {
        "~/.local/bin/claude",   -- Claude Code binary
        { source = "~/.claude", mode = "rw" },      -- Claude config (needs write access)
        { source = "~/.claude.json", mode = "rw" },  -- Claude auth/settings
        "~/.gitconfig",          -- Git config (for commits)
    },

    -- Network filtering (optional)
    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" }
    },

    -- Git options
    git = {
        historyDepth = 50,       -- First-parent commits on default branch (default: 50)
        blockForceAdd = true,    -- Block force-added gitignored files (default: true)
    },
}
```

**Note:** Those `additionalMounts` for Claude Code files? Required if you want Claude to actually run inside the sandbox. Stick 'em in your user config (`~/.config/claude-cage/config`) so they apply to all your projects.

**Tip:** The `launch` command can include arguments (e.g., `launch = "claude --dangerously-skip-permissions"`), or just pass 'em on the command line. CLI arguments get tacked onto whatever launch command you've set.

**Config layering:** Configs stack up and merge in order:

1. `/etc/claude-cage.conf` (system)
2. `~/.config/claude-cage/config` (user)
3. `includeIf` matches (directory-scoped configs declared in system/user config)
4. `.claude-cage` at git root (project)

Arrays like `exclude`, `carry`, and `additionalMounts` combine across all levels. Scalars like `mode` get overridden — closer configs win.

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

When your CWD is under `~/Projects/public/`, that config gets pulled in. Use a visible filename like `claude-cage.config` so it's easy to spot. Same merge rules — arrays combine, scalars override.

**Want the full picture?** Check [`.claude-cage.example`](.claude-cage.example) for project-level settings and [`examples/`](examples/) for system and user config examples includin' `includeIf`.


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

# Scoped mode - only export the subdirectory you're in
claude-cage --scoped

# Preview what would happen (no changes)
claude-cage --dry-run

# Verbose output
claude-cage --verbose

# Sync Claude's changes manually (current branch, specific branch, or all)
claude-cage git-merge
claude-cage git-merge feature-branch
claude-cage git-merge --all

# Attach to an existing active session
claude-cage --attach-session                     # Auto-select or prompt
claude-cage --attach-session 2025-02-06_14-30-22      # Specific session

# Clean up cached sessions for this project
claude-cage clean                                # Interactive selection
claude-cage clean 2025-02-06_14-30-22                 # Remove specific session
claude-cage clean --all                          # Remove all sessions
```

**Note:** Anythin' claude-cage doesn't recognize gets passed straight through to the launch command. So `claude-cage --resume` runs `claude --resume` inside the sandbox.

**Cleanup:** The `clean` command wipes out cached work/intermediary directories and `.caged/` symlinks. If a session's got uncommitted changes, you'll hear about it before anythin' gets deleted.

## Sessions

Every time you fire up claude-cage, it creates a session tagged with a timestamp (e.g., `2025-02-06_14-30-22`). Each session gets its own work directory while sharin' the same intermediary repo.

### Session Lifecycle

Here's how it decides what to do when you run `claude-cage`:

1. **Join an active session** — If another project's already runnin' in a session, claude-cage joins it (if `isolated = false`). Your project gets its own work directory inside the same session, and both projects are mounted in the sandbox.
2. **Reuse a clean session** — If there's an inactive session lyin' around with no uncommitted changes, claude-cage takes it over. No sense lettin' it collect dust.
3. **Prompt on dirty sessions** — If the only available session has uncommitted work, you get asked: pick it up, wipe it clean, or start fresh.
4. **Create a new session** — If none of the above apply, a fresh session gets spun up.

### Cross-Project Sharing

By default, sessions are shared across projects. Fire up claude-cage in project A, then fire it up in project B on the same machine — project B joins project A's session. Both work directories get mounted in B's sandbox, so Claude can see and work on both projects at once.

This is handy when your projects talk to each other — a frontend and a backend, a library and the app that uses it. Claude gets the full picture without you havin' to cram everythin' into one repo.

**If you don't want that**, set `isolated = true` in your config. Isolated sessions are fenced off — only the same project with `isolated = true` can reuse or join them. Different projects won't even see 'em.

```lua
claude_cage {
    -- Keep this project's session to itself
    isolated = true,
}
```

### Attach & Multi-Terminal

`--attach-session` lets two terminals share the exact same workspace — same work directory, same session:

```bash
# Terminal 1: Start a session
claude-cage

# Terminal 2: Attach to the same session
claude-cage --attach-session
```

### Session Logs

Every session keeps a log — a little black box of what went down on the way into the cage and what happened behind the scenes while you were in there. You'll find it at `~/.cache/claude-cage/logs/<session-id>.log`.

What's in the log:
- Config and setup output (what got loaded, which session was picked)
- Sync activity — every commit that came or went gets a `[sync]` line
- Sandbox launch and exit markers (with exit code)

What ain't in there: the interactive session itself. Once the sandbox door opens, the log steps aside. It don't record what Claude does inside the cage.

Logs get cleaned up automatically when you run `claude-cage clean`. If you've got `createCagedDir = true`, there's a handy symlink at `.caged/sessions/<session-id>/log` pointin' right at it.

## Sync Architecture

Quick refresher on the three repos (see [How It Works](#how-it-works)):
- **Source** — your actual project
- **Intermediary** — sanitized bare repo in `~/.cache/`, secrets stripped out
- **Work** (the cage) — Claude's copy inside the sandbox

Here's how the sync works. Three tiers. Source → intermediary is always runnin'. The other two? Your call.

| Tier | Direction | Config | Default | Mechanism |
|------|-----------|--------|---------|-----------|
| 1 | Source → intermediary | Always on | — | post-commit/post-merge hooks |
| 2 | Cage → source (non-active branches) | `autoSync` | `true` | Pipe listener + temp-index |
| 3 | Cage → source (active branch) | `syncActiveBranch` | `false` | Pipe listener + stash/apply/pop |

With the defaults, Claude's commits on branches you're *not* sittin' on land automatically via temp-index — no checkout, no conflict risk. Your active branch stays clean until you say otherwise with `claude-cage git-merge`.

### Manual Sync

When `autoSync` is off — or when you just want to control exactly when Claude's work comes home — `git-merge` is your friend. It uses the same format-patch/git-am pipeline as auto-sync, so commits get properly mapped and hooks stay out of the way.

```bash
# Sync current branch (refuses if your tree is dirty)
claude-cage git-merge

# Sync a specific branch
claude-cage git-merge feature-branch

# Sync everything at once
claude-cage git-merge --all
```

**How it works:** `git-merge` walks the intermediary branch, finds what hasn't been synced yet, and applies those commits to your source repo one at a time via `git am --3way`. Same mechanism as auto-sync — just triggered when *you* say so.

**Dirty tree?** If you're mergin' to your current branch and there are uncommitted changes, claude-cage won't touch it. Stash or commit first, then run it again.

**When to use it:**
- `autoSync = false` — You want full control over all branches
- Active branch with `syncActiveBranch = false` (the default) — Auto-sync handles other branches, but your active branch waits for you
- After reviewin' Claude's work — Check the diff first, merge when you're satisfied

### Bringin' Dirty Files Into the Cage

By default, the cage starts from your last committed state — uncommitted edits in your source tree stay put on your side. If you want Claude to see your work-in-progress, opt in:

```bash
# One-off: bring this session's WIP into the cage
claude-cage --with-dirty

# Always-on: set in your .claude-cage config
claude_cage {
    bringDirty = true,
}
```

With `--with-dirty` (or `bringDirty = true`), claude-cage replays your modified, new, and deleted files into the cage's work dir at startup. Excluded patterns and gitignored files stay out, same as always. If the cage already has uncommitted work of its own (a reused dirty session), the carry's skipped so nothin' clobbers it.

**On exit:** if the cage's dirty files all match your source byte-for-byte (Claude didn't touch the WIP you carried in), claude-cage clears the cage out — your source already has every change, so there's nothin' left to preserve. The "leavin' it around" warning only shows when there's genuinely new work in the cage.

When your source is dirty and you didn't pass the flag, you'll see a one-line hint at startup pointin' at the option — no surprises either way.

### Co-Create Workflow (EXPERIMENTAL)

When `syncActiveBranch = true`, you and Claude are workin' the same branch at the same time. Claude's commits get synced back to your source repo automatically — and if you've got uncommitted work sittin' in your tree, claude-cage handles it without blowin' anythin' away.

Pair it with `bringDirty = true` (or `--with-dirty`) if you also want Claude startin' from your WIP. They're independent: sync's about commits flowin' back, carry's about your edits goin' in.

**Here's what happens when Claude pushes:**
1. Claude pushes commits, and claude-cage checks if your workin' tree is dirty
2. If it is: your changes (includin' untracked files) get stashed automatically
3. Claude's commits are applied via `git am --3way`
4. Your stash gets popped right back on top

**When there's a conflict:**
- Claude's commits still land clean on the branch (applied before the stash pop)
- Your workin' tree gets conflict markers — standard git conflict state
- The stash stays put (git don't drop it on a failed pop)
- Sort it out with your usual tools: edit the markers, `git checkout --ours/--theirs`, `git mergetool`, whatever you like
- Once you've cleaned up, run `git stash drop` to toss the stash

**Recommendations:**
- Work on a fresh branch when co-creatin' — keeps things clean if you need to rewind
- Commit your work often so there's less sittin' in the stash

**Known limitations:**
- Stagin' state (what you had `git add`'d vs unstaged) ain't preserved durin' sync — everythin' comes back as unstaged modifications
- This is experimental — back up important uncommitted work before you go trustin' it with your life

## Network Filtering

Network filterin' uses iptables to control what Claude can reach. Works in both modes:

- **bwrap mode** — Uses slirp4netns to create an isolated network namespace. No sudo required.
- **Docker mode** — Configures iptables inside the container, then drops privileges before runnin' your command.

**Allowlist mode** — Lock it all down. Only what you say gets through:
```lua
networkMode = "allowlist",
allow = {
    domains = { "github.com:443", "registry.npmjs.org:443" },
    networks = { "10.0.0.0/8" }
}
```

**Blocklist mode** — Everythin's open except what you nail shut:
```lua
networkMode = "blocklist",
block = {
    domains = { "internal.company.com" },
    ips = { "169.254.169.254" }  -- AWS metadata endpoint
}
```


## Sandbox Security

Under the hood, the sandbox locks down what the AI can see on your host. The two modes handle it differently — because they're built on different foundations.

### Bwrap Mode

Your host system directories (`/etc`, `/usr`, `/bin`, `/lib`, `/lib64`, `/sbin`) are mounted read-only into the sandbox so tools and libraries work. On top of that, sensitive paths get masked — directories become empty tmpfs overlays, files become `/dev/null`. None of the good stuff leaks through.

**Default masked paths:**

| Path | What It Protects |
|------|-----------------|
| `/etc/shadow`, `/etc/gshadow` | Hashed user and group passwords |
| `/etc/sudoers`, `/etc/sudoers.d` | Sudo rules and configuration |
| `/etc/ssl/private` | SSL/TLS private keys (Debian/Ubuntu/Arch) |
| `/etc/pki/tls/private`, `/etc/pki/nssdb` | SSL/TLS private keys and NSS database (RHEL/Fedora) |
| `/etc/letsencrypt` | Let's Encrypt certificates and private keys |
| `/etc/security` | PAM security configuration |
| `/etc/openvpn`, `/etc/wireguard`, `/etc/ipsec.d`, `/etc/ipsec.secrets` | VPN configs, keys, and pre-shared secrets |
| `/etc/NetworkManager/system-connections`, `/etc/wpa_supplicant`, `/etc/ppp` | WiFi passwords and network credentials |
| `/etc/docker` | Docker daemon config and registry auth |
| `/etc/samba` | Samba configuration and credentials |
| `/etc/krb5.keytab` | Kerberos keytab |
| `/etc/machine-id` | Unique machine fingerprint |

Both lists are fully configurable via `bwrap.systemMounts` and `bwrap.maskPaths` in your config. Defaults are written out on first run by the config builder, and arrays merge across config levels — so a system admin can set a base list and you can add more.

```lua
bwrap = {
    systemMounts = { "/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin" },
    maskPaths = {
        "/etc/shadow", "/etc/gshadow",
        -- add your own paths here
    },
},
```

### Docker Mode

Docker containers use the image's own `/etc`, `/usr`, and friends — your host's sensitive files ain't exposed in the first place. Host paths only enter the container through explicit `additionalMounts`. So there's no equivalent `bwrap` config needed for Docker mode.

## Docker Mode

If you prefer Docker — or you're on macOS where bwrap ain't an option:

```lua
claude_cage {
    mode = "docker",
    exclude = { ".env" }
}
```

Network filterin' works in Docker mode too — iptables with a privilege drop after setup. Same deal.

## Direct Mount Mode

Not every project needs the full git sync treatment. Maybe you're workin' on open source with nothin' to hide. Maybe you just want a sandbox around a directory and some network protection.

**Direct mount** skips the intermediary clone and mounts your source straight up:

```bash
# One-off direct mount
claude-cage --direct-mount

# Or set it in config
claude_cage {
    directMount = true
}
```

**What you still get:**
- Filesystem isolation — Claude still can't see your home directory, SSH keys, none of that
- Network filterin' (allowlist/blocklist mode)
- Whatever additional mounts you configure

**What you're skippin':**
- The intermediary/work directory clone
- Git sync and hooks
- File exclusion (everythin's mounted directly)

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

### Use Case: Multi-Project

If both projects use claude-cage, you don't need to do anythin' special. Sessions are shared by default — run claude-cage on your frontend, then run it on your backend, and Claude sees both in the same sandbox with full git sync on each.

### Use Case: Hybrid Mode

Want the full git workflow for your main project but also let Claude peek at repos that *don't* use claude-cage? Use `additionalMounts` to bring 'em along read-only:

```lua
claude_cage {
    additionalMounts = {
        { source = "~/projects/open-source", mode = "ro" }
    }
}
```

Or if you want the main project completely fenced off from other claude-cage sessions, add `isolated = true`:

```lua
claude_cage {
    isolated = true,
    additionalMounts = {
        { source = "~/projects/open-source", mode = "ro" }
    }
}
```

Now you've got:
- Full git workflow on your main project
- Read-only access to reference code from other projects
- Claude can look but can't lay a finger on the other repos

## Working with Large Repos

**By default, claude-cage exports your committed history** (minus excluded files) into the sandbox. Small project? No sweat. Massive monorepo? That's a whole lotta files and a whole lotta waitin'.

Two ways to slim things down:

### Run from a Subdirectory

By default, runnin' `claude-cage` from anywhere inside a git repo sets the cage up at the **git root** and drops you into your invocation subdir once you're inside. Same view as if you'd cd'd up to the root, started the cage, and cd'd back. No data leakage, no nested-repo collisions — just the whole repo with Claude landin' where you were.

```bash
cd ~/myrepo/services/auth
claude-cage     # cage is rooted at ~/myrepo, shell starts in services/auth
```

First time you run claude-cage from a subdir of a fresh repo, you'll get a quick prompt askin' whether you want the whole repo or a scoped run; once the repo's caged (config, cache, anything), the default just kicks in silently.

### Slimmin' Down with --scoped

If your repo's huge and you only care about a subdir, you can scope the export instead. `--scoped` builds an intermediary containin' only that subdirectory — faster to build, less noise for Claude:

```bash
cd ~/massive-monorepo/services/auth
claude-cage --scoped
```

Your commits still sync back to the main repo on the branch you started on.

You can also set it in config:
```lua
git = { scoped = true }
```

**What scoped mode does:**
- Only exports files under the current subdirectory
- Creates its own scoped intermediary (doesn't mess with full-repo cages)
- Blocks merge commits inside the cage (merges need the full tree)
- Gets cleaned up automatically when a broader-scope cage covers the same path

### Exclude What Claude Doesn't Need

Directories like `node_modules`, `vendor`, or `build` are usually `.gitignore`'d, so they won't end up in the cage anyway — claude-cage only exports committed content. But if your repo has large committed directories Claude doesn't need to touch, excludin' them speeds things up:

```lua
exclude = {
    "docs/generated/**",
    "test/fixtures/large-dataset/**",
    "third-party/**",
    "assets/videos/**",
}
```

**Why bother?**
- Faster cage setup — less to haul across
- Smaller context for Claude to chew on
- Keeps Claude's hands off parts of the codebase you don't want touched

## File Locations

**Here's what lives on your machine:**
```
~/.cache/claude-cage/
├── intermediary/<project-path>/          # Shared bare repo (git origin)
├── scoped/<git-root>/<scope>/.bare/      # Scoped bare repo (subdirectory only)
├── logs/<session-id>.log                 # Per-session operational log
└── sessions/
    └── <timestamp>/                      # One per session (e.g., 2025-02-06_14-30-22)
        └── work/<project-path>/          # Claude's working copy

your-project/
├── .claude-cage                          # Your config
├── .caged/                              # Optional symlinks (createCagedDir=true)
│   ├── intermediary → ~/.cache/.../intermediary/<project-path>/
│   ├── sync.log     → ~/.cache/.../intermediary/<project-path>/sync.log
│   └── sessions/
│       └── <timestamp>/
│           ├── work → ~/.cache/.../sessions/<timestamp>/work/<project-path>/
│           └── log  → ~/.cache/.../logs/<session-id>.log
└── .git/hooks/                          # Source hooks always added
    ├── post-commit.d/claude-cage-*      # Syncs your commits to intermediary
    └── post-merge.d/claude-cage-*       # Syncs merge commits to intermediary
```

**Inside the sandbox:**
```
/home/you/your-project/           # Working directory (same path as yours)
/run/home/you/.cache/.../         # Git origin (intermediary bare repo)
/tmp/claude-cage/pipe             # Hook communication pipe
```

## Failed Patch Recovery

Sometimes patches fail to apply — merge conflicts happen, ain't nobody's fault. Failed patches get saved to `claude-cage-failed-patches/from-intermediary/<branch>/` in your project.

Next time you fire up `claude-cage`, you'll get an interactive prompt:

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

If there's a conflict durin' the apply, you get dropped into a shell to sort it out yourself.

## Recovering Session Work

So Claude did the work, made the commits, but the session ended before anythin' got synced back to your source repo. Maybe the pipe wasn't runnin'. Maybe auto-sync was off. Maybe life happened. Point is — the work's still sittin' there in the session cache. You just gotta go get it.

### Option 1: Attach to the Session

Easiest way. If the session still exists, fire up a new cage attached to it:

```bash
claude-cage --attach-session
```

This drops you right into the same work directory Claude was usin'. From there, Claude (or you) can push the commits, and the sync pipeline picks 'em up like nothin' happened. If there's more than one session lyin' around, you'll get a list to pick from. You can also pass the timestamp directly:

```bash
claude-cage --attach-session 2025-02-06_14-30-22
```

### Option 2: Shell Into It Yourself

If you'd rather handle things personally, `--test` drops you into a shell inside the sandbox instead of launchin' Claude:

```bash
claude-cage --attach-session 2025-02-06_14-30-22 --test
```

Now you're standin' in Claude's workspace with full git access. Push what needs pushin', inspect what needs inspectin'.

### Option 3: Manual Recovery

Don't want to fire up the cage at all? Fine. The work directory's still on disk — you just need to find it and push to the intermediary yourself.

**Finding the work directory:**

If you've got `createCagedDir = true` in your config, the symlinks are right there in your project:

```
your-project/.caged/sessions/<timestamp>/work → ~/.cache/.../work/<project-path>/
```

If not, go straight to the cache:

```
~/.cache/claude-cage/sessions/<timestamp>/work/<your-project-path>/
```

**Pushing the commits:**

The work directory is a regular git repo. Its remote points at the intermediary. So:

```bash
cd ~/.cache/claude-cage/sessions/2025-02-06_14-30-22/work/home/you/your-project/
git log --oneline  # See what's there
git push origin <branch>
```

That gets the commits into the intermediary. Now bring 'em home:

```bash
cd ~/your-project
claude-cage git-merge            # Sync current branch
claude-cage git-merge --all      # Or sync everything
```

`git-merge` walks the intermediary, finds what hasn't been synced, and applies it to your source repo via `git am --3way`. Same mechanism as auto-sync — just on your schedule.

## Troubleshooting

**"Unprivileged user namespaces are not available"**
```bash
# Ubuntu 23.10+ blocks this by default
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

**DNS not working inside sandbox**

The sandbox uses slirp4netns DNS at 10.0.2.3. If you're filterin' network access, make sure DNS is allowed — it's handled automatically in allowlist mode, so if it ain't workin' you probably touched somethin' you shouldn't have.


## Contributing

Contributions welcome. Just remember — commit messages gotta have that Con Air energy.

## License

BSD 2-Clause. See [LICENSE](LICENSE) for details.

---

*"Put... the bunny... back... in the box."* — Oh wait, wrong README. But you get the idea. Keep your files safe. Use the cage.
