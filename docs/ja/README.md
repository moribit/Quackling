# Quackling ドキュメント

[English](../en/README.md) · **日本語**

← [プロジェクト README に戻る](../../README.ja.md)

Quackling は Zig のみで書かれた、独立した DuckDB Quack プロトコルクライアントです。
このドキュメント群では、サーバの起動方法、ライブラリの使い方、そして実装がどのように
構成され検証されているかを説明します。

## はじめに

| ドキュメント | 内容 |
|--------------|------|
| [サーバ構築 (Server setup)](SERVER_SETUP.md) | `quack` 拡張のインストール、`quack_serve()` の起動、URI 形式、サーバの常駐化、リバースプロキシによる TLS、トラブルシューティング表 |
| [CLI](CLI.md) | `quackling` の全フラグ、5種類の出力フォーマット、`QUACK_TOKEN`、標準入力からの SQL 読み込み、`--stats` の読み方 |

## ライブラリを使う

| ドキュメント | 内容 |
|--------------|------|
| [API リファレンス](API.md) | `Client`、`Result`、`RowStream`、`typed.iterator`、`Param` union、`Pool`、`Transport`、エラー分類の全体 |
| [型サポート (Type support)](TYPES.md) | DuckDB の全型とその読み出し方、NULL と有効性マスク (validity mask) のセマンティクス、入れ子型へのアクセス、ベクトルエンコーディング、ゼロコピー (zero-copy) の生存期間規則 |
| [WASM](WASM.md) | `wasm32-freestanding` 向けビルド、FFI エクスポート面の全体、JS からの呼び出し手順、線形メモリ (linear memory) 上の TypedArray ビュー |
| [性能 (Performance)](PERFORMANCE.md) | 測定方法と再現コマンド付きのコーデックベンチマーク、アロケーションが行数に比例しない理由、エンドツーエンドのストリーミング、メモリ有界性、性能上の落とし穴 |
| [Akamata 統合](AKAMATA.md) | Web フレームワーク自身の HTTP client への検証済み transport アダプタ、チャンク指向と行指向の不一致、行シムより独自 `State.db` が優れる理由 |

## 実装を理解する

| ドキュメント | 内容 |
|--------------|------|
| [アーキテクチャ (Architecture)](ARCHITECTURE.md) | 階層化の規則、トランスポートの注入、セッション状態機械、単一カーソル制約、メモリ所有権 (ownership)、ストリーミングモデル |
| [ワイヤプロトコル (Wire protocol)](PROTOCOL.md) | Quack ワイヤフォーマットのバイト単位リファレンス: フレーミング、プリミティブのエンコーディング、全メッセージ本体、`DataChunkWrapper` |

## 検証

| ドキュメント | 内容 |
|--------------|------|
| [テスト (Testing)](TESTING.md) | 6層のテスト戦略、各層が証明できること・できないこと、メタ層としてのミューテーションテスト (mutation testing)、実行が遅い理由 |
| [セキュリティ (Security)](SECURITY.md) | 脅威モデル、トークンの取り扱い、メモリ安全性、リソース制限、SQL インジェクション境界、対象外事項の明示 |

## クイックリファレンス

| 項目 | 値 |
|------|-----|
| Zig バージョン | 0.16.0 |
| 検証済みバージョン | DuckDB v1.5.5、`quack` 拡張、Quack プロトコルバージョン 1 |
| デフォルトポート | 9494 |
| HTTP パス | `/quack` |
| Content type | `application/vnd.duckdb` |
| URI スキーム | `quack:host[:port]` |

Quack はプレリリース (pre-release) 段階の拡張であり、上流は破壊的変更を想定しています。
DuckDB v1.5.5 では現時点で動作します。安定版となるのは DuckDB 2.0 (「Cyanoptera」) で、
2026年秋に予定されており、まだリリースされていません。
