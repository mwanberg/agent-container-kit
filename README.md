# agent-container-kit

A hardened container setup for running Claude Code on a project. The agent works inside a container with default-deny network access, a permission policy it cannot edit, and read-only access to the files that build and configure its own container.

It is for developers who want Claude Code working in their project's code, with what it can reach, run and change kept within limits they can read and adjust.

## What is here

- `ddev-sidecar/`: Claude Code in a sidecar, a second container that runs beside a DDEV project's own containers (PHP, Drupal, WordPress). Start with [ddev-sidecar/README.md](ddev-sidecar/README.md).
- `host/context7-proxy/`: an optional proxy on your machine that gives sessions current library documentation from Context7, a documentation service with an API key, without putting that key in the container.
- `extras/`: optional pieces to copy into a project by hand, such as a Claude Code skill (instructions the agent loads for a kind of task) that drafts research prompts for sessions without web access.
- `tools/`: checks for anyone changing the kit itself.

## Upstream

The DDEV sidecar builds on [makraz/ddev-claude](https://github.com/makraz/ddev-claude) at v0.4.2. The kit's installer checks that the project has exactly that version of the add-on, and stops without changing anything if the add-on is at another version.

## Status

A snapshot as of October 2026: built on ddev-claude v0.4.2, and tested on one Drupal project under DDEV on macOS. The pinned values (the base image digest, the Composer image digest, the Playwright and axe-core versions, and the Sury, NodeSource and Claude Code signing-key fingerprints) were set on 2026-10-10, and the kit's own checks stop a build when one no longer holds. No update schedule is promised. On a later date, the upstream version and those pins are the first things to check.

## License

MIT, in [LICENSE](LICENSE). [NOTICE](NOTICE) credits ddev-claude and carries its license.
