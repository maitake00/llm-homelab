# llm-homelab — 8GB VRAMで動かす自前LLM基盤

RTX 3060 Ti(8GB)+RAM 48GBのPCで、ローカルLLM・日英対応RAG・LoRA特化モデルを運用するための構成一式。
オープンなLLMを自分のサーバーで動かし、監視付きで運用しながら、8GB VRAMという制約下でのチューニング方法を実測でまとめている。

## 全体構成

このリポジトリ(llm-homelab)は**基盤**。RAGとLoRAは姉妹リポジトリに分離している。

| リポジトリ | 役割 |
| --- | --- |
| **llm-homelab**(これ) | Ollama・監視(Prometheus/Grafana)・リランカー(Xinference)のDockerスタック |
| **llamaindex-rag** | 日英対応RAGパイプライン(LlamaIndex自作) |
| **lora-secretary** | 秘書スタイルLoRA(Swallow 8B、Colab学習→手元GGUF化) |

[llamaindex-rag] 質問 → bge-m3で検索 → bge-rerankerでリランク → LLMが回答
│ │ │
[llm-homelab] Ollama(GPU) Xinference(CPU) Ollama(GPU)
│
[lora-secretary] secretary(Swallow 8B + 秘書LoRA) ← LLMとして使用可


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
# スタックを起動(このリポジトリのフォルダで)。リランカーは自動でlaunchされる。
docker compose up -d

# リランカーの起動確認(初回はビルド+ロードで数分)
docker compose logs xinference | tail -20   # "準備完了。サーバを維持します。" が出ればOK
docker exec xinference xinference list       # bge-reranker-v2-m3 が出ればOK
```

補足:
- Windows で **ネイティブ版 Ollama** も使っている場合、ポート 11434 の競合を避けるため終了しておく(Dockerの Ollama と別インスタンスに繋がるのを防ぐ)。
- 再起動後は `docker compose up -d` だけで復帰できる(モデルは Ollama が自動ロード、リランカーは Xinference のカスタムイメージが自動 launch)。
- リランカーの詳細と背景(なぜカスタムイメージか)は [XINFERENCE_RERANKER.md](./XINFERENCE_RERANKER.md) を参照。

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

# 4. リランカー(Xinference)はカスタムイメージが自動で用意・launchするため追加手順は不要
#    (peft除去 + sentence-transformers + 自動launch を ./xinference/Dockerfile に焼き込み済み)
```

アクセス: チャットUI http://localhost:8091 / Grafana http://localhost:3000 / Xinference http://localhost:9997

---

## 8GB VRAMで得た運用ノウハウ(実測に基づく)

- **少しでもGPUから漏れると激遅**: 20%CPUオフロードで速度は約1/5(60→13 t/s)。「だいたい乗る」は不十分で、100% GPUに収め切ることが速度の絶対条件。
- **num_ctxはVRAMの最大レバー**: qwen3.5の既定256Kは過剰。4096に絞ると本体がGPUに収まり速度が跳ねる。
- **OLLAMA_MAX_LOADED_MODELS**: RAGは埋め込み+生成の2モデルを使う。1だと毎回6.4GBの載せ替えが発生して激遅。2にすると重い方が常駐し、軽い埋め込みは都度ロード(2-3秒)で済む。
- **KVキャッシュ量子化(q8_0)+Flash Attention**: qwen3.5系で生成が1-2 t/sに壊れる不具合に遭遇し無効化。品質面でもフル精度KVの方が良いので外して正解だった。
- **thinkingモデルの暴走**: 思考ブロックがコンテキストを食い潰しEmpty Responseになる。API側の thinking=False + temperature=0 + num_predict上限で制御。
- **リランカーの供給問題**: Ollamaはリランカー非対応。Xinference v2.9.0はtorchcodecバグでrerankが壊れるため v2.8.0-cpu に固定。sentence-transformers追加+peft削除+自動launchをカスタムイメージ(./xinference/Dockerfile)に焼き込んで恒久化。

構築の経緯と各つまずきの詳細は [IMPLEMENTATION.md](./IMPLEMENTATION.md) を参照。
