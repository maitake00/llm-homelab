# llm-homelab — 自前LLM基盤を立てて運用する

オープンなLLMを自分のサーバーで動かし、監視付きで運用するための構成一式。
「自前でLLMを運用すると実際どこが大変なのか」を体験しながら、インフラ×AI(LLMOps)のスキルとポートフォリオを作ることを目的にしています。

## なぜ作ったか (このプロジェクトの位置づけ)

個人的に必要だから作ったのではなく、**実務で使われるLLMの自前運用(LLMOps)がどういうものか、手を動かして理解するため**に立てました。作って動かす過程で出てくる運用課題(コスト・リソース・証明書・監視など)を記録し、解決していくことそのものが成果物です。

## 構成

| コンポーネント | 役割 |
| --- | --- |
| Ollama | LLM本体。オープンモデルをローカルで動かす(推論はAPI課金なし) |
| Open WebUI | ChatGPT風のチャットUI |
| Caddy | リバースプロキシ。独自ドメイン+HTTPSを自動化 |
| Prometheus | メトリクス収集 |
| Grafana | ダッシュボード |
| node-exporter | サーバー自身のCPU/メモリ/ディスク監視 |
| cAdvisor | 各コンテナのリソース監視 |

```
[ブラウザ] --HTTPS--> [Caddy] --> [Open WebUI] --> [Ollama]
                                    Prometheus <- node-exporter / cAdvisor / Ollama
                                    Grafana <- Prometheus
```

## 動かす前提

- Docker と Docker Compose が入っていること
- メモリ 8GB 以上を推奨(小さいモデルなら4GBでも可)
- GPUは無くても動く(CPU推論。遅いが体験には十分)。GPUがあれば `docker-compose.yml` の該当箇所を有効化
- 公開する場合は、独自ドメインとサーバーの80/443番ポートが開いていること

## 使い方

```bash
# 1. 設定ファイルを用意
cp .env.example .env
#   .env を編集: DOMAIN, WEBUI_SECRET_KEY, GRAFANA_PASSWORD を設定
#   秘密鍵の生成例:  openssl rand -hex 32

# 2. 起動
docker compose up -d

# 3. モデルを1個ダウンロード(初回だけ。軽量なqwen2.5:3bなどから)
docker exec -it ollama ollama pull qwen2.5:3b

# 4. アクセス
#   チャットUI :  https://<DOMAIN>   (ローカル検証は Caddyfile を切り替えて http://localhost)
#   Grafana   :  http://localhost:3000  (admin / .envのGRAFANA_PASSWORD)
```

停止は `docker compose down`、ログ確認は `docker compose logs -f <サービス名>`。

## 4週間ロードマップ

1. **1週目 — 動かす**: Ollama + Open WebUI を起動し、モデルを1個入れてチャットできる状態にする。「モデルが重い」「CPUだと遅い」等の最初の痛みを `OPERATIONS_LOG.md` に記録。
2. **2週目 — 公開する**: Caddyで独自ドメイン+HTTPS化。証明書・ポート・アクセス制限まわりの詰まりを記録。ここがインフラの核。
3. **3週目 — 監視する**: Prometheus + Grafana でサーバーとコンテナ、LLMのメトリクスをダッシュボード化。「監視対象＝自分のLLM基盤」がやっと成立する。
4. **4週目 — 公開&発信**: この構成をGitHubに公開し、`OPERATIONS_LOG.md` を元にZenn/Qiitaに1本記事を書く。構成図とダッシュボードのスクショを添える。

## 次の一手 (面倒をネタに変える)

運用中に見つけた面倒 —— 例: 「モデル切り替えが面倒」「トークン消費量が見えない」「どのモデルが速いか比べたい」 —— が、次に作る**自分のツール**のネタになります。それが2本目のGitHub実績になり、最初に探していた「需要のある作るもの」に繋がります。
