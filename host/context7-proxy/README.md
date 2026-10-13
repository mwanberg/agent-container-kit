# Context7 proxy (optional)

Context7 gives the agent current library and framework documentation through MCP. This folder runs a small Caddy proxy on your machine, outside every container: the sidecar sends Context7 requests to the proxy with a placeholder key, and the proxy swaps in your real API key and forwards them to Context7. Your key never enters the sidecar.

The sidecar works without it.

| File | What it does |
| --- | --- |
| `Caddyfile` | The proxy: listens on port 8788 on the loopback addresses, answers `/healthz`, and forwards `/context7/*` to Context7 with your key. |
| `start-proxy.sh` | Loads your key and runs Caddy in the foreground. Read its header for where the key can come from. |
| `com.local.context7-proxy.plist` | macOS only: a launchd agent that keeps the proxy running. |

## What you need

- Caddy on the host: see <https://caddyserver.com/docs/install> (on macOS with Homebrew, `brew install caddy`).
- A Context7 API key from <https://context7.com/dashboard>.

## Set it up

These commands copy the proxy's files to `~/.config/context7-proxy/`, outside every project so no sidecar mounts them, and create a key file only you can read. Run them on the host, from the kit's `host/context7-proxy/` folder:

```sh
mkdir -p ~/.config/context7-proxy
cp Caddyfile start-proxy.sh com.local.context7-proxy.plist ~/.config/context7-proxy/
touch ~/.config/context7-proxy/api-key
chmod 600 ~/.config/context7-proxy/api-key
```

Open `~/.config/context7-proxy/api-key` in an editor, paste the key as its only line, and save. If you keep the key in a password manager instead, skip the file and set `CONTEXT7_API_KEY` from the manager's command line tool when you start the proxy, in the form `CONTEXT7_API_KEY="$(<the manager's command that prints the key>)" sh ~/.config/context7-proxy/start-proxy.sh`. The launchd agent below reads the key file only, so the password-manager route runs the proxy from a terminal.

## Start it

On any system, in a terminal that stays open:

```sh
sh ~/.config/context7-proxy/start-proxy.sh
```

Ctrl-C stops it.

### macOS: keep it running with launchd

Edit `~/.config/context7-proxy/com.local.context7-proxy.plist` and replace `YOUR-USER` in every path with your macOS user name. Then:

```sh
cp ~/.config/context7-proxy/com.local.context7-proxy.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.local.context7-proxy.plist
```

It starts now and at every login. Logs go to `proxy.out.log` and `proxy.err.log` in `~/.config/context7-proxy/`. Do not also run `start-proxy.sh` in a terminal while it is loaded: only one process can listen on port 8788.

- After changing the key or `~/.config/context7-proxy/Caddyfile`: `launchctl kickstart -k gui/$(id -u)/com.local.context7-proxy`
- To remove the launchd agent: `launchctl unload ~/Library/LaunchAgents/com.local.context7-proxy.plist`, then delete that file.
- To remove the proxy completely, also delete `~/.config/context7-proxy/`, which holds the copied files, the logs and your key file. If the key served nothing else, revoke it in the Context7 dashboard.

## Turn it on for a project

On the host, merge the `context7` entry from the kit's `ddev-sidecar/templates/mcp.json.template` into the `mcpServers` object of the project's `.mcp.json`, or copy the template to `.mcp.json` if the project has none. If you keep the kit's files out of git with `.git/info/exclude`, add `/.mcp.json` to it too. The sidecar's managed settings already allow and approve this one server at this address, so no rebuild is needed: the next `ddev claude` session uses it. The agent cannot edit `.mcp.json` itself; that file is yours.

## Confirm it works

1. On the host: `curl -s http://127.0.0.1:8788/healthz` prints `ok`.
2. `ddev claude` starts without warning that nothing answers at the MCP proxy.
3. In the session, `/mcp` lists `context7` as connected.

If step 1 passes and step 2 warns, your Docker does not send the sidecar's `host.docker.internal` traffic to the host's loopback. On Docker Engine for Linux, the sidecar's `host-gateway` entry resolves to the default bridge's address unless the daemon's `host-gateway-ip` setting names another. Find the address the sidecar uses with `ddev claude exec getent ahostsv4 host.docker.internal`, add it to the `bind` line in `~/.config/context7-proxy/Caddyfile`, and restart the proxy. This route is untested; afterwards, check that other machines on your network cannot reach port 8788 at that address.

## What it protects, and what it does not

- The key is held only in the proxy's memory and in your key file or password manager. The sidecar holds the word `placeholder`.
- The proxy listens on the loopback addresses, so other machines cannot reach it.
- It does not check who is calling. Any process on your machine, and any container that can reach port 8788 on `host.docker.internal`, can use it and spend your key's quota. Put nothing more powerful than a documentation key behind it without adding caller authentication.
- To rotate the key, replace the file's contents and restart the proxy.
