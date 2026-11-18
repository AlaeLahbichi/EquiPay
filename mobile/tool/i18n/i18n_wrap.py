"""Entoure les textes affichés (français) des fichiers Dart avec tr(...).

- 'Texte'                      -> tr('Texte')
- 'Payé par ${a} · $b'          -> tr('Payé par {0} · {1}', [a, b])
- 'Ligne 1 ' 'ligne 2'          -> tr('Ligne 1 ' 'ligne 2')
Les chaînes techniques (SQL, clés, chemins, comparaisons) sont laissées telles quelles.
Usage : python3 i18n_wrap.py fichier.dart...
"""
import re
import sys

CTX_SKIP = re.compile(
    r"(\.(select|from|eq|neq|rpc|or|order|channel|not|isFilter|inFilter|gte|gt|lt|lte|upsert|insert|update|"
    r"contains|startsWith|endsWith|replaceAll|split|getString|setString|getBool|setBool|getStringList|"
    r"setStringList|remove|byName|asNameMap|containsKey|invokeMethod|storage|getPublicUrl|like|ilike)\s*\(\s*$)"
    r"|(RegExp|ValueKey|Key|PageStorageKey|asset|Image\.asset|AssetImage|Uri\.parse|Uri\.https|Uri\.http|"
    r"print|debugPrint|ArgumentError|StateError|UnimplementedError|Locale|tr|Text\.rich_skip)\s*\(\s*$"
    r"|(==|!=)\s*$|\bcase\s+$|heroTag:\s*$|fontFamily:\s*$|restorationId:\s*$|@pragma\(\s*$|\bimport\s+$|"
    r"\bexport\s+$|\bpart\s+$|semanticsIdentifier:\s*$|payload:\s*$|channel\s*$"
)


def tokenize(src):
    """Renvoie la liste des littéraux : (début, fin, texte statique avec {n}, [expressions], brut)."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        raw = False
        start = i
        if c == 'r' and i + 1 < n and src[i + 1] in '\'"' and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == '_')):
            raw = True
            i += 1
            c = src[i]
        if c in '\'"':
            q = src[i:i + 3] if src[i:i + 3] in ("'''", '"""') else c
            i += len(q)
            parts = []  # ('s', text) | ('e', expr)
            buf = []
            while i < n and not src.startswith(q, i):
                ch = src[i]
                if ch == '\\' and not raw:
                    buf.append(src[i:i + 2])
                    i += 2
                    continue
                if ch == '$' and not raw:
                    if i + 1 < n and src[i + 1] == '{':
                        depth, j = 1, i + 2
                        # parcours de l'expression (chaînes imbriquées comprises)
                        while j < n and depth:
                            if src[j] in '\'"':
                                qq = src[j]
                                j += 1
                                while j < n and src[j] != qq:
                                    if src[j] == '\\':
                                        j += 1
                                    elif src[j] == '$' and j + 1 < n and src[j + 1] == '{':
                                        d2, j = 1, j + 2
                                        while j < n and d2:
                                            if src[j] == '{':
                                                d2 += 1
                                            elif src[j] == '}':
                                                d2 -= 1
                                            j += 1
                                        continue
                                    j += 1
                                j += 1
                                continue
                            if src[j] == '{':
                                depth += 1
                            elif src[j] == '}':
                                depth -= 1
                            j += 1
                        if buf:
                            parts.append(('s', ''.join(buf)))
                            buf = []
                        parts.append(('e', src[i + 2:j - 1]))
                        i = j
                        continue
                    m = re.match(r'\$([A-Za-z_][A-Za-z0-9_]*)', src[i:])
                    if m:
                        if buf:
                            parts.append(('s', ''.join(buf)))
                            buf = []
                        parts.append(('e', m.group(1)))
                        i += len(m.group(0))
                        continue
                buf.append(ch)
                i += 1
            if buf:
                parts.append(('s', ''.join(buf)))
            i += len(q)
            out.append({'start': start, 'end': i, 'parts': parts, 'raw': raw, 'quote': q})
            continue
        i += 1
    return out


def group(src, lits):
    """Regroupe les littéraux adjacents ('a' 'b')."""
    groups = []
    for lit in lits:
        if groups and re.fullmatch(r'\s*', src[groups[-1][-1]['end']:lit['start']]):
            groups[-1].append(lit)
        else:
            groups.append([lit])
    return groups


def visible(text):
    t = text.strip()
    if not re.search(r'[A-Za-zÀ-ÿ]', t):
        return False
    if re.match(r'^(package:|dart:|https?:|assets/|io\.|com\.|@|#|\.\./|\./)', t):
        return False
    if re.fullmatch(r'[a-z0-9_.:/\-]+', t):  # clé, nom de colonne, identifiant
        return False
    if re.search(r'\w_\w', t) and not re.search(r'[À-ÿ]', t) and ' ' not in t.strip():
        return False
    if '*,' in t or re.search(r'\b[a-z_]+\([a-z_, ]+\)', t):  # requêtes select
        return False
    if re.fullmatch(r'[A-Z]{3}', t):  # code devise
        return False
    return bool(re.search(r'[À-ÿ ]', t) or t[0].isupper() or t[-1] in '.!?…:')


def enum_ranges(src):
    """Zones où un appel tr(...) est impossible : valeurs d'enum, déclarations const."""
    ranges = []
    for m in re.finditer(r'\benum\s+\w+[^{]*\{', src):
        depth, j = 1, m.end()
        while j < len(src) and depth:
            if src[j] in '([{':
                depth += 1
            elif src[j] in ')]}':
                depth -= 1
            elif src[j] == ';' and depth == 1:
                break
            j += 1
        ranges.append((m.end(), j))
    for m in re.finditer(r'\b(static\s+const|^const)\s+[\w<>, ?]+\s*=', src, re.M):
        j = src.find(';\n', m.end())
        ranges.append((m.start(), j))
    return ranges


def convert(src):
    lits = tokenize(src)
    ranges = enum_ranges(src)
    edits = []
    for g in group(src, lits):
        start, end = g[0]['start'], g[-1]['end']
        if any(a <= start < b for a, b in ranges):
            continue
        if any(l['raw'] or len(l['quote']) == 3 for l in g):
            continue
        before = src[max(0, start - 80):start]
        line_before = before.split('\n')[-1]
        after = src[end:end + 6]
        if CTX_SKIP.search(line_before) or re.match(r'\s*:', after) and re.search(r'[{,]\s*$', line_before):
            continue
        if re.match(r'\s*(==|!=)', after) or after.startswith('.tr') or re.search(r'\btr\(\s*$', line_before):
            continue
        static = ''.join(t for l in g for k, t in l['parts'] if k == 's')
        if not visible(static):
            continue
        q = g[0]['quote']
        args = []
        pieces = []
        for l in g:
            text = ''
            for kind, t in l['parts']:
                if kind == 's':
                    text += t
                else:
                    text += '{%d}' % len(args)
                    args.append(convert(t))  # textes imbriqués dans l'expression
            pieces.append(l['quote'] + text + l['quote'])
        sep = [src[a['end']:b['start']] for a, b in zip(g, g[1:])]
        joined = pieces[0] + ''.join(s + p for s, p in zip(sep, pieces[1:]))
        repl = 'tr(%s)' % joined if not args else 'tr(%s, [%s])' % (joined, ', '.join(args))
        edits.append((start, end, repl))
    for start, end, repl in reversed(edits):
        src = src[:start] + repl + src[end:]
    return src


def main():
    for path in sys.argv[1:]:
        src = open(path, encoding='utf-8').read()
        new = convert(src)
        if new != src:
            if "l10n/i18n.dart'" not in new:
                depth = ('/' + path).split('/lib/')[1].count('/')
                imp = "import '%sl10n/i18n.dart';\n" % ('../' * depth)
                m = list(re.finditer(r"^import [^\n]+\n", new, re.M))
                pos = m[-1].end() if m else 0
                new = new[:pos] + imp + new[pos:]
            open(path, 'w', encoding='utf-8').write(new)
            print('✓', path)


if __name__ == '__main__':
    main()
