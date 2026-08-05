#!/usr/bin/env python3
"""Idempotently maintain a managed block inside identity/AGENTS.md.

    merge-agents.py <agents.md> <block.md>

netclaw does not create AGENTS.md itself — a fresh deployment has SOUL.md but no
AGENTS.md — so this both creates the file and keeps one section of it current.

The block is delimited by HTML comments. Everything outside them is the
operator's (or the agent's) to edit and is never touched; everything inside is
replaced wholesale on every run, so updating agents-block.md propagates on the
next `docker compose up`. Exits 0 with no write when the content already
matches, which keeps `git diff` quiet on repeat runs.
"""
import pathlib
import sys

BEGIN = "<!-- BEGIN nixie:tooling — managed by config-init, edits inside are overwritten -->"
END = "<!-- END nixie:tooling -->"

HEADER = """# Deployment Mission and Operating Playbook

This file describes how this Netclaw deployment performs its job. Keep durable
mission guidance, recurring workflows, skill-selection rules, delegation
practices, and quality checks here.

Do not store secrets, credentials, private customer data, or other audience-
sensitive facts in this file. The same playbook can guide Personal, Team, and
Public conversations and the sub-agents they launch.

## Mission and Desired Outcomes

<!-- What function does this agent perform, for whom, and what does success look like? -->

## Recurring Workflows

<!-- Describe repeatable steps for important tasks. -->

## Organizational Conventions
"""

agents_path = pathlib.Path(sys.argv[1])
block_path = pathlib.Path(sys.argv[2])

block = f"{BEGIN}\n{block_path.read_text().strip()}\n{END}\n"

if agents_path.exists():
    current = agents_path.read_text()
else:
    current = HEADER + "\n"

if BEGIN in current and END in current:
    head, _, rest = current.partition(BEGIN)
    _, _, tail = rest.partition(END)
    updated = head + block + tail.lstrip("\n")
elif BEGIN in current or END in current:
    # Half a marker pair means someone edited one out. Refuse rather than
    # guess at where the block starts or ends and mangle the file.
    sys.stderr.write("[config-init] AGENTS.md has a mismatched nixie:tooling marker; leaving alone\n")
    sys.exit(0)
else:
    updated = current.rstrip("\n") + "\n\n" + block

if updated != current:
    agents_path.write_text(updated)
    print("written")
else:
    print("unchanged")
