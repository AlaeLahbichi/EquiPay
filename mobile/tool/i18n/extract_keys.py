import sys, re, json, glob
sys.path.insert(0, sys.argv[1])
from i18n_wrap import tokenize, group

def unesc(t):
    return re.sub(r"\\(.)", lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), t)

def text_of(g):
    out = ''
    for l in g:
        for k, t in l['parts']:
            out += unesc(t) if k == 's' else '${' + t + '}'
    return out

keys = []
def add(k):
    if k and re.search(r'[A-Za-zÀ-ÿ]', k) and k not in keys and '${' not in k:
        keys.append(k)

ENUM_ARGS = {'ActivityType': [0], 'TravelMode': [0, 2], '_Sort': [0], '_Measure': [0, 1], 'MemberSort': [0],
             'Plan': [0, 2], 'PlanFeature': [0], 'BudgetCategory': [0]}
for path in sorted(glob.glob('lib/**/*.dart', recursive=True)):
    if '/l10n/' in path:
        continue
    src = open(path).read()
    lits = tokenize(src)
    for g in group(src, lits):
        start, end = g[0]['start'], g[-1]['end']
        before = src[max(0, start - 20):start]
        if re.search(r'\btr\(\s*$', before) or src[end:end + 3] == '.tr':
            add(text_of(g))
    # valeurs d'enums
    for m in re.finditer(r'\benum\s+(\w+)[^{]*\{', src):
        name = m.group(1)
        if name not in ENUM_ARGS:
            continue
        body = src[m.end():src.index(';', m.end())]
        for vm in re.finditer(r'^\s*\w+\((.*?)\)[,;]?\s*$', body, re.M | re.S):
            pass
        for call in re.finditer(r'\b\w+\(((?:[^()]|\([^()]*\))*)\)', body):
            for l in tokenize(call.group(1)):
                add(text_of([l]))
    # listes constantes affichées avec .tr
    for lm in re.finditer(r'static const (_features|suggestions|usages|referrals|countries) = \[(.*?)\n  \];', src, re.S):
        for g in group(lm.group(2), tokenize(lm.group(2))):
            t = text_of(g)
            if not re.fullmatch(r'[a-z_]+', t):
                add(t)
    if path.endswith('money.dart'):
        for cm in re.finditer(r"Currency\('[A-Z]{3}', '((?:[^'\\]|\\.)*)'", src):
            add(unesc(cm.group(1)))
add('Autre')
# messages des fonctions de la base
for path in sorted(glob.glob('../supabase/migrations/*.sql')):
    for m in re.finditer(r"raise exception '((?:[^']|'')*)'", open(path).read()):
        t = m.group(1).replace("''", "'")
        if '%' not in t and re.search(r'[a-zé]', t):
            add(t)
# Les numéros déjà traduits ne bougent pas : les nouveaux textes s'ajoutent à la fin
import os
old = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else []
merged = old + [k for k in keys if k not in old]
json.dump(merged, open(sys.argv[2], 'w'), ensure_ascii=False, indent=0)
print(len(merged), 'clés,', len(merged) - len(old), 'nouvelles')
