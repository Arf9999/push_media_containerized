#!/usr/bin/env bash

# ====================================================================
# Automated conversion of MzansiLM (125M) to Ollama GGUF model
# ====================================================================
# Prerequisites:
#   - git, python, pip, curl installed
#   - Ollama installed and running (ollama serve)
#   - llama.cpp repository will be cloned into a temporary folder
#
# This script performs the following steps:
#   1. Clone llama.cpp and install its Python requirements
#   2. Clone the MzansiLM model repository from Hugging Face
#   3. Convert the Safetensors model to GGUF using llama.cpp's helper
#   4. Create an Ollama Modelfile pointing to the generated GGUF
#   5. Build the Ollama model
#   6. Clean up temporary directories (optional)
#
# Usage:
#   ./alpha/convert_mzansilm.sh
#   The script will leave the generated .gguf and Modelfile in the current
#   directory, ready for `ollama create`.
# ====================================================================

set -euo pipefail

# ---- Configuration ---------------------------------------------------
LLAMA_REPO="https://github.com/ggerganov/llama.cpp.git"
MODEL_REPO="https://huggingface.co/anrilombard/mzansilm-125m"
WORKDIR="$(mktemp -d)"
LLAMA_DIR="$WORKDIR/llama.cpp"
MODEL_DIR="$WORKDIR/mzansilm-125m"
GGUF_OUT="mzansilm-125m.gguf"
MODFILE="Modelfile"

echo "[Step 1] Cloning llama.cpp into $LLAMA_DIR"
git clone "$LLAMA_REPO" "$LLAMA_DIR"
cd "$LLAMA_DIR"
# Install Python dependencies for the conversion script
pip install -r requirements.txt

echo "[Step 2] Cloning MzansiLM repository"
git clone "$MODEL_REPO" "$MODEL_DIR"

echo "[Step 3] Converting to GGUF"
# Use the conversion script provided by llama.cpp
python ./convert_hf_to_gguf.py "$MODEL_DIR" --outfile "$GGUF_OUT"

# Move the GGUF out of the temporary workspace for easier access
mv "$GGUF_OUT" "$PWD/"

# ---- Create Ollama Modelfile ---------------------------------------
cat > "$MODFILE" <<EOF
FROM ./mzansilm-125m.gguf
# Adjust temperature for translation tasks (lower keeps output stable)
PARAMETER temperature 0.3
PARAMETER top_p 0.9
SYSTEM "You are a helpful multilingual assistant fluent in all 11 official South African languages including isiXhosa, Zulu, Sepedi, Setswana, and Sesotho."
EOF

echo "[Step 4] Ollama Modelfile created at $PWD/$MODFILE"

# ---- Build the model in Ollama --------------------------------------
# The model name "mzansilm" can be changed if desired
ollama create mzansilm -f "$MODFILE"

echo "[Step 5] Ollama model 'mzansilm' built successfully."

echo "[Step 6] Cleanup temporary workspace"
rm -rf "$WORKDIR"

echo "All done! You can now run the model with:"
echo "    ollama run mzansilm"
