#!/usr/bin/env python3
"""Ensure a Directory.Build.props exists with two build-hygiene settings.

Lifted from a Claude Code dev-sandbox entrypoint and retargeted: there it wrote
/workspace/Directory.Build.props, here the path is passed in so it can land in
the netclaw workspaces directory.

  NoWarn += NU1510        a PackageReference duplicating a dep already in the
                          SDK/framework is a warning we do not care about
  TreatWarningsAsErrors   false at the root, so a stray warning cannot fail a
                          build the agent is trying to run

Merges into an existing file so user-authored content survives. If the file is
present but unparseable, leaves it completely alone rather than clobbering it.
"""
import os
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]


def make_default():
    root = ET.Element("Project")
    pg = ET.SubElement(root, "PropertyGroup")
    ET.SubElement(pg, "NoWarn").text = "$(NoWarn);NU1510"
    ET.SubElement(pg, "TreatWarningsAsErrors").text = "false"
    return ET.ElementTree(root)


if os.path.exists(path):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        if root.tag.split("}")[-1] != "Project":
            raise ValueError(f"root is <{root.tag}>, not <Project>")
    except Exception as e:
        sys.stderr.write(
            f"[config-init] Directory.Build.props unparseable ({e}); leaving alone\n"
        )
        sys.exit(0)
else:
    tree = make_default()
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=False)
    sys.exit(0)

pg = root.find("PropertyGroup")
if pg is None:
    pg = ET.SubElement(root, "PropertyGroup")

changed = False

nowarn = pg.find("NoWarn")
if nowarn is None:
    ET.SubElement(pg, "NoWarn").text = "$(NoWarn);NU1510"
    changed = True
else:
    existing = (nowarn.text or "").strip()
    tokens = [t.strip() for t in existing.split(";") if t.strip()]
    if "NU1510" not in tokens:
        nowarn.text = (existing + ";NU1510") if existing else "$(NoWarn);NU1510"
        changed = True

twae = pg.find("TreatWarningsAsErrors")
if twae is None:
    ET.SubElement(pg, "TreatWarningsAsErrors").text = "false"
    changed = True
elif (twae.text or "").strip().lower() != "false":
    twae.text = "false"
    changed = True

if changed:
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=False)
