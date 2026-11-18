import json, re, sys
sp, lang, out = sys.argv[1], sys.argv[2], sys.argv[3]
keys = json.load(open(f'{sp}/keys.json'))
vals = {}
for line in open(f'{sp}/tr_{lang}.txt', encoding='utf-8').read().split('\n'):
    if not line.strip():
        continue
    i, _, t = line.partition('\t')
    vals[int(i)] = t.replace('\\n', '\n')
for i in list(vals):
    k = keys[i] if i < len(keys) else ''
    v = vals[i].strip(' ')
    vals[i] = (' ' if k.startswith(' ') else '') + v + (' ' if k.endswith(' ') else '')
missing = [i for i in range(len(keys)) if i not in vals]
bad = []
for i, k in enumerate(keys):
    if i in vals:
        ph_k, ph_t = set(re.findall(r'\{\d\}', k)), set(re.findall(r'\{\d\}', vals[i]))
        if not ph_t <= ph_k:
            bad.append((i, k, vals[i]))
        # espaces de début/fin conservés
        if k.startswith(' ') != vals[i].startswith(' ') or k.endswith(' ') != vals[i].endswith(' '):
            bad.append((i, 'espaces', repr(vals[i])))
print(lang, 'manquants:', missing[:20], len(missing), 'problèmes:', bad[:10])
def dart(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$').replace('\n', '\\n') + "'"
name = 'translations' + lang.capitalize()
lines = [f'// Traductions : texte français → {lang}. Généré à partir des textes de l\'app ; un texte absent s\'affiche en français.',
         f'const {name} = <String, String>{{']
for i, k in enumerate(keys):
    if i in vals and vals[i] != k:
        lines.append(f'  {dart(k)}: {dart(vals[i])},')
lines.append('};\n')
open(out, 'w', encoding='utf-8').write('\n'.join(lines))
