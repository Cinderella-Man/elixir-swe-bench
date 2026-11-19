"""Rough shell reader: which programs does a bash command line run? Heredoc bodies and quoted text are not commands."""
import re
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "time", "{", "(", "fi", "done", "esac", "in", "for", "case", "function", "select", "}", ")"}
WRAPPERS = {"sudo", "env", "nohup", "exec", "command", "nice", "stdbuf", "setsid", "xargs", "timeout", "time", "builtin"}
BUILTINS = {"cd", "echo", "export", "set", "unset", "true", "false", "exit", "return", "source", ".", "read", "local", "declare", "shift", "wait", "trap", "pushd", "popd", "printf", "test", "[", "[[", ":", "eval", "alias", "break", "continue", "type", "ulimit", "umask", "kill", "let", "readonly", "typeset", "hash", "shopt", "jobs", "fg", "bg", "disown", "getopts", "mapfile", "readarray", "times", "pwd", "dirs", "history", "help", "compgen", "complete", "caller", "enable", "logout", "suspend", "bind", "exec", "command", "builtin"}

def strip_heredocs(cmd):
    """Returns (text without heredoc bodies, [(delimiter, body, line that opened it)])."""
    lines = cmd.split("\n"); out = []; bodies = []; i = 0
    while i < len(lines):
        line = lines[i]; out.append(line)
        probe = re.sub(r"'[^']*'", "''", line) if "<<" in line else line
        tags = [m.group(2) for m in HEREDOC.finditer(line)] if "<<" in probe or "<<" in line else []
        i += 1
        for tag in tags:
            body = []
            while i < len(lines) and lines[i].strip() != tag:
                body.append(lines[i]); i += 1
            i += 1
            bodies.append((tag, "\n".join(body), line))
    return "\n".join(out), bodies

def unquote_scan(text):
    """Replace quoted strings by placeholders; return (text, list of quoted strings)."""
    out = []; quoted = []; i = 0; n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append("X"); i += 2; continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0: j = n
            quoted.append(text[i + 1:j]); out.append(" Q "); i = j + 1; continue
        if c == '"':
            j = i + 1; buf = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n: buf.append(text[j:j + 2]); j += 2; continue
                buf.append(text[j]); j += 1
            s = "".join(buf); quoted.append(s)
            subs = re.findall(r"\$\(([^()]*(?:\([^()]*\)[^()]*)*)\)", s)
            out.append(" Q " + " ".join(f"$( {x} )" for x in subs)); i = j + 1; continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;"):
            j = text.find("\n", i)
            if j < 0: j = n
            i = j; continue
        out.append(c); i += 1
    return "".join(out), quoted

SPLIT = re.compile(r"\|\||&&|\$\(|[;|&\n(){}`]")
def programs(cmd, depth=0):
    """List of (program, argv words) the command line runs, in order."""
    text, bodies = strip_heredocs(cmd)
    flat, quoted = unquote_scan(text)
    found = []
    for seg in SPLIT.split(flat):
        words = seg.split()
        while words:
            w = words[0]
            if w in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w) or re.match(r"^\d*[<>]", w):
                words = words[1:]; continue
            if w in ("sudo", "env", "nohup", "exec", "command", "nice", "stdbuf", "setsid", "time", "builtin"):
                words = words[1:]
                while words and (words[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])): words = words[1:]
                found.append((w, [])); continue
            if w == "timeout":
                found.append((w, [])); words = words[1:]
                while words and words[0].startswith("-"):
                    words = words[2:] if words[0] in ("-k", "-s", "--signal", "--kill-after") else words[1:]
                words = words[1:]; continue
            if w == "xargs":
                found.append((w, [])); words = words[1:]
                while words and words[0].startswith("-"):
                    words = words[2:] if words[0] in ("-I", "-n", "-P", "-d", "-L", "-s", "-E") else words[1:]
                continue
            break
        if not words: continue
        w = words[0]
        if w == "Q" or w.startswith("$") or w.startswith("-") or not re.match(r"^[A-Za-z0-9_./~\[:+-]+$", w): continue
        found.append((w, words[1:]))
        if w == "find" and "-exec" in words:
            k = words.index("-exec")
            if k + 1 < len(words) and words[k + 1] != "Q": found.append((words[k + 1], []))
    if depth < 2:
        # sh -c '...' / bash -lc "..." bodies and $(...) inside double quotes were already flattened; scan sh -c strings
        for m in re.finditer(r"\b(?:ba)?sh\s+-l?c\s+(['\"])", text):
            q = m.group(1); j = text.find(q, m.end())
            if j > 0: found += programs(text[m.end():j], depth + 1)[0]
    return found, bodies
