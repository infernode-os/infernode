# Filesystem Mounting in Inferno

## How Inferno Accesses Your macOS Filesystem

Inferno runs in its own namespace but can access your macOS files through special devices and mounting.

### The #U Device

**What it is:** A device that provides access to the host (macOS) filesystem

**Syntax:** `#U` or `#U*` or `#U/path`

**Example:**
- `#U*` - All of macOS filesystem
- `#U/Users/pdfinn` - Specific macOS path

### Automatic Setup (via profile)

The `/lib/sh/profile` script automatically sets up access:

```bash
# 1. Create mount namespace
mount -ac {mntgen} /n

# 2. Mount macOS filesystem to /n/local
trfs '#U*' /n/local

# 3. Find your macOS home directory
ghome=/n/local/^`{echo 'echo $HOME' | os sh}

# 4. Create acme-home in your macOS home
lhome=$ghome^/acme-home
```

### After Profile Runs

You can access your macOS files:

```
; ls /n/local/Users
[your macOS users]

; ls /n/local/Users/pdfinn
[your macOS home directory]

; cat /n/local/Users/pdfinn/.zshrc
[your shell config]
```

### The `trfs` Command

**Purpose:** Translates between Inferno and host filesystem

**Usage:**
```
trfs '#U*' /n/local
```

This makes your entire macOS filesystem visible at `/n/local`.

### The `mntgen` Command

**Purpose:** Creates a mount table for the namespace

**Usage:**
```
mount -ac {mntgen} /n
```

Creates `/n` as a mount point directory.

### Variables Set by Profile

- `$user` - Your Inferno username (from `/dev/user`)
- `$home` - Your Inferno home. On desktop hosts this is your HOST home
  (`$ghome`); `/usr/<user>` is the durable Inferno-side home tree,
  bound whole from `~/.infernode/usr` (see `docs/PERSISTENCE.md`)
- `$ghome` - Your macOS home (e.g., `/n/local/Users/<you>`)
- `$infhome` - `~/.infernode` (durable user state; overlay source)
- `$lhome` - acme-home directory (`$ghome/acme-home`)
- `$emuhost` - Host OS type (MacOSX, Linux, Nt)

### Manual Mounting

You can also mount manually:

```
; mount -ac {mntgen} /n
; trfs '#U*' /n/local
; ls /n/local/Users/pdfinn
```

### Namespace File

The `/usr/inferno/namespace` file can also specify default bindings:

```
bind -ia #C /
```

This is executed automatically on startup.

### Common Mount Points

After profile runs:
- `/n/local` - Your entire macOS filesystem
- `/n/local/Users/pdfinn` - Your macOS home
- `$lhome/acme-home` - Persistent acme workspace
- `/usr/<user>` - Durable Inferno home tree (bound from `~/.infernode/usr`)
- `/tmp` - Temporary files (bound from `~/.infernode/tmp`)

### Accessing Mac Files from Inferno

```
; cd /n/local/Users/pdfinn/Documents
; ls
; cat some-file.txt
; grep pattern *.txt
```

All Inferno utilities work on macOS files through `/n/local`!

### Creating Files on Mac from Inferno

```
; echo "created from Inferno" > /n/local/Users/pdfinn/test.txt
```

This creates a real file on your Mac filesystem.

### Security Note

Inferno has full access to your macOS filesystem through `/n/local`. Be careful with commands like `rm` - they can delete real Mac files!

### Troubleshooting

**If /n/local doesn't appear:**
- Check that `mntgen.dis` and `trfs.dis` are compiled
- Run manually: `mount -ac {mntgen} /n`
- Run manually: `trfs '#U*' /n/local`

**If you get errors:**
- Check that the profile ran: `ls /n`
- Verify utilities exist: `ls /dis/{mntgen,trfs,os}.dis`

### Profile Location

The shell profile is at: `/lib/sh/profile`

Edit this to customize your Inferno startup environment.

---

**Summary:** Yes, Inferno automatically mounts your macOS home directory at `/n/local/Users/yourusername` via the profile script using `trfs` and the `#U` device.
