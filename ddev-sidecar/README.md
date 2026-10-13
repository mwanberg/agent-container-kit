# Claude Code sidecar for DDEV

This kit runs Claude Code in a sidecar container beside your DDEV project. It builds on the `makraz/ddev-claude` add-on and adjusts it: a default-deny firewall that allows only listed domains and never the `web` container, a Claude Code policy baked into the image where the agent cannot edit it, `.ddev` and `.git` mounted read-only, and guard hooks that stop risky tool calls or prompt you to approve them.

It is not a sandbox for leaving an agent to work unsupervised. Read each approval prompt, and review what the agent changes.

## Before you start

- DDEV v1.24.0 or later (the add-on's minimum) and Docker.
- A DDEV project. If it has no `.git` at its root, remove the `../.git:/var/www/html/.git:ro` line from `.ddev/docker-compose.zz-claude-overlay.yaml` after step 2; otherwise Docker creates an empty `.git` folder in the project. A `.git` file (a worktree or submodule checkout) needs no change: it is mounted read-only like a `.git` folder.
- `sha256sum` or `shasum` on the host. macOS ships `shasum`.
- A Claude Pro, Max, Team, Enterprise or Console account to sign in with. The free claude.ai plan does not include Claude Code.

## How to install the kit

Run each install command on your host machine and from your DDEV project root unless a step says otherwise. `<kit>` stands for this kit's path (the one with `ddev-sidecar/` in it). Keep the kit outside the project's directory, so the sidecar never mounts it. Do not run `ddev start` or `ddev restart` until step 5.

### 1. Install the add-on at the pinned version

Run:

```sh
ddev add-on get makraz/ddev-claude --version v0.4.2
```

When it finishes, that process prints its own next steps. Skip them and go on to step 2: they restart the project, which would build the add-on's own sidecar instead of the kit's.

### 2. Run the kit's installer

In a terminal:

```sh
sh <kit>/ddev-sidecar/install.sh
```

The installer checks that the add-on's files are exactly the ones v0.4.2 installs, then prompts you about each optional piece and explains each one on screen. At a `[Y/n]` or `[y/N]` prompt, pressing Enter takes the capital letter. A question that ends in a question mark and no brackets, such as the PHP version when `.ddev/config.yaml` does not set it, needs a typed answer. The last prompt, `Write these changes? [Y/n]`, follows a list of what the installer will write. Nothing is written before you answer yes there, so answering no, or pressing Ctrl-C at any prompt, leaves the project unchanged. It runs no DDEV command.

The installer adds the kit's files the project lacks, replaces the add-on's copies of the files in the kit's `overlay/overwrite/`, creates the build fragment (step 3) and adds the agent's `ddev-sidecar` skill under `.claude/skills/`. It never overwrites a kit file the project already has: if the project's copy differs, the installer lists it under "Left as they are", with the path of the kit's copy to compare it with. Keep yours only if you changed it on purpose, such as the overlay file with its `.git` line removed as "Before you start" says.

Run again later on a project it already installed, the installer adds nothing twice. It asks again only about the pieces it did not add, Context7 and the agent note, and then Enter answers no.

If one of its checks fails, the installer stops without writing anything and prints an error naming the check:

- **Not run in a terminal**: the installer stops before any check. Run it in a terminal.
- **Not beside its `overlay/` or `templates/` folder or `upstream-files.sha256`**: run the `install.sh` that came with the kit, not a copy.
- **Not a DDEV project root**: there is no `.ddev/config.yaml` here. Change to the project root.
- **Neither `sha256sum` nor `shasum`**: install one.
- **Add-on files missing**: the add-on is not installed. Go back to step 1.
- **Files differ from what v0.4.2 installs**: a different add-on version, or a local edit. Move the named files out of the project, run step 1 again, then this step.
- **`.ddev/claude.yaml` lacks settings**: the project already has its own `claude.yaml`. Add the lines the message prints, then run this again.
- **`.ddev/claude.yaml` turns on the add-on's `php` extra**: the kit's build fragment installs PHP, and the extra would install a second version into the same image. Remove `php` from `extras`, then run this again.

### 3. Check the build fragment

`.ddev/claude.local/Dockerfile.fragment` is the build fragment. It installs PHP and Node in the sidecar, with the optional tools you chose in step 2. When the installer created it, nothing in it needs changing: go on to step 4, unless the installer printed a line starting `Replace CORE-LINT-PACKAGES`, in which case do what that line says first.

If the project already had a fragment, the installer left it as it was. Compare it with `<kit>/ddev-sidecar/templates/php-toolchain.fragment.template`, and fill in its `PHP_VERSION` and `NODE_MAJOR` lines if they still hold the template's placeholders, as the template's header describes.

To change later what the fragment installs:

- **A PHP extension the site needs.** The installer adds the Postgres, Redis and Memcached extensions when the project's DDEV configuration names those services. For another one, add a line in the form the list uses, such as `php${PHP_VERSION}-ldap`, to the fragment's list of PHP extensions. Without the extension a database or cache backend needs, drush and tests cannot start the site.
- **An optional tool block.** Uncomment it as the fragment's header describes. Each block's `Needs` line says what it builds on: the Drupal browser tests need `phpunit.xml` and `vendor/bin/phpunit` at the project root; the browser checks, and the accessibility checkers built on them, need Node 20 or newer in the sidecar, and the build stops with a message on an older one; the lint block needs its `CORE-LINT-PACKAGES` placeholder replaced with what the command in its comment prints. For pages that load web fonts, the browser checks also need each font host added as described under "Allowing another domain".
- **The PHP or Node version.** The PHP version has to match the web container's exactly, so change it when `php_version` in `.ddev/config.yaml` changes. Move the fragment out of the project, run the installer again and answer with the new versions, copy back any lines you had added, then do step 5 again.

Each change takes effect at step 5.

### 4. Add which services the agent's sidecar may reach

A DDEV project runs as several containers, which DDEV calls services: `web` and usually `db`, plus one or more for each add-on, such as `redis` or `solr`. This kit ships with `db` on by default. If that's all you need, skip to the next step. If you need more, keep reading.

Each add-on's services are named under `services:` in its `.ddev/docker-compose.*.yaml` file. The sidecar's firewall blocks all of them except the ones listed in `CLAUDE_SIDECAR_SERVICES`, under the `claude` service's `build: args:` in `.ddev/docker-compose.zz-claude-overlay.yaml`.

`CLAUDE_SIDECAR_SERVICES` takes one quoted string of service names separated by spaces, such as `CLAUDE_SIDECAR_SERVICES: "db redis"`: no commas, and the name under `services:`, not the container name. The default is `"db"`, and the installer also adds `.ddev/docker-compose.zz-claude-db.yaml`, which connects the sidecar to the database.

- Never add `web`. It has open internet access, so a connection to it would let data leave past the firewall; if it is listed, the firewall stops with an error and the sidecar does not start. Tests that need a web server run one inside the sidecar through the fragment's optional test block.
- A project without a database container: delete `.ddev/docker-compose.zz-claude-db.yaml` and set the value to `""`.

`CLAUDE_SIDECAR_SERVICES` is baked into the image, so a change to it takes effect when the image is next built.

### 5. Build and start the sidecar

```sh
ddev claude rebuild
```

Then, if the project is stopped:

```sh
ddev start
```

or, if it is running:

```sh
ddev restart
```

This builds the sidecar's image and starts it. If the build or the start fails, the last lines of the output say what failed and how to fix it.

### 6. Start Claude Code and sign in

```sh
ddev claude
```

The first time, Claude Code prompts you to sign in. Open the link it shows (press `c` to copy it if no browser opens). If the browser then shows a code, paste it at `Paste code here if prompted`. You stay signed in across restarts.

If you signed in with a Claude Team or Enterprise account, run `/status`. If it shows server-managed settings (the settings your organization sets on claude.ai) as the active source, your organization's settings apply instead of the kit's permission rules and guard hooks, while the firewall and read-only mounts still apply. Before using the sidecar on that account, ask whoever administers your organization's Claude Code settings whether they allow the kit's policy file to apply too; otherwise sign in with an account outside the organization.

`ddev claude help` lists the other commands, such as `ddev claude shell` for a terminal inside the sidecar.

## After install

**Review the agent's code before you run it in the site.** The agent cannot change `.ddev` from the sidecar, but code it writes runs in the web container when you load the site or run `ddev drush`, and the web container can change `.ddev`. DDEV builds the sidecar from those files as root and runs some of them on your machine at the next start.

**Changing the status line.** The status line script is `.ddev/claude/statusline-command.sh`. Claude Code runs it with details of the session as JSON on standard input and shows what it prints; [Claude Code's status line documentation](https://code.claude.com/docs/en/statusline) lists the fields. The script runs inside the sidecar, where `jq` and `git` are available. Edit it on the host, then run `ddev claude rebuild` and `ddev restart`. A status line set anywhere else does not run in the sidecar: the kit's policy sets `allowManagedHooksOnly`, under which Claude Code runs only the status line the policy names.

To turn the status line on after answering no at install, copy the `statusLine` entry from `<kit>/ddev-sidecar/overlay/add/.ddev/claude/managed-settings.json` into `.ddev/claude/managed-settings.json` as a top-level key, for example just above `"hooks"`, keeping a comma after its closing brace. To turn it off, delete that entry. Then rebuild and restart. The script is installed either way, so turning it on later needs only this edit.

**The agent note.** Its text is in `<kit>/ddev-sidecar/templates/agent-note.md`. To add it after install, append that text to the project's `CLAUDE.md` or `AGENTS.md`, or to `CLAUDE.local.md` if you keep the installed files out of git.

**Allowing another domain.** To let the agent reach another domain, add it on its own line to `.ddev/claude/egress-domains.list`, then run `ddev claude rebuild` and `ddev restart`. Each line also allows that domain's subdomains, and each is a place data can be sent, so add only what the work needs. The add-on's own `extra_allowed_domains` setting has no effect with the kit.

**Context7.** The Context7 proxy runs on your machine and gives the agent current library documentation without putting your Context7 API key in the sidecar. Its setup, including turning it on for a project after install, is in `<kit>/host/context7-proxy/README.md`.

**The installed files in git.** After install, the add-on's and the kit's files show in `git status`. Commit them, or list them in the project's `.gitignore`. Step 1 appended lines to `.gitignore`, each starting with `/.ddev/`; one of them, `/.ddev/claude.local/`, keeps the build fragment out of git, so to share the fragment with the rest of the team, delete that line. If you can neither commit nor change `.gitignore`, for example in a repository whose tracked files you cannot change, answer yes at the installer's prompt `Hide the kit's files from git on this computer only?`: the installer then lists the files in `.git/info/exclude` and puts the agent note in `CLAUDE.local.md`, which Claude Code also loads, in place of a tracked `CLAUDE.md` or `AGENTS.md`. Or add them to your local `.git/info/exclude` later, once:

```sh
sh <kit>/ddev-sidecar/install.sh --exclude-lines >> .git/info/exclude
```

That covers the add-on's files, the kit's files, the build fragment and `.mcp.json`. A `CLAUDE.md` the installer created needs its own `/CLAUDE.md` line. Then move the add-on's `.gitignore` lines, the ones starting with `/.ddev/`, into `.git/info/exclude` too; `grep -n '^/\.ddev/' .gitignore` shows them.

**When something fails.** A failed build, start or `ddev claude` ends with a block headed `AGENT-CONTAINER-KIT: <stage> STOPPED` that says what failed and how to fix it. If the sidecar did not start, run `ddev claude` to see that block.

**Uninstall.** Follow [UNINSTALL.md](UNINSTALL.md). `ddev add-on remove claude` on its own leaves the kit's files behind.

## Stricter install

Step 1 lets DDEV download the add-on from GitHub. To check it first, download it yourself, confirm GitHub has verified the tag's signature, and install from your copy. This needs `git` and the GitHub CLI, `gh`, signed in to GitHub. Outside the project:

```sh
git clone --branch v0.4.2 https://github.com/makraz/ddev-claude.git
gh api repos/makraz/ddev-claude/git/ref/tags/v0.4.2 -q '.object.sha'
```

The second command prints the tag's id. Put it in place of `<id>` here; this prints `true` when GitHub has verified the signature:

```sh
gh api repos/makraz/ddev-claude/git/tags/<id> -q '.verification.verified'
```

Then, from the project root, install from your copy in place of step 1 and continue with step 2:

```sh
ddev add-on get <path-to>/ddev-claude
```

## What the kit changes in the add-on

**Files it replaces, in `.ddev/`:**

- `config.claude.yaml`: drops the add-on's start hook, which ran a script from `.ddev` on your machine at every `ddev start`. The image is rebuilt only when you run `ddev claude rebuild`.
- `claude/Dockerfile.base`: builds from a pinned base image, checks Claude Code against Anthropic's signed release manifest, bakes the policy, guard hooks, firewall and status line into the image as root-owned files, limits the sidecar user's `sudo` to the firewall, gives that user your host user and group ids, and adds a `drush` command that runs the project's own drush.
- `claude/init-firewall.sh`: blocks all outgoing traffic except DNS lookups, HTTPS to the domains in `egress-domains.list`, the DDEV services you list, and the Context7 proxy on your machine. It blocks private addresses and IPv6, checks at every start that the web container is unreachable, and stops the sidecar if a check fails.
- `commands/host/claude`, the `ddev claude` command: starts Claude Code in its default permission mode, never with `--dangerously-skip-permissions`, re-applies the firewall and checks the image before each session, and warns about nested `.git` folders.

**Files it adds:**

- `.ddev/docker-compose.zz-claude-overlay.yaml`: mounts `.ddev` and `.git` read-only in the sidecar, empties credential variables passed in from your shell, keeps sign-in and shell history in Docker volumes, turns off telemetry and error reporting, sets `IS_DDEV_PROJECT` so the site loads its DDEV-generated settings as it does in the web container, and limits the sidecar to 6 GB of memory and 512 processes. Its name starts with `zz` so it sorts after the add-on's own compose file, whose settings it overrides.
- `.ddev/docker-compose.zz-claude-db.yaml`: connects the sidecar to the database.
- `.ddev/claude.yaml`: keeps the project a plain bind mount and the add-on's default plugins off.
- `.ddev/claude/managed-settings.json`: the Claude Code policy. It denies package installs, recursive deletes, `sudo`, and reading secrets and database dumps; turns off web fetch, web search and claude.ai connectors; allows only the Context7 MCP server; and turns off bypass permission mode.
- `.ddev/claude/hooks/`: the guard hooks, which stop or prompt for approval on writes to protected files and on git commands that change the repository.
- `.ddev/claude/egress-domains.list`: the domains the firewall allows.
- `.ddev/claude/fix-it-messages.txt` and `fix-it.sh`: the messages printed when a build, a start or a guard hook stops something.
- `.ddev/claude/key-check.sh`: checks package signing keys during the build.
- `.ddev/claude/statusline-command.sh`: Claude Code's status line, showing the folder, git branch, model, effort level and context remaining. The installer prompts whether to turn it on, and installs the script either way.
- `.ddev/claude/scratch-copy.sh`: lets the agent copy protected files to a scratch folder to work on the copies.
- `.ddev/claude/hook-health.py` and `hook-cases.json`: a test run of the guard hooks that the agent can run inside the sidecar.
- `.claude/skills/ddev-sidecar/`: the agent's guide to the sidecar, with copies of this README and `UNINSTALL.md`.

**Made by the installer from the kit's template (step 3):** `.ddev/claude.local/Dockerfile.fragment`, which installs PHP and Node in the sidecar. The add-on's base image has neither, so without the fragment the agent can edit files but cannot run PHP, drush, composer, tests or Node builds. The template's test, rendered-site, accessibility and lint blocks are optional.

**Optional, from the kit:** the Context7 proxy and the project's `.mcp.json` entry for it, and the agent note.
