# Extras

Optional pieces that work with the kit's sidecar. The installer does not add them; copy the ones you want.

## research-prompt

A Claude Code skill for sessions without web access, such as the DDEV sidecar, where web search and web fetch are denied. When current web information would help, the agent drafts a self-contained research prompt for you to run in a web-enabled AI tool, instead of searching itself, and keeps names and other identifying details out of it. You bring the report back, and the agent files it where you tell it to.

To add it to a project, run from the project root on your machine, with `<kit>` the path to this kit:

```sh
mkdir -p .claude/skills
cp -R <kit>/extras/research-prompt .claude/skills/
```
