#!/bin/bash
# ChromaDB(llamaindex-rag側のベクトルDB)を定期バックアップするスクリプト。
#
# 背景: RAG APIはホスト上のuvicornで単独稼働し、ChromaDBもホスト上の
#       ローカルディレクトリのみに存在する(単一障害点)。
#       誤削除・破損時に復旧できるよう、世代管理付きでtar.gzバックアップを取る。
#
# 使い方:
#   ./scripts/backup-chroma.sh
#   crontab に登録する例(毎日3時に実行):
#     0 3 * * * /path/to/new-project/scripts/backup-chroma.sh >> ~/backup-chroma.log 2>&1
#
# 環境変数で上書き可能:
#   CHROMA_DIR  バックアップ対象のChromaDB永続化ディレクトリ
#   BACKUP_DIR  バックアップ保存先ディレクトリ
#   KEEP_COUNT  保持する世代数(これを超えた古いものから削除)
set -euo pipefail

CHROMA_DIR="${CHROMA_DIR:-$HOME/home/llm-platform/llamaindex-rag/chroma_db}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/home/llm-platform/backups/chroma}"
KEEP_COUNT="${KEEP_COUNT:-14}"

if [ ! -d "$CHROMA_DIR" ]; then
  echo "✗ ChromaDBディレクトリが見つかりません: $CHROMA_DIR" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

timestamp="$(date +%Y%m%d_%H%M%S)"
archive="$BACKUP_DIR/chroma_${timestamp}.tar.gz"

echo "=== ChromaDBバックアップ開始: $CHROMA_DIR -> $archive ==="
tar -czf "$archive" -C "$(dirname "$CHROMA_DIR")" "$(basename "$CHROMA_DIR")"
echo "✓ バックアップ完了 ($(du -h "$archive" | cut -f1))"

echo "=== 古い世代の整理(直近 ${KEEP_COUNT} 世代を保持) ==="
mapfile -t old_backups < <(ls -1t "$BACKUP_DIR"/chroma_*.tar.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)))
if [ "${#old_backups[@]}" -gt 0 ]; then
  rm -f -- "${old_backups[@]}"
  echo "✓ ${#old_backups[@]}件の古いバックアップを削除しました"
else
  echo "  削除対象なし"
fi
