# カスタム Xinference (リランカー bge-reranker-v2-m3 用)
# 公式 v2.8.0-cpu は peft/HybridCache 衝突でリランカーがロード時にクラッシュする。
# peft除去 + sentence-transformers + 起動時の自動launch をイメージに焼き込む。
FROM xprobe/xinference:v2.8.0-cpu

RUN pip install --no-cache-dir sentence-transformers && \
    pip uninstall -y peft

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
