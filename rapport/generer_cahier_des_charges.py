"""Génère rapport/Cahier_des_charges_EquiPay.pdf (charte « Lagon » de l'app, logos EquiPay et EMSI)."""

import sys
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    Image,
    KeepTogether,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents

ROOT = Path(sys.argv[1])
OUT = ROOT / "rapport" / "Cahier_des_charges_EquiPay.pdf"
LOGO_APP = ROOT / "mobile" / "assets" / "branding" / "logo.png"
LOGO_EMSI = ROOT / "rapport" / "logo" / "emsi_logo.png"

# ---------- Charte « Lagon » (mobile/lib/theme/app_colors.dart) ----------
PRIMARY = colors.HexColor("#0D9488")
PRIMARY_LIGHT = colors.HexColor("#2DD4BF")
TEAL_2 = colors.HexColor("#14B8A6")
ACCENT = colors.HexColor("#F97316")
TEXT = colors.HexColor("#0F172A")
TEXT_2 = colors.HexColor("#64748B")
BG = colors.HexColor("#F8FAFC")
POSITIVE = colors.HexColor("#16A34A")
NEGATIVE = colors.HexColor("#DC2626")
NEUTRAL = colors.HexColor("#64748B")
WARNING = colors.HexColor("#D97706")
TINT = colors.HexColor("#E6F6F4")  # sarcelle très clair
LINE = colors.HexColor("#E2E8F0")

F = "/System/Library/Fonts/Supplemental/"
pdfmetrics.registerFont(TTFont("Arial", F + "Arial.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Bold", F + "Arial Bold.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Italic", F + "Arial Italic.ttf"))
pdfmetrics.registerFont(TTFont("Arial-BoldItalic", F + "Arial Bold Italic.ttf"))
pdfmetrics.registerFontFamily("Arial", normal="Arial", bold="Arial-Bold", italic="Arial-Italic", boldItalic="Arial-BoldItalic")

W, H = A4
MARGIN = 20 * mm

body = ParagraphStyle("body", fontName="Arial", fontSize=10, leading=15, textColor=TEXT, spaceAfter=6)
small = ParagraphStyle("small", parent=body, fontSize=8.5, leading=12, textColor=TEXT_2)
cell = ParagraphStyle("cell", parent=body, fontSize=8.8, leading=12, spaceAfter=0)
cell_b = ParagraphStyle("cellb", parent=cell, fontName="Arial-Bold")
cell_h = ParagraphStyle("cellh", parent=cell, fontName="Arial-Bold", textColor=colors.white)
bullet = ParagraphStyle("bullet", parent=body, leftIndent=14, bulletIndent=4, spaceAfter=3)
h1 = ParagraphStyle("h1", fontName="Arial-Bold", fontSize=19, leading=24, textColor=PRIMARY, spaceBefore=4, spaceAfter=10)
h2 = ParagraphStyle("h2", fontName="Arial-Bold", fontSize=13, leading=17, textColor=TEXT, spaceBefore=12, spaceAfter=6)
h3 = ParagraphStyle("h3", fontName="Arial-Bold", fontSize=10.5, leading=14, textColor=PRIMARY, spaceBefore=8, spaceAfter=4)
lead = ParagraphStyle("lead", parent=body, fontSize=11, leading=16.5, textColor=TEXT_2)


# ---------- Éléments graphiques ----------
class SectionTitle(Flowable):
    """Titre de chapitre : numéro dans une pastille sarcelle + trait orange."""

    def __init__(self, number, title):
        super().__init__()
        self.number, self.title = number, title
        self.width, self.height = W - 2 * MARGIN, 16 * mm

    def wrap(self, aw, ah):
        return self.width, self.height

    def draw(self):
        c = self.canv
        c.setFillColor(PRIMARY)
        c.roundRect(0, 4 * mm, 11 * mm, 11 * mm, 3 * mm, stroke=0, fill=1)
        c.setFillColor(colors.white)
        c.setFont("Arial-Bold", 13)
        c.drawCentredString(5.5 * mm, 7.6 * mm, str(self.number))
        c.setFillColor(TEXT)
        c.setFont("Arial-Bold", 18)
        c.drawString(15 * mm, 6.8 * mm, self.title)
        c.setFillColor(ACCENT)
        c.rect(15 * mm, 3 * mm, 18 * mm, 1.1 * mm, stroke=0, fill=1)


class Callout(Flowable):
    """Encadré : bande colorée à gauche, fond teinté."""

    def __init__(self, text, color=PRIMARY, tint=TINT, title=None):
        super().__init__()
        self.color, self.tint = color, tint
        style = ParagraphStyle("co", parent=body, fontSize=9.6, leading=14, spaceAfter=0)
        content = (f"<b>{title}</b><br/>" if title else "") + text
        self.p = Paragraph(content, style)

    def wrap(self, aw, ah):
        self.aw = aw
        _, h = self.p.wrap(aw - 12 * mm, ah)
        self.h = h + 8 * mm
        return aw, self.h

    def draw(self):
        c = self.canv
        c.setFillColor(self.tint)
        c.roundRect(0, 0, self.aw, self.h, 3 * mm, stroke=0, fill=1)
        c.setFillColor(self.color)
        c.rect(0, 0, 1.6 * mm, self.h, stroke=0, fill=1)
        self.p.drawOn(c, 7 * mm, 4 * mm)


class Swatch(Flowable):
    """Pastilles de couleur de la charte."""

    def __init__(self, items):
        super().__init__()
        self.items = items
        self.width = W - 2 * MARGIN
        self.height = 30 * mm * ((len(items) + 3) // 4)

    def wrap(self, aw, ah):
        return self.width, self.height

    def draw(self):
        c = self.canv
        col_w = self.width / 4
        for k, (name, hexa, role) in enumerate(self.items):
            x = (k % 4) * col_w
            y = self.height - (k // 4 + 1) * 30 * mm
            c.setFillColor(colors.HexColor(hexa))
            c.setStrokeColor(LINE)
            c.roundRect(x, y + 13 * mm, col_w - 5 * mm, 14 * mm, 2.5 * mm, stroke=1, fill=1)
            c.setFillColor(TEXT)
            c.setFont("Arial-Bold", 8.8)
            c.drawString(x, y + 8.5 * mm, name)
            c.setFont("Arial", 8)
            c.setFillColor(TEXT_2)
            c.drawString(x, y + 4.8 * mm, hexa.upper())
            c.drawString(x, y + 1.3 * mm, role)


class Architecture(Flowable):
    """Schéma d'architecture : app, Supabase, backend IA, MLflow, services externes."""

    def __init__(self):
        super().__init__()
        self.width, self.height = W - 2 * MARGIN, 112 * mm

    def wrap(self, aw, ah):
        return self.width, self.height

    def box(self, x, y, w, h, title, lines, fill=colors.white, stroke=PRIMARY, title_color=PRIMARY):
        c = self.canv
        c.setFillColor(fill)
        c.setStrokeColor(stroke)
        c.setLineWidth(1.2)
        c.roundRect(x, y, w, h, 3 * mm, stroke=1, fill=1)
        c.setFillColor(title_color)
        c.setFont("Arial-Bold", 9.5)
        c.drawCentredString(x + w / 2, y + h - 6 * mm, title)
        c.setFillColor(TEXT)
        c.setFont("Arial", 7.6)
        for i, line in enumerate(lines):
            c.drawCentredString(x + w / 2, y + h - 11 * mm - i * 3.9 * mm, line)

    def arrow(self, x1, y1, x2, y2, label=None, color=TEXT_2, lx=None, ly=None):
        c = self.canv
        c.setStrokeColor(color)
        c.setFillColor(color)
        c.setLineWidth(1)
        c.line(x1, y1, x2, y2)
        import math

        a = math.atan2(y2 - y1, x2 - x1)
        s = 2.2 * mm
        p = c.beginPath()
        p.moveTo(x2, y2)
        p.lineTo(x2 - s * math.cos(a - 0.4), y2 - s * math.sin(a - 0.4))
        p.lineTo(x2 - s * math.cos(a + 0.4), y2 - s * math.sin(a + 0.4))
        p.close()
        c.drawPath(p, stroke=0, fill=1)
        if label:
            c.setFont("Arial-Italic", 7.2)
            tx = lx if lx is not None else (x1 + x2) / 2
            ty = ly if ly is not None else (y1 + y2) / 2 + 1.5 * mm
            tw = c.stringWidth(label, "Arial-Italic", 7.2)
            c.setFillColor(BG)
            c.rect(tx - tw / 2 - 1 * mm, ty - 1 * mm, tw + 2 * mm, 3.6 * mm, stroke=0, fill=1)
            c.setFillColor(TEXT_2)
            c.drawCentredString(tx, ty, label)

    def draw(self):
        c = self.canv
        w = self.width
        # Fond
        c.setFillColor(BG)
        c.roundRect(0, 0, w, self.height, 4 * mm, stroke=0, fill=1)
        bw, bh = 52 * mm, 38 * mm
        # Colonne gauche : app
        self.box(5 * mm, 37 * mm, bw, bh + 4 * mm, "Application mobile",
                 ["Flutter (iOS, Android)", "Material 3 · palette Lagon", "Carte Apple Plans (MapKit)",
                  "Temps réel · mode hors ligne", "62 tests de widgets"],
                 fill=TINT)
        # Centre haut : Supabase
        cx = w / 2 - bw / 2
        self.box(cx, 70 * mm, bw, bh, "Supabase (cloud)",
                 ["Auth : e-mail + Google", "PostgreSQL + règles RLS", "Storage : photos, reçus, logos",
                  "Realtime : mises à jour en direct"])
        # Centre bas : backend
        self.box(cx, 4 * mm, bw, bh + 18 * mm, "Backend IA (FastAPI, Mac)",
                 ["Port 8000 · jeton JWT Supabase", "Assistant v16 (Qwen3-4B)", "Scanner de reçus v2 (Qwen3-VL)",
                  "Décrire la dépense v1", "Organiser le trajet", "Modèles MLX 4 bits", "Apple Silicon (GPU Metal)"],
                 stroke=ACCENT, title_color=ACCENT)
        # Droite : MLflow + externes
        rx = w - bw - 5 * mm
        self.box(rx, 70 * mm, bw, bh, "MLflow (port 5000)",
                 ["Suivi des entraînements", "Registre + alias « champion »", "Métriques et artefacts",
                  "Partagé avec le PC (RTX 5080)"])
        self.box(rx, 4 * mm, bw, bh + 18 * mm, "Services externes",
                 ["OSRM : temps de trajet", "Apple Plans : lieux, itinéraires", "Taux de change (CDN)",
                  "OpenStreetMap (secours)", "", "Tous gratuits, sans clé"],
                 stroke=TEXT_2, title_color=TEXT_2)
        ax = 5 * mm + bw
        # App → Supabase et App → backend
        self.arrow(ax, 72 * mm, cx, 86 * mm, "données, auth", lx=(ax + cx) / 2 - 1 * mm, ly=83 * mm)
        self.arrow(ax, 44 * mm, cx, 34 * mm, "IA (HTTPS)", lx=(ax + cx) / 2 - 1 * mm, ly=33 * mm)
        # Backend → MLflow (champion lu au démarrage) et backend → services externes
        self.arrow(cx + bw - 8 * mm, 60 * mm, rx + 8 * mm, 70 * mm, "champion", lx=(cx + bw + rx) / 2, ly=66.5 * mm)
        self.arrow(cx + bw, 30 * mm, rx, 30 * mm, "itinéraires", ly=32 * mm)


def table(rows, widths, header=True, zebra=True, first_bold=False):
    data = []
    for r, row in enumerate(rows):
        def style(c):
            if header and r == 0:
                return cell_h
            return cell_b if first_bold and c == 0 else cell
        data.append([Paragraph(str(v), style(c)) for c, v in enumerate(row)])
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    st = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE),
    ]
    if header:
        st += [("BACKGROUND", (0, 0), (-1, 0), PRIMARY)]
    if zebra:
        for r in range(1 if header else 0, len(rows)):
            if r % 2 == 0:
                st.append(("BACKGROUND", (0, r), (-1, r), BG))
    t.setStyle(TableStyle(st))
    return t


def P(text, style=body):
    return Paragraph(text, style)


def bullets(items, style=bullet):
    return [Paragraph(i, style, bulletText="•") for i in items]


def prio(level):
    color = {"Essentielle": "#0D9488", "Importante": "#F97316", "Souhaitable": "#64748B"}[level]
    return f'<font color="{color}"><b>{level}</b></font>'


# ---------- Mise en page ----------
class Doc(BaseDocTemplate):
    def __init__(self, path):
        super().__init__(path, pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=26 * mm,
                         bottomMargin=20 * mm, title="Cahier des charges — EquiPay",
                         author="Projet Génération Textuelle — EMSI", subject="Cahier des charges de l'application EquiPay")
        frame = Frame(MARGIN, 20 * mm, W - 2 * MARGIN, H - 46 * mm, id="body")
        cover = Frame(0, 0, W, H, id="cover", leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates([PageTemplate("cover", [cover], onPage=draw_cover),
                               PageTemplate("page", [frame], onPage=draw_page)])

    def afterFlowable(self, f):
        if isinstance(f, Paragraph) and f.style.name in ("h1", "h2"):
            level = 0 if f.style.name == "h1" else 1
            text = f.getPlainText()
            key = f"h{id(f)}"
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(text, key, level=level)
            self.notify("TOCEntry", (level, text, self.page, key))


def draw_cover(c, doc):
    c.saveState()
    # Fond dégradé sarcelle (bandes) en haut
    steps = 60
    top_h = H * 0.56
    for i in range(steps):
        t = i / steps
        r = 0x0D + (0x14 - 0x0D) * t
        g = 0x94 + (0xB8 - 0x94) * t
        b = 0x88 + (0xA6 - 0x88) * t
        c.setFillColorRGB(r / 255, g / 255, b / 255)
        c.rect(0, H - top_h + i * top_h / steps, W, top_h / steps + 1, stroke=0, fill=1)
    # Formes décoratives
    c.setFillColor(colors.Color(1, 1, 1, alpha=0.08))
    c.circle(W - 30 * mm, H - 40 * mm, 60 * mm, stroke=0, fill=1)
    c.circle(25 * mm, H - top_h + 15 * mm, 35 * mm, stroke=0, fill=1)
    # Logo EMSI sur un cartouche blanc
    c.setFillColor(colors.white)
    c.roundRect(MARGIN, H - 38 * mm, 78 * mm, 24 * mm, 4 * mm, stroke=0, fill=1)
    c.drawImage(str(LOGO_EMSI), MARGIN + 4 * mm, H - 35 * mm, width=70 * mm, height=70 * mm * 140 / 640,
                mask="auto", preserveAspectRatio=True)
    # Titre
    c.setFillColor(colors.white)
    c.setFont("Arial", 13)
    c.drawString(MARGIN, H - 72 * mm, "PROJET GÉNÉRATION TEXTUELLE · EMSI 5e ANNÉE")
    c.setFont("Arial-Bold", 40)
    c.drawString(MARGIN, H - 92 * mm, "Cahier des charges")
    c.setFillColor(ACCENT)
    c.rect(MARGIN, H - 99 * mm, 30 * mm, 1.8 * mm, stroke=0, fill=1)
    c.setFillColor(colors.white)
    c.setFont("Arial", 15)
    c.drawString(MARGIN, H - 113 * mm, "EquiPay — l'application qui partage les dépenses")
    c.drawString(MARGIN, H - 121 * mm, "entre amis, enrichie par l'intelligence artificielle")
    # Carte blanche avec le logo de l'app
    card_w, card_h = 92 * mm, 92 * mm
    cx, cy = W / 2 - card_w / 2, 52 * mm
    c.setFillColor(colors.Color(0, 0, 0, alpha=0.08))
    c.roundRect(cx + 1.5 * mm, cy - 2 * mm, card_w, card_h, 8 * mm, stroke=0, fill=1)
    c.setFillColor(colors.white)
    c.roundRect(cx, cy, card_w, card_h, 8 * mm, stroke=0, fill=1)
    c.drawImage(str(LOGO_APP), cx + 8 * mm, cy + 8 * mm, width=card_w - 16 * mm, height=card_h - 16 * mm,
                preserveAspectRatio=True)
    # Pied de couverture
    c.setFillColor(TEXT_2)
    c.setFont("Arial", 9.5)
    c.drawString(MARGIN, 30 * mm, "Version 1.0 · Octobre 2026")
    c.drawRightString(W - MARGIN, 30 * mm, "Document de référence du projet")
    c.setStrokeColor(LINE)
    c.line(MARGIN, 26 * mm, W - MARGIN, 26 * mm)
    c.setFont("Arial", 8.5)
    c.drawString(MARGIN, 20 * mm, "Flutter · Supabase · FastAPI · MLX · MLflow · Apple Plans")
    c.restoreState()


def draw_page(c, doc):
    c.saveState()
    # En-tête : logo EquiPay, titre, logo EMSI
    c.setFillColor(PRIMARY)
    c.rect(0, H - 4 * mm, W, 4 * mm, stroke=0, fill=1)
    c.drawImage(str(LOGO_APP), MARGIN, H - 19 * mm, width=12 * mm, height=12 * mm, preserveAspectRatio=True)
    c.setFillColor(TEXT)
    c.setFont("Arial-Bold", 9)
    c.drawString(MARGIN + 15 * mm, H - 12 * mm, "EquiPay")
    c.setFont("Arial", 8)
    c.setFillColor(TEXT_2)
    c.drawString(MARGIN + 15 * mm, H - 16 * mm, "Cahier des charges · v1.0")
    c.drawImage(str(LOGO_EMSI), W - MARGIN - 42 * mm, H - 18 * mm, width=42 * mm, height=42 * mm * 140 / 640,
                mask="auto", preserveAspectRatio=True)
    c.setStrokeColor(LINE)
    c.line(MARGIN, H - 21 * mm, W - MARGIN, H - 21 * mm)
    # Pied de page
    c.line(MARGIN, 14 * mm, W - MARGIN, 14 * mm)
    c.setFont("Arial", 8)
    c.setFillColor(TEXT_2)
    c.drawString(MARGIN, 9 * mm, "EMSI — Projet Génération Textuelle · Octobre 2026")
    c.setFillColor(PRIMARY)
    c.roundRect(W - MARGIN - 12 * mm, 7 * mm, 12 * mm, 5.5 * mm, 2.5 * mm, stroke=0, fill=1)
    c.setFillColor(colors.white)
    c.setFont("Arial-Bold", 8)
    c.drawCentredString(W - MARGIN - 6 * mm, 8.6 * mm, str(doc.page))
    c.restoreState()


# ---------- Contenu ----------
def H1(n, title):
    return [PageBreak(), SectionTitle(n, title), Paragraph(f"{n}. {title}", ParagraphStyle("h1", parent=h1, fontSize=0.1, leading=0.1, textColor=colors.white, spaceAfter=0, spaceBefore=0))]


def story():
    s = [NextPageTemplate("page"), PageBreak()]

    # Sommaire
    s.append(Paragraph("Sommaire", ParagraphStyle("toc_title", parent=h1)))
    toc = TableOfContents()
    toc.levelStyles = [
        ParagraphStyle("toc1", fontName="Arial-Bold", fontSize=10.5, leading=15, textColor=TEXT, leftIndent=0, spaceBefore=3),
        ParagraphStyle("toc2", fontName="Arial", fontSize=9.2, leading=12, textColor=TEXT_2, leftIndent=12),
    ]
    toc.dotsMinLevel = 0
    toc.tableStyle = TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                                 ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 0),
                                 ("BOTTOMPADDING", (0, 0), (-1, -1), 1)])
    s.append(toc)

    # 1. Présentation
    s += H1(1, "Présentation du projet")
    s.append(P("EquiPay est une application mobile qui permet à un groupe d'amis de partager les dépenses d'une "
               "activité commune — un voyage, une sortie, une colocation ou un crédit — puis de savoir, à tout moment, "
               "qui doit combien à qui. Elle intègre plusieurs modèles d'intelligence artificielle, entraînés et suivis "
               "dans le cadre du projet de Génération Textuelle, pour supprimer la saisie fastidieuse et aider à "
               "organiser les voyages.", lead))
    s.append(Paragraph("1.1 Contexte et problématique", h2))
    s += bullets([
        "Dans un groupe, les dépenses sont avancées par des personnes différentes, dans des devises différentes, "
        "et réparties de façon inégale : les comptes deviennent vite flous.",
        "Les applications existantes (Tricount, Splitwise…) demandent une saisie manuelle de chaque dépense et "
        "n'aident pas à préparer le voyage lui-même.",
        "Les tickets de caisse, les phrases du type « J'ai payé 45 € de taxi pour Sara et moi » et la liste des "
        "visites à faire contiennent déjà toute l'information : l'IA peut l'extraire.",
    ])
    s.append(Paragraph("1.2 Objectifs", h2))
    s.append(table([
        ["Objectif", "Résultat attendu"],
        ["Partager simplement les dépenses", "Créer une activité, inviter par code, ajouter une dépense en quelques secondes"],
        ["Équilibrer les comptes", "Soldes en temps réel et nombre minimal de remboursements"],
        ["Saisir sans effort grâce à l'IA", "Scanner un ticket ou décrire la dépense en une phrase"],
        ["Organiser les voyages", "Programme partagé, votes, calendrier, carte et trajet optimisé"],
        ["Assister l'utilisateur", "Assistant conversationnel qui répond aux questions sur l'app"],
        ["Suivre les modèles (MLOps)", "Entraînements, métriques et versions « champion » dans MLflow"],
    ], [60 * mm, W - 2 * MARGIN - 60 * mm], first_bold=True))
    s.append(Paragraph("1.3 Périmètre", h2))
    s.append(P("<b>Inclus :</b> application mobile (iOS en priorité, base Android prête), base de données et "
               "authentification Supabase, backend d'IA local (FastAPI sur Mac Apple Silicon), entraînement des "
               "modèles (PC avec GPU RTX 5080) et suivi MLflow."))
    s.append(P("<b>Hors périmètre (version 1) :</b> paiement intégré, publication sur les stores, hébergement du "
               "backend dans le cloud, notifications push."))
    s.append(Callout("La base de données est livrée vide : les données réelles sont saisies par les utilisateurs. "
                     "Seuls le schéma, les règles d'accès et les fonctions sont fournis par migrations.",
                     title="Principe"))

    # 2. Acteurs
    s += H1(2, "Acteurs et rôles")
    s.append(P("Chaque activité a ses propres rôles. Une même personne peut être créatrice d'une activité et simple "
               "membre d'une autre."))
    s.append(table([
        ["Acteur", "Description", "Droits principaux"],
        ["Visiteur", "Personne non connectée", "Découvrir l'app, poser des questions à l'assistant, créer un compte"],
        ["Utilisateur", "Personne connectée (e-mail ou Google)", "Créer des activités, rejoindre par code, gérer son profil"],
        ["Créateur (owner)", "A créé l'activité", "Tout gérer : modifier, accepter les demandes, changer les rôles, "
                                                 "supprimer, appliquer un trajet proposé"],
        ["Membre", "Participant actif", "Ajouter des dépenses et des photos, voter, ajouter au programme"],
        ["Spectateur", "Participant en lecture", "Consulter dépenses, soldes et programme ; ajouter des photos"],
    ], [32 * mm, 48 * mm, W - 2 * MARGIN - 80 * mm], first_bold=True))

    # 3. Fonctionnel
    s += H1(3, "Besoins fonctionnels")
    s.append(P("Chaque besoin est identifié et priorisé : " + prio("Essentielle") + " (indispensable à la v1), "
               + prio("Importante") + " (forte valeur), " + prio("Souhaitable") + " (confort)."))
    s.append(Callout("L'IA ne crée jamais rien à la place de l'utilisateur : le scanner et la phrase "
                     "<i>pré-remplissent</i> le formulaire, et le trajet proposé n'est enregistré qu'après "
                     "« Appliquer ». L'humain valide toujours.", color=ACCENT, tint=colors.HexColor("#FFF4EC"),
                     title="Règle de conception"))
    s.append(Spacer(1, 4))
    modules = [
        ("3.1 Compte et profil", [
            ["F-01", "Inscription et connexion par e-mail et mot de passe, avec confirmation", "Essentielle"],
            ["F-02", "Connexion avec Google", "Importante"],
            ["F-03", "Profil : nom, nom d'utilisateur, photo ; suppression du compte", "Essentielle"],
            ["F-04", "Thème clair / sombre / système ; langue français, anglais, arabe", "Souhaitable"],
        ]),
        ("3.2 Activités", [
            ["F-05", "Créer une activité : nom, type (voyage, sortie, quotidien, crédit), devise, logo", "Essentielle"],
            ["F-06", "Rejoindre par code d'accès ; le créateur accepte ou refuse la demande", "Essentielle"],
            ["F-07", "Gérer les participants : rôle membre ou spectateur, retrait", "Essentielle"],
            ["F-08", "Menu à trois points : modifier, archiver, résumé, graphique, insights, supprimer", "Importante"],
            ["F-09", "Archiver pour soi seul ; page « Activités archivées » (ouvrir, désarchiver, supprimer)", "Importante"],
            ["F-10", "Sélection multiple sur l'accueil pour archiver ou supprimer plusieurs activités", "Souhaitable"],
            ["F-11", "Tri des participants : A → Z, solde croissant, solde décroissant", "Souhaitable"],
        ]),
        ("3.3 Dépenses", [
            ["F-12", "Ajouter une dépense : montant, devise, date, payeur, catégorie, photo du reçu", "Essentielle"],
            ["F-13", "Répartition à parts égales, en pourcentages, en montants ou en parts", "Essentielle"],
            ["F-14", "Conversion automatique dans la devise de l'activité (taux de change)", "Importante"],
            ["F-15", "Détail d'une dépense : répartition, pourcentages, montants ; modifier et supprimer", "Essentielle"],
        ]),
        ("3.4 Soldes et remboursements", [
            ["F-16", "Solde de chaque participant (payé − sa part), mis à jour en temps réel", "Essentielle"],
            ["F-17", "Résumé : pour chacun, à qui rembourser et de qui recevoir, en un minimum de virements", "Essentielle"],
            ["F-18", "Copier le résumé pour l'envoyer au groupe", "Souhaitable"],
            ["F-19", "Graphiques par participant (payé, part, solde) et page Insights", "Importante"],
        ]),
        ("3.5 Photos de l'activité", [
            ["F-20", "Album partagé : ajout de plusieurs photos, visionneuse, suppression", "Importante"],
        ]),
        ("3.6 Programme des voyages et sorties", [
            ["F-21", "To-do list : nom, lieu, adresse, date et heure de chaque activité prévue", "Essentielle"],
            ["F-22", "Vote pour / contre de chaque participant, compteurs en direct", "Essentielle"],
            ["F-23", "Lieu placé automatiquement sur la carte (recherche Apple Plans + suggestions)", "Importante"],
            ["F-24", "Vues Liste, Calendrier (jour par jour, ordre des heures) et Carte (filtre par date)", "Importante"],
            ["F-25", "Carte Apple Plans native : bulles numérotées, couleur selon les votes", "Importante"],
            ["F-26", "Organiser le trajet par l'IA ; appliquer le programme ; ouvrir l'itinéraire dans Plans", "Importante"],
        ]),
        ("3.7 Fonctions d'intelligence artificielle", [
            ["F-27", "Scanner un ticket : enseigne, date, total, devise et articles pré-remplis", "Essentielle"],
            ["F-28", "Décrire la dépense en une phrase : montant, payeur, participants, répartition", "Importante"],
            ["F-29", "Assistant conversationnel (support) avec historique", "Importante"],
            ["F-30", "Organisation du trajet : meilleur ordre jour par jour et programme rédigé", "Importante"],
        ]),
        ("3.8 Fonctions transverses", [
            ["F-31", "Mises à jour en temps réel entre les téléphones du groupe", "Essentielle"],
            ["F-32", "Bandeau hors ligne et rechargement au retour du réseau", "Importante"],
            ["F-33", "Clavier fermé en touchant n'importe où dans l'app", "Souhaitable"],
        ]),
    ]
    for title, rows in modules:
        s.append(KeepTogether([
            Paragraph(title, h2),
            table([["N°", "Besoin", "Priorité"]] + [[r[0], r[1], prio(r[2])] for r in rows],
                  [14 * mm, W - 2 * MARGIN - 44 * mm, 30 * mm], first_bold=True),
        ]))

    # 4. Non fonctionnel
    s += H1(4, "Besoins non fonctionnels")
    s.append(table([
        ["Domaine", "Exigence", "Mesure / mise en œuvre"],
        ["Sécurité", "Chaque utilisateur ne voit que ses activités",
         "Règles RLS PostgreSQL sur toutes les tables ; jeton JWT Supabase vérifié par le backend (ES256)"],
        ["Confidentialité", "Photos de reçus privées", "Stockage privé, liens signés valables 1 h"],
        ["Performance", "App fluide, IA rapide", "Rechargements regroupés ; miniatures décodées à 400 px ; "
                                               "scanner ~5,5 s/ticket, phrase ~2 s"],
        ["Mémoire", "Backend sobre sur un Mac de 18 Go", "Modèles MLX 4 bits : backend ~5,8 Go (contre 11 Go en PyTorch)"],
        ["Disponibilité", "Utilisable sans réseau stable", "Bandeau hors ligne, temps estimés si OSRM ne répond pas"],
        ["Ergonomie", "Prise en main immédiate", "Material 3, palette Lagon, mode sombre, retours clairs en français"],
        ["Compatibilité", "iPhone d'abord", "iOS (Apple Plans natif) ; Android prêt avec carte OpenStreetMap"],
        ["Qualité", "Code testé", "62 tests Flutter, 27 tests backend, analyse statique sans avertissement"],
        ["Coût", "Aucun abonnement", "Services gratuits et sans clé ; modèles exécutés en local"],
    ], [28 * mm, 50 * mm, W - 2 * MARGIN - 78 * mm], first_bold=True))

    # 5. Architecture
    s += H1(5, "Architecture technique")
    s.append(P("L'application parle à deux systèmes : Supabase pour les comptes et les données partagées, et un "
               "backend d'IA local pour les modèles. MLflow conserve l'historique des entraînements et désigne la "
               "version « champion » chargée par le backend."))
    s.append(Spacer(1, 4))
    s.append(Architecture())
    s.append(Spacer(1, 10))
    s.append(Paragraph("5.1 Choix technologiques", h2))
    s.append(table([
        ["Couche", "Technologie", "Pourquoi"],
        ["Mobile", "Flutter (Dart), Material 3", "Un seul code pour iOS et Android, interface moderne"],
        ["Carte", "MapKit (vue native Swift)", "Rendu Apple Plans, gratuit, itinéraires dans les rues"],
        ["Données", "Supabase (PostgreSQL, Auth, Storage, Realtime)", "Sécurité par lignes (RLS), temps réel intégré"],
        ["API IA", "FastAPI (Python)", "Léger, typé (Pydantic), documentation automatique"],
        ["Inférence", "MLX 4 bits sur Apple Silicon", "Rapide sur GPU Metal, faible mémoire"],
        ["Entraînement", "PyTorch + LoRA (PEFT) sur RTX 5080", "Affinage efficace de modèles de 4 milliards de paramètres"],
        ["MLOps", "MLflow (registre, alias champion)", "Comparer les versions, tracer chaque essai"],
    ], [26 * mm, 62 * mm, W - 2 * MARGIN - 88 * mm], first_bold=True))

    # 6. IA
    s += H1(6, "Modèles d'intelligence artificielle")
    s.append(P("Quatre fonctions reposent sur des modèles de langage. Trois sont affinés sur des données propres au "
               "projet ; le quatrième utilise un modèle de base guidé par un algorithme."))
    s.append(table([
        ["Fonction", "Modèle", "Méthode", "Résultat"],
        ["Assistant", "Qwen3-4B Instruct 2507", "LoRA (jeu de données v2), MLX 4 bits", "Champion v16 · score 0,770"],
        ["Décrire la dépense", "Qwen3-4B Instruct 2507", "LoRA 3 époques, MLX 4 bits",
         "v1 · score 0,976 (base : 0,656) · 72,5 % de réponses exactes"],
        ["Scanner de reçus", "Qwen3-VL-4B (vision)", "LoRA, 4 sources de tickets, 7 devises",
         "v2 · score 0,954 ; total juste 97,2 % · MLX 4 bits : 0,941"],
        ["Organiser le trajet", "Qwen3-4B (modèle de base)", "OSRM + algorithme d'ordre + rédaction",
         "Ordre optimal jusqu'à 8 lieux/jour"],
    ], [30 * mm, 38 * mm, 50 * mm, W - 2 * MARGIN - 118 * mm], first_bold=True))
    s.append(Paragraph("6.1 Cycle de vie des modèles (MLOps)", h2))
    s += bullets([
        "<b>Données :</b> jeux d'entraînement, de validation et de test versionnés (empreinte enregistrée dans MLflow).",
        "<b>Entraînement :</b> sur le PC (GPU RTX 5080), adaptateurs LoRA, arrêt anticipé sur la validation.",
        "<b>Évaluation :</b> modèle de base, ancienne version et nouvelle version comparés sur le même jeu de test "
        "(score pondéré, exactitude par champ, matrices de confusion).",
        "<b>Promotion :</b> la meilleure version reçoit l'alias « champion » dans le registre MLflow.",
        "<b>Déploiement :</b> fusion de l'adaptateur, conversion MLX 4 bits sur le Mac, réévaluation, puis "
        "chargement par le backend. La version PyTorch reste disponible en secours.",
    ])
    s.append(Paragraph("6.2 Garde-fous", h2))
    s += bullets([
        "Les chiffres ne viennent jamais du modèle quand un calcul est possible : temps de trajet par OSRM, ordre "
        "par l'algorithme, répartitions ramenées à exactement 100 %.",
        "Les noms cités dans une phrase sont reliés aux vrais membres (correspondance approchée) ; un nom inconnu "
        "n'est pas inventé.",
        "Réponse illisible ou hors sujet : l'app l'explique et propose de reformuler.",
    ])

    # 7. Données
    s += H1(7, "Données et API")
    s.append(Paragraph("7.1 Tables principales (Supabase)", h2))
    s.append(table([
        ["Table", "Contenu"],
        ["profiles", "Profil de chaque utilisateur (nom, nom d'utilisateur, photo)"],
        ["activities", "Activité : nom, type, devise, logo"],
        ["activity_members", "Participants, rôle, date d'archivage personnelle"],
        ["activity_join_codes · join_requests", "Code d'accès et demandes pour rejoindre"],
        ["expenses · expense_shares", "Dépenses et part de chaque participant (en %)"],
        ["attachments", "Reçus et photos de l'activité (fichiers dans Storage)"],
        ["trip_items · trip_votes", "Programme du voyage et votes pour / contre"],
        ["chat_messages", "Historique de l'assistant"],
    ], [56 * mm, W - 2 * MARGIN - 56 * mm], first_bold=True))
    s.append(Spacer(1, 4))
    s.append(P("Vues calculées : soldes par participant (<i>activity_balances</i>) et totaux par activité "
               "(<i>activity_totals</i>).", small))
    s.append(Paragraph("7.2 API du backend d'IA", h2))
    s.append(table([
        ["Route", "Rôle"],
        ["GET /health", "État du serveur et des modèles chargés"],
        ["POST /chat · GET /chat/history", "Question à l'assistant, historique"],
        ["POST /receipts/scan", "Photo d'un ticket → champs de la dépense"],
        ["POST /expenses/describe", "Phrase libre → montant, payeur, participants, répartition"],
        ["POST /trips/optimize", "Lieux du programme → ordre optimal, temps gagné, texte"],
    ], [62 * mm, W - 2 * MARGIN - 62 * mm], first_bold=True))
    s.append(Spacer(1, 4))
    s.append(P("Toutes les routes d'IA exigent le jeton de connexion Supabase et ne modifient aucune donnée.", small))

    # 8. Charte
    s += H1(8, "Charte graphique")
    s.append(P("L'identité visuelle « Lagon » associe un sarcelle apaisant (confiance, voyage) à un orange "
               "énergique (action, porte-monnaie). Elle est appliquée à l'app comme à ce document."))
    logo_row = Table([[Image(str(LOGO_APP), width=42 * mm, height=42 * mm),
                       P("<b>Logo EquiPay</b><br/>Un « e » sarcelle qui s'envole en avion, et un porte-monnaie "
                         "orange : le voyage et le partage des dépenses réunis. Utilisé pour l'icône de l'app, "
                         "l'écran de démarrage et les activités sans logo.")]],
                     colWidths=[50 * mm, W - 2 * MARGIN - 50 * mm])
    logo_row.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
    s.append(logo_row)
    s.append(Paragraph("8.1 Couleurs", h2))
    s.append(Swatch([
        ("Primaire", "#0D9488", "Boutons, titres, liens"),
        ("Primaire (sombre)", "#2DD4BF", "Primaire en mode sombre"),
        ("Accent", "#F97316", "Mise en avant, porte-monnaie"),
        ("Texte", "#0F172A", "Texte principal"),
        ("À recevoir", "#16A34A", "Solde positif, vote pour"),
        ("À rembourser", "#DC2626", "Solde négatif, vote contre"),
        ("Neutre", "#64748B", "Texte secondaire, à jour"),
        ("Avertissement", "#D97706", "Champ à vérifier"),
    ]))
    s.append(Paragraph("8.2 Types d'activité", h2))
    s.append(Swatch([
        ("Voyage", "#0D9488", "Avion"),
        ("Sortie", "#8B5CF6", "Fête"),
        ("Quotidien", "#3B82F6", "Maison"),
        ("Crédit", "#F59E0B", "Carte"),
    ]))
    s.append(Paragraph("8.3 Principes d'interface", h2))
    s += bullets([
        "Material 3, coins arrondis (16 à 22 px), cartes aérées, dégradé sarcelle pour les chiffres clés.",
        "Mode clair et mode sombre (fonds #F8FAFC et #0B1220).",
        "Couleurs de solde cohérentes partout : vert = on te doit, rouge = tu dois, gris = à jour.",
        "Textes en français, simples, au tutoiement.",
    ])

    # 9. Contraintes
    s += H1(9, "Contraintes et hypothèses")
    s.append(table([
        ["Contrainte", "Conséquence"],
        ["Backend d'IA exécuté sur le Mac (Apple Silicon)", "Le Mac doit être allumé, serveurs lancés "
         "(MLflow puis backend) et sur le même réseau que le téléphone"],
        ["Adresse du backend par nom (Alaes-MacBook-Pro.local)", "Fonctionne à la maison et en partage de connexion ; "
         "un Wi-Fi d'école peut bloquer les échanges entre appareils"],
        ["Mémoire de 18 Go", "Modèles en 4 bits, chargés à la première utilisation"],
        ["Services gratuits (OSRM, Apple Plans, taux de change)", "Internet nécessaire pour le trajet et la carte ; "
         "usage léger"],
        ["Entraînement sur un PC séparé", "MLflow partagé entre le PC et le Mac sur le réseau local"],
        ["Base livrée vide", "Aucune donnée insérée par les développeurs"],
    ], [72 * mm, W - 2 * MARGIN - 72 * mm], first_bold=True))

    # 10. Planning
    s += H1(10, "Planning et livrables")
    s.append(P("Jalons réalisés (d'après les migrations de la base et l'historique MLflow) :"))
    s.append(table([
        ["Date", "Jalon", "Livrable"],
        ["06/10/2026", "Fondations", "Schéma Supabase, règles d'accès, app Flutter de base"],
        ["07–08/10", "Comptes et invitations", "Connexion, profils, photos, demandes pour rejoindre"],
        ["07–10/10", "Assistant", "Jeu de données, entraînements, champion v16 dans MLflow"],
        ["10/10", "Dépenses", "Saisie, répartitions, devises verrouillées, photos de l'activité"],
        ["10–11/10", "Scanner de reçus", "Modèle v2 (Qwen3-VL), évaluation, intégration"],
        ["12/10", "Gestion avancée", "Archivage, menu d'actions, résumé des remboursements, « Décrire la dépense »"],
        ["12/10", "Optimisation", "Scanner en MLX 4 bits, rechargements regroupés, nettoyage du projet"],
        ["13/10", "Programme de voyage", "To-do list, votes, calendrier, carte Apple Plans, trajet par l'IA"],
    ], [24 * mm, 44 * mm, W - 2 * MARGIN - 68 * mm], first_bold=True))
    s.append(Paragraph("10.1 Livrables", h2))
    s += bullets([
        "Code source : application mobile, backend d'IA, migrations Supabase, scripts d'entraînement.",
        "Modèles livrés et autonomes (dossier <i>model/</i>) et historique complet dans MLflow.",
        "Rapports d'évaluation des modèles (comparaisons base / versions, matrices de confusion).",
        "Ce cahier des charges et la documentation de lancement (README).",
    ])

    # 11. Recette
    s += H1(11, "Recette et critères d'acceptation")
    s.append(table([
        ["Domaine", "Critère d'acceptation"],
        ["Comptes", "Un utilisateur ne voit jamais l'activité d'un autre groupe (vérifié par les règles RLS)"],
        ["Dépenses", "Les parts d'une dépense totalisent toujours 100 % ; les soldes du groupe totalisent 0"],
        ["Remboursements", "Le résumé propose au plus (n − 1) virements pour n participants concernés"],
        ["Temps réel", "Une dépense ou un vote apparaît chez les autres sans recharger la page"],
        ["Scanner", "Total juste sur au moins 95 % des tickets du jeu de test"],
        ["Phrase", "Score d'évaluation supérieur à 0,95 ; aucun membre inventé"],
        ["Trajet", "Ordre jamais plus long que l'ordre de départ ; heures fixées respectées"],
        ["Carte", "Un lieu trouvé apparaît sur la carte ; filtre par date opérationnel"],
        ["Qualité", "Tous les tests automatiques passent ; aucune alerte d'analyse statique"],
    ], [34 * mm, W - 2 * MARGIN - 34 * mm], first_bold=True))

    # 12. Évolutions
    s += H1(12, "Évolutions envisagées")
    s.append(table([
        ["Évolution", "Intérêt"],
        ["Hébergement du backend sur un serveur GPU", "Utiliser l'IA partout, sans le Mac"],
        ["Publication App Store / Play Store", "Ouvrir l'app au public (TestFlight dans un premier temps)"],
        ["Connexion avec Apple", "Exigée par l'App Store quand Google est proposé"],
        ["Heures d'ouverture des lieux", "Trajets encore plus réalistes"],
        ["Affinage du modèle de trajet", "Textes plus personnalisés, suivi comparatif dans MLflow"],
        ["Notifications", "Prévenir d'une nouvelle dépense ou d'un vote"],
        ["Version Android testée", "Toucher tous les utilisateurs"],
    ], [72 * mm, W - 2 * MARGIN - 72 * mm], first_bold=True))
    s.append(Spacer(1, 14))
    s.append(Callout("EquiPay réunit dans une seule app le partage des dépenses, l'organisation du voyage et "
                     "quatre usages concrets de l'IA générative, avec une démarche MLOps complète : données "
                     "versionnées, évaluations comparatives et déploiement contrôlé de la meilleure version.",
                     title="En résumé"))
    return s


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc = Doc(str(OUT))
    doc.multiBuild(story())
    print(OUT)


if __name__ == "__main__":
    main()
