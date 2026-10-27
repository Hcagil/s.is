#!/usr/bin/env python3
# Finds a node in a uiautomator dump (stdin) and prints its centre "x y".
# Usage: sis_ui_find.py label|msg|send <label>. Exit 1: no match. Exit 2: bad usage.
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
            if label.lower() in haystack.lower():
                print(centre(b))
                return 0
        return 1
    if mode == "send":
        edits = [b for n, b in nodes if n.get("class") == "android.widget.EditText"]
        if not edits:
            return 1
        ex1, ey1, ex2, ey2 = edits[0]
        candidates = [
            b
            for n, b in nodes
            if n.get("clickable") == "true" and b[0] >= ex2 - 5 and b[1] < ey2 and b[3] > ey1
        ]
        if not candidates:
            return 1
        print(centre(max(candidates, key=lambda b: b[0])))
        return 0
    return 2


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(2)
    sys.exit(find_node(sys.argv[1], sys.argv[2]))
