# llm-homelab — 8GB VRAMで動かす自前LLM基盤

RTX 3060 Ti(8GB)+RAM 48GBのPCで、ローカルLLM・日英対応RAG・LoRA特化モデルを運用するための構成一式。
「自前でLLMを運用すると実際どこが大変か」を体験しながら、インフラ×AI(LLMOps)のスキルとポートフォリオを作ることを目的に構築した。

## 全体構成

このリポジトリ(llm-homelab)は**基盤**。RAGとLoRAは姉妹リポジトリに分離している。

| リポジトリ | 役割 |
| --- | --- |
| **llm-homelab**(これ) | Ollama・監視(Prometheus/Grafana)・リランカー(Xinference)のDockerスタック |
| **llamaindex-rag** | 日英対応RAGパイプライン(LlamaIndex自作) |
| **lora-secretary** | 秘書スタイルLoRA(Swallow 8B、Colab学習→手元GGUF化) |

```
[llamaindex-rag]  質問 → bge-m3で検索 → bge-rerankerでリランク → LLMが回答
                     │              │                  │
[llm-homelab]     Ollama(GPU)   Xinference(CPU)     Ollama(GPU)
                     │
[lora-secretary]  secretary(Swallow 8B + 秘書LoRA) ← LLMとして使用可
```

## コンポーネント

| サービス | 役割 |
| --- | --- |
| Ollama | LLM本体。生成(qwen3.5:9b / secretary)と埋め込み(bge-m3)。GPU |
| Xinference | リランカー(bge-reranker-v2-m3)。CPU。v2.8.0-cpu固定 |
| Open WebUI | ChatGPT風チャットUI |
| Caddy | リバースプロキシ |
| Prometheus + Grafana | メトリクス収集・ダッシュボード |
| node-exporter / cAdvisor | ホスト・コンテナのリソース監視 |

## 導入モデル

| モデル | 用途 | 実測速度(8GB VRAM) |
| --- | --- | --- |
| qwen3.5:9b | 汎用生成(テキスト+画像+ツール) | 約56 t/s(100% GPU) |
| secretary | 秘書口調の生成(Swallow 8B+LoRA) | 同等 |
| bge-m3 | 多言語埋め込み(日英対応) | - |
| bge-reranker-v2-m3 | リランク(Xinference側) | CPU |

---

## 起動手順

```bash
# 1. スタックを起動(このリポジトリのフォルダで)
docker compose up -d

# 2. リランカーを起動(Xinferenceは再起動のたびに必要)
docker exec xinference xinference launch --model-name bge-reranker-v2-m3 --model-type rerank
docker exec xinference xinference list   # 起動確認
```

補足:
- Windows で **ネイティブ版 Ollama** も使っている場合、ポート 11434 の競合を避けるため終了しておく(Dockerの Ollama と別インスタンスに繋がるのを防ぐ)。
- 再起動後は上の2ステップを実行すれば復帰できる(モデルは Ollama が自動ロード、リランカーのみ手動 launch が必要)。

### コンテナを作り直した場合のみ(compose down / イメージ変更後)

Xinference の pip 変更はコンテナ再作成で消えるため、再実行が必要:
```bash
docker exec xinference pip install sentence-transformers
docker exec xinference pip uninstall -y peft
```
(恒久化するならフル版イメージ xprobe/xinference:v2.8.0 か、カスタムDockerfile化)

---

## 初期セットアップ(初回のみ)

```bash
# 1. 設定
cp .env.example .env   # DOMAIN, WEBUI_SECRET_KEY, GRAFANA_PASSWORD を設定

# 2. 起動
docker compose up -d

# 3. モデル導入
docker exec -it ollama ollama pull qwen3.5:9b
docker exec -it ollama ollama pull bge-m3

# 4. リランカー(Xinference)
docker exec xinference pip install sentence-transformers
docker exec xinference pip uninstall -y peft
docker exec xinference xinference launch --model-name bge-reranker-v2-m3 --model-type rerank
```

アクセス: チャットUI http://localhost:8091 / Grafana http://localhost:3000 / Xinference http://localhost:9997

---

## 8GB VRAMで得た運用ノウハウ(実測に基づく)

- **少しでもGPUから漏れると激遅**: 20%CPUオフロードで速度は約1/5(60→13 t/s)。「だいたい乗る」は不十分で、100% GPUに収め切ることが速度の絶対条件。
- **num_ctxはVRAMの最大レバー**: qwen3.5の既定256Kは過剰。4096に絞ると本体がGPUに収まり速度が跳ねる。
- **OLLAMA_MAX_LOADED_MODELS**: RAGは埋め込み+生成の2モデルを使う。1だと毎回6.4GBの載せ替えが発生して激遅。2にすると重い方が常駐し、軽い埋め込みは都度ロード(2-3秒)で済む。
- **KVキャッシュ量子化(q8_0)+Flash Attention**: qwen3.5系で生成が1-2 t/sに壊れる不具合に遭遇し無効化。品質面でもフル精度KVの方が良いので外して正解だった。
- **thinkingモデルの暴走**: 思考ブロックがコンテキストを食い潰しEmpty Responseになる。API側の thinking=False + temperature=0 + num_predict上限で制御。
- **リランカーの供給問題**: Ollamaはリランカー非対応。Xinference v2.9.0はtorchcodecバグでrerankが壊れるため v2.8.0-cpu に固定し、sentence-transformers追加+peft削除で動作。

構築の経緯と各つまずきの詳細は [IMPLEMENTATION.md](./IMPLEMENTATION.md) を参照。
