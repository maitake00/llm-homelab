# 8GB VRAMで「実質的な最大の賢さ」を出す — 実装記録(最終版)

対象環境: RTX 3060 Ti (VRAM 8GB / 実効約6.5GB) + RAM 48GB + i5 12600K。
当初計画した層(1/3/4/5/6)の実装結果と、計画からの変更点を記録する。

## 実装結果サマリ

| 層 | 計画 | 結果 |
| --- | --- | --- |
| 層1 RAG+ツール | AnythingLLM → RAGFlow | **LlamaIndexで自作**(llamaindex-rag) ✅ |
| 層3 モデル選定 | qwen3.5:9b | qwen3.5:9b + **secretary**(LoRA) ✅ |
| 層4 メモリ最適化 | KV量子化+Flash Attn | **num_ctx=4096 + MAX_LOADED=2** に変更 ✅ |
| 層5 投機的デコード | MTP/llama.cpp | 未着手(22秒/クエリで実用十分のため保留) |
| 層6 LoRA特化 | 秘書スタイル | **Swallow 8B + LoRA → secretary** ✅ |

## 層1: RAG — なぜRAGFlowをやめてLlamaIndex自作にしたか

計画では RAGFlow(高品質RAGエンジン)だったが、以下の問題で移行した。

1. **日本語が中国語トークンに変換される**: RAGFlowのトークナイザーは中国語前提で、「基盤→基盘」「運用→运用」のように壊れる。キーワード検索が劣化し、リランカーへ渡る本文も壊れてスコアが全滅(0.01前後)。日英混在の運用では致命的。
2. **リランカー統合の泥沼**: Ollamaはリランカー非対応。Xinference最新版はtorchcodecバグでrerankロード失敗。
3. **回避不能**: RAGFlowに日本語トークナイズを直す設定は存在しない。

**最終構成(llamaindex-rag)**:
```
文書(日/英) → SentenceSplitter(512/64) → bge-m3埋め込み → Chroma
質問 → ベクトル検索(top_k=40) → bge-reranker-v2-m3(Xinference)で上位5件 → LLM回答
```
- 多言語はbge-m3/bge-rerankerのベクトル系に寄せることで、言語別トークナイザー不要
- リランカーは正常動作(関連チャンク0.325 vs 無関係0.008 と正しく差がつく)
- thinking切替(THINK=1で深掘りモード、文脈も自動8192に拡張)

## 層4: メモリ最適化 — 計画からの変更

- ❌ **KVキャッシュ量子化(q8_0)+Flash Attention** → qwen3.5系で生成が1-2 t/sに崩壊する不具合。無効化(フル精度KVは品質面でも有利)。
- ✅ **num_ctx=4096** → 実測プロンプトは1662トークン程度で8192は過剰。4096でモデルが100% GPUに乗り56 t/s。
- ✅ **OLLAMA_MAX_LOADED_MODELS=2** → RAGの「埋め込み+生成」2モデル問題。1だと毎クエリ6.4GBの再ロードで2分超、2で再ロード消滅。
- ✅ **生成パラメータ**: temperature=0 / presence_penalty=0 / num_predict=800(thinking暴走の安全弁)

## 層6: LoRA — 実施記録

- **データ**: 秘書スタイル86件(自作・合成)。敬語の使い分け、
  ハルシネーション抑制の手本(知らないことは「わからない」)を含む。
- **ベース選定の試行錯誤**: Qwen3-4B → 出力に中国語(简体字)が混入し不採用。
  → **Llama-3.1-Swallow-8B**(日本語特化、Nejumi 10B未満首位)で解決。
- **学習**: Colab T4 / Unsloth / 4bit LoRA(r=16) / 5エポック / 数分で完了。
- **変換**: ColabはRAM 12.7GBで8BのGGUF化が不可 → **アダプタ(154MB)のみDL、手元(RAM 48GB)でマージ+GGUF化**。
  transformers v5系の tokenizer_class="TokenizersBackend" が llama.cpp と非互換
  → "PreTrainedTokenizerFast" に書き換えて解決。
- **成果**: secretary(Q4_K_M 約5GB)。秘書口調・捏造抑制・正しい敬語を確認。
  RAGと組み合わせ(`LLM_MODEL=secretary`)て「知識=RAG、口調=LoRA」の分担が完成。

## 層5: 投機的デコード(未着手・保留)

RAG応答が約22秒と実用域のため保留。着手する場合の選択肢:
1. llama.cpp を直接使い `--model-draft`(小さいドラフトモデル)で投機的デコード
2. MTPヘッド入りGGUFの利用(対応モデルに限る)

## 学び(次のプロジェクトに持ち越すもの)

- ツール選定は「機能の多さ」より「自分の言語・データとの相性」。RAGFlowは高機能だが日本語で詰んだ。
- 8GBでは「100% GPUに乗るか」が全て。モデルサイズ・num_ctx・同時ロード数の3つで調整する。
- ColabとローカルのRAM/GPUを「学習=Colab、変換=手元」と使い分けると、無料枠でも8Bを扱える。
- 検証は自分のベンチ(MODEL_BENCHMARK.md)と実測値で。カタログスペックやLossの絶対値は当てにならない。
