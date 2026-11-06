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
