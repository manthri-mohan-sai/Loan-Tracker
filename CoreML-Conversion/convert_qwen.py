#!/usr/bin/env python3
"""
Convert Qwen2.5-0.5B-Instruct to CoreML format for iOS (Loan Tracker app).

Downloads the model from HuggingFace, wraps it, traces with torch.jit,
converts to a CoreML model with variable-length input, then compiles to
.mlmodelc ready to be added to Xcode or uploaded to a CDN.

Requirements:
    pip install -r requirements.txt

Usage (run on a Mac):
    python3 convert_qwen.py

Output:
    Qwen2.5-0.5B-Instruct.mlpackage    <- intermediate, can delete after
    Qwen2.5-0.5B-Instruct.mlmodelc/   <- add this to your CDN / Xcode bundle

Notes:
    - First run downloads ~1 GB of weights from HuggingFace.
    - Conversion takes 5-15 min depending on your Mac.
    - The compiled model is ~280-350 MB (float16 weights).
    - iOS target: 16+ (no makeState needed; stateful upgrade possible later).
"""

import os
import subprocess
import sys
from pathlib import Path

# ── Dependency check ──────────────────────────────────────────────────────────
try:
    import torch
    import coremltools as ct
    import numpy as np
    from transformers import AutoModelForCausalLM, AutoConfig
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run:  pip install -r requirements.txt")
    sys.exit(1)

# ── Configuration ─────────────────────────────────────────────────────────────
MODEL_ID     = "Qwen/Qwen2.5-0.5B-Instruct"
OUTPUT_NAME  = "Qwen2.5-0.5B-Instruct"

# Maximum token sequence the model will accept (prompt + generated output).
# Increasing this makes the model slower and larger.
# 1024 fits: ~700-token prompt + 300-token JSON output comfortably.
MAX_SEQ_LEN  = 1024

# Length of the dummy tensor used for torch.jit.trace.
# Must be <= MAX_SEQ_LEN. Any value works; 64 is fast.
TRACE_LEN    = 64


# ── Model Wrapper ─────────────────────────────────────────────────────────────
class QwenForward(torch.nn.Module):
    """
    Strips the Qwen model down to a single input → single output function.
    CoreML requires clean tensor I/O with no complex return types.

    Input:  input_ids  shape [1, seq_len]  dtype int64
    Output: logits     shape [1, seq_len, vocab_size]  dtype float32 → cast to float16
    """
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        return self.model(
            input_ids=input_ids,
            use_cache=False,          # no KV cache; non-stateful inference
            output_attentions=False,
            output_hidden_states=False,
        ).logits


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("  Qwen2.5-0.5B-Instruct → CoreML Converter")
    print("=" * 60)
    print(f"  Model      : {MODEL_ID}")
    print(f"  Output     : {OUTPUT_NAME}.mlmodelc")
    print(f"  Max tokens : {MAX_SEQ_LEN}")
    print()

    # ── Step 1: Load from HuggingFace ─────────────────────────────────────
    print("Step 1/4  Loading model from HuggingFace (~1 GB on first run)...")
    hf_model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float32,   # float32 for stable tracing; cast to f16 later
        low_cpu_mem_usage=True,
    )
    hf_model.eval()

    cfg = AutoConfig.from_pretrained(MODEL_ID)
    print(f"          Loaded: {cfg.num_hidden_layers} layers, "
          f"vocab_size={cfg.vocab_size}, hidden={cfg.hidden_size}")

    wrapper = QwenForward(hf_model)

    # ── Step 2: Trace ─────────────────────────────────────────────────────
    print(f"Step 2/4  Tracing model with dummy input (seq_len={TRACE_LEN})...")
    dummy = torch.zeros(1, TRACE_LEN, dtype=torch.long)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy)
    print("          Trace complete.")

    # ── Step 3: CoreML conversion ─────────────────────────────────────────
    print("Step 3/4  Converting to CoreML (5-15 min)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="input_ids",
                # Variable sequence length from 1 to MAX_SEQ_LEN
                shape=ct.Shape(
                    shape=(1, ct.RangeDim(min_size=1, max_size=MAX_SEQ_LEN))
                ),
                dtype=np.int32,
            )
        ],
        outputs=[
            ct.TensorType(name="logits", dtype=np.float16)
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,   # Neural Engine for speed
        compute_precision=ct.precision.FLOAT16,     # halves model size
    )
    mlmodel.short_description = (
        f"Qwen2.5-0.5B-Instruct — max {MAX_SEQ_LEN} tokens — Loan Tracker"
    )

    package_path = f"{OUTPUT_NAME}.mlpackage"
    print(f"          Saving {package_path}...")
    mlmodel.save(package_path)
    print(f"          Saved.")

    # ── Step 4: Compile to .mlmodelc ──────────────────────────────────────
    modelc_path = f"{OUTPUT_NAME}.mlmodelc"
    print(f"Step 4/4  Compiling to {modelc_path}...")

    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", package_path, "."],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print()
        print("  Compilation failed — run this manually:")
        print(f"    xcrun coremlcompiler compile {package_path} .")
        print()
        print(f"  Error output:\n{result.stderr.strip()}")
        return

    # ── Summary ───────────────────────────────────────────────────────────
    size_bytes = sum(
        f.stat().st_size for f in Path(modelc_path).rglob("*") if f.is_file()
    )
    print()
    print("=" * 60)
    print(f"  Done!  {modelc_path}  ({size_bytes / 1024**2:.0f} MB)")
    print("=" * 60)
    print()
    print("Next steps:")
    print()
    print("  1. Upload the compiled model to a CDN or S3:")
    print(f"       {modelc_path}/")
    print("     Then update CoreMLModelManager.remoteModelURL in Xcode.")
    print()
    print("  2. Download the tokenizer vocab files and add to Xcode target")
    print("     (check 'Copy items if needed', target: Loan Tracker):")
    print()
    print(f"     vocab.json  →  rename to  qwen_vocab.json")
    print(f"     https://huggingface.co/{MODEL_ID}/resolve/main/vocab.json")
    print()
    print(f"     merges.txt  →  rename to  qwen_merges.txt")
    print(f"     https://huggingface.co/{MODEL_ID}/resolve/main/merges.txt")
    print()
    print("  3. Build the Xcode project and test!")
    print()


if __name__ == "__main__":
    main()
