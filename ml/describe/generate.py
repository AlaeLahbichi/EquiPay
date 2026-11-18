"""Générateur de phrases « Décrire la dépense » avec la réponse exacte attendue.

Chaque exemple combine : quoi (catégorie, commerce), combien (montant + devise écrits de mille façons),
quand (date relative), qui a payé, pour qui (avec, pour, tout le monde sauf…), comment répartir
(parts égales, %, montants, parts) et le détail des articles. 4 styles : français, SMS, darija, anglais.
Les variantes de formulation marquées « test » ne servent jamais à l'entraînement.
"""
import calendar
import datetime as dt
import random
import unicodedata

from schema import empty

NAMES = ["Sara", "Yassine", "Karim", "Imane", "Omar", "Salma", "Mehdi", "Nadia", "Hamza", "Lina", "Youssef", "Ines",
         "Hugo", "Lea", "Thomas", "Camille", "Amine", "Rania", "Adam", "Zineb", "Anas", "Ayoub", "Meryem", "Nora",
         "Lucas", "Emma", "Paul", "Julie", "Reda", "Ghita", "Othmane", "Kenza", "Ilyas", "Hiba", "Walid", "Soukaina",
         "Maxime", "Chloe", "Nicolas", "Sofia", "Bilal", "Douae", "Ali", "Fatima", "Said", "Houda", "Malak", "Ismail"]

# code : (part du jeu, facteur depuis l'euro, mots par style, décimales habituelles)
CURRENCIES = {
    "EUR": (0.34, 1.0, {"fr": ["€", " €", " euros", " eur", " EUR"], "en": ["€", " euros", " EUR"], "dj": [" euro", "€", " euros"], "sms": ["€", "e", " euros", " eur"]}),
    "MAD": (0.34, 10.9, {"fr": [" dh", " dhs", " dirhams", " MAD", "dh"], "en": [" MAD", " dirhams", " dh"], "dj": [" dh", " drahem", " dirham", "dh"], "sms": ["dh", " dh", " dhs", "dhs"]}),
    "USD": (0.10, 1.1, {"fr": [" dollars", " $", " USD"], "en": ["$", " dollars", " USD", " bucks"], "dj": [" dollar", " $"], "sms": ["$", " dollars"]}),
    "GBP": (0.04, 0.86, {"fr": [" livres", " £", " GBP"], "en": ["£", " pounds", " quid"], "dj": [" pound"], "sms": ["£", " livres"]}),
    "CHF": (0.03, 0.94, {"fr": [" CHF", " francs suisses"], "en": [" CHF", " Swiss francs"], "dj": [" CHF"], "sms": [" chf"]}),
    "TND": (0.03, 3.4, {"fr": [" DT", " dinars tunisiens", " TND"], "en": [" TND", " Tunisian dinars"], "dj": [" dinar tounsi", " DT"], "sms": [" dt", " tnd"]}),
    "DZD": (0.02, 145.0, {"fr": [" DA", " dinars algériens", " DZD"], "en": [" DZD", " Algerian dinars"], "dj": [" DA"], "sms": [" da"]}),
    "TRY": (0.03, 38.0, {"fr": [" livres turques", " TL", " TRY"], "en": [" lira", " TL", " TRY"], "dj": [" lira"], "sms": [" tl"]}),
    "AED": (0.03, 4.0, {"fr": [" AED", " dirhams émiratis"], "en": [" AED", " dirhams (UAE)"], "dj": [" AED"], "sms": [" aed"]}),
    "SAR": (0.02, 4.1, {"fr": [" riyals", " SAR"], "en": [" riyals", " SAR"], "dj": [" riyal"], "sms": [" sar"]}),
    "CAD": (0.01, 1.5, {"fr": [" dollars canadiens", " CAD"], "en": [" CAD", " Canadian dollars"], "dj": [" CAD"], "sms": [" cad"]}),
    "JPY": (0.01, 165.0, {"fr": [" yens", " JPY", "¥"], "en": [" yen", "¥", " JPY"], "dj": [" yen"], "sms": [" yens"]}),
}

# titre, mots par style, commerces, articles (nom, prix min, prix max en euros), montant min/max en euros
CATEGORIES = [
    ("Restaurant", {"fr": ["resto", "restaurant", "dîner", "déjeuner", "repas", "déj"], "en": ["dinner", "lunch", "restaurant", "meal"], "dj": ["l3cha", "lghda", "resto", "makla"]},
     ["Dar Moha", "Le Jardin", "Café Clock", "Pizza Hut", "Nomad", "La Sqala", "Chez Ali", "Le Petit Zinc", "Sushi Box", "Al Fassia", "Big Mama"],
     [("Tajine", 8, 15), ("Couscous", 9, 16), ("Pizza", 9, 15), ("Coca", 2, 4), ("Thé", 1, 3), ("Salade", 6, 11), ("Dessert", 4, 8), ("Burger", 8, 14)], (20, 160)),
    ("Café", {"fr": ["café", "petit-déj", "brunch", "petit déjeuner"], "en": ["coffee", "breakfast", "brunch"], "dj": ["9hwa", "ftour", "café"]},
     ["Starbucks", "Paul", "Café de France", "Venezia Ice", "Amandine"], [("Café", 1.5, 4), ("Croissant", 1, 3), ("Jus d'orange", 3, 6), ("Crêpe", 3, 6)], (4, 40)),
    ("Courses", {"fr": ["courses", "supermarché", "provisions", "épicerie"], "en": ["groceries", "shopping", "supermarket"], "dj": ["l9adya", "courses", "lmo9adiya"]},
     ["Marjane", "Carrefour", "Lidl", "Monoprix", "BIM", "Acima", "Franprix"], [("Eau", 1, 3), ("Pain", 1, 2), ("Lait", 1, 2), ("Fruits", 3, 8), ("Viande", 8, 20), ("Pâtes", 1, 3)], (12, 200)),
    ("Taxi", {"fr": ["taxi", "uber", "vtc", "petit taxi", "course en taxi"], "en": ["taxi", "uber", "cab", "ride"], "dj": ["taxi", "careem", "tomobil"]},
     ["Uber", "Careem", "Heetch", "Bolt"], [], (3, 60)),
    ("Essence", {"fr": ["essence", "plein", "carburant", "gasoil"], "en": ["gas", "fuel"], "dj": ["lisans", "lmazot", "l'essence"]},
     ["Afriquia", "Total", "Shell", "Winxo"], [], (25, 120)),
    ("Hébergement", {"fr": ["hôtel", "nuit d'hôtel", "riad", "airbnb", "logement"], "en": ["hotel", "airbnb", "accommodation"], "dj": ["lotel", "riad", "airbnb"]},
     ["Riad Yasmine", "Ibis", "Hotel Atlas", "Riad Dar Anika", "Kenzi"], [], (50, 600)),
    ("Transport", {"fr": ["billets de train", "train", "TGV", "billets de bus", "billets d'avion"], "en": ["train tickets", "bus tickets", "plane tickets"], "dj": ["tran", "lkar", "tickets dial tran"]},
     ["ONCF", "SNCF", "Al Boraq", "CTM", "Ryanair"], [("Billet", 10, 60)], (10, 300)),
    ("Sortie", {"fr": ["ciné", "cinéma", "bowling", "concert", "musée", "excursion", "quad", "hammam"], "en": ["movie", "bowling", "concert", "museum", "tour", "quad ride"], "dj": ["cinema", "quad", "hammam", "tsara"]},
     ["Pathé", "Mégarama", "Atlas Quad", "Hammam Mouassine", "Musée YSL"], [("Place", 8, 15), ("Popcorn", 4, 7)], (8, 200)),
    ("Bar", {"fr": ["verres", "bar", "soirée", "apéro"], "en": ["drinks", "bar", "night out"], "dj": ["soirée", "bar"]},
     ["Le Comptoir", "Sky Bar", "Le Duke"], [("Bière", 4, 8), ("Cocktail", 8, 14), ("Soda", 2, 4)], (15, 150)),
    ("Parking / péage", {"fr": ["parking", "péage", "autoroute"], "en": ["parking", "toll"], "dj": ["parking", "l'autoroute", "péage"]},
     [], [], (2, 30)),
    ("Location de voiture", {"fr": ["location de voiture", "loc voiture", "voiture de location"], "en": ["car rental", "rental car"], "dj": ["location dial tomobil", "kra dial tomobil"]},
     ["Hertz", "Avis", "Europcar", "Sixt"], [], (40, 400)),
    ("Pharmacie", {"fr": ["pharmacie", "médicaments"], "en": ["pharmacy", "medicine"], "dj": ["dwa", "pharmacie"]},
     ["Pharmacie Centrale"], [("Doliprane", 2, 5), ("Pansements", 2, 6)], (4, 60)),
    ("Cadeau", {"fr": ["cadeau", "cadeau d'anniversaire", "fleurs"], "en": ["gift", "birthday present", "flowers"], "dj": ["cadeau", "hdiya"]},
     ["Fnac", "Sephora", "Zara"], [], (10, 200)),
    ("Loyer", {"fr": ["loyer", "loyer de l'appart"], "en": ["rent"], "dj": ["lkra", "kra dial dar"]}, [], [], (300, 1500)),
    ("Factures", {"fr": ["facture d'électricité", "facture internet", "wifi", "facture d'eau"], "en": ["electricity bill", "internet bill", "wifi"], "dj": ["dow", "lwifi", "lma"]},
     ["Lydec", "Maroc Telecom", "Orange", "inwi", "EDF"], [], (15, 120)),
]

MONTHS_FR = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
MONTHS_EN = list(calendar.month_name)[1:]
WD = {"fr": ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"],
      "en": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
      "dj": ["letnin", "tlat", "larb3", "lkhmis", "jjem3a", "ssebt", "l7ed"]}

NON_EXPENSE = {
    "fr": ["c'est quoi mon solde ?", "combien je dois à {n} ?", "qui doit de l'argent ?", "salut ça va ?", "comment ajouter un membre ?",
           "rappelle à {n} de me rembourser", "on se voit {d} ?", "merci !", "supprime la dernière dépense", "quel est le total du voyage ?",
           "{n} m'a remboursé {d}", "on fait les comptes {d} ?", "tu peux m'aider ?", "c'est qui qui a payé le {w} ?", "combien on a dépensé pour le {w} ?",
           "{n} me doit combien ?", "j'ai remboursé {n}", "modifie la dépense du {w}", "on part à quelle heure {d} ?", "qui vient au {w} {d} ?",
           "est-ce que {n} a payé sa part ?", "montre-moi les dépenses de {n}", "on partage comment le {w} ?", "{n} est en retard",
           "bonne nuit tout le monde", "c'était trop bien {d} !", "il reste combien dans la caisse ?", "envoie le récap à {n}"],
    "en": ["how much do I owe {n}?", "hello", "what's my balance?", "who still owes money?", "thanks!", "can you help me?", "delete the last expense",
           "did {n} pay back?", "who paid for the {w}?", "how much did we spend on the {w}?", "{n} paid me back {d}", "see you {d}",
           "what time do we leave {d}?", "send the summary to {n}"],
    "dj": ["ch7al katsal liya {n}?", "salam labas?", "chkon li mazal ma khelsch?", "chokran", "kifach nzid chi wa7ed?", "ch7al kayn f lkhzina?",
           "{n} rje3 lia flousi {d}", "chkon li khelles {w}?", "ch7al sre3na f {w}?", "fin ghadi n9essro {d}?", "{n} khlles lia",
           "wach {n} khlles?", "bslama", "nta3rfo {d} f {w}"],
}
NON_EXPENSE_FILL = {"d": {"fr": ["demain", "hier", "ce soir", "samedi", "la semaine prochaine"], "en": ["tomorrow", "yesterday", "tonight", "on Saturday"],
                          "dj": ["ghda", "lbare7", "had l3chiya", "ssebt"]},
                    "w": {"fr": ["resto", "taxi", "riad", "voyage", "ciné", "loyer", "plein"], "en": ["dinner", "taxi", "hotel", "trip", "rent"],
                          "dj": ["l3cha", "taxi", "riad", "safar", "lkra"]}}

def deaccent(text):
    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()


class Gen:
    def __init__(self, seed, split):
        self.rng = random.Random(seed)
        self.split = split

    def pick(self, options):
        """La dernière variante d'une liste de 3+ est réservée au test (formulations jamais vues)."""
        if len(options) >= 3:
            if self.split != "test":
                return self.rng.choice(options[:-1])
            if self.rng.random() < 0.5:
                return options[-1]
        return self.rng.choice(options)

    # ---------------------------------------------------------------- montants
    def money(self, value, code, style, whole):
        decimals = 0 if whole else 2
        if style in ("en",) or (style in ("dj", "sms") and self.rng.random() < 0.5) or (code in ("USD", "GBP", "CAD") and self.rng.random() < 0.6):
            sep_dec, sep_thou = ".", self.rng.choice([",", ""])
        else:
            sep_dec, sep_thou = ",", self.rng.choice([" ", ".", ""])
        whole_part, cents = divmod(round(value * 100), 100)
        digits = f"{whole_part:d}"
        if sep_thou and whole_part >= 1000:
            groups = []
            while digits:
                groups.insert(0, digits[-3:])
                digits = digits[:-3]
            digits = sep_thou.join(groups)
        num = digits + (f"{sep_dec}{cents:02d}" if decimals else "")
        word = self.pick(CURRENCIES[code][2]["sms" if style == "sms" else style])
        if word.strip() in ("$", "£", "€", "¥") and self.rng.random() < 0.5:
            return word.strip() + num
        return num + word

    def amount_value(self, eur_min, eur_max, code):
        factor = CURRENCIES[code][1]
        value = self.rng.uniform(eur_min, eur_max) * factor
        if factor >= 30 or self.rng.random() < 0.55:
            step = 100 if factor >= 100 else (10 if factor >= 10 and value > 100 else 1)
            return float(max(step, round(value / step) * step)), True
        return round(value, 2), False

    # ---------------------------------------------------------------- dates
    def date_phrase(self, today, style):
        kind = self.rng.choices(["none", "today", "yesterday", "before", "weekday", "weekday_last", "dom", "dm", "num"],
                                [0.28, 0.12, 0.18, 0.05, 0.1, 0.07, 0.07, 0.07, 0.06])[0]
        st = "fr" if style == "sms" else style
        if kind == "none":
            return None, None
        if kind == "today":
            return self.pick({"fr": ["aujourd'hui", "ce midi", "ce soir", "ce matin", "tout à l'heure"], "en": ["today", "tonight", "this morning", "earlier today"],
                              "dj": ["lyoum", "lyouma", "had sba7", "had l3chiya"]}[st]), today
        if kind == "yesterday":
            return self.pick({"fr": ["hier", "hier soir", "hier midi", "hier matin"], "en": ["yesterday", "last night", "yesterday evening"],
                              "dj": ["lbare7", "lbar7", "lbare7 f lil"]}[st]), today - dt.timedelta(days=1)
        if kind == "before":
            return {"fr": "avant-hier", "en": "the day before yesterday", "dj": "nhar lowel"}[st], today - dt.timedelta(days=2)
        if kind in ("weekday", "weekday_last"):
            back = self.rng.randint(2, 6)
            day = today - dt.timedelta(days=back)
            name = WD[st][day.weekday()]
            if kind == "weekday":
                text = {"fr": self.pick([name, f"{name} soir", f"ce {name}"]), "en": self.pick([f"on {name}", f"{name}", f"{name} night"]),
                        "dj": self.pick([f"nhar {name}", name])}[st]
            else:
                text = {"fr": self.pick([f"{name} dernier", f"{name} passé"]), "en": f"last {name}", "dj": f"{name} li fat"}[st]
            return text, day
        day = today - dt.timedelta(days=self.rng.randint(1, 60))
        if kind == "dom":
            if day.month != today.month:
                day = today.replace(day=self.rng.randint(1, today.day)) if today.day > 1 else today
            return {"fr": f"le {day.day}", "en": f"on the {day.day}{'st' if day.day in (1, 21, 31) else 'nd' if day.day in (2, 22) else 'rd' if day.day in (3, 23) else 'th'}",
                    "dj": f"nhar {day.day}"}[st], day
        if kind == "dm":
            return {"fr": f"le {day.day} {MONTHS_FR[day.month - 1]}", "en": f"on {MONTHS_EN[day.month - 1]} {day.day}", "dj": f"nhar {day.day} {MONTHS_FR[day.month - 1]}"}[st], day
        return {"fr": f"le {day.day:02d}/{day.month:02d}", "en": f"on {day.month:02d}/{day.day:02d}", "dj": f"{day.day:02d}/{day.month:02d}"}[st], day

    # ---------------------------------------------------------------- personnes
    def name_text(self, name, style):
        """Prénom écrit comme dans un message : minuscule, petite faute… (la réponse garde le vrai nom)."""
        r = self.rng.random()
        if style == "sms" or r < 0.25:
            name = name.lower()
        if self.rng.random() < 0.06 and len(name) > 3:
            i = self.rng.randrange(1, len(name) - 1)
            name = name[:i] + name[i] * 2 + name[i + 1:] if self.rng.random() < 0.5 else name[:i] + name[i + 1:]
        return name

    def join(self, names, style):
        names = [self.name_text(n, style) if n != "moi" else {"en": "me", "dj": "ana"}.get(style, "moi") for n in names]
        if len(names) == 1:
            return names[0]
        sep = {"en": " and ", "dj": " w "}.get(style, " et ")
        return ", ".join(names[:-1]) + sep + names[-1]

    def make(self):
        rng = self.rng
        members = rng.sample(NAMES, rng.randint(2, 7))
        me = rng.choice(members)
        others = [m for m in members if m != me]
        today = dt.date(2025, 1, 1) + dt.timedelta(days=rng.randint(0, 680))
        activity_currency = rng.choices(["EUR", "MAD", "USD", "GBP", "CHF"], [0.45, 0.4, 0.07, 0.04, 0.04])[0]
        style = rng.choices(["fr", "sms", "dj", "en"], [0.42, 0.2, 0.2, 0.18])[0]
        st = "fr" if style == "sms" else style
        meta = {"style": style, "members": members, "me": me, "today": today, "currency": activity_currency}

        if rng.random() < 0.08:  # pas une dépense
            sentence = self.pick(NON_EXPENSE[st]).replace("{n}", self.name_text(rng.choice(others), style))
            for key, opts in NON_EXPENSE_FILL.items():
                sentence = sentence.replace("{" + key + "}", rng.choice(opts[st]))
            return self.finish(sentence, empty(False), meta, kind="non_expense")

        target = empty(True)
        title, words, merchants, items_pool, (lo, hi) = rng.choice(CATEGORIES)
        target["title"] = title
        clauses = []
        word = self.pick(words[st])
        merchant = rng.choice(merchants) if merchants and rng.random() < 0.45 else None
        if merchant:
            target["merchant"] = merchant
            what = self.pick({"fr": [f"{word} chez {merchant}", f"{word} au {merchant}", f"{word} ({merchant})", f"{merchant} : {word}"],
                              "en": [f"{word} at {merchant}", f"{word} ({merchant})", f"{merchant} {word}"],
                              "dj": [f"{word} f {merchant}", f"{word} 3nd {merchant}", f"{merchant}"]}[st])
        else:
            what = word
        clauses.append(("what", what))

        # Devise : celle de l'activité le plus souvent, parfois une autre (voyage), parfois non dite
        code = activity_currency if rng.random() < 0.65 else rng.choices(list(CURRENCIES), [c[0] for c in CURRENCIES.values()])[0]
        amount, whole = self.amount_value(lo, hi, code)
        items = []
        if items_pool and rng.random() < 0.28:
            for label, a, b in rng.sample(items_pool, rng.randint(1, min(3, len(items_pool)))):
                qty = rng.choice([1, 1, 2, 2, 3, 4])
                line_value, line_whole = self.amount_value(a * qty, b * qty, code)
                show_qty = qty > 1 or rng.random() < 0.4
                items.append({"label": label, "qty": qty if show_qty else None, "price": line_value, "whole": line_whole})
            amount = round(sum(i["price"] for i in items), 2)
            whole = all(i["whole"] for i in items)
        amount_said = rng.random() > (0.45 if items else 0.06)
        currency_said = rng.random() > 0.06
        if amount_said:
            money = self.money(amount, code, style, whole) if currency_said else self.money(amount, code, style, whole).rstrip(" €$£¥abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZéè").strip() or str(amount)
            if not currency_said:
                money = f"{amount:g}" if whole else (f"{amount:.2f}".replace(".", ",") if st == "fr" else f"{amount:.2f}")
            target["amount"] = amount
            target["currency"] = code if currency_said else None
            clauses.append(("amount", self.pick({"fr": [money, f"de {money}", f"pour {money}", f"à {money}", f"total {money}", f"ça a coûté {money}"],
                                                  "en": [money, f"for {money}", f"total {money}", f"it was {money}", f"cost {money}"],
                                                  "dj": [money, f"b {money}", f"dfe3na {money}", f"kan {money}"]}[st])))
        if not amount_said:
            # Total non indiqué : somme des articles, ou 0 sans articles
            target["amount"] = round(sum(i["price"] for i in items), 2) if items else 0
        if items:
            parts = []
            for it in items:
                price = self.money(it["price"], code, style, it["whole"]) if (currency_said or not amount_said) else (f"{it['price']:g}")
                label = it["label"].lower() + ("s" if it["qty"] and it["qty"] > 1 and st != "dj" and not it["label"].endswith("s") else "")
                parts.append(f"{it['qty']} {label} {price}" if it["qty"] else f"{label} {price}")
            if not amount_said or currency_said:
                target["currency"] = code if (currency_said or not amount_said) else target["currency"]
            joined = {"fr": " et ", "en": " and ", "dj": " w "}[st].join(parts) if len(parts) <= 2 else ", ".join(parts)
            clauses.append(("items", self.pick({"fr": [f"({joined})", f"dont {joined}", f": {joined}"], "en": [f"({joined})", f": {joined}"], "dj": [f"({joined})", f": {joined}"]}[st])))
            target["items"] = [{"label": i["label"], "qty": i["qty"], "price": i["price"]} for i in items]
        else:
            target["items"] = []

        date_text, date = self.date_phrase(today, style)
        if date_text:
            clauses.append(("date", date_text))
            target["date"] = date.isoformat()

        # Participants
        mode = rng.choices(["none", "with", "for", "all", "except", "me_and"], [0.25, 0.3, 0.12, 0.1, 0.1, 0.13])[0]
        participants = None
        if mode == "with":
            chosen = rng.sample(others, rng.randint(1, len(others)))
            participants = ["moi"] + chosen
            text = self.pick({"fr": ["avec {L}", "avec {L}", "accompagné de {L}"], "en": ["with {L}"], "dj": ["m3a {L}", "m3a {L}"]}[st])
            clauses.append(("people", text.replace("{L}", self.join(chosen, style))))
        elif mode == "for":
            chosen = rng.sample(others, rng.randint(1, len(others)))
            participants = chosen
            text = self.pick({"fr": ["pour {L}", "pour {L}", "entre {L}"], "en": ["for {L}", "between {L}"], "dj": ["l {L}", "dial {L}"]}[st])
            clauses.append(("people", text.replace("{L}", self.join(chosen, style))))
        elif mode == "all":
            participants = ["moi"] + others
            clauses.append(("people", self.pick({"fr": ["tout le monde", "pour tout le monde", "entre nous tous", "pour tout le groupe"],
                                                  "en": ["everyone", "for everybody", "for the whole group"], "dj": ["kolchi", "kolna", "ga3 lgroupe"]}[st])))
        elif mode == "except" and len(others) >= 2:
            excluded = rng.sample(others, rng.randint(1, max(1, len(others) - 1)))
            participants = ["moi"] + [o for o in others if o not in excluded]
            text = self.pick({"fr": ["tout le monde sauf {L}", "pour tous sauf {L}", "sans {L}", "tout le monde à part {L}"],
                              "en": ["everyone except {L}", "everyone but {L}", "all of us except {L}"], "dj": ["kolchi bla {L}", "kolchi mn ghir {L}", "kolna bla {L}"]}[st])
            clauses.append(("people", text.replace("{L}", self.join(excluded, style))))
        elif mode == "me_and":
            chosen = rng.sample(others, rng.randint(1, min(2, len(others))))
            participants = ["moi"] + chosen
            text = self.pick({"fr": ["entre moi et {L}", "moi et {L}", "juste moi et {L}"], "en": ["between me and {L}", "me and {L}"], "dj": ["ana w {L}", "ghir ana w {L}"]}[st])
            clauses.append(("people", text.replace("{L}", self.join(chosen, style))))
        if rng.random() < 0.03 and mode in ("with", "for"):  # personne hors de l'activité : ignorée
            outsider = rng.choice([n for n in NAMES if n not in members])
            clauses[-1] = (clauses[-1][0], clauses[-1][1] + {"fr": " et ", "en": " and ", "dj": " w "}[st] + outsider)

        # Répartition
        split = None
        pool = participants if participants and len(participants) >= 2 else None
        r = rng.random()
        if pool and r < 0.12:
            split = {"type": "equal"}
            clauses.append(("split", self.pick({"fr": ["à parts égales", "on partage", "chacun sa part", "on divise équitablement"],
                                                 "en": ["split equally", "split evenly", "shared equally"], "dj": ["n9esmoha", "kol wa7ed b 7a9o", "bnos bnos"]}[st])))
        elif pool and len(pool) <= 3 and r < 0.30:
            kind = rng.choice(["percent", "percent", "amounts", "shares"])
            people = pool
            if kind == "percent":
                cuts = sorted(rng.sample(range(10, 91, 5), len(people) - 1))
                values = [b - a for a, b in zip([0] + cuts, cuts + [100])]
                if 0 in values:
                    values = [round(100 / len(people), 2)] * len(people)
            elif kind == "shares":
                values = [rng.randint(1, 4) for _ in people]
            else:
                if target["amount"] is None:
                    kind, values = "shares", [rng.randint(1, 4) for _ in people]
                else:
                    total = target["amount"]
                    cuts = sorted(rng.uniform(0.2, 0.8) * total for _ in range(len(people) - 1))
                    values = [round(b - a, 2 if not whole else 0) for a, b in zip([0] + cuts, cuts + [total])]
                    values[-1] = round(total - sum(values[:-1]), 2)
                    if any(v <= 0 for v in values):
                        kind, values = "shares", [rng.randint(1, 4) for _ in people]
            split = {"type": kind, "values": {p: (int(v) if float(v).is_integer() else v) for p, v in zip(people, values)}}
            def who(p):
                return {"en": "me", "dj": "ana"}.get(st, "moi") if p == "moi" else self.name_text(p, style)
            if kind == "percent":
                if len(people) == 2 and rng.random() < 0.4:
                    text = {"fr": f"{values[0]}/{values[1]} entre {who(people[0])} et {who(people[1])}", "en": f"{values[0]}/{values[1]} between {who(people[0])} and {who(people[1])}",
                            "dj": f"{values[0]}/{values[1]} bin {who(people[0])} w {who(people[1])}"}[st]
                else:
                    text = ", ".join({"fr": f"{who(p)} {v:g}%", "en": f"{who(p)} {v:g}%", "dj": f"{who(p)} {v:g}%"}[st] for p, v in zip(people, values))
            elif kind == "shares":
                text = ", ".join({"fr": f"{v} part{'s' if v > 1 else ''} pour {who(p)}", "en": f"{v} share{'s' if v > 1 else ''} for {who(p)}",
                                  "dj": f"{v} parts l {who(p)}"}[st] for p, v in zip(people, values))
            else:
                text = ", ".join({"fr": f"{who(p)} doit {self.money(v, code, style, float(v).is_integer())}", "en": f"{who(p)} owes {self.money(v, code, style, float(v).is_integer())}",
                                  "dj": f"{who(p)} {self.money(v, code, style, float(v).is_integer())}"}[st] for p, v in zip(people, values))
            clauses.append(("split", text))
        target["participants"] = participants
        target["split"] = split

        # Qui a payé
        r = rng.random()
        if r < 0.62:
            payer = "moi" if rng.random() < 0.6 else rng.choice(others)
            target["paid_by"] = payer
            if payer == "moi":
                text = self.pick({"fr": ["j'ai payé", "c'est moi qui ai payé", "payé par moi", "j'ai avancé", "réglé par moi", "j'ai tout payé"],
                                  "en": ["I paid", "paid by me", "I covered it", "I picked up the bill"], "dj": ["khlest", "ana li khlest", "khlest ana", "ana li dfe3t"]}[st])
            else:
                n = self.name_text(payer, style)
                text = self.pick({"fr": ["payé par {n}", "{n} a payé", "c'est {n} qui a payé", "{n} a avancé", "réglé par {n}", "{n} a tout réglé"],
                                  "en": ["{n} paid", "paid by {n}", "{n} covered it", "{n} got the bill"], "dj": ["{n} li khlass", "khlass {n}", "{n} li dfe3", "dfe3 {n}"]}[st]).replace("{n}", n)
            clauses.append(("payer", text))

        # Ordre des morceaux : « quoi » d'abord en général, le reste mélangé
        head = [c for c in clauses if c[0] == "what"]
        tail = [c for c in clauses if c[0] != "what"]
        rng.shuffle(tail)
        ordered = head + tail if rng.random() < 0.8 else tail[:1] + head + tail[1:]
        sep = rng.choice([", ", " ", ", ", " - "]) if style != "sms" else rng.choice([" ", ", "])
        sentence = sep.join(text for _, text in ordered)
        if style != "sms" and rng.random() < 0.5:
            sentence = sentence[0].upper() + sentence[1:]
        if rng.random() < 0.15:
            sentence = self.pick({"fr": ["ajoute ", "note : ", "dépense : ", "rajoute "], "en": ["add ", "note: ", "expense: "], "dj": ["zid ", "kteb ", "sajjel "]}[st]) + sentence
        return self.finish(sentence, target, meta, kind=mode)

    def finish(self, sentence, target, meta, kind):
        if meta["style"] == "sms":
            sentence = deaccent(sentence.lower())
            for a, b in [("avec ", "ac "), ("pour ", "pr "), ("j'ai ", "jai "), ("c'est ", "c "), ("aujourd'hui", "auj"), ("tout le monde", "tt le monde"),
                         ("quelque", "qq"), (" euros", "e"), ("rendez-vous", "rdv")]:
                if self.rng.random() < 0.7:
                    sentence = sentence.replace(a, b)
        meta = {**meta, "kind": kind, "today": meta["today"].isoformat()}
        return {"sentence": sentence, "target": target, "meta": meta}
