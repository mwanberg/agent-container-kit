#!/usr/bin/env python3
"""Case run for the ddev-claude sidecar's PreToolUse hooks.

Feeds every case in hook-cases.json to its hook twice, once over a pipe and
once over a socketpair, and checks the decision against the expected one. A
hook can read a pipe correctly and still read nothing from a socket: a
`$(</dev/stdin)` redirect reopens /proc/self/fd/0, which works on a pipe and
fails on a socket, leaving the call allowed.

The hooks fed are the ones the managed policy registers under PreToolUse,
matched to a case's "hook" by script name, and each run is bounded by that
registration's timeout. A hook still running then is killed with everything it
started and counts as a failure.

The hooks run from a scratch folder laid out as the image lays them out: both
hooks, guard-lib.sh from beside the guard hook, and fix-it.sh and
fix-it-messages.txt from beside this script.

Usage:
  python3 -I hook-health.py [--guard PATH] [--git PATH] [--settings PATH]
                            [--cases PATH]

Defaults are the baked hooks and policy, the copies that execute, and the
cases file beside this script. Prints each failing case and a total per
transport; exits 1 if any case fails.

The hooks run under /bin/bash, which has to be bash 4.3 or later, with jq on
PATH. The sidecar image has both; macOS's /bin/bash is 3.2. To check a change
before a rebuild, run the project's copy in the sidecar from the host with
`ddev claude exec python3 -I /var/www/html/.ddev/claude/hook-health.py`,
passing --guard, --git and --settings with their paths under
/var/www/html/.ddev/claude.

A case is one JSON object:
  hook       "guard" (guardrail-protect.sh) or "git" (git-screen.sh)
  expect     "allow" (no output), "ask" or "deny"
  one payload source:
    bash     a command, sent as a Bash call
    write    a path, sent as a Write call
    tool     a tool name, with optional "input" as its tool_input
    raw      the payload text exactly as given, for malformed input
  cwd        optional, the payload's working directory (default /var/www/html)
  reason_contains  optional, for an ask or deny: strings the reason must hold
  condition  optional, the hook's environment:
    path-empty        PATH set to the empty string
    jq-missing        PATH reaching every command on the runner's PATH except jq
    jq-broken         a jq that exits 1, first on the runner's PATH
    lib-missing       no guard-lib.sh beside the hooks
    messages-missing  no fix-it-messages.txt beside the hooks
  note       optional, printed with a failure
An ask or deny also has to carry a non-empty reason.
"""

import argparse
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK_DIR = "/usr/local/lib/agent-container-kit"
HOOKS = {"guard": "guardrail-protect.sh", "git": "git-screen.sh"}
SOURCES = ("bash", "write", "tool", "raw")
CONDITIONS = ("path-empty", "jq-missing", "jq-broken", "lib-missing", "messages-missing")
FIELDS = {"hook", "expect", "input", "note", "reason_contains", "condition", "cwd", *SOURCES}
LIB = "guard-lib.sh"
FIX_IT = "fix-it.sh"
MESSAGES = "fix-it-messages.txt"


def payload(case):
    """Build the PreToolUse payload bytes a case describes."""
    if "raw" in case:
        return case["raw"].encode()
    if "bash" in case:
        tool, tool_input = "Bash", {"command": case["bash"]}
    elif "write" in case:
        tool, tool_input = "Write", {"file_path": case["write"], "content": "x"}
    else:
        tool, tool_input = case["tool"], case.get("input", {})
    return json.dumps({
        "session_id": "case-run",
        "hook_event_name": "PreToolUse",
        "cwd": case.get("cwd", "/var/www/html"),
        "tool_name": tool,
        "tool_input": tool_input,
    }).encode()


def run(argv, data, transport, timeout, env, cwd):
    """Run a hook with `data` on stdin over `transport`.

    Returns (returncode, stdout), or None when the hook outlives `timeout`.
    The hook gets its own process group so anything it started is killed with
    it; a surviving child would hold stdout open, blocking the read that
    follows the kill, and outlive the run.
    """
    parent = child = None
    if transport == "socket":
        parent, child = socket.socketpair()
        parent.sendall(data)
        parent.shutdown(socket.SHUT_WR)
    try:
        proc = subprocess.Popen(
            argv, stdin=child.fileno() if child else subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env, cwd=cwd, start_new_session=True)
        try:
            out, _ = proc.communicate(None if child else data, timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            return None
        return proc.returncode, out
    finally:
        for end in (parent, child):
            if end:
                end.close()


def decide(result):
    """Return (decision, reason) from a hook run's result."""
    if result is None:
        return "timeout", ""
    returncode, stdout = result
    if returncode != 0:
        return "exit %d" % returncode, ""
    out = stdout.decode().strip()
    if not out:
        return "allow", ""
    try:
        spec = json.loads(out)["hookSpecificOutput"]
    except (ValueError, KeyError, TypeError):
        return "badjson", out[:120]
    return spec.get("permissionDecision", "none"), spec.get("permissionDecisionReason", "")


def judge(case, got, reason):
    """Return None when a decision passes the case, else a detail for the
    failure line, empty when the decision itself is the wrong one."""
    if got != case["expect"]:
        return ""
    if got == "allow":
        return None
    if not reason.strip():
        return "an empty reason"
    missing = [text for text in case.get("reason_contains", []) if text not in reason]
    return "a reason lacking %s" % json.dumps(missing) if missing else None


def strings(value):
    return isinstance(value, list) and all(isinstance(t, str) and t for t in value)


def read_json(path, what):
    """Parse a JSON file; exit naming the file when it cannot be read."""
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        sys.exit("hook-health.py: cannot read %s %s: %s" % (what, path, error))


def load(path):
    """Read and validate the cases file; exit on a malformed case."""
    cases = read_json(path, "the cases file")
    for i, case in enumerate(cases):
        problems = []
        if set(case) - FIELDS:
            problems.append("unknown fields %s" % sorted(set(case) - FIELDS))
        if case.get("hook") not in HOOKS:
            problems.append("hook must be %s" % " or ".join(HOOKS))
        if case.get("expect") not in ("allow", "ask", "deny"):
            problems.append("expect must be allow, ask or deny")
        if sum(k in case for k in SOURCES) != 1:
            problems.append("needs exactly one of %s" % ", ".join(SOURCES))
        if not strings(case.get("reason_contains", [])):
            problems.append("reason_contains must be a list of non-empty strings")
        elif case.get("reason_contains") and case.get("expect") == "allow":
            problems.append("reason_contains needs an ask or deny")
        if case.get("condition", CONDITIONS[0]) not in CONDITIONS:
            problems.append("condition must be one of %s" % ", ".join(CONDITIONS))
        if not isinstance(case.get("cwd", "/"), str):
            problems.append("cwd must be a string")
        if problems:
            sys.exit("%s case %d: %s" % (path, i, "; ".join(problems)))
    return cases


def registered(settings):
    """Map each case hook name to its registered PreToolUse timeout; exit when
    the registered hooks are not exactly the ones the cases cover."""
    policy = read_json(settings, "the managed policy")
    by_script = {}
    for group in policy.get("hooks", {}).get("PreToolUse", []):
        for hook in group.get("hooks", []):
            if hook.get("type") != "command":
                continue
            try:
                script = Path(shlex.split(hook.get("command", ""))[-1]).name
            except (ValueError, IndexError):
                sys.exit("%s registers a hook command that cannot be parsed: %r" % (
                    settings, hook.get("command")))
            if "timeout" not in hook:
                sys.exit("%s registers %s with no timeout to judge a hang by" % (settings, script))
            by_script[script] = hook["timeout"]
    if set(by_script) != set(HOOKS.values()):
        sys.exit("%s registers PreToolUse hooks %s, but the cases cover %s" % (
            settings, sorted(by_script), sorted(HOOKS.values())))
    return {name: by_script[script] for name, script in HOOKS.items()}


def environments(scratch):
    """Build the hook environment for each PATH condition under `scratch`."""
    original = os.environ.get("PATH", "")
    no_jq = scratch / "no-jq"
    no_jq.mkdir()
    for directory in original.split(os.pathsep):
        if not os.path.isdir(directory):
            continue
        for entry in os.scandir(directory):
            link = no_jq / entry.name
            if entry.name != "jq" and not os.path.lexists(link):
                link.symlink_to(entry.path)
    broken = scratch / "broken-jq"
    broken.mkdir()
    (broken / "jq").write_text("#!/bin/sh\nexit 1\n")
    (broken / "jq").chmod(0o755)
    paths = {
        "path-empty": "",
        "jq-missing": str(no_jq),
        "jq-broken": str(broken) + os.pathsep + original,
    }
    return {name: {**os.environ, "PATH": value} for name, value in paths.items()}


def layout(folder, sources, without=None):
    """Copy every file in `sources` (a name to path map) but `without` into
    `folder`, and return the hook paths there by case hook name."""
    folder.mkdir()
    for name, source in sources.items():
        if name != without:
            shutil.copy(source, folder / name)
    return {hook: str(folder / script) for hook, script in HOOKS.items()}


def label(case):
    text = json.dumps(case.get("bash", case.get("write", case.get("tool", case.get("raw")))))
    return text + (" under %s" % case["condition"] if "condition" in case else "")


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Hook case run over pipe and socketpair.")
    parser.add_argument("--guard", default=HOOK_DIR + "/" + HOOKS["guard"])
    parser.add_argument("--git", default=HOOK_DIR + "/" + HOOKS["git"])
    parser.add_argument("--settings", default="/etc/claude-code/managed-settings.json",
                        help="managed policy: the hook registrations and their timeouts")
    parser.add_argument("--cases", default=str(here / "hook-cases.json"))
    args = parser.parse_args()

    sources = {
        HOOKS["guard"]: (args.guard, "the guard hook; pass --guard with its path"),
        HOOKS["git"]: (args.git, "the git screen; pass --git with its path"),
        LIB: (str(Path(args.guard).parent / LIB), "the hooks' library, read from beside the guard hook"),
        FIX_IT: (str(here / FIX_IT), "the message helper, read from beside this script"),
        MESSAGES: (str(here / MESSAGES), "the message file, read from beside this script"),
    }
    needed = list(sources.values()) + [
        (args.settings, "the managed policy; pass --settings with its path"),
        (args.cases, "the cases file; pass --cases with its path"),
    ]
    missing = ["hook-health.py: %s is missing: %s" % (path, what)
               for path, what in needed if not os.path.isfile(path)]
    if missing:
        sys.exit("\n".join(missing))

    timeouts = registered(args.settings)
    cases = load(args.cases)
    failed = {"pipe": 0, "socket": 0}
    with tempfile.TemporaryDirectory() as raw_scratch:
        scratch = Path(raw_scratch)
        envs = environments(scratch)
        files = {name: path for name, (path, _) in sources.items()}
        scripts = {
            None: layout(scratch / "kit", files),
            "lib-missing": layout(scratch / "no-lib", files, LIB),
            "messages-missing": layout(scratch / "no-messages", files, MESSAGES),
        }
        for case in cases:
            data = payload(case)
            condition = case.get("condition")
            env = envs.get(condition)
            argv = ["/bin/bash", scripts.get(condition, scripts[None])[case["hook"]]]
            for transport in failed:
                got, reason = decide(run(argv, data, transport, timeouts[case["hook"]], env, scratch))
                why = judge(case, got, reason)
                if why is not None:
                    failed[transport] += 1
                    print("FAIL %-6s %-5s want=%-5s got=%-7s %s%s%s" % (
                        transport, case["hook"], case["expect"], got, label(case),
                        "  %s" % why if why else "",
                        "  (%s)" % case["note"] if "note" in case else ""))
    for transport, count in failed.items():
        print("%s: %d cases, %d passed, %d failed" % (transport, len(cases), len(cases) - count, count))
    sys.exit(1 if any(failed.values()) else 0)


if __name__ == "__main__":
    main()
