#!/bin/bash
# Strata one-time model preparation - run INSIDE the llama-swap container:
#
#   docker exec -it <llama-swap-container> /opt/strata/first-setup.sh [IQ2_XS]
#
# Downloads the GGUF model (+ MTP draft layer) into the bind-mounted data dir,
# prepares the pack and writes the run config. The engine is already in the
# image (BUILD.json, source=local), so NO compilation happens here.
# Mainland-China friendly: STRATA_SOURCE=modelscope skips Hugging Face entirely
# (same repo names on modelscope.cn, no proxy needed).
#
# Env:
#   STRATA_MODEL      quant size (default IQ2_XS; IQ3_XXS/IQ3_S need more RAM)
#   STRATA_DATA_DIR   where model files go (default /strata - the bind mount)
#   STRATA_SOURCE     modelscope or huggingface (default auto)
#   STRATA_GPUS       which GPUs share the model (default all -> layer split)
set -e

MODEL="${1:-${STRATA_MODEL:-IQ2_XS}}"
DATA_DIR="${STRATA_DATA_DIR:-/strata}"
GPUS="${STRATA_GPUS:-all}"

cd /opt/strata
echo "=== Strata first setup: model=${MODEL} data=${DATA_DIR} gpus=${GPUS} source=${STRATA_SOURCE:-auto} ==="
.venv/bin/python setup.py --no-start --yes \
    --model "${MODEL}" \
    --data-dir "${DATA_DIR}" \
    --gpus "${GPUS}" \
    --vision no

# The run config is written to /opt/strata (image layer, lost on image update);
# copy it onto the bind mount so it survives. All paths inside are absolute
# (exe -> /opt/strata/engine/strata, model -> ${DATA_DIR}/...), so it works
# from anywhere. llama-swap's entry should point --config at this copy.
cp -v /opt/strata/strata-*.json "${DATA_DIR}/"
echo "=== Done. Point llama-swap's entry at: --config ${DATA_DIR}/strata-*.json ==="
ls -la "${DATA_DIR}/"
