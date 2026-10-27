#!/usr/bin/env python3
# Finds a node in a uiautomator dump (stdin) and prints its centre "x y".
# Usage: sis_ui_find.py label|msg <label|alt|alt>. Exit 1: no match. Exit 2: bad usage.
import re
import sys
import xml.etree.ElementTree as ET


def parse_bounds(bounds_str):
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds_str or "")
    return tuple(map(int, match.groups())) if match else None


def centre(b):
    return f"{(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2}"


def find_node(mode, label):
    root = ET.parse(sys.stdin).getroot()
    nodes = [(n, parse_bounds(n.get("bounds"))) for n in root.iter("node")]
    nodes = [(n, b) for n, b in nodes if b]
    if mode in ("label", "msg"):
        for node, b in nodes:
            if mode == "msg" and node.get("class") == "android.widget.EditText":
                continue
            haystack = node.get("text", "") + "\n" + node.get("content-desc", "")
            alts = [a.lower() for a in label.split("|") if a]
            if any(a in haystack.lower() for a in alts):
                print(centre(b))
                return 0
        return 1
    return 2


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(2)
    sys.exit(find_node(sys.argv[1], sys.argv[2]))
