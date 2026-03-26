# envswitch

Switch shell environments with a single command. No binaries, no hooks to approve, no `.env` files in your repos.

```
$ staging
 ✓ Loaded staging  (5 vars)

$ production
 ! Load production env? (y/n): y
 ✓ Loaded production  (12 vars)

$ unsetenv
 ✓ Cleared production environment
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/octopols/envswitch/main/remote-install.sh | bash
source ~/.zshrc
```

<details>
<summary>Or clone locally</summary>

```bash
git clone https://github.com/octopols/envswitch.git
cd envswitch && bash install.sh && source ~/.zshrc
```
</details>

## How it works

1. Env files live in `~/.envs/` — one file per environment
2. Each `.env` file automatically becomes a shell command
3. Type the name → it loads. Type another → previous one clears first
4. Add `production.env` → `production` is now a command. No config changes.

## Commands

```
addenv [name]           Create env (interactive wizard if no args)
editenv <name>          Open env in editor
rmenv <name>            Delete env
loadenv <name>          Load env by name or path
unsetenv                Unload current env
envstatus               Show active env + masked values
envstatus --full        Reveal all values
envls                   List all envs
envrefresh              Re-scan after editing tags
envhelp                 Show all commands

setenvdir <path>        Change env directory
setenveditor <cmd>      Change editor
protectenv <name>       Require confirmation to load
unprotectenv <name>     Remove confirmation
```

## Auto-loading (monorepo support)

Add tags to env file headers to auto-load on `cd` and branch switch:

```bash
# ~/.envs/growth_staging.env
# dir: ~/monorepo
# branch: growth/*
API_KEY=sk-staging-123
```

```bash
# ~/.envs/growth_production.env
# (no tags — manual only, never auto-loads)
API_KEY=sk-prod-456
```

Now:

```
$ cd ~/monorepo                    # on branch growth/feature-x
 ✓ Auto-loaded growth_staging  (dir:~/monorepo, branch:growth/feature-x)

$ production                       # context-aware: resolves to growth_production
 › Context: growth
 ✓ Loaded growth_production  (5 vars)

$ git switch payments/new-api
 ✓ Auto-loaded payments_staging  (branch:payments/new-api)

$ cd ~/Desktop
 ✓ Left mapped directory, clearing payments_staging
```

**Rule: only tag your safe defaults.** Tag staging envs for auto-load. Production envs stay untagged — reached manually or through context resolution.

**Performance:** no dir tags = zero overhead. Dir match without branch tags = no git call. Git is only read (~1ms) when branch disambiguation is needed. Results are cached.

## Configuration

Set before the `source` line in `.zshrc`, or use runtime commands:

| Variable | Default | Runtime |
|---|---|---|
| `ENVSWITCH_DIR` | `~/.envs` | `setenvdir` |
| `ENVSWITCH_EDITOR` | `$EDITOR` / `code` | `setenveditor` |
| `ENVSWITCH_PROTECT` | `production:prod` | `protectenv` |
| `ENVSWITCH_PROMPT` | `true` | set `false` to use your own prompt |

## Comparison

| | envswitch | direnv | dotenv | aws-vault |
|---|---|---|---|---|
| Scope | Whole shell | Per directory | Per app (runtime) | AWS creds only |
| Switch staging → prod | `production` | Edit `.envrc` + `direnv reload` | Restart app | `aws-vault exec prod` |
| Monorepo + branches | Auto-load by dir + branch pattern | One `.envrc` per dir, no branch awareness | N/A | N/A |
| Files in repo | No — everything in `~/.envs` | Yes — `.envrc` in each project | Yes — `.env` in project root | No |
| Install | `source` one file | Binary + shell hook + `direnv allow` per dir | Language-specific package | Binary + keychain setup |
| Protection for prod | Built-in confirmation prompt | None | None | Session-based |
| Config changes needed | None — add a file, get a command | Edit `.envrc`, run `direnv allow` | Edit app config | Edit `~/.aws/config` |

## Uninstall

```bash
bash ~/.config/envswitch/uninstall.sh
source ~/.zshrc
```

Env files in `~/.envs` are left untouched.

## License

MIT
