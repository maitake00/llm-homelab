# 8GB VRAMで「実質的な最大の賢さ」を出す実装ガイド

対象環境: RTX 3060 Ti (VRAM 8GB / 実効約6.5GB) + RAM 48GB + i5 12600K。
実装する層: 1(RAG＋ツール) / 3(モデル選定) / 4(メモリ最適化) / 5(投機的デコード) / 6(LoRA特化)。

推奨する実装順は **3 → 4 → 5 → 1 → 6**。土台(モデル＋メモリ)を固めてから、速度・拡張・特化を足す。

---

## 層3: ベースモデルを選定・導入

VRAMに完全に収まる範囲で、最も容量の大きい新世代モデルを選ぶ。8GBの実効VRAMだと **8〜9B級 + Q4** が上限。

推奨: **qwen3.5:9b**(thinking＋tools＋vision、Qwen最新世代の9B)。
- 論理・ツール呼び出しが安定、日本語も強い
- thinking対応なので層2(推論厚め)も後から足せる

```bash
docker exec -it ollama ollama pull qwen3.5:9b
# 埋め込み用(層1のRAGで使う)も入れておく
docker exec -it ollama ollama pull nomic-embed-text
```

導入後 `docker exec -it ollama ollama ps` で **100% GPU** を確認する。CPU%が出たら層4の設定を強める。

---

## 層4: メモリ最適化(全レイヤーをGPUに載せる)

`docker-compose.yml` の ollama サービスに設定済み(環境変数):

| 設定 | 効果 |
| --- | --- |
| `OLLAMA_FLASH_ATTENTION=1` | Attention計算を効率化。KVキャッシュ量子化の前提 |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | KVキャッシュを量子化してVRAM消費を削減(q8_0は品質ほぼ無劣化。さらに削るなら q4_0) |
| `OLLAMA_MAX_LOADED_MODELS=1` | 8GBでは1モデルのみ常駐 |
| `OLLAMA_KEEP_ALIVE=30m` | ロード待ちを減らす |

反映:
```bash
docker compose up -d   # 設定を再読み込み
```

さらにモデル単位で **num_ctx を4096に** 絞る(Open WebUI の Advanced Params か、対話で `/set parameter num_ctx 4096`)。
狙いは「モデル本体＋量子化KVキャッシュ」を実効6.5GBに収め切ること。`ollama ps` が **100% GPU** になれば成功で、生成速度が跳ね上がる。

---

## 層5: 投機的デコード / MTP(速度を稼ぐ)

**正直な実現性**: Ollama単体では投機的デコード(draftモデル併用)の簡単なスイッチが無く、ここは一段ハードルが高い。選択肢は2つ。

1. **MTP版のGGUFを使う** — モデルによっては「MTPヘッド入り」のGGUF変種が配布されている(例のQwythos記事参照)。これをOllamaに `hf.co/...:MTP-Q4_K_M` の形で取り込めば、投機的デコードの恩恵を受けられる。対応モデルに限られる。
2. **llama.cpp を直接使う** — llama.cpp は `--model-draft`(小さいドラフトモデル)で投機的デコードに対応。Ollamaの外で `llama-server` を立て、本モデル＝9B・ドラフト＝0.5〜1B の組み合わせで動かす。自由度は高いが構築の手間がかかる。

推奨: まずは層3・4で"素の速度"を確定させ、それでも遅い場合のみ着手する。日常が快適なら層5は後回しでよい。

---

## 層1: RAG＋ツール(AnythingLLM)

`docker-compose.yml` に AnythingLLM を追加済み。これが「賢さを外付けする」最大のレバー。

起動後、ブラウザで **http://localhost:3001** を開き、初回セットアップで:
- LLM Provider: **Ollama** / Base URL: `http://ollama:11434` / モデル: `qwen3.5:9b`
- Embedding: **Ollama** / モデル: `nomic-embed-text`
- Vector DB: **LanceDB**(内蔵、設定不要)

使い方:
1. **ワークスペースを作る**(用途ごと: 「秘書」「セキュリティ」等)
2. **ドキュメントを投入**(PDF/Markdown/URL) → 自動でベクトル化され、RAGで参照される
3. **ツール(エージェント機能)** を有効化 → Web検索・スクレイピング・コード実行などを呼べる

これで「9B＋自分の資料＋ツール」になり、素の9Bを大きく超える実用性が出る。
llm-homelab のログや設定ドキュメントを投入すれば、"自分の環境に詳しいセキュリティ秘書"になる。

---

## 層6: LoRAファインチューニング(用途特化)

秘書口調・セキュリティ用語での応答スタイルを覚えさせ、狭い領域で格上のように振る舞わせる。

**あなたの強み**: ローカルGPU(3060 Ti)＋RAM 48GB。Colab無料枠がGGUF変換で落ちる問題(Zenn記事参照)を、48GBのRAMで回避しやすい。

手順の骨子(Unsloth使用):
1. **環境**: ローカルで動かすなら Python環境に `unsloth` を導入(GPU学習)。手軽さ優先ならColab(T4)でも可。
2. **ベース選択**: 8GB VRAMでLoRA学習するなら、学習は 4bit ロードの小さめモデル(4B級)が安全。推論用の9Bとは別に、特化用の小さいベースを選ぶのが現実的。
3. **データ整形**: 「指示 → 理想の応答」のペアを用意(秘書の口調例、セキュリティQ&Aなど)。数百〜数千件。
4. **LoRA学習**: 付箋(全体の0.2%程度)だけ学習。数十ステップ〜。Training Lossが下がるのを確認。
5. **GGUF変換 → Ollama取り込み**: 学習したモデルをGGUF化し、Modelfileで `ollama create my-secretary -f Modelfile` して常用モデル化。

**注意**: FTは「スタイル・応対パターン」を変えるのに向く。最新情報や知識の追加は層1(RAG)の担当。両者を組み合わせる(知識=RAG、口調=LoRA)のが定石。

---

## 全体の組み合わせ(完成形)

```
[あなた]
   │
   ▼
AnythingLLM (層1: RAG＋ツール)  ← 自分の資料・Web検索・コード実行を注入
   │
   ▼
Ollama (層4: Flash Attn + KV量子化 + num_ctx最適化で 100% GPU)
   │
   ├─ 層3: qwen3.5:9b (VRAMに収まる最大容量・新世代)
   ├─ 層6: LoRA特化版 my-secretary (口調・セキュリティ特化)
   └─ 層5: (必要なら)MTP/投機的デコードで高速化
```

効果の体感が大きい順は **層1(RAG/ツール) > 層3+4(モデル＋全GPU化) > 層6(特化) > 層5(速度)**。
まず層3・4で"速くて確実に動く土台"を作り、層1で賢さを外付けし、余力で層6・5を足すのが、8GBで到達できる実質的な最大構成。
