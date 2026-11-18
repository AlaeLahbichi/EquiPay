"""Tickets de caisse synthétiques (France, Maroc, et quelques autres pays) avec étiquettes exactes.

Chaque ticket suit les conventions de son pays : virgule ou point décimal, séparateur de milliers,
symbole de la devise, format de la date. Le rendu est ensuite abîmé (rotation, flou, ombre, bruit,
compression) pour ressembler à une photo.
"""
import datetime as dt
import random

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

FONTS = [
    "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Courier.ttc", "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Supplemental/Courier New.ttf", "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf", "/System/Library/Fonts/Supplemental/PTMono.ttc",
    "/System/Library/Fonts/Supplemental/Arial Narrow.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Tahoma.ttf",
]

FR_SHOPS = ["CAFE DE LA GARE", "LE PETIT ZINC", "BOULANGERIE PAUL", "CARREFOUR CITY", "MONOPRIX", "FRANPRIX",
            "BRASSERIE DU MARCHE", "PIZZERIA BELLA NAPOLI", "LE BISTROT D'ANTOINE", "PHARMACIE CENTRALE",
            "INTERMARCHE", "LECLERC DRIVE", "AUCHAN", "SUSHI SHOP", "CREPERIE DE BRETAGNE", "LA MIE CALINE",
            "RELAY", "FNAC", "DECATHLON", "PICARD", "LE COMPTOIR", "CHEZ MARCEL", "TABAC DE LA PLACE"]
FR_STREETS = ["12 rue de Lyon", "45 avenue Jean Jaures", "3 place de la Republique", "8 bd Saint-Michel",
              "21 rue du Commerce", "102 rue de Rivoli", "7 quai des Chartrons", "15 cours Mirabeau"]
FR_CITIES = ["75012 Paris", "69002 Lyon", "13001 Marseille", "33000 Bordeaux", "31000 Toulouse", "59000 Lille",
             "44000 Nantes", "06000 Nice", "67000 Strasbourg", "34000 Montpellier"]
MA_SHOPS = ["CAFE CLOCK", "MARJANE", "CARREFOUR MARKET", "ACIMA", "LABEL VIE", "BIM", "PATISSERIE AMANDINE",
            "RESTAURANT DAR MOHA", "CAFE DE FRANCE", "SNACK AL AMAL", "PHARMACIE AL MANAR", "PAUL MAROC",
            "VENEZIA ICE", "LA SQALA", "RESTAURANT AL FASSIA", "KOUTOUBIA PIZZA", "HANOUT ESSAADA",
            "STARBUCKS MOROCCO MALL", "DECATHLON MAROC", "JUMIA PICK UP"]
MA_STREETS = ["224 Derb Chtouka", "Bd Mohammed V", "Av. Hassan II", "Rue Ibn Batouta", "Bd Zerktouni",
              "Av. Mohammed VI", "Rue de Fes", "Place Jemaa El Fna", "Bd d'Anfa", "Av. des FAR"]
MA_CITIES = ["Marrakech", "Casablanca", "Rabat", "Fes", "Tanger", "Agadir", "Meknes", "Oujda", "Kenitra", "Tetouan"]
US_SHOPS = ["JOE'S DINER", "BLUE BOTTLE COFFEE", "WALGREENS", "TRADER JOE'S", "CHIPOTLE", "TARGET", "CVS PHARMACY"]
US_STREETS = ["123 Main St", "450 Market St", "88 Broadway", "2100 Sunset Blvd"]
US_CITIES = ["San Francisco, CA 94103", "New York, NY 10012", "Austin, TX 78701", "Los Angeles, CA 90028"]
UK_SHOPS = ["PRET A MANGER", "TESCO EXPRESS", "COSTA COFFEE", "BOOTS", "WAGAMAMA", "SAINSBURY'S LOCAL"]
UK_STREETS = ["14 Oxford Street", "2 Baker Street", "77 King's Road", "10 High Street"]
UK_CITIES = ["London W1D 1BS", "Manchester M1 1AE", "Edinburgh EH1 1RE", "Bristol BS1 4DJ"]
CH_SHOPS = ["MIGROS", "COOP", "CAFE DU LAC", "MANOR FOOD", "BOULANGERIE DU BOURG"]
CH_STREETS = ["Rue du Rhone 12", "Bahnhofstrasse 45", "Rue de Bourg 8"]
CH_CITIES = ["1204 Geneve", "8001 Zurich", "1003 Lausanne"]

FOOD = ["Cafe creme", "Espresso", "Croissant", "Pain au chocolat", "Baguette", "Jus d'orange", "Eau minerale",
        "Sandwich jambon", "Salade cesar", "Croque monsieur", "Pizza margherita", "Burger maison", "Frites",
        "Coca-Cola 33cl", "Biere pression", "Verre de vin", "Tarte citron", "Menu midi", "Plat du jour",
        "Tajine poulet", "Couscous royal", "The a la menthe", "Harira", "Pastilla", "Msemen", "Jus d'avocat",
        "Brochettes", "Tanjia", "Lait 1L", "Yaourt x4", "Riz basmati 1kg", "Huile olive 1L", "Pates 500g",
        "Tomates kg", "Pommes kg", "Poulet roti", "Fromage", "Chocolat noir", "Cafe moulu", "Dentifrice",
        "Doliprane 1000", "Shampoing", "Piles AA x4", "Cahier A4", "Stylo bleu", "Sac cabas"]

# devise, symbole(s), décimales, séparateur décimal(s), séparateur de milliers(s), format de date, boutiques…
LOCALES = {
    "FR": dict(currency="EUR", symbols=["€", "EUR", "E"], dec=[","], thou=[" ", ".", ""], dates=["%d/%m/%Y", "%d/%m/%y", "%d-%m-%Y", "%d.%m.%Y"],
               shops=FR_SHOPS, streets=FR_STREETS, cities=FR_CITIES, country="France", weight=0.36,
               labels=dict(total=["TOTAL", "TOTAL TTC", "NET A PAYER", "A PAYER", "MONTANT TTC"], sub=["SOUS-TOTAL", "TOTAL HT"],
                           tax=["TVA 10%", "TVA 20%", "TVA 5,5%"], cash=["ESPECES", "ESP."], change=["RENDU", "MONNAIE RENDUE"],
                           card=["CB", "CARTE BANCAIRE", "CB SANS CONTACT"], qty="x")),
    "MA": dict(currency="MAD", symbols=["DH", "DHS", "MAD", "Dhs"], dec=[".", ","], thou=[" ", ",", ""], dates=["%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d/%m/%y"],
               shops=MA_SHOPS, streets=MA_STREETS, cities=MA_CITIES, country="Maroc", weight=0.36,
               labels=dict(total=["TOTAL", "TOTAL TTC", "NET A PAYER", "TOTAL DH", "MONTANT"], sub=["SOUS-TOTAL", "TOTAL HT"],
                           tax=["TVA 10%", "TVA 20%"], cash=["ESPECES", "CASH"], change=["RENDU", "MONNAIE"],
                           card=["CARTE", "CB", "TPE"], qty="x")),
    "US": dict(currency="USD", symbols=["$", "USD"], dec=["."], thou=[",", ""], dates=["%m/%d/%Y", "%m/%d/%y", "%b %d, %Y"],
               shops=US_SHOPS, streets=US_STREETS, cities=US_CITIES, country="USA", weight=0.12,
               labels=dict(total=["TOTAL", "AMOUNT DUE", "BALANCE DUE"], sub=["SUBTOTAL"], tax=["TAX", "SALES TAX 8.875%"],
                           cash=["CASH"], change=["CHANGE"], card=["VISA", "MASTERCARD", "CREDIT"], qty="@")),
    "UK": dict(currency="GBP", symbols=["£", "GBP"], dec=["."], thou=[",", ""], dates=["%d/%m/%Y", "%d/%m/%y"],
               shops=UK_SHOPS, streets=UK_STREETS, cities=UK_CITIES, country="Royaume-Uni", weight=0.08,
               labels=dict(total=["TOTAL", "BALANCE DUE", "TOTAL TO PAY"], sub=["SUBTOTAL"], tax=["VAT 20%"],
                           cash=["CASH"], change=["CHANGE"], card=["CARD", "CONTACTLESS"], qty="x")),
    "CH": dict(currency="CHF", symbols=["CHF", "Fr."], dec=[".", ","], thou=["'", " ", ""], dates=["%d.%m.%Y", "%d.%m.%y"],
               shops=CH_SHOPS, streets=CH_STREETS, cities=CH_CITIES, country="Suisse", weight=0.08,
               labels=dict(total=["TOTAL", "TOTAL CHF", "MONTANT"], sub=["SOUS-TOTAL"], tax=["TVA 8.1%", "MWST 8.1%"],
                           cash=["ESPECES", "BAR"], change=["RENDU", "RUECKGELD"], card=["CARTE", "TWINT"], qty="x")),
}

MONTHS_FR = ["janv.", "fevr.", "mars", "avr.", "mai", "juin", "juil.", "aout", "sept.", "oct.", "nov.", "dec."]


def fmt_amount(value, dec, thou, rng):
    """1250.5 → « 1 250,50 », « 1.250,50 », « 1,250.50 », « 1250.50 »… (toujours 2 décimales)."""
    whole, cents = divmod(round(value * 100), 100)
    digits = f"{whole:d}"
    if thou and whole >= 1000:
        groups = []
        while digits:
            groups.insert(0, digits[-3:])
            digits = digits[:-3]
        digits = thou.join(groups)
    return f"{digits}{dec}{cents:02d}"


def money(value, loc, style, rng):
    text = fmt_amount(value, style["dec"], style["thou"], rng)
    sym = style["symbol"]
    if style["sym_pos"] == "none":
        return text
    if sym in ("$", "£") or style["sym_pos"] == "before":
        return f"{sym}{text}" if sym in ("$", "£") else f"{sym} {text}"
    return f"{text} {sym}" if sym not in ("€",) or rng.random() < 0.6 else f"{text}{sym}"


def make_ticket(rng: random.Random):
    code = rng.choices(list(LOCALES), weights=[v["weight"] for v in LOCALES.values()])[0]
    loc = LOCALES[code]
    dec = rng.choice(loc["dec"])
    thou_choices = [t for t in loc["thou"] if t != dec]
    style = {"dec": dec, "thou": rng.choice(thou_choices), "symbol": rng.choice(loc["symbols"]),
             "sym_pos": rng.choice(["after", "after", "before", "none"])}
    if style["symbol"] in ("$", "£"):
        style["sym_pos"] = rng.choice(["before", "before", "none"])

    merchant = rng.choice(loc["shops"])
    street, city = rng.choice(loc["streets"]), rng.choice(loc["cities"])
    date = dt.date(2023, 1, 1) + dt.timedelta(days=rng.randrange(0, 1400))
    if code == "FR" and rng.random() < 0.15:
        date_text = f"{date.day:02d} {MONTHS_FR[date.month - 1]} {date.year}"
    else:
        date_text = date.strftime(rng.choice(loc["dates"]))
    time_text = f"{rng.randrange(7, 23):02d}:{rng.randrange(60):02d}"

    # Gros montants de temps en temps (milliers) pour apprendre les séparateurs
    big = rng.random() < 0.12
    n_items = rng.randint(1, 4 if big else 9)
    items = []
    for name in rng.sample(FOOD, n_items):
        qty = rng.choice([1, 1, 1, 1, 2, 2, 3, 4])
        unit = round(rng.uniform(150, 2500) if big else rng.uniform(0.5, 25 if code != "MA" else 150), 2)
        if rng.random() < 0.25:
            unit = float(round(unit))  # prix ronds (« 12,00 »)
        items.append({"label": name, "qty": qty, "price": round(unit * qty, 2), "unit": unit, "qty_printed": False})
    total = round(sum(i["price"] for i in items), 2)

    lines = []  # (texte gauche, texte droite, gras)
    width = rng.choice([30, 32, 36, 40])
    lines.append((merchant.center(width), None, True))
    address_printed = rng.random() < 0.85
    if address_printed:
        lines.append((street.center(width), None, False))
        lines.append((city.center(width), None, False))
    if rng.random() < 0.4:
        lines.append((f"Tel: 0{rng.randrange(1, 10)} {rng.randrange(10, 99)} {rng.randrange(10, 99)} {rng.randrange(10, 99)} {rng.randrange(10, 99)}", None, False))
    lines.append(("", None, False))
    lines.append((f"{date_text}  {time_text}", f"Tk {rng.randrange(1000, 99999)}" if rng.random() < 0.5 else None, False))
    lines.append(("-" * width, None, False))
    show_unit = rng.random() < 0.4
    for it in items:
        it["qty_printed"] = it["qty"] > 1 or rng.random() < 0.5
        left = f"{it['qty']} {loc['labels']['qty']} {it['label']}" if it["qty_printed"] else it["label"]
        if show_unit and it["qty"] > 1:
            lines.append((left, None, False))
            lines.append((f"   {it['qty']} x {fmt_amount(it['unit'], style['dec'], '', rng)}", fmt_amount(it["price"], style["dec"], style["thou"], rng), False))
        else:
            lines.append((left, fmt_amount(it["price"], style["dec"], style["thou"], rng), False))
    lines.append(("-" * width, None, False))
    other = {}
    if rng.random() < 0.5:
        lab = rng.choice(loc["labels"]["sub"])
        sub = total if "HT" not in lab else round(total / 1.2, 2)
        other["subtotal"] = sub
        lines.append((lab, fmt_amount(sub, style["dec"], style["thou"], rng), False))
    if rng.random() < 0.5:
        tax = round(total - total / 1.2, 2)
        other["tax"] = tax
        lines.append((rng.choice(loc["labels"]["tax"]), fmt_amount(tax, style["dec"], style["thou"], rng), False))
    total_label = rng.choice(loc["labels"]["total"])
    amount_text = money(total, loc, style, rng)
    lines.append((total_label, amount_text, True))
    pay = rng.random()
    if pay < 0.45:
        cash = total + rng.choice([0.5, 1, 2, 5, 10, 20, 50]) if total < 500 else total + rng.choice([20, 50, 100])
        cash = float(int(cash) + (0 if rng.random() < 0.7 else 1))
        cash = max(cash, total)
        other["cash"], other["change"] = cash, round(cash - total, 2)
        lines.append((rng.choice(loc["labels"]["cash"]), fmt_amount(cash, style["dec"], style["thou"], rng), False))
        lines.append((rng.choice(loc["labels"]["change"]), fmt_amount(cash - total, style["dec"], style["thou"], rng), False))
    elif pay < 0.85:
        other["card"] = total
        lines.append((rng.choice(loc["labels"]["card"]), fmt_amount(total, style["dec"], style["thou"], rng), False))
    lines.append(("", None, False))
    lines.append((rng.choice(["MERCI DE VOTRE VISITE", "A BIENTOT", "THANK YOU", "MERCI ET A BIENTOT", "SHUKRAN"]).center(width), None, False))

    target = {
        "merchant": merchant, "address": f"{street}, {city}" if address_printed else None, "date": date.isoformat(),
        "amount_text": amount_text, "amount": total, "currency": loc["currency"],
        "items": [{"label": i["label"], "qty": i["qty"] if i["qty_printed"] else None, "price": i["price"]} for i in items],
    }
    return render(lines, width, rng), target, {k: v for k, v in other.items()}, loc["currency"]


def render(lines, width, rng):
    font_path = rng.choice(FONTS)
    size = rng.randint(20, 28)
    font = ImageFont.truetype(font_path, size)
    bold = ImageFont.truetype(font_path, size + rng.choice([0, 2, 4]))
    char_w = font.getlength("M")
    w = int(char_w * (width + 4))
    line_h = int(size * rng.uniform(1.25, 1.55))
    h = line_h * (len(lines) + 3)
    paper = tuple(int(c) for c in (rng.uniform(235, 255), rng.uniform(232, 252), rng.uniform(220, 245)))
    ink = tuple([rng.randint(10, 70)] * 3)
    img = Image.new("RGB", (w, h), paper)
    d = ImageDraw.Draw(img)
    y = line_h
    x0 = int(char_w * 2)
    for left, right, strong in lines:
        f = bold if strong else font
        d.text((x0, y), left, fill=ink, font=f)
        if right:
            d.text((w - x0 - f.getlength(right), y), right, fill=ink, font=f)
        y += line_h
    return degrade(img, rng)


def degrade(img, rng):
    # Fond (table) autour du ticket, légère rotation, ombre, flou, bruit, compression
    bg = tuple(int(c) for c in rng.choice([(60, 50, 40), (200, 200, 205), (120, 90, 60), (30, 30, 35), (170, 160, 140)]))
    pad = rng.randint(20, 140)
    canvas = Image.new("RGB", (img.width + 2 * pad, img.height + 2 * pad), bg)
    canvas.paste(img, (pad, pad))
    canvas = canvas.rotate(rng.uniform(-4, 4), resample=Image.BICUBIC, expand=True, fillcolor=bg)
    if rng.random() < 0.6:  # ombre / éclairage inégal
        shade = Image.linear_gradient("L").resize(canvas.size).rotate(rng.uniform(0, 360))
        canvas = Image.composite(canvas, ImageEnhance.Brightness(canvas).enhance(rng.uniform(0.55, 0.85)), shade)
    if rng.random() < 0.5:
        canvas = canvas.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.3)))
    canvas = ImageEnhance.Contrast(canvas).enhance(rng.uniform(0.75, 1.2))
    if rng.random() < 0.4:
        noise = Image.effect_noise(canvas.size, rng.uniform(8, 25)).convert("RGB")
        canvas = Image.blend(canvas, noise, rng.uniform(0.03, 0.1))
    return canvas
