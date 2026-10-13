#!/usr/bin/env python3
"""Checks that every failure message the kit refers to actually exists.

When the kit stops something (a failed build, a firewall error at start, a
guard denial), it prints a message by naming its id in fix-it-messages.txt.
An id that is misspelled, renamed, or deleted shows the user a generic "no
message with this id" block instead of the fix. For use after adding,
renaming, or removing a message, or any line that names one.

Usage, from the kit's root folder: python3 -I tools/message-ids.py <folder>
where <folder> is the kit folder to check, such as ddev-sidecar.

Exits 1 when a file names an id the message file lacks, or the message file
defines an id twice. Ids that no file names are listed without failing.

Every file in that folder except Markdown and JSON is scanned. A word
counts as an id when its first part, up to the first hyphen, is one the
message file uses (such as build- or guard-) and it is not part of a path, so
a typo in that first part is not caught.
"""

import re
import sys
from collections import Counter
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: message-ids.py <folder>, such as ddev-sidecar")
    root = Path(sys.argv[1])
    found = sorted(path for path in root.rglob("fix-it-messages.txt") if path.is_file())
    if len(found) != 1:
        sys.exit("%s: expected one fix-it-messages.txt, found %d" % (root, len(found)))
    messages = found[0]

    defined = re.findall(r"^\[([^\]\n]+)\]$", messages.read_text(), re.M)
    ids = set(defined)
    families = sorted({name.split("-", 1)[0] for name in ids})
    word = re.compile(r"(?<![\w./-])((?:%s)(?:-[a-z0-9]+)+)(?![\w./-])" % "|".join(map(re.escape, families)))

    callers = sorted(path for path in root.rglob("*")
                     if path.is_file() and path != messages and path.suffix not in (".md", ".json"))
    named = set()
    missing = []
    references = 0
    for path in callers:
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for name in word.findall(line):
                references += 1
                named.add(name)
                if name not in ids:
                    missing.append("%s:%d: %s is not in %s" % (
                        path.relative_to(root), number, name, messages.relative_to(root)))

    duplicated = sorted(name for name, count in Counter(defined).items() if count > 1)
    unused = sorted(ids - named)
    for line in missing:
        print(line)
    for name in duplicated:
        print("%s defines %s more than once" % (messages.relative_to(root), name))
    for name in unused:
        print("no caller names %s" % name)
    print("%d ids, %d references in %d files: %d missing, %d duplicated, %d with no caller" % (
        len(ids), references, len(callers), len(missing), len(duplicated), len(unused)))
    sys.exit(1 if missing or duplicated else 0)


if __name__ == "__main__":
    main()
