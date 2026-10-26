"""Extract or replace a new-file section of a unified patch.

extract <patch> <path> <out>: write the added file's content to <out>.
replace <patch> <path> <content>: rewrite that new-file section from <content>
(or append a new-file section when the patch has none for <path>).
"""
import re
import sys


def sections(text):
    parts = re.split(r"(?m)^(?=diff --git )", text)
    return [p for p in parts if p]


def is_new_file(section, path):
    return section.startswith(f"diff --git a/{path} b/{path}\n") and "\nnew file mode" in section.split("@@", 1)[0]


def build(path, content):
    lines = content.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    body = "".join("+" + line + "\n" for line in lines)
    return (
        f"diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n"
        f"@@ -0,0 +1,{len(lines)} @@\n" + body
    )


def main():
    mode, patch, path, other = sys.argv[1:5]
    text = open(patch).read()
    parts = sections(text)
    if mode == "extract":
        (section,) = [p for p in parts if is_new_file(p, path)]
        hunk = section.split("\n@@", 1)[1].split("\n", 1)[1]
        out = "".join(l[1:] + "\n" for l in hunk.split("\n") if l.startswith("+"))
        open(other, "w").write(out)
    elif mode == "replace":
        new = build(path, open(other).read())
        matches = [i for i, p in enumerate(parts) if is_new_file(p, path)]
        if matches:
            parts[matches[0]] = new
        else:
            parts.append(new)
        open(patch, "w").write("".join(parts))
    else:
        raise SystemExit("unknown mode")


main()
