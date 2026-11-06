"""Escáner de literales de cadena de Swift (con interpolaciones anidadas). Devuelve (inicio, fin, contenido) por línea."""
def literals(line):
    out = []; i = 0; n = len(line)
    while i < n:
        c = line[i]
        if c == '/' and i + 1 < n and line[i+1] == '/': break           # comentario
        if c == '#' and i + 1 < n and line[i+1] == '"':                 # raw string: se salta entero
            j = line.find('"#', i + 2)
            i = n if j < 0 else j + 2; continue
        if c == '"':
            if line.startswith('"""', i): return out                    # multilínea: fuera
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
                    if ch == '"':                                        # literal anidado dentro de \( )
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
    """Separa un literal en texto fijo y las interpolaciones \\( ) (con paréntesis y literales anidados)."""
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
    """Regex de la clave que generaría Xcode para el literal: \\( ) → %@/%lld/…, % → %%, escapes resueltos."""
    import re
    esc = {'\\n': '\n', '\\t': '\t', '\\"': '"', '\\\\': '\\', "\\'": "'"}
    parts = split_interp(s)
    # Xcode solo duplica los % si el literal lleva interpolaciones; sin ellas la clave es el texto tal cual
    fixed = [re.sub(r'\\[nt"\\\']', lambda m: esc[m.group(0)], p) for p in parts]
    if len(parts) > 1: fixed = [p.replace('%', '%%') for p in fixed]
    return re.compile(r'(?:%@|%lld|%ld|%d|%lf|%f)'.join(re.escape(p) for p in fixed) + r'\Z')


def multiline_spans(src):
    """Números de línea (1-based) dentro de literales multilínea \"\"\" ... \"\"\"."""
    inside, out = False, set()
    for ln, line in enumerate(src.splitlines(), 1):
        if inside: out.add(ln)
        if line.count('"""') % 2 == 1: inside = not inside
    return out
