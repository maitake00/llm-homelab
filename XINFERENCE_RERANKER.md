# 層1(仕上げ): Xinference で リランカー(bge-reranker-v2-m3)を配信

Ollamaはリランカー非対応なので、専用サーバ **Xinference** で `bge-reranker-v2-m3` を動かし、RAGFlowに登録して2段階検索(候補を精密に並べ替え)を実現する。品質の最大レバー。

構成:
```
RAGFlow → bge-m3で候補50件(Ollama) → bge-reranker-v2-m3で精密リランク(Xinference) → 上位5件 → qwen3.5:9bが回答
```

---

## 1. Xinference を起動

`docker-compose.yml`に `xinference` サービスを追加済み。llm-homelabフォルダ(new-project)で反映:

```bash
docker compose up -d
```

- Xinferenceのイメージは大きい(数GB)ので初回pullに時間がかかる。
- 起動確認: ブラウザで **http://localhost:9997** を開くと Xinference のUIが出る。
- リランカーは小さい(約568M)ので **CPUで動く**(GPUはOllama専用のまま)。

---

## 2. 依存を整える(v2.8.0-cpu で必須)

CPU軽量版イメージは `sentence-transformers` を同梱しておらず、また入れると新しい `peft` が
古い `transformers` と衝突する(`cannot import name 'HybridCache'`)。次の2手で解消:

```bash
# rerankバックエンドに必要
docker exec xinference pip install sentence-transformers
# 衝突する peft を除去(rerankには不要)
docker exec xinference pip uninstall -y peft
```

確認:
```bash
docker exec xinference python -c "import sentence_transformers; print('OK', sentence_transformers.__version__)"
```
`OK ...` が出ればimport成功。

> 注意: この pip 変更はコンテナの書き込み層に入る。`docker restart`/再起動では残るが、
> `docker compose down` やイメージ変更で**コンテナを作り直すと消える**。その場合は上の2手を再実行。
> 恒久化するなら、フル版イメージ `xprobe/xinference:v2.8.0`(全依存同梱)を使うか、
> 上記を焼き込んだカスタムDockerfileにする。

## 3. リランカーモデルを起動(launch)

```bash
docker exec xinference xinference launch --model-name bge-reranker-v2-m3 --model-type rerank
docker exec xinference xinference list
```
`bge-reranker-v2-m3  rerank  bge-reranker-v2-m3` が出ればOK。

動作確認:
```bash
curl -s -X POST http://localhost:9997/v1/rerank -H "Content-Type: application/json" \
  -d "{\"model\":\"bge-reranker-v2-m3\",\"query\":\"hello\",\"documents\":[\"hi there\",\"goodbye\"]}"
```
`relevance_score` 付きの結果が返れば成功。

> 重要: `xinference launch` は実行時の状態。コンテナ再起動/PC再起動のたびに**再launchが必要**。
> PC再起動後の起動チェックリストに「Xinferenceでrerankを再launch」を必ず入れる。

---

## 3. RAGFlow にリランカーを登録

RAGFlow → **Model providers** → **Xinference** を追加(Ollamaと同じ要領):

- **Model type**: **rerank**
- **Model name (UID)**: `bge-reranker-v2-m3`(手順2で出たUID)
- **Base URL**: `http://host.docker.internal:9997/v1`
- 保存 → Verify

登録できたら、**System Model Settings** の **Rerank** 欄で `bge-reranker-v2-m3` を選んで保存。

> つながらない場合: RAGFlowコンテナから届くか確認
> `docker exec docker-ragflow-cpu-1 curl -s http://host.docker.internal:9997/v1/models`

---

## 4. 2段階検索を有効化

### 検索テスト画面で確認
データセット「test」→ 検索テスト → **リランキングモデル** の欄で `bge-reranker-v2-m3` を選択 → テスト実行。
リランク有り/無しで、上位に来るチャンクの精度が変わるのが分かる。

### チャットアシスタントに反映
Chat → アシスタント作成/設定 → 取得(Retrieval)設定で:
- **Rerank model**: `bge-reranker-v2-m3`
- **Top N**(1次候補): 大きめ(小さいKBなら10、増えたら50)
- **Similarity threshold**: 低め(0.1〜0.2)から
- **Keyword similarity weight**: ハイブリッド有効

これで「bge-m3で広く拾う → リランカーで精密に絞る」の2段階が完成し、RAGの品質が最大化される。

---

## メモ
- Xinferenceは重いので、使わないときは `docker stop xinference` で止めてRAMを空けてよい(RAGを使うときだけ起動)。
- リランカーはRAGの精度に効くが、1クエリごとにリランク処理が入るぶん、レスポンスは少し遅くなる(品質優先の割り切り)。
- リランク有無で精度がどう変わるかは、検索テストで実際に比較して確認するとよい。
