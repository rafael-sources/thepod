"""Swift string literal scanner (with nested interpolations). Returns (start, end, content) per line."""
def literals(line):
    out = []; i = 0; n = len(line)
    while i < n:
        c = line[i]
        if c == '/' and i + 1 < n and line[i+1] == '/': break           # comment
        if c == '#' and i + 1 < n and line[i+1] == '"':                 # raw string: skipped entirely
            j = line.find('"#', i + 2)
            i = n if j < 0 else j + 2; continue
        if c == '"':
            if line.startswith('"""', i): return out                    # multiline: out
            j = i + 1; depth = 0; body = ''
            while j < n:
                ch = line[j]
                if depth == 0:
                    if ch == '\\' and j + 1 < n:
                        if line[j+1] == '(': depth = 1; body += '\\('; j += 2; continue
                        body += ch + line[j+1]; j += 2; continue
                    if ch == '"': break
                    body += ch; j += 1
                else:
                    if ch == '"':                                        # nested literal inside \( )
                        k = j + 1
                        while k < n and line[k] != '"':
                            if line[k] == '\\': k += 1
                            k += 1
                        body += line[j:k+1]; j = k + 1; continue
                    if ch == '(': depth += 1
                    elif ch == ')': depth -= 1
                    body += ch; j += 1
            out.append((i, j + 1, body)); i = j + 1; continue
        i += 1
    return out


def split_interp(s):
    """Splits a literal into fixed text and the \\( ) interpolations (with nested parentheses and literals)."""
    parts, cur, i, n = [], '', 0, len(s)
    while i < n:
        if s.startswith('\\(', i):
            d, j = 1, i + 2
            while j < n and d:
                if s[j] == '"':
                    k = j + 1
                    while k < n and s[k] != '"':
                        if s[k] == '\\': k += 1
                        k += 1
                    j = k + 1; continue
                d += s[j] == '('; d -= s[j] == ')'; j += 1
            parts.append(cur); cur = ''; i = j
        elif s[i] == '\\' and i + 1 < n: cur += s[i:i+2]; i += 2
        else: cur += s[i]; i += 1
    parts.append(cur)
    return parts


def key_regex(s):
    """Regex of the key Xcode would generate for the literal: \\( ) → %@/%lld/…, % → %%, escapes resolved."""
    import re
    esc = {'\\n': '\n', '\\t': '\t', '\\"': '"', '\\\\': '\\', "\\'": "'"}
    parts = split_interp(s)
    # Xcode only doubles % if the literal has interpolations; without them the key is the text as is
    fixed = [re.sub(r'\\[nt"\\\']', lambda m: esc[m.group(0)], p) for p in parts]
    if len(parts) > 1: fixed = [p.replace('%', '%%') for p in fixed]
    return re.compile(r'(?:%@|%lld|%ld|%d|%lf|%f)'.join(re.escape(p) for p in fixed) + r'\Z')


def multiline_spans(src):
    """Line numbers (1-based) inside multiline literals \"\"\" ... \"\"\"."""
    inside, out = False, set()
    for ln, line in enumerate(src.splitlines(), 1):
        if inside: out.add(ln)
        if line.count('"""') % 2 == 1: inside = not inside
    return out
