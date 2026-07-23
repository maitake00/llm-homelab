# 層1(仕上げ): Xinference で リランカー(bge-reranker-v2-m3)を配信

Ollamaはリランカー非対応なので、専用サーバ **Xinference** で `bge-reranker-v2-m3` を動かし、
自作RAG(LlamaIndex, `llamaindex-rag/`)から呼び出して2段階検索(候補を精密に並べ替え)を実現する。品質の最大レバー。

構成:RAG → bge-m3で候補40件(Ollama) → bge-reranker-v2-m3で精密リランク(Xinference) → 上位5件 → qwen3.5:9bが回答

---

## 1. 起動(自動)

`xinference` サービスはカスタムイメージ(`./xinference/Dockerfile`)でビルドされる。
起動するだけで、リランカーが**自動でlaunchされる**(手作業ゼロ)。

```bash
docker compose up -d xinference
```

- 初回はベースイメージのpull + ビルドで時間がかかる。
- リランカーは小さい(約568M)ので **CPUで動く**(GPUはOllama専用のまま)。
- `torchao ... Failed to load` の警告はGPU用ライブラリのもので、CPU運用では無害。

起動確認(数分後、リランカーのロード完了を待つ):
```bash
docker compose logs xinference | tail -20
# "準備完了。サーバを維持します。" が出ていればOK
```

---

## 2. なぜカスタムイメージなのか(背景)

公式 `xprobe/xinference:v2.8.0-cpu` には2つの落とし穴がある:

1. `sentence-transformers` が未同梱 → リランカーのロードに必要。
2. `peft` が新しい `transformers` と衝突(`cannot import name 'HybridCache'`)し、
   **リランカーがロード時にクラッシュ**する(launch直後にUIDが消え、`Available model uids: []` になる)。

以前はコンテナ内で毎回 `pip install sentence-transformers` + `pip uninstall -y peft` を手動実行していたが、
`docker compose down` やイメージ変更でコンテナを作り直すと消え、**再起動のたびに障害が再発**していた。

そこで `./xinference/Dockerfile` で以下を**イメージに焼き込み**、恒久化した:

```dockerfile
FROM xprobe/xinference:v2.8.0-cpu
RUN pip install --no-cache-dir sentence-transformers && pip uninstall -y peft
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`entrypoint.sh` がサーバ起動 → 準備完了を待機 → `xinference launch` を自動実行する。
これにより、起動チェックリストから「pip修正」「rerank再launch」の手作業が不要になった。

> v2.9.0 は torchcodec バグで rerank が壊れるため、動作する **v2.8.0-cpu に固定**している。

---

## 3. 動作確認

リランカーが応答するか直接テスト(`relevance_score` 付きの結果が返れば成功):
```bash
curl -s -X POST http://localhost:9997/v1/rerank -H "Content-Type: application/json" \
  -d '{"model":"bge-reranker-v2-m3","query":"監視","documents":["Prometheusで監視する","猫の写真"]}'
```

起動済みモデルの一覧:
```bash
docker exec xinference xinference list
# bge-reranker-v2-m3  rerank ... が出ればOK
```

---

## 4. 自作RAG(server.py)からの利用

自作RAGは `llamaindex-rag/xinference_rerank.py` の `XinferenceRerank` で、
Xinference の `/v1/rerank` を叩いてノードを並べ替える。接続先は `config.py` の
`XINFERENCE_BASE_URL`(既定 `http://localhost:9997`)。

> 重要: `XinferenceRerank` はRAGサーバ起動時に接続を張る。**Xinferenceを先に起動**してから
> RAGサーバ(`uvicorn server:app`)を起動すること。順番を逆にすると、リランカーに繋がらず
> `[XinferenceRerank] rerank失敗のため素の順序を使用` にフォールバックし、検索品質が落ちる。

起動順(鉄則):
docker compose up -d # Xinference がリランカーを自動launch
↓ ログで "準備完了" を確認
cd llamaindex-rag && uvicorn server:app --host 0.0.0.0 --port 8000

---

## メモ
- Xinferenceは使わないときは `docker stop xinference` で止めてRAMを空けてよい(RAGを使うときだけ起動)。
- リランカーはRAGの精度に効くが、1クエリごとにリランク処理が入るぶんレスポンスは少し遅くなる(品質優先の割り切り)。
- リランク有無で精度がどう変わるかは、実際に比較して確認するとよい。
