"""render.py <content.json> <raw dir>: renders the demo art with FLUX.1-schnell (Apache-2.0) on a CUDA GPU.

Prompts are encoded with T5 alone on the GPU, then the transformer runs without offload (~1 s an image on
a 32 GB card). Each image is <kind>-<slug>-<part>-<seed>.png; existing files are skipped.
"""
import gc, json, os, sys
import torch
from diffusers import FluxPipeline

C, OUT = json.load(open(sys.argv[1])), sys.argv[2]
os.makedirs(OUT, exist_ok=True)
BD, PO, SQ, HS = (1920, 1088), (1024, 1536), (1024, 1024), (768, 768)
NO_TEXT = ", no text, no letters, no words, no logo, no watermark"

jobs = []  # (name, prompt, size, seed)
for m in C["movies"]:
    jobs += [(f"movie-{m['slug']}-backdrop", m["backdrop"], BD, m["seeds"]["backdrop"]),
             (f"movie-{m['slug']}-poster", m["poster"], PO, m["seeds"]["poster"])]
for s in C["shows"]:
    jobs += [(f"show-{s['slug']}-backdrop", s["backdrop"], BD, s["seeds"]["backdrop"]),
             (f"show-{s['slug']}-poster", s["poster"], PO, s["seeds"]["poster"])]
    jobs += [(f"show-{s['slug']}-e{i}", "cinematic still, " + e[2], BD, seed)
             for i, (e, seed) in enumerate(zip(s["episodes"], s["seeds"]["episodes"]), 1)]
for ch in C["live"]:
    jobs += [(f"live-{ch['number']}", ch["prompt"], BD, seed) for seed in (1, 2)]
for i, a in enumerate(C["actors"]):
    jobs.append((f"actor-{i}", a["prompt"], HS, a["seed"]))
for a in C["albums"]:
    jobs.append((f"album-{a['slug']}", a["prompt"], SQ, a["seed"]))
jobs = [j for j in jobs if not os.path.exists(f"{OUT}/{j[0]}-{j[3]}.png")]

pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-schnell", transformer=None, vae=None,
                                    torch_dtype=torch.bfloat16).to("cuda")
embeds = {}
with torch.no_grad():
    for _, prompt, _, _ in jobs:
        if prompt not in embeds:
            pe, ppe, _ = pipe.encode_prompt(prompt=prompt + NO_TEXT, prompt_2=prompt + NO_TEXT, max_sequence_length=256)
            embeds[prompt] = (pe.cpu(), ppe.cpu())
del pipe
gc.collect(); torch.cuda.empty_cache()
pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-schnell", text_encoder=None, text_encoder_2=None,
                                    tokenizer=None, tokenizer_2=None, torch_dtype=torch.bfloat16).to("cuda")
for name, prompt, (w, h), seed in jobs:
    pe, ppe = embeds[prompt]
    pipe(prompt_embeds=pe.cuda(), pooled_prompt_embeds=ppe.cuda(), width=w, height=h, num_inference_steps=4,
         guidance_scale=0.0, generator=torch.Generator("cpu").manual_seed(seed)).images[0].save(f"{OUT}/{name}-{seed}.png")
    print(name, seed, flush=True)
