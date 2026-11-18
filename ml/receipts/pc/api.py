"""Interface web pour tester le scanner de reçus à la main.

  python api.py                          → adaptateur le plus récent de outputs/
  python api.py --from-registry          → champion du registre MLflow « equipay-receipt »
  python api.py --adapter <dossier>      → adaptateur précis
  python api.py --base                   → modèle de base sans adaptateur (comparaison)
Puis ouvrir http://localhost:8100 (ou http://<IP du PC>:8100 depuis le Mac).
"""
import argparse
import io
import os
import threading
import time
from pathlib import Path

os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")

import torch  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, File, HTTPException, UploadFile  # noqa: E402
from fastapi.responses import HTMLResponse  # noqa: E402
from PIL import Image, UnidentifiedImageError  # noqa: E402

import evaluate_cuda  # noqa: E402
import receipt_data as D  # noqa: E402
import receipt_metrics as M  # noqa: E402

HERE = Path(__file__).resolve().parent
app = FastAPI(title="EquiPay — scanner de reçus")
STATE = {}
LOCK = threading.Lock()  # une analyse à la fois sur le GPU


def latest_adapter():
    if (HERE.parent / "adapter" / "adapter_config.json").exists():  # modèle importé sur le Mac
        return HERE.parent / "adapter"
    found = sorted((HERE / "outputs").glob("*/adapter/adapter_config.json"), key=lambda p: p.stat().st_mtime)
    return found[-1].parent if found else None


def registry_adapter(tracking_uri):  # noqa: D401 — champion du registre
    import mlflow

    mlflow.set_tracking_uri(tracking_uri)
    client = mlflow.MlflowClient()
    version = client.get_model_version_by_alias("equipay-receipt", "champion")
    path = mlflow.artifacts.download_artifacts(artifact_uri=version.source, dst_path=str(HERE / "registry_cache"))
    return Path(path), f"equipay-receipt v{version.version} (champion du registre)"


@app.get("/health")
def health():
    return {"ok": True, "model": STATE.get("label")}


@app.post("/scan")
async def scan(file: UploadFile = File(...)):
    try:
        image = Image.open(io.BytesIO(await file.read()))
        image.load()
    except (UnidentifiedImageError, OSError):
        raise HTTPException(400, "Ce fichier n'est pas une image lisible.")
    image = D.resize(image, STATE["max_side"])
    tic = time.perf_counter()
    with LOCK:
        texts, lengths = evaluate_cuda.predict(STATE["model"], STATE["processor"], [image], STATE["prompt"])
    data = M.parse_json(texts[0])
    items = []
    for it in (data or {}).get("items") or []:
        if isinstance(it, dict):
            items.append({"label": it.get("label"), "qty": it.get("qty"), "price": M.to_number(it.get("price"))})
    return {
        "model": STATE["label"],
        "ok": data is not None,
        "merchant": (data or {}).get("merchant"),
        "address": (data or {}).get("address"),
        "date": (data or {}).get("date"),
        "amount_text": (data or {}).get("amount_text"),
        "total": M.to_number((data or {}).get("amount")),
        "currency": (data or {}).get("currency"),
        "items": items,
        "items_sum": sum(i["price"] or 0 for i in items),
        "raw": texts[0],
        "latency_s": round(time.perf_counter() - tic, 2),
        "tokens": lengths[0],
        "device": STATE["device"],
    }


@app.get("/", response_class=HTMLResponse)
def page():
    return PAGE.replace("{{MODEL}}", STATE.get("label", "?"))


PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scanner de reçus EquiPay</title>
<style>
:root{--bg:#f6f8fa;--card:#fff;--text:#0f172a;--muted:#64748b;--primary:#0f766e;--line:#e2e8f0;--bad:#dc2626}
@media (prefers-color-scheme: dark){:root{--bg:#0b1220;--card:#111a2e;--text:#e2e8f0;--muted:#94a3b8;--primary:#2dd4bf;--line:#1e293b}}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,sans-serif;background:var(--bg);color:var(--text)}
main{max-width:980px;margin:0 auto;padding:24px 16px}h1{margin:0 0 4px;font-size:24px}.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:20px}@media(max-width:760px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px}
#drop{border:2px dashed var(--line);border-radius:14px;padding:28px;text-align:center;cursor:pointer}
#drop.over{border-color:var(--primary)}#preview{max-width:100%;max-height:520px;display:none;margin:12px auto 0;border-radius:10px}
button{background:var(--primary);color:#fff;border:0;border-radius:10px;padding:12px 18px;font-size:16px;font-weight:600;cursor:pointer;width:100%;margin-top:12px}
button:disabled{opacity:.5;cursor:default}.total{font-size:34px;font-weight:800}table{width:100%;border-collapse:collapse;margin-top:10px}table.info td:first-child{width:90px}
td,th{padding:8px 6px;border-bottom:1px solid var(--line);text-align:left}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
pre{white-space:pre-wrap;word-break:break-word;background:var(--bg);padding:10px;border-radius:10px;font-size:12px}
.err{color:var(--bad)}details{margin-top:12px}
</style></head><body><main>
<h1>Scanner de reçus EquiPay</h1><div class="muted">Modèle : {{MODEL}}</div>
<div class="grid">
 <section class="card">
  <div id="drop">Dépose la photo d'un ticket ici<br><span class="muted">ou clique pour la choisir</span></div>
  <input id="file" type="file" accept="image/*" hidden>
  <img id="preview" alt="Ticket choisi">
  <button id="go" disabled>Analyser le ticket</button>
 </section>
 <section class="card" id="result"><div class="muted">Le résultat s'affichera ici.</div></section>
</div></main>
<script>
const drop=document.getElementById('drop'),input=document.getElementById('file'),preview=document.getElementById('preview'),go=document.getElementById('go'),out=document.getElementById('result');
let chosen=null;
const fmt=(v,c)=>v==null?'—':Number(v).toLocaleString('fr-FR',{maximumFractionDigits:2})+(c?' '+c:'');
const esc=s=>String(s??'').replace(/[&<>"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[ch]));
function pick(f){if(!f)return;chosen=f;preview.src=URL.createObjectURL(f);preview.style.display='block';go.disabled=false;}
drop.onclick=()=>input.click();input.onchange=()=>pick(input.files[0]);
drop.ondragover=e=>{e.preventDefault();drop.classList.add('over')};drop.ondragleave=()=>drop.classList.remove('over');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('over');pick(e.dataTransfer.files[0])};
go.onclick=async()=>{
 go.disabled=true;go.textContent='Analyse en cours…';out.innerHTML='<div class="muted">Lecture du ticket…</div>';
 const fd=new FormData();fd.append('file',chosen);
 try{
  const r=await fetch('/scan',{method:'POST',body:fd});const d=await r.json();
  if(!r.ok)throw new Error(d.detail||'Erreur');
  const rows=d.items.map(i=>`<tr><td>${esc(i.label)}</td><td class="n">${i.qty??''}</td><td class="n">${fmt(i.price)}</td></tr>`).join('');
  const gap=d.total!=null&&d.items.length&&Math.abs(d.items_sum-d.total)>0.01;
  out.innerHTML=(d.ok?'':'<p class="err">Réponse illisible : le modèle n\\'a pas produit de JSON valide.</p>')+
   `<div class="muted">Total payé</div><div class="total">${fmt(d.total,esc(d.currency))}</div>`+
   (d.amount_text?`<div class="muted">Imprimé sur le ticket : « ${esc(d.amount_text)} »</div>`:'')+
   `<table class="info"><tr><td class="muted">Enseigne</td><td>${esc(d.merchant)||'—'}</td></tr>`+
   `<tr><td class="muted">Adresse</td><td>${esc(d.address)||'—'}</td></tr>`+
   `<tr><td class="muted">Date</td><td>${esc(d.date)||'—'}</td></tr></table>`+
   `<table><thead><tr><th>Article</th><th class="n">Qté</th><th class="n">Prix</th></tr></thead><tbody>${rows||'<tr><td colspan=3 class="muted">Aucun article</td></tr>'}</tbody></table>`+
   `<p class="muted">Somme des articles : ${fmt(d.items_sum)}${gap?' — <span class="err">différente du total (taxes, service ou remise ?)</span>':''}</p>`+
   `<p class="muted">Analysé en ${d.latency_s} s (${d.tokens} jetons, ${esc(d.device)})</p>`+
   `<details><summary>Réponse brute du modèle</summary><pre>${esc(d.raw)}</pre></details>`;
 }catch(e){out.innerHTML=`<p class="err">${esc(e.message)}</p>`}
 go.disabled=false;go.textContent='Analyser le ticket';
};
</script></body></html>"""


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--adapter")
    p.add_argument("--from-registry", action="store_true")
    p.add_argument("--base", action="store_true", help="modèle de base sans adaptateur")
    p.add_argument("--v1", help="dossier de l'adaptateur v1 (utilise le prompt v1)")
    p.add_argument("--model", default=evaluate_cuda.BASE_MODEL)
    p.add_argument("--max-side", type=int, default=1024)
    p.add_argument("--port", type=int, default=8100)
    p.add_argument("--tracking-uri", default=os.environ.get("EQUIPAY_MLFLOW_URI", "http://192.168.1.23:5000"))
    args = p.parse_args()
    STATE["device"] = evaluate_cuda.device()

    merged = HERE.parent / "model"
    STATE["prompt"] = D.PROMPT
    if args.v1:
        adapter, label, STATE["prompt"] = Path(args.v1), "equipay-receipt v1 (prompt v1)", D.PROMPT_V1
    elif args.base:
        adapter, label = None, f"{args.model} (base, sans entraînement)"
    elif not args.adapter and not args.from_registry and (merged / "config.json").exists():
        # Modèle final enregistré sur le Mac : base + LoRA déjà fusionnés
        args.model, adapter, label = str(merged), None, "equipay-receipt v2 — Qwen3-VL-4B affiné"
    elif args.from_registry:
        adapter, label = registry_adapter(args.tracking_uri)
    else:
        adapter = Path(args.adapter) if args.adapter else latest_adapter()
        if adapter is None:
            raise SystemExit("Aucun adaptateur dans outputs/ : entraîne d'abord, ou utilise --base / --from-registry.")
        label = f"equipay-receipt v2 — adaptateur {adapter.parent.name if adapter.name == 'adapter' else adapter.name}"
    print(f"Chargement : {label}…", flush=True)
    STATE["model"], STATE["processor"] = evaluate_cuda.load_model(adapter, args.model, merge=True)
    STATE["label"], STATE["max_side"] = label, args.max_side
    print(f"Interface : http://localhost:{args.port}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
