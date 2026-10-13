# Removing the kit and the add-on

These steps remove the kit, upstream's `makraz/ddev-claude` add-on, and what both leave behind. Run every command on the host, from the project root. `<kit>` stands for the folder holding the kit (the one with `ddev-sidecar/` in it), and `<project>` for the DDEV project name.

Do not run `ddev add-on remove claude` on its own. It deletes only the add-on files that still carry DDEV's `#ddev-generated` marker, and the kit's files carry none, so the kit's compose files stay behind and declare a `claude` service the add-on no longer defines.

The project starts normally between any two steps, but not between the add-on removal and the delete inside step 3.

## 1. Note the sidecar's image

If the project is stopped, run `ddev start` first: the command below reads the running container.

```sh
docker inspect --format '{{.Image}}' ddev-<project>-claude
```

Keep the `sha256:` id it prints for step 6. `ddev stop` removes the container, after which this command has nothing to read.

## 2. Stop the project

```sh
ddev stop
```

## 3. Remove the add-on and the kit's files

Run the add-on removal and the delete below, one after the other, before anything starts the project. If `ddev add-on remove claude` has already run, skip it and carry on with the delete below.

```sh
ddev add-on remove claude
```

This deletes the add-on's files that still carry the marker, and its removal actions delete the files its builder generated: `.ddev/claude/Dockerfile`, `extra-domains.list`, `settings.json`, `tools.list`, `.mount-mode`, `.build-stamp`, and `.ddev/docker-compose.claude-mounts.yaml`. It keeps `.ddev/claude.yaml`, `.ddev/.claude/` and `.ddev/claude.local/`, and prints a `docker volume rm` line; step 6 covers the volumes.

Then delete every file the kit's `install.sh` added or replaced. The list includes `.ddev/claude.yaml`, whether it was the kit's copy or the project's own, so keep a copy of that file first if you wrote it. This lists them from the kit's own tree:

```sh
for tree in add overwrite; do (cd <kit>/ddev-sidecar/overlay/$tree && find . -type f); done
```

and this deletes them:

```sh
for tree in add overwrite; do (cd <kit>/ddev-sidecar/overlay/$tree && find . -type f); done | xargs rm -f
```

That also deletes the skill's `SKILL.md` in `.claude/skills/ddev-sidecar/`.

## 4. Remove the folders left behind

```sh
find .ddev/claude .ddev/claude.local .ddev/.claude .claude/skills/ddev-sidecar
```

What is left: upstream's `.ddev/claude/extras/*.domains` files, which carry no marker; your build fragment in `.ddev/claude.local/`; the add-on's `.ddev/.claude/bash_history.d/`; the copies of the kit's `README.md` and `UNINSTALL.md` that the kit's installer put in `.claude/skills/ddev-sidecar/`; and empty folders. Keep a copy of anything you want, then:

```sh
rm -rf .ddev/claude .ddev/claude.local .ddev/.claude .claude/skills/ddev-sidecar
```

If the kit's skill was the only content of `.claude/skills/`, and the add-on's `claude` command the only host command, remove the empty folders. `rmdir` removes a folder only if it is empty:

```sh
rmdir .claude/skills .claude .ddev/commands/host .ddev/commands
```

## 5. Start the project

```sh
ddev start
docker ps --filter name=ddev-<project>-claude
```

The second command lists no container.

## 6. Remove the Docker leftovers

The sidecar's sign-in, settings and shell history are in named volumes. Removing them means signing in again on any later install.

```sh
docker volume rm ddev-<project>-claude-config ddev-<project>-claude-history
```

`docker volume ls --filter name=claude` also shows `<project>_claude_state` if the add-on's own volume was ever created; remove it the same way.

If `docker network ls --filter name=claude-isolated` lists `ddev-<project>-claude-isolated`, remove it:

```sh
docker network rm ddev-<project>-claude-isolated
```

Remove the image with the id from step 1:

```sh
docker image rm <id>
```

Earlier rebuilds can leave untagged (dangling) images. List them:

```sh
docker image ls --filter dangling=true
```

Remove the ones you recognize with `docker image rm <id>`. `docker image prune` removes every dangling image on the machine, not only the sidecar's.

## 7. Remove the git lines

**If you used `.git/info/exclude`.** Delete from it the lines this prints, which start with the `# ddev-claude add-on and agent-container-kit` line:

```sh
sh <kit>/ddev-sidecar/install.sh --exclude-lines
```

Also delete the `/CLAUDE.local.md` or `/CLAUDE.md` line if the installer added one, and any lines you moved there from `.gitignore`.

**Install that commits the kit's files.** `git status` shows the deletions from steps 3 and 4; commit them.

**Either way.** The add-on appended lines to the project's `.gitignore`, and removing the add-on leaves them. Each names a path under `/.ddev/claude/`, `/.ddev/.claude/`, `/.ddev/.claude.export/`, `/.ddev/claude.local/` or `/.ddev/docker-compose.claude-mounts.yaml`. This lists them with their line numbers, along with any `/.ddev/` lines of your own:

```sh
grep -n '^/\.ddev/' .gitignore
```

Delete the add-on's lines. If the project had no `.gitignore` before the add-on, the add-on created it: delete it once those lines are gone and it is empty.

## 8. Remove the Context7 entry and the agent note

If you set up Context7 for this project, delete the `context7` entry from `.mcp.json`, or the file if it holds nothing else. The proxy on the host is separate; its own README says how to stop it and delete its key folder, `~/.config/context7-proxy/`.

If the installer added the agent note, delete it from `CLAUDE.md`, `AGENTS.md` or `CLAUDE.local.md`; its text is in `<kit>/ddev-sidecar/templates/agent-note.md`. If the installer created the file for the note and it holds nothing else, delete the file.

To use upstream's add-on without the kit, install it afresh after these steps, following its own README.
