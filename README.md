# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

Now, I'm gonna tell you about `claude-cage`. It's a bash script that's gonna keep your files locked down tight while lettin' Claude Code do its work. Three layers of protection. Three layers between your precious code and anything that might go wrong. That's how we do this right.

## What This Thing Does

Listen up. `claude-cage` sets up a containment system - three levels of security, each one watchin' the other:

1. **Source directory** - That's your actual project files. Your life's work. The thing you came here to protect.
2. **Sync directory** - A perfect copy, maintained by `unison`. Like a mirror, but better.
3. **Mounted directory** - Where Claude Code operates. Permission-mapped through `bindfs`. Controlled. Contained.

Every change Claude makes gets synced back to your source. But only the changes you allow. The rest? They stay on the outside where they belong.

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
sudo apt install unison bindfs lua

# RHEL/CentOS
sudo yum install unison bindfs lua
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
    -- User to run Claude Code as
    user = "claude",

    -- Source directory under current directory to allow reading from
    -- If not provided, source must be provided as a command-line argument
    source = "my-directory",

    -- Sync directory for unison to sync source with
    -- If empty, will use syncprepend + source
    sync = "claude-my-directory",

    -- Prefix for auto-generated sync directory name
    -- If sync is empty, sync directory will be: syncprepend + source
    syncprepend = "claude-",

    -- Files/folders that Claude should not have access to and should not be synced
    excludePath = { "target", "dist", ".env" },
    excludeName = { "*.tmp", ".DS_Store" },
    excludeRegex = { ".*\\.log$" },
    belowPath = { "node_modules" },

    -- Mounted directory name created under the user's home directory
    mounted = "my-directory"
}
```

### Configuration Options

- **user**: User account to run Claude Code as (default: `"claude"`)
- **source**: Source directory to sync (can be overridden via command-line)
- **sync**: Sync directory name (auto-generated if empty)
- **syncprepend**: Prefix for auto-generated sync directory (default: `"claude-"`)
- **mounted**: Directory name under `/home/<user>/` where files will be mounted

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

### Config Merging

- **Simple values** (user, source, etc.): Later configs override earlier ones
- **Arrays** (all exclude options): Values get **merged** across all config levels

Example: System config has `excludePath = [".git"]` and local config has `excludePath = ["secrets.txt"]`. Final result? Both get excluded: `[".git", "secrets.txt"]`.

## Usage

### First Run

First time you run this, if the user don't exist, you'll see this:

```
User 'claude' does not exist.
Create user 'claude'? [y/N]
```

The user gets created with `--disabled-login` - no interactive login, but can still run processes through `su`. That's how we launch Claude Code. Controlled access.

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
2. **Bindfs** mounts the sync directory with permission mapping:
   - Files created by the Claude user appear as owned by you
   - Ensures proper permissions when files sync back to source
3. **Claude Code** runs in the mounted directory, working on your files
4. **Changes sync bidirectionally** in real-time

Three layers. Each one doin' its job. That's how you keep things under control.

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

3. Claude Code starts in `/home/claude/my-web-app`
4. Make your changes with Claude Code
5. Changes automatically appear in `./my-web-app`

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
