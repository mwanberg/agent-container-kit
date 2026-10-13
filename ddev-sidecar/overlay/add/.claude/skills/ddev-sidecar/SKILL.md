---
name: ddev-sidecar
description: Use inside the agent-container-kit DDEV sidecar when the question is about the sidecar itself, such as a stop headed AGENT-CONTAINER-KIT (GUARD STOPPED, GUARD ASKS), GUARDRAIL or GIT SCREEN, what the policy allows, how to allow a domain or reach a service, or whether the sandbox is working, and to help the user change a sidecar setting on the host.
---

# DDEV sidecar

This session runs in a sidecar container beside a DDEV project. A default-deny firewall, a Claude Code policy and guard hooks are baked into its image, root-owned, and the project is mounted at `/var/www/html` with `.ddev` and `.git` read-only.

You can read `.ddev` but not change it: DDEV builds this image from it and runs files from it on the host. Every change to the sidecar is one the user makes on the host.

## Where the answers are

Read the file the table names in full, with the Read tool, before answering. In the policy, hooks and domains rows, the paths before the semicolon are the copies in force now and those after it are the project's copies, which the next image build bakes.

The paths under `/etc/` and `/usr/local/` exist only inside the sidecar, and the checks below run only there. If `/etc/agent-container-kit/image-built-at` does not exist, this session is not in the sidecar: answer from the project's copies, by path from the project root, and from the kit's README beside this skill, `.claude/skills/ddev-sidecar/README.md`, and do not read `/etc/claude-code/`.

| Question | Where |
| --- | --- |
| Why a tool call was stopped or prompted for approval | The message itself. Its header carries an id, such as `[guard-write-ddev]`, which names its block in `/usr/local/lib/agent-container-kit/fix-it-messages.txt`. |
| Why an image build, a sidecar start or `ddev claude` stopped | The block headed `AGENT-CONTAINER-KIT: <stage> STOPPED [<id>]` on the user's terminal. Ask the user for it, then read the block with that id in the message file. |
| What the policy allows, prompts for approval and denies | `/etc/claude-code/managed-settings.json`, whose `_comment` explains the rule forms; `/var/www/html/.ddev/claude/managed-settings.json` |
| What the guard hooks screen, and the cases that test them | `guardrail-protect.sh`, `git-screen.sh`, `guard-lib.sh` and `hook-cases.json` in `/usr/local/lib/agent-container-kit/`; `/var/www/html/.ddev/claude/hooks/` and `/var/www/html/.ddev/claude/hook-cases.json` |
| Which domains are reachable | `/etc/agent-container-kit/firewall/egress-domains.list`; `/var/www/html/.ddev/claude/egress-domains.list`. The header of `/usr/local/bin/init-firewall.sh` says what the firewall enforces and its limits. |
| Which DDEV services are reachable | `/etc/agent-container-kit/firewall/services.list`, baked from `CLAUDE_SIDECAR_SERVICES` in `/var/www/html/.ddev/docker-compose.zz-claude-overlay.yaml` |
| The sidecar's mounts, environment and limits | `/var/www/html/.ddev/docker-compose.zz-claude-overlay.yaml` |
| What the image installs (PHP, Node, optional blocks) | The build fragment, `/var/www/html/.ddev/claude.local/Dockerfile.fragment`, which `ddev claude rebuild` splices into a copy of the template `/var/www/html/.ddev/claude/Dockerfile.base`, written as `/var/www/html/.ddev/claude/Dockerfile` |
| The add-on's build settings | `/var/www/html/.ddev/claude.yaml` |
| When this image was built | `/etc/agent-container-kit/image-built-at` |
| What `ddev claude` and its subcommands do | `/var/www/html/.ddev/commands/host/claude` |
| Which host commands apply a change to a file the image is built from | The header of `/var/www/html/.ddev/config.claude.yaml` |
| Installing, applying a change, optional pieces, uninstalling | The kit's documents, `/var/www/html/.claude/skills/ddev-sidecar/README.md` and `/var/www/html/.claude/skills/ddev-sidecar/UNINSTALL.md`. In them, `<kit>` is the user's copy of the kit on the host, and every command runs on the host, never in the sidecar. |

## Helping the user change something

1. Read in full the file the table names for the setting, including its header comments, which say what the setting does and what a change to it needs.
2. Write out the exact edit: the file's path from the project root, and the lines to add, remove or replace. The user makes it on the host. A change to a hook's decision also edits the cases in `.ddev/claude/hook-cases.json` that assert the old decision, in the same change.
3. Name the host-side steps: the commands the header of `.ddev/config.claude.yaml` names. Say that each command runs on the host, from the project root, never in the sidecar.
4. Say which check proves the change, to run in the session the user opens with `ddev claude` afterwards: for a file in a baked-copy pair below, that pair's `diff`; for a hook or its cases, that `diff` and then the hook case run; for the services list, its in-force file; then the behavior the change was for. To check a hook edit before the rebuild, the docstring of `/usr/local/lib/agent-container-kit/hook-health.py` gives the host command.

## Checking the protections are in force

Run these yourself.

**The hook case run.** With no options it feeds every case in the baked `hook-cases.json` to the hooks the live policy registers, over a pipe and over a socket.

```sh
python3 -I /usr/local/lib/agent-container-kit/hook-health.py
```

Pass: exit status 0, and both totals, `pipe:` and `socket:`, end `0 failed`. That proves the baked hooks return the decision every case expects; whether this session runs them is the `/status` check below. A `FAIL` line means a baked hook returns a different decision for that case than expected; it names the hook, the expected and actual decision, and the case: tell the user.

**The build.** This lists every file under `.ddev` modified since the image was built:

```sh
find /var/www/html/.ddev -newer /etc/agent-container-kit/image-built-at -type f
```

Pass: it lists no file the image is built from: the build fragment, `claude.yaml`, the compose overlay (for its build arguments), and the files under `.ddev/claude/` that `Dockerfile.base` copies. It compares modification times, so a file saved without a change also shows. A listed build file may hold a change the image lacks: name it to the user, with the host-side steps.

**The baked copies.** Compare each pair file by file, one `diff` per pair:

```sh
diff /var/www/html/.ddev/claude/managed-settings.json /etc/claude-code/managed-settings.json
diff /var/www/html/.ddev/claude/egress-domains.list /etc/agent-container-kit/firewall/egress-domains.list
diff /var/www/html/.ddev/claude/hooks/guardrail-protect.sh /usr/local/lib/agent-container-kit/guardrail-protect.sh
diff /var/www/html/.ddev/claude/hooks/git-screen.sh /usr/local/lib/agent-container-kit/git-screen.sh
diff /var/www/html/.ddev/claude/hooks/guard-lib.sh /usr/local/lib/agent-container-kit/guard-lib.sh
diff /var/www/html/.ddev/claude/hook-cases.json /usr/local/lib/agent-container-kit/hook-cases.json
```

Pass: no output. Output means the image does not hold the project's copy of that file: tell the user, with the host-side steps. A `diff` of a pair's two folders lists every other baked file, so it never passes.

**The read-only mounts.**

```sh
grep -e ' /var/www/html/[.]ddev ' -e ' /var/www/html/[.]git ' /proc/self/mountinfo
```

Pass: a line for `.ddev`, and one for `.git` where the project has a top-level `.git`, each showing the mount point followed by options that start with `ro`. A missing line, or options that start with `rw`, means that folder is writable from here: stop and tell the user.

**The firewall.** `1.1.1.1` is one of the firewall's DNS resolvers, allowed on port 53 only, and this is the probe the firewall runs on itself at start:

```sh
timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
```

Pass: it fails at once with exit status 1, because the firewall rejects the connection. Exit status 124 means it timed out: something other than the firewall stopped it, so the check proved nothing; say so to the user. If it succeeds, egress is not contained: stop and tell the user.

**What only the user can check.** `/status` is a slash command the user runs; ask them to run it once and say which managed settings source it shows as active. It should be the managed settings file baked into this image. If a claude.ai organization's server-managed settings are active instead, Claude Code applies them in place of that file by default, apart from a few keys it reads from every source (Claude Code's settings docs list them), so the kit's permission rules and hooks may not be in force, while the firewall, the read-only mounts, the unreachable web container and the absence of credentials do not depend on Claude Code settings and hold either way.
