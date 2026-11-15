#!/usr/bin/env python3
"""
The agent-loop tests' scripted model (../agentloop/mock_openai.py) with the
scenarios of lucibridge_promote_test.sh.

Usage: mock.py LOGFILE   (prints the bound port, then serves)
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "mock_openai", os.path.join(HERE, "..", "agentloop", "mock_openai.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
tool = m.tool

NOTES = "/usr/lbtest/notes"
MORE = "/usr/lbtest/more"
ELSEWHERE = "/usr/lbtest/home/.ssh"

m.SCENARIOS.update({
    # --- lucibridge_promote_test.sh ---
    # A task given one folder to write; its model goes for the overlay's
    # own records through its tools, the forged base as its last call
    # (each tool call's cowfs writes the base again when it starts).
    "forge_delegate": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Editor tools=write,read paths=" + NOTES +
                                         " brief=SCENARIO:child_forge go"})]},
        {"content": "Started the editor."},
    ],
    "child_forge": [
        {"tools": [tool("write", {"path": NOTES + "/authorized_keys",
                                  "content": "ssh-ed25519 AAAA-TASK-KEY\n"}),
                   tool("read", {"path": NOTES + "/.cowmeta"})]},
        {"tools": [tool("write", {"path": NOTES + "/.cowbase", "content": "\n"})]},
        {"tools": [tool("write", {"path": NOTES + "/.whiteout", "content": "todo.txt\n"})]},
        {"tools": [tool("write", {"path": NOTES + "/.cowmeta",
                                  "content": "basepath=" + ELSEWHERE + "\n"})]},
        {"content": "Tidied the notes. SCENARIO:forge_promote"},
    ],
    "forge_promote": [
        {"tools": [tool("task", {"command": "promote", "args": "1"})]},
        {"content": "Promoted the edit."},
    ],
    # A second task, which only writes a file; the test changes its
    # overlay's record itself.
    "plain_delegate": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Second tools=write paths=" + MORE +
                                         " brief=SCENARIO:child_plain go"})]},
        {"content": "Started the second."},
    ],
    "child_plain": [
        {"tools": [tool("write", {"path": MORE + "/m2.txt", "content": "from task 2\n"})]},
        {"content": "Wrote the file."},
    ],
    "second_promote": [
        {"tools": [tool("task", {"command": "promote", "args": "2"})]},
        {"content": "Asked for the second."},
    ],
})

if __name__ == "__main__":
    m.main()
