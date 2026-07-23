#!/bin/bash
# サーバ起動 → 準備完了を待つ → リランカー自動launch → サーバ維持
set -e
MODEL_NAME="bge-reranker-v2-m3"
PORT=9997

echo "[entrypoint] Xinference を起動します..."
xinference-local -H 0.0.0.0 --port "${PORT}" &
SERVER_PID=$!

echo "[entrypoint] サーバの準備完了を待機中..."
for i in $(seq 1 60); do
  if xinference list >/dev/null 2>&1; then
    echo "[entrypoint] サーバ準備完了。"
    break
  fi
  sleep 2
done

echo "[entrypoint] リランカー ${MODEL_NAME} を launch します..."
xinference launch --model-name "${MODEL_NAME}" --model-type rerank || \
  echo "[entrypoint] launch 非ゼロ終了(既に起動済みの可能性)。続行します。"

echo "[entrypoint] 準備完了。サーバを維持します。"
wait "${SERVER_PID}"
