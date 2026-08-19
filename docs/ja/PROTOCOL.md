# Quack Remote Protocol — ワイヤフォーマット リファレンス

[English](../en/PROTOCOL.md) · **日本語**
→ [ドキュメント目次](./README.md)

> DuckDB のソース (`duckdb/duckdb-quack` @ main、`duckdb/duckdb` v1.4.1) から導出し、
> **稼働中の `quack_serve()` サーバに対してバイト単位で検証済み** (DuckDB v1.5.5、quack v1)。
> Quack はベータ版であり、破壊的変更が予期される。`src/protocol/compat.zig` を参照。

## 1. トランスポート (transport)

| プロパティ      | 値                                               |
|---------------|--------------------------------------------------|
| メソッド        | `POST`                                           |
| パス            | `/quack`                                         |
| リクエスト型    | `application/vnd.duckdb`                         |
| レスポンス型    | `application/vnd.duckdb`                         |
| デフォルトポート | `9494`                                           |
| URI スキーム    | `quack:host[:port]` → `http://host:port`          |
| TLS           | サーバ側には無い。リバースプロキシで終端すること      |
| CORS          | サーバは `Access-Control-Allow-Origin: *` を送る    |

`GET /` は人間可読なバナーを返す。`OPTIONS /quack` は CORS プリフライトに対して 204 を返す。
すべてのリクエストは完全な往復 (round trip) である。すなわち、リクエストメッセージが 1 つ入り、
レスポンスメッセージが 1 つ出る。このプロトコルは厳密にクライアント駆動であり、サーバから
プッシュすることは決してない。

## 2. メッセージフレーミング (message framing)

HTTP ボディは **連続する 2 つのトップレベルオブジェクト** が背中合わせに並んだものである:

```
body := <MessageHeader object> <Message body object>
```

いずれも DuckDB の `BinarySerializer` によって
`SerializationCompatibility::FromIndex(7)` (DuckDB 1.4.0 世代のルール。これによって
`serialize_default_values = false` が設定され、圧縮ベクトル (compressed vector) が
有効になる) でエンコードされる。

### オブジェクトのエンコーディング

オブジェクトは、センチネル (sentinel) となるフィールド id で終端されるフラットな
フィールド列である:

```
object := { field_id:u16le  value }*  0xFFFF
```

* `field_id` は `uint16` の **リトルエンディアン** (`field_id_t`)。
* `0xFFFF` (`MESSAGE_TERMINATOR_FIELD_ID`) がオブジェクトを終端する。
* フィールドは id の昇順で書き込まれる。読み手はフィールドが **存在しない** ことを許容しなければならない。
* `WritePropertyWithDefault` で書き込まれたフィールドは、**型のデフォルト値と等しい場合に
  完全に省略される** (`""`、`0`、`false`、`nullptr`)。これはデコーダの同期ずれ (desync) の
  **最も一般的な原因** である。フィールドが存在すると決して仮定してはならない。

## 3. プリミティブのエンコーディング

| 型                        | エンコーディング                                        |
|--------------------------|-------------------------------------------------------|
| `bool`                   | 生の 1 バイト (`0`/`1`) — varint では **ない**            |
| `char`                   | 生の 1 バイト                                          |
| `int8/16/32/64`          | **符号付き** LEB128 (符号拡張。zigzag では *ない*)        |
| `uint8/16/32/64`, `idx_t`| **符号なし** LEB128                                     |
| `float`                  | 生の 4 バイト、IEEE-754 リトルエンディアン                 |
| `double`                 | 生の 8 バイト、IEEE-754 リトルエンディアン                 |
| `hugeint_t` (i128)       | 符号付き LEB128 の `upper:i64`、続いて符号なし LEB128 の `lower:u64` |
| `uhugeint_t` (u128)      | 符号なし LEB128 の `upper`、続いて符号なし LEB128 の `lower` |
| `string`                 | 符号なし LEB128 のバイト長、続いて生の UTF-8 バイト列       |
| blob / `WriteDataPtr`    | 符号なし LEB128 のバイト数、続いて生のバイト列              |
| enum                     | 基底となる整数として (varint)。`serialize_enum_as_string` は強制的に無効化される |
| `optional_idx`           | 符号なし LEB128。`UINT64_MAX` は「未設定」を意味する         |
| list / `vector<T>`       | 符号なし LEB128 の要素数、続いて `count` 個のエンコード済み要素 |
| pointer / `unique_ptr<T>`| 1 バイトの「存在」フラグ。`1` の場合、指し先が後続する        |

手書きのデコーダが躓く非対称性に注意すること。`bool` の **値** は生のバイトだが、
`uint8_t` の **値** は varint である。

## 4. MessageHeader

```
field 1  type              MessageType enum (varint)          [always present]
field 2  connection_id     string   [omitted when empty]
field 3  client_query_id   optional_idx (varint, u64 max = unset)  [always present]
```

## 5. MessageType

| 値     | 名前                  | 方向       |
|-------|----------------------|-----------|
| 0     | `INVALID`            | —         |
| 1     | `CONNECTION_REQUEST` | C → S     |
| 2     | `CONNECTION_RESPONSE`| S → C     |
| 3     | `PREPARE_REQUEST`    | C → S     |
| 4     | `PREPARE_RESPONSE`   | S → C     |
| 7     | `FETCH_REQUEST`      | C → S     |
| 8     | `FETCH_RESPONSE`     | S → C     |
| 9     | `APPEND_REQUEST`     | C → S     |
| 10    | `SUCCESS_RESPONSE`   | S → C     |
| 11    | `DISCONNECT_MESSAGE` | C → S     |
| 100   | `ERROR_RESPONSE`     | S → C     |

5 と 6 は未使用であることに注意 (開発中に削除された)。

## 6. メッセージボディ

以下のすべてのボディフィールドは `WritePropertyWithDefault` を使う → **デフォルト値のときは省略される**。

### `CONNECTION_REQUEST` (1)
```
1 auth_string                 string
2 client_duckdb_version       string
3 client_platform             string
4 min_supported_quack_version idx_t
5 max_supported_quack_version idx_t
```

### `CONNECTION_RESPONSE` (2)
```
1 server_duckdb_version string
2 server_platform       string
3 quack_version         idx_t
```
割り当てられたセッション id は、ボディではなく **ヘッダ** の `connection_id`
(32 文字の大文字 16 進文字列) で届く。

### `PREPARE_REQUEST` (3)
```
1 sql_query string
```
ヘッダの `connection_id` はセッション id を保持していなければならない。

### `PREPARE_RESPONSE` (4)
```
1 result_types     vector<LogicalType>
2 result_names     vector<string>
3 needs_more_fetch bool
4 results          vector<unique_ptr<DataChunkWrapper>>
5 result_uuid      hugeint_t
```

### `FETCH_REQUEST` (7)
```
1 uuid hugeint_t     -- the result_uuid from PREPARE_RESPONSE
```

### `FETCH_RESPONSE` (8)
```
1 results     vector<unique_ptr<DataChunkWrapper>>
2 batch_index optional_idx
```
`FETCH_RESPONSE` は `needs_more_fetch` を **持たない**。ストリーミングは、レスポンスが
チャンク (chunk) を 0 個返した時点で終了する。

### `APPEND_REQUEST` (9)
```
1 schema_name  string
2 table_name   string
3 append_chunk unique_ptr<DataChunkWrapper>
```

### `SUCCESS_RESPONSE` (10) / `DISCONNECT_MESSAGE` (11)
ボディは空 (`0xFFFF` 終端子のみ)。

### `ERROR_RESPONSE` (100)
```
1 message string   -- ErrorData::RawMessage()
```

## 7. DataChunkWrapper

このラッパーはシリアライズのシグネチャに関するバグを回避するためだけに存在する。
1 つのフィールドを保持する 1 つのオブジェクトである:

```
field 300 "chunk" -> DataChunk object
```

### DataChunk
```
field 100 rows     sel_t (uint32 varint)
field 101 types    vector<LogicalType>
field 102 columns  list of objects, one per column, each a Vector
```
`rows` は 0 のときに省略される (デフォルト値のスキップ) ため、空のチャンクも正当である。

### Vector
```
field 90  vector_type        VectorType enum  [absent => FLAT_VECTOR]
field 100 has_validity_mask  bool
field 101 validity           blob, ceil(count/64)*8 bytes, bit=1 means VALID
field 102 data               fixed-width: blob of GetTypeIdSize(type)*count
                             VARCHAR:     list<string> of length count
field 103 children           STRUCT: list of child Vector objects
field 103 array_size         ARRAY: uint64
field 104 child              ARRAY: child Vector object
field 104 list_size          LIST: uint64
field 105 entries            LIST: list of {100:offset u64, 101:length u64}
field 106 child              LIST: child Vector object
```

**有効性マスク (validity mask) のセマンティクス:** マスクは `uint64` ワードのビットセットであり、
LSB が先頭 (LSB-first) である。ビットが立っていればその行は **有効** (非 NULL) である。
`has_validity_mask` が `false` の場合 (またはフィールドが存在しない場合)、すべての行が有効である。

### VectorType (field 90) — 圧縮エンコーディング
```
0 FLAT_VECTOR       (default when field 90 absent)
1 FSST_VECTOR
2 CONSTANT_VECTOR   one value follows, logically repeated for all rows
3 DICTIONARY_VECTOR 91:sel_vector blob (sel_t*count), 92:dict_count, then child vector
4 SEQUENCE_VECTOR   91:seq_start i64, 92:seq_increment i64 — no data follows
```
DuckDB v1.5.5 からキャプチャしたフィクスチャ (fixture) では、field 90 は **一度も**
出力されなかった。すなわち、すべてのベクトルはフラットな形で届いた。しかしエンコーダは
データに基づいてこれらの表現を動的に選択し、`serialization_compatibility` の index 7 は
圧縮ベクトル (compressed vector) を有効にする。したがって field 90 を無視するクライアントは、
たった 1 つのクエリでデコードを誤る状態にある。`Quackling` は FLAT、CONSTANT、DICTIONARY、
SEQUENCE をデコードし、FSST については推測するのではなく
`error.UnsupportedVectorType` を返す。

### LogicalType
```
field 100 id             LogicalTypeId enum (varint)
field 101 type_info      unique_ptr<ExtraTypeInfo>  (present byte, then object)
```

`ExtraTypeInfo` は `100:type` (`ExtraTypeInfoType`) と `101:alias`
(string、デフォルト値のときスキップされる) で始まり、続いて `103:extension_info` (nullable)、
さらにサブタイプ固有のフィールドが続く。**フィールド 200/201 は多重定義 (overload) されている** —
その意味は field 100 の `ExtraTypeInfoType` に依存し、field 100 は常にそれらに先行する:

| `ExtraTypeInfoType` | 値     | field 200            | field 201      |
|---------------------|-------|----------------------|----------------|
| `DECIMAL`           | 2     | `width` (u8)         | `scale` (u8)   |
| `STRING`            | 3     | —                    | —              |
| `LIST`              | 4     | 子の `LogicalType`     | —              |
| `STRUCT`            | 5     | `child_list_t` (`{0:name, 1:LogicalType}` ペアのリスト) | — |
| `ENUM`              | 6     | `values_count` (idx_t) | `values` (文字列のリスト) |
| `ARRAY`             | 9     | 子の `LogicalType`     | `array_size` (u64) |

### 他の型の表現を再利用する型

3 つの論理型 (logical type) は独自のエンコーディングを持たない。これを認識することが
デコーダを小さく保つ鍵である:

* **MAP** (`102`) は `ListTypeInfo` を使い、`STRUCT(key, value)` をラップする。
  レイアウトは `LIST` と完全に同一である。
* **UNION** (`107`) は `StructTypeInfo` を使う。その **最初の子は隠された
  `UTINYINT` のタグ** であり、その後にメンバーが続く。レイアウトは `STRUCT` と完全に同一で、
  タグが与えられた行においてどのメンバーが有効かを選択する。
* **VARIANT** (`109`) もまた `STRUCT` であり、`keys` / `children` / `values` からなる。

### ENUM の物理的な格納形式

ENUM のセルは辞書 (dictionary) へのインデックスを格納する。そのインデックスを表現できる
最も狭い符号なし整数が使われる (`EnumTypeInfo::DictType`):

| 辞書のサイズ      | 格納形式  |
|-----------------|----------|
| ≤ 255           | `uint8`  |
| ≤ 65 535        | `uint16` |
| ≤ 4 294 967 295 | `uint32` |

### BIGNUM

`BIGNUM` (`39`) は追加の型情報を持たず、文字列と同様に格納される。field
102 は長さ前置のバイト列 (byte run) のリストである。

## 8. 接続のライフサイクル

```
CONNECTION_REQUEST  ──▶  CONNECTION_RESPONSE   (header carries connection_id)
PREPARE_REQUEST     ──▶  PREPARE_RESPONSE      (types + names + first chunks + uuid)
FETCH_REQUEST(uuid) ──▶  FETCH_RESPONSE        (more chunks; repeat while non-empty)
DISCONNECT_MESSAGE  ──▶  SUCCESS_RESPONSE
```

いずれのリクエストも、代わりに `ERROR_RESPONSE` を返す可能性がある。サーバはレスポンスあたり
最大 `quack_fetch_batch_chunks` 個のチャンクをまとめる (デフォルトは **12**) ため、大きな結果は
FETCH の往復を繰り返して届く。`PREPARE_RESPONSE.needs_more_fetch` が、フェッチを開始すべきか
どうかを伝える。それ以降は、空の `results` リストが終端を知らせる。

## 9. 認証 (authentication)

トークンベースである。クライアントはトークンを `CONNECTION_REQUEST.auth_string` に入れ、
サーバはそれを `quack_serve(token := ...)` (または生成されたランダムな 128 ビットの 16 進トークン)
と、差し替え可能な (pluggable) `quack_authentication_function` を介して比較する。HTTP の認証ヘッダは
**存在しない** — トークンはプロトコルメッセージのボディ内部を通って移動する。だからこそ
トランスポート層の TLS が重要になる。(プロキシ向けの) 追加の HTTP ヘッダは、`quack` シークレットの
`EXTRA_HTTP_HEADERS` を介して帯域外 (out-of-band) でサポートされる。

トークンは 4 文字以上でなければならない。ハンドシェイクが失敗すると `ERROR_RESPONSE` が返る。

## 10. パラメータ

プロトコルバージョン 1 には、**クエリパラメータのワイヤ表現が存在しない**。
`PrepareRequestMessage` はフィールドをちょうど 1 つ (SQL 文字列) だけ持ち、サーバはそれを
そのまま `SendQuery` に渡す。稼働中のサーバに対して検証済み:

* `SELECT ?` → `ERROR_RESPONSE`: *"Expected 1 parameters, but none were supplied"*。
* `PREPARE_REQUEST` に未知のフィールドを追加する → **HTTP 500**。サーバは予期しない
  フィールドを拒否するため、クライアントが独自に導入することはできない。

したがってクライアントは、パラメータを SQL テキストに展開する (`src/params.zig` が
厳格なエスケープ処理とともに行っていること) か、あるいは SQL レベルの
`PREPARE` / `EXECUTE` を使う必要がある。後者はプロトコル上で通常どおり機能する。

## 11. 結果カーソル (result cursor) の寿命

各接続は結果カーソルを **1 つ** だけ保持する。`PREPARE_REQUEST` の処理は、SQL を実行する
*前に* `connection.duckdb_query_result.reset()` を呼ぶ
(`quack_server.cpp`)。したがって:

* 新しい PREPARE は常に直前の結果を破棄し、
* 新しいクエリがその後に失敗した場合でもそれは行われる — reset が先に起きるためである。

そのため、ある結果をストリーミングしながら同じ接続で別のクエリを発行するクライアントは、
破棄されたカーソルに対して FETCH することになる。クエリを並行に実行するには、
別々の接続が必要である。

## 12. 検証済みの観察結果

稼働中のサーバ (`quack_serve('quack:localhost:9494', token=>'super_secret')`) からキャプチャ:

* `SELECT 42 AS answer` → 94 バイトの `PREPARE_RESPONSE`。完全に消費され、INTEGER(13)、
  チャンク 1 つ、CONSTANT ベクトル 1 つ、ペイロードは `2a 00 00 00`。
* `connection_id` は 32 文字の大文字 16 進文字列である。
* `client_query_id` は、アクティブなトランザクションが無いとき「存在するが `UINT64_MAX`」となる。
* `SELECT i FROM range(100000)` → `PREPARE_RESPONSE` に 12 チャンク、
  `needs_more_fetch = 1`、加えて `result_uuid`、その後 FETCH の往復。
* 空の結果 (`WHERE false`) でも型と名前は返され、`rows`
  フィールドは省略される。
* ネストした型はロスレスに往復する: `STRUCT`、`LIST`、`ARRAY`、`MAP`、
  `UNION`、`ENUM`、`VARIANT`、`BIGNUM` はそれぞれキャプチャされ、すべてのバイトが
  説明された状態でデコードされた (`tests/fixtures/` を参照)。
* **FSST ベクトルはワイヤ上に決して現れない。** `Vector::Serialize` に FSST の
  分岐は存在せず、そのようなベクトルは `ToUnifiedFormat` へ落ちて、送信前に
  フラット化される (`duckdb/src/common/types/vector.cpp` の
  `// TODO: other compressed vector types (FSST)` によるフォールスルー)。
