# API リファレンス

[English](../en/API.md) · **日本語**

→ [ドキュメント目次](./README.md)

[`../../src/root.zig`](../../src/root.zig) が再公開する Quackling の公開 API です。
型のデコードは [TYPES.md](./TYPES.md)、ワイヤ形式 (wire format) は
[PROTOCOL.md](./PROTOCOL.md) で個別に扱います。

**目次:** [公開シンボル](#1-root-が公開するもの) · [Client](#2-client) ·
[Result](#3-result-と-rowstream) · [typed](#4-typed-struct-マッピング) ·
[params](#5-params-クエリパラメータ) · [Pool](#6-pool) ·
[Transport](#7-transport) · [エラー](#8-エラー処理) ·
[Stats](#9-stats-と-observer) · [エンドポイント](#10-エンドポイントの形式)

---

## 1. `root` が公開するもの

```zig
const quackling = @import("quackling");
```

| 公開シンボル | 実体 |
|--------|-----------|
| `Client`, `ClientOptions` | [`../../src/client.zig`](../../src/client.zig) |
| `Result`, `RowStream` | [`../../src/result.zig`](../../src/result.zig) |
| `DataChunk`, `Row`, `Vector`, `VectorType`, `Value`, `LogicalType`, `LogicalTypeId`, `ValidityMask` | `../../src/types/` |
| `Transport`, `MockTransport`, `CancelToken`, `Header`, `transport_mod` | [`../../src/transport/transport.zig`](../../src/transport/transport.zig) |
| `NativeTransport` | [`../../src/transport/native.zig`](../../src/transport/native.zig) — wasm では `@compileError` |
| `Stats`, `Observer` | [`../../src/stats.zig`](../../src/stats.zig) |
| `ErrorInfo`, `errors` | [`../../src/error.zig`](../../src/error.zig) |
| `typed` | [`../../src/typed.zig`](../../src/typed.zig) |
| `params`, `Param` | [`../../src/params.zig`](../../src/params.zig) |
| `Pool`, `PoolOptions`, `Lease` | [`../../src/pool.zig`](../../src/pool.zig) |
| `uri` | [`../../src/uri.zig`](../../src/uri.zig) |
| `serialization`, `protocol` | 階層化されたモジュール。高度な用途とテスト向け |

---

## 2. `Client`

1 つの `Client` は 1 つの論理的な Quack 接続、すなわち 1 つのサーバ側セッションと 1 つの結果
カーソルです。グローバル状態を持たないため、1 プロセス内に多数共存できます。

### `Client.Options`

| フィールド | 型 | 既定値 | 意味 |
|-------|------|---------|---------|
| `allocator` | `std.mem.Allocator` | *必須* | URL、セッション id、送信バッファ、デコード済み構造の確保に使う |
| `endpoint` | `[]const u8` | *必須* | `quack:host[:port]`、または素の `http://host:port` / `https://host:port` URL。[§10](#10-エンドポイントの形式) 参照 |
| `token` | `[]const u8` | `""` | 認証トークン。プロトコルメッセージの**内部**で送られ、ログには決して出ない |
| `transport` | `Transport` | *必須* | コアライブラリは自動選択しない。それが wasm から使える理由 |
| `headers` | `[]const Header` | `&.{}` | 追加の HTTP ヘッダ。認証プロキシ用など |
| `timeout_ms` | `?u32` | `null` | トランスポートに渡すリクエストごとの期限 |
| `max_response_bytes` | `usize` | `256 * 1024 * 1024` | これより大きいレスポンスはデコードを拒否。`Reader` のバイト長上限にもなる |
| `observer` | `?Observer` | `null` | リクエストごとのフック。[§9](#9-stats-と-observer) 参照 |

`endpoint` と `token` は**借用 (borrow)** です。`Options` は `Client.options` に値として
保持されるため、クライアントより長生きしなければなりません。

### メソッド

```zig
pub fn init(options: Options) Error!Client
```
`endpoint` を解析してリクエスト URL (例: `http://localhost:9494/quack`) を構築します。
**I/O は一切行いません** — ハンドシェイクもソケットもありません。したがってクライアントの構築は
軽量でブロックしえず、これが `Pool` が自身のロック下でクライアントを作る理由です。
エラー: `error.InvalidUrl`、`error.EmptyHost`、`error.InvalidPort`、`error.OutOfMemory`。

```zig
pub fn deinit(self: *Client) void
```
接続済みならベストエフォートで `DISCONNECT` を送り (失敗は無視)、URL、セッション id、
サーバ識別文字列、送信バッファ、直近のエラーメッセージを解放します。`Result` は借用元の
クライアントより**先に** `deinit` しなければなりません。

```zig
pub fn connect(self: *Client, cancel: ?*CancelToken) Error!void
```
ハンドシェイクを実行します。トークンを載せた `CONNECTION_REQUEST` を送り、サーバの
`quack_version` が `[min_supported_version, max_supported_version]` (どちらも `1`) の範囲内で
あることを検証し、レスポンス**ヘッダ**からセッション id を、本体からサーバの DuckDB バージョンと
プラットフォームを保存します。冪等で、すでに接続済みなら即座に戻ります。

エラー: サーバのエラーテキストが `"authenticat"` / `"invalid token"` / `"unauthorized"` に
一致した場合は `error.AuthenticationFailed` (照合は意図的に狭く、取りこぼしても
`ServerError` と報告され、それも正確です)。その他のエラーレスポンスは `error.ServerError`、
`error.UnsupportedProtocolVersion`、`error.UnexpectedMessageType` (セッション id を含まない
レスポンスも含む)、およびトランスポートのエラー。

`query` が遅延接続するため、通常これを呼ぶ必要はありません。

```zig
pub fn isConnected(self: *const Client) bool
pub fn lastError(self: *const Client) []const u8
```
`isConnected` は `connection_id.len > 0` です。`lastError` はサーバが返したテキストをそのまま
返します。SQL が誤っているときにユーザが得られる最も有用な情報が DuckDB のメッセージだから
です。なければ `""` を返します。文字列はクライアントが所有し、次のサーバエラーで置き換えられます。

```zig
pub fn disconnect(self: *Client) Error!void
```
`DISCONNECT` を送りセッションを破棄します。未接続なら何もしません。後片付けはベストエフォート
で、ラウンドトリップが失敗してもセッション id はクリアされ、トランスポートのエラーはそのまま
返されます。

```zig
pub fn query(self: *Client, sql: []const u8) Error!Result
pub fn queryWithCancel(self: *Client, sql: []const u8, cancel: ?*CancelToken) Error!Result
```
必要なら接続し、`PREPARE_REQUEST` を送り、最初のチャンクバッチを保持したストリーミング
`Result` を返します。

結果は**クライアントを借用**します。クライアントより先に `deinit` しなければならず、同時に
開けるのは 1 つだけです。`query_generation` は PREPARE ごとに、しかも SQL 実行の*前に*
インクリメントされます。サーバは PREPARE を受理した時点で `duckdb_query_result.reset()` を
呼ぶため、新しいクエリがその後失敗しても以前のカーソルは消えているからです。その後に FETCH を
試みる古い結果には、次のクエリの行ではなく `error.ResultSuperseded` が返ります。

```zig
var a = try client.query("SELECT * FROM big");
var b = try client.query("SELECT 1");   // サーバ側で a のカーソルが破棄される
_ = try a.nextChunk();                  // error.ResultSuperseded
```

エラー: `error.ServerError` (SQL 不正 — テキストは `lastError()`)、
`error.UnexpectedMessageType`、およびトランスポート／シリアライズのエラー。

```zig
pub fn queryParams(self: *Client, sql: []const u8, args: []const Param) Error!Result
pub fn queryParamsWithCancel(self: *Client, sql: []const u8, args: []const Param, cancel: ?*CancelToken) Error!Result
```
`args` から `?` プレースホルダを置換し ([§5](#5-params-クエリパラメータ) 参照)、あとは `query`
と同じ挙動です。`args.len == 0` のときは SQL を**そのまま**送ります — 書き換えパスは一切
走りません。バインド後の SQL は戻る前に解放されます。

```zig
var result = try client.queryParams(
    "SELECT * FROM users WHERE id = ? AND name = ?",
    &.{ .{ .integer = 42 }, .{ .text = "o'brien" } },
);
defer result.deinit();
```

追加のエラー: `error.ParameterCountMismatch`、`error.UnsupportedParameter`、
`error.InvalidUtf8`。

```zig
pub fn exec(self: *Client, sql: []const u8) Error!void
pub fn execParams(self: *Client, sql: []const u8, args: []const Param) Error!void
```
文を実行して行を捨てます — `query` + ドレイン + `deinit` です。DDL と DML に使ってください。
(行数が必要なら `query` と `Result.drain()` を使います。)

```zig
try client.exec("CREATE TABLE t (id INTEGER, name VARCHAR)");
try client.execParams("INSERT INTO t VALUES (?, ?)", &.{ Param.int(1), Param.str("a") });
```

```zig
pub fn fetch(self: *Client, uuid: i128, cancel: ?*CancelToken)
    Error!struct { response: Response, body: msg.FetchResponse }
```
公開されていますが、次のバッチを引くために `Result` が呼ぶことを意図しています。返り値は
どちらも呼び出し側が所有します。独自の結果ドライバを実装する場合にのみ使ってください。

```zig
pub fn append(self: *Client, table: []const u8, columns: []const encoder.Column) Error!void
pub fn appendToSchema(
    self: *Client,
    schema: []const u8,
    table: []const u8,
    columns: []const encoder.Column,
    cancel: ?*CancelToken,
) Error!void
```
バルク挿入 (bulk insert)。INSERT 文の代わりに `DataChunk` 全体を `APPEND_REQUEST`
として送信します。`append` はスキーマ `"main"` を対象とし、`appendToSchema` は
スキーマとキャンセルトークンを受け取ります。`query` と同様、接続は遅延して行われます。

`encoder.Column` は型とその値の組です。

```zig
pub const Column = struct {
    type: LogicalType,
    values: []const Value,
};
```

```zig
const ids = [_]quackling.Value{ .{ .integer = 1 }, .{ .integer = 2 } };
const names = [_]quackling.Value{ .{ .varchar = "a" }, .null };
try client.append("events", &.{
    .{ .type = .{ .id = .integer }, .values = &ids },
    .{ .type = .{ .id = .varchar }, .values = &names },
});
```

以下の制約はすべて実際に強制されます。

| 規則 | 違反した場合 |
|------|-------------|
| テーブルが既に存在しなければならない | サーバが存在しないテーブルを拒否し、`error.ServerError` として表面化する |
| `columns` はテーブルのスキーマと順序・型の両方で一致しなければならない | サーバ側で拒否される |
| 1 回の呼び出しで最大 `serialization.encoder.max_rows` (**2048**) 行 | `error.TooManyRows`。送信前にクライアント側で発生する |

使う価値がある理由は次のとおりです。値は既に型付けされているため SQL の解析が不要で、
1 リクエストがチャンク全体を運びます。同一サーバに対して 1 行ごとのパラメータ付き INSERT と
比較した実測値は、**20,480 行が 10 ms (1.97M rows/s、10 リクエスト) 対 3,821 ms
(5.4k rows/s、20,480 リクエスト) で約 370 倍**である。値はバイナリで送られるため
この経路では SQL エスケープが一切発生せず、[§5](#5-params-クエリパラメータ) で述べる
インジェクション面も消えます。

エンコーダ ([`../../src/serialization/encoder.zig`](../../src/serialization/encoder.zig))
はデコーダの鏡像であり、そのテストは出力したものが同一にデコードし直せることを検証します。

### 読み取り可能な状態

`Client` は次のフィールドを直接公開します (慣習として読み取り専用):
`server_version`、`server_platform`、`quack_version`、`connection_id`、`url`、
`stats`、`options`、`query_generation`、`last_error`。

### 完全な例

```zig
var http = try quackling.NativeTransport.init(allocator, .{});
defer http.deinit();

var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .token = "super_secret",
    .transport = http.transport(),
});
defer client.deinit();

var result = client.query("SELECT 42 AS answer") catch |err| switch (err) {
    error.ServerError => {
        std.debug.print("server said: {s}\n", .{client.lastError()});
        return err;
    },
    else => return err,
};
defer result.deinit();

if (try result.scalar()) |v| std.debug.print("{f}\n", .{v});
```

---

## 3. `Result` と `RowStream`

チャンクは到着したそばから提供され、消費側が次へ進んだ時点で解放されます。したがってピーク
メモリは結果全体のサイズではなくバッチサイズに追随します。

### メタデータ

| メソッド | シグネチャ | 備考 |
|--------|-----------|-------|
| `columnCount` | `fn (*const Result) usize` | |
| `columnName` | `fn (*const Result, usize) ?[]const u8` | 範囲外は `null`。PREPARE レスポンスバッファを借用 |
| `columnType` | `fn (*const Result, usize) ?LogicalType` | 範囲外は `null` |
| `columnIndex` | `fn (*const Result, []const u8) ?usize` | `mem.eql` による線形走査。該当列がなければ `null` |

列メタデータは PREPARE レスポンスを借用し、`Result` はそれを生存期間中ずっと保持します。
したがってチャンクのペイロードとは違い、名前と型は `nextChunk` をまたいでも有効です。

### 消費

```zig
pub fn nextChunk(self: *Result) Error!?*const DataChunk
```
次のチャンク、尽きたら `null` を返します。**返されたポインタは次の `nextChunk` 呼び出しで
無効化されます。** これがデコードをゼロコピー (zero-copy) に保っている仕組みで、チャンクの
ペイロードは `Result` が保持するレスポンスバッファを指しています。

呼び出しごとに: キャンセルトークンを確認し (セットされていれば `error.Cancelled`)、保留中の
チャンクがあれば渡し、なければ別のバッチを FETCH し (先に直前のバッチを解放するので常駐は
ちょうど 1 バッチ)、`client.stats.chunks_received` / `rows_received` と observer の `onChunk`
を更新します。

```zig
pub fn rows(self: *Result) RowStream
pub fn drain(self: *Result) Error!u64
pub fn scalar(self: *Result) Error!?Value
pub fn deinit(self: *Result) void
```

`drain` は結果全体を走査して `rows_seen` を返します。DDL/DML に便利です。
`scalar` はチャンクを 1 つ引いて行 0・列 0 を返し、結果が空か列がなければ `null` を返します。
行が 1 行だけであることは検証しません。
`deinit` は現在の FETCH バッチ、デコード済み PREPARE 本体、PREPARE レスポンスバッファを
解放します。

`RowStream` はチャンク境界を透過的にまたぎます:

```zig
pub fn next(self: *RowStream) Error!?Row
```

`Row` ([`../../src/types/data_chunk.zig`](../../src/types/data_chunk.zig)) は何もコピーしない
ビューです: `get(col) !Value`、`isNull(col) bool`、`columnCount() usize`。

### 観測可能なカウンタ

`rows_seen`、`chunks_seen`、`fetches` は読み取ってよい素のフィールドです。`result_uuid` と
`generation` はプロトコル上の管理用です。

### `max_fetches`

```zig
max_fetches: u64 = 5_000_000,
```

ストリーム終端は*サーバ*が空バッチを送ることで通知されるため、それを送らないサーバがあれば
無限ループになりえます。文書化されたバッチサイズ (12 チャンク × 2048 行) では、この上限でも
10¹¹ 行をはるかに超えて許容するので、正当な利用で到達することはありません。これはひとえに、
壊れた／敵対的なピアが呼び出し側をハングさせないためのもので、`error.FetchLimitExceeded` が
そのために用意されたエラーです。

### 3 つの消費スタイル

**1. チャンク指向 (最速)。** DuckDB はベクタ化されているので、第一級の API もそうです。
アクセサの規則は [TYPES.md §9](./TYPES.md#9-ゼロコピーアクセスの規則) を参照してください。

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;
    if (col.asSlice(i64)) |slice| {
        for (slice) |v| consume(v);            // 真にゼロコピー
    } else if (col.isFlat(i64)) {
        for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
    } else {
        for (0..chunk.row_count) |i| consume((try col.getValue(i)).asI64().?);
    }
}
```

**2. 行指向。**

```zig
var rows = result.rows();
while (try rows.next()) |row| {
    if (row.isNull(1)) continue;
    const id = (try row.get(0)).asI64().?;
    const name = (try row.get(1)).asSlice().?;   // チャンクを借用
}
```

**3. 型付き struct。** [§4](#4-typed-struct-マッピング) 参照。

**4. スカラー。**

```zig
var r = try client.query("SELECT count(*) FROM t");
defer r.deinit();
const n = (try r.scalar()).?.asI64().?;
```

---

## 4. `typed`: struct マッピング

`DataChunk` API の上に厳格に構築されており、プロトコルコアはこのファイルの存在を知りません。
フィールド名は結果ごとに 1 回だけ実行時に列名と照合され、フィールドごとの変換は
コンパイル時 (comptime) に解決されます。

```zig
pub fn iterator(comptime T: type, result: *Result) Error!Iterator(T)
pub fn collect(comptime T: type, allocator: std.mem.Allocator, result: *Result) Error![]T
pub fn convert(comptime T: type, v: Value) Error!T
pub fn Mapping(comptime T: type) type    // .init(*const Result), .read(Row)
pub fn Iterator(comptime T: type) type   // .next() Error!?T
```

```zig
const User = struct { id: i64, name: []const u8, score: f64, nickname: ?[]const u8 };

var it = try quackling.typed.iterator(User, &result);
while (try it.next()) |user| {
    std.debug.print("{d} {s} {d}\n", .{ user.id, user.name, user.score });
}
```

### フィールド対応の規則

- `T` は `struct` でなければならず、さもなければ `@compileError` です。
- 各フィールド名は `result.columnIndex(field_name)` で引かれます。照合は**名前による完全一致・
  大文字小文字を区別**し、列の順序は無関係です。結果に余分な列があっても無視されます。
  対応する列がないフィールドは `error.MissingColumn` で、`iterator()` が (つまりストリーム途中
  ではなく最初に) 返します。

### 変換表

| フィールド型 | 受け付ける `Value` | 規則 |
|-----------|------------------|------|
| `bool` | `.boolean` | それ以外は `error.TypeMismatch` |
| 任意の整数 | `asI64()` 経由、加えて `i64` 範囲外の値は `.ubigint`/`.hugeint`/`.uhugeint` | `std.math.cast`。範囲外は黙って切り捨てず `error.TypeMismatch` |
| 任意の浮動小数 | `asF64()` 経由 | `@floatCast` |
| `[]const u8` | `.varchar` / `.blob` / ENUM の `.label` (`asSlice()` 経由) | **チャンクバッファを借用** |
| 任意の `enum` | `asI64()` から `std.meta.intToEnum` | 範囲外は `error.TypeMismatch` |
| `?T` | 何でも | `.null` → `null`、それ以外は `T` へ再帰 |
| それ以外 | — | `@compileError` |

`[]const u8` 以外のポインタフィールド (非スライス、非 const、子が `u8` でない) は実行時エラー
ではなく `@compileError` です。

### NULL の扱い

`?T` フィールドが NULL を吸収します。**非オプショナルのフィールドに NULL が来た場合は
`error.UnexpectedNull`** で、黙ってゼロにはなりません。オプショナルを区別する意義そのものです。

```zig
try std.testing.expectError(error.UnexpectedNull, quackling.typed.convert(i64, .null));
try std.testing.expectEqual(@as(?i64, null), try quackling.typed.convert(?i64, .null));
```

### `collect`

```zig
const users = try quackling.typed.collect(User, allocator, &result);
defer allocator.free(users);
```

これはストリーミングを無効化するため、小さな結果専用です。さらに悪いことに、`[]const u8`
フィールドは依然チャンクバッファを借用しています。`collect` が戻った時点で全チャンクは
解放済みなので、収集されたスライス中の文字列フィールドは**ダングリング**します。`collect` は
スカラーのみの struct に限って使うか、`iterator` ループ内で自分で `dupe` してください。

### `typed.Error`

`error{ MissingColumn, TypeMismatch, UnexpectedNull } || result.Error` なので、型付きループは
トランスポートやプロトコルのエラーも表面化させます。

---

## 5. `params`: クエリパラメータ

### 置換がクライアント側で行われる理由

Quack プロトコルバージョン 1 には**パラメータのワイヤ表現が存在しません**。
`PrepareRequestMessage` はフィールドをちょうど 1 つ — SQL 文字列 — しか運ばず、サーバは
それを直接 `SendQuery(sql)` に渡します (`duckdb-quack/src/quack_server.cpp`)。実サーバに対して
確認した 2 つの事実:

- `SELECT ?` は *"Expected 1 parameters, but none were supplied"* を返す — 供給する経路が
  ありません。
- `PREPARE_REQUEST` にフィールドを追加するとサーバは HTTP 500 を返す — 未知のフィールドは
  拒否されるため、勝手に作ることはできません。

そのためパラメータは [`../../src/params.zig`](../../src/params.zig) で**クライアント側**に
SQL テキストへ描画されます。これは安全性の責務すべてを 1 つの小さく徹底的にテストされた
ファイルに置くことになるため、エンコーダは厳格であり、曖昧さのないリテラル形式を持たない
ものは近似せず拒否されます。

サーバ側のプリペアドステートメントが必要なら、SQL レベルの `PREPARE` / `EXECUTE` が
プロトコル上で問題なく使えます。

### `Param` union

```zig
pub const Param = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    hugeint: i128,     // 128 ビット整数。f64 の精度を超えるため厳密に描画
    unsigned: u64,
    uhugeint: u128,
    double: f64,
    text: []const u8,  // '' エスケープ付きの引用文字列リテラルとして描画
    blob: []const u8,  // 16 進エスケープ付きの BLOB リテラルとして描画
    date: i32,         // 1970-01-01 からの日数
    timestamp: i64,    // エポックからのマイクロ秒
    decimal: Value.Decimal,
    raw_sql: []const u8,  // 事前に描画された SQL をそのまま挿入 — エスケープされない
};
```

意図的に `Value` より小さな集合です。ここにあるすべてのバリアント (variant) は厳密で曖昧さの
ない SQL リテラル形式を持ちます。テキスト形式が損失を伴うか方言依存になる型
(`INTERVAL`、`UUID`、`TIME`、`ENUM`、ネスト型) は推測せず**省かれています**。キャスト付きの
`.raw_sql`、あるいは `.text` とサーバ側 `CAST` を使ってください。

便利なコンストラクタ:

```zig
pub fn int(v: anytype) Param   // .{ .integer = @intCast(v) }
pub fn str(v: []const u8) Param // .{ .text = v }
```

`Param.int` は `@intCast` を使うため、`i64` の範囲外の値はコンパイル時エラーまたは安全性
チェックの失敗になり、黙ってラップすることはありません。広い整数には `.hugeint` /
`.unsigned` / `.uhugeint` を使ってください。

### 描画表

| バリアント | 生成される SQL テキスト | 例 |
|---------|------------------|---------|
| `.null` | `NULL` | `NULL` |
| `.boolean` | `TRUE` / `FALSE` | `TRUE` |
| `.integer` | 10 進数字 | `42` |
| `.hugeint` | 10 進数字、128 ビットの完全精度 | `170141183460469231731687303715884105727` |
| `.unsigned` | 10 進数字 | `18446744073709551615` |
| `.uhugeint` | 10 進数字 | — |
| `.double` (有限) | `{d}::DOUBLE` — 最短往復形式。DuckDB が DECIMAL でなく DOUBLE と読むようキャスト | `1.5::DOUBLE` |
| `.double` (NaN) | `'NaN'::DOUBLE` | `'NaN'::DOUBLE` |
| `.double` (+∞ / −∞) | `'Infinity'::DOUBLE` / `'-Infinity'::DOUBLE` | |
| `.text` | 単一引用符で囲み、すべての `'` を二重化 | `'o''brien'` |
| `.blob` | 全バイトを 16 進エスケープし `::BLOB` | `'\x00\xFF\x61'::BLOB` |
| `.date` | `DATE 'YYYY-MM-DD'` | `DATE '2024-03-15'` |
| `.timestamp` | `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.ffffff]'` | `TIMESTAMP '2024-03-15 12:34:56'` |
| `.decimal` | スケールなしの値と scale から厳密な桁を生成 — 浮動小数の往復なし | `12.34`, `-0.05`, `7` |
| `.raw_sql` | そのまま挿入 | `now()` |

日付・タイムスタンプ・decimal の描画は
[`../../src/types/value.zig`](../../src/types/value.zig) の `writeDate` / `writeTimestamp` /
`writeDecimal` を再利用します。したがって実装はちょうど 1 つで、値の表示とパラメータの
バインドの間に食い違いは生じません。

### ⚠️ 警告: `.raw_sql` はそのまま挿入される

> **`.raw_sql` はエスケープも引用もされず、検証もされません。信頼できない入力から
> 決して構築しないでください。**
>
> これは式のための脱出口 — `now()`、列参照、キャスト — であり、注入 (injection) に対して
> 安全でない*唯一の* `Param` バリアントです。他のすべてのバリアントは、文の構造を変えられない
> 自己完結したリテラルに描画されます。値がユーザ、リクエストボディ、ファイル名、自分が
> 書いていない設定ファイル、あるいは任意のネットワークピア由来なら、`.raw_sql` に入れる
> べきではありません。

```zig
// 問題なし: コード自身が選んだリテラル。
try client.execParams("INSERT INTO t VALUES (?, ?)", &.{
    Param.int(1), .{ .raw_sql = "now()" },
});

// 致命的: ユーザ入力を SQL として扱う。
// .{ .raw_sql = user_input }   <-- 絶対にしないこと
```

### 厳格性の規則

`bind(allocator, sql, params) Error![]u8` は呼び出し側が所有する新規確保の SQL を返します。
次のすべてを適用します。

1. **UTF-8 検証。** 妥当な UTF-8 でない `.text` パラメータは `error.InvalidUtf8` です。
   不正なバイト列がサーバ上で意外な解析結果を生まないようにするためです。
2. **NUL の拒否。** `0` バイトを含む `.text` パラメータは `error.UnsupportedParameter` です。
   DuckDB は文字列リテラル内に NUL を持てません。
3. **`''` エスケープ。** `.text` の値中のすべての `'` は二重化されるため、古典的な注入
   ペイロードはリテラル内に留まります。`"'; DROP TABLE users; --"` は
   `'''; DROP TABLE users; --'` に描画され、1 つの引用文字列となり文の構造は変わりません。
4. **次の領域内の `?` はプレースホルダではなくデータ** — スキャナは各領域をそのまま
   コピーします:
   - 単一引用の文字列リテラル `'...'`。`''` エスケープを尊重するので `'a''?b'` は無傷;
   - 二重引用の識別子 `"weird?col"`;
   - ドル引用文字列 `$tag$ ... $tag$`。タグには英数字と `_` のみ許可;
   - `--` 行コメント (行末まで);
   - `/* ... */` ブロックコメント (閉じられていない場合は入力末尾まで)。
5. **件数の完全一致。** プレースホルダが多すぎても*少なすぎても*
   `error.ParameterCountMismatch` です。呼び出し側とクエリが文の形について食い違っていること
   を意味します。`bind("SELECT 1", &.{one_param})` も失敗します。
6. **素朴な整形が壊してしまうケースに対する厳密なリテラル形式。** `NaN` と `±Infinity` は
   明示的な引用＋キャスト形式、128 ビット整数は完全精度で出力、`DECIMAL` は浮動小数を
   経由せずスケールなしの値と scale から桁単位で厳密に描画されます。

ネストは追跡**しません**。ブロックコメントはネストせず、スキャナは単一パスです。これは上記
構文に対する SQL の意味論と一致します。

### `params.Error`

`error{ ParameterCountMismatch, UnsupportedParameter, InvalidUtf8 } ||
std.mem.Allocator.Error`。

---

## 6. `Pool`

Quack は接続ごとに独立したサーバ側セッションと結果カーソルを与えるため、単一の `Client` では
同時に 1 クエリしか進行できません。並行リクエストを処理するサーバには複数の接続が必要です。
プールはミューテックスで保護され、スレッド間で共有しても安全です。グローバル状態を持たない
ため、複数のプールが共存できます。

### `Pool.Options`

| フィールド | 型 | 既定値 | 意味 |
|-------|------|---------|---------|
| `allocator` | `std.mem.Allocator` | *必須* | プール自身のリストと各 `Client` を確保 |
| `endpoint` | `[]const u8` | *必須* | すべてのプール接続に渡される |
| `token` | `[]const u8` | `""` | すべてのプール接続に渡される |
| `transport` | `Transport` | *必須* | 全接続で**共有**。プールがスレッドセーフなら、これもスレッドセーフでなければならない。`NativeTransport` はスレッドセーフ (`std.http.Client` が自身のソケットをスレッドセーフにプールするため) |
| `io` | `std.Io` | *必須* | プール自身のブロッキング待機に使う。トランスポートと同じ `Io` を渡すこと。通常は `std.Io.Threaded` |
| `headers` | `[]const Header` | `&.{}` | 各 `Client` に転送 |
| `timeout_ms` | `?u32` | `null` | 各 `Client` に転送 |
| `max_response_bytes` | `usize` | `256 * 1024 * 1024` | 各 `Client` に転送 |
| `observer` | `?Observer` | `null` | 各 `Client` に転送 |
| `max_connections` | `usize` | `8` | 生存接続数の上限。`0` にすると `init` が `error.PoolExhausted` を返す |
| `min_connections` | `usize` | `0` | `init` 時に先行して開く数 (`max_connections` に丸められる)。残りは要求時に作成 |
| `wait_policy` | `WaitPolicy` | `.wait` | 飽和時に `acquire` が取る動作 |
| `on_deinit_wait` | `?*const fn (ctx: ?*anyopaque, outstanding: usize) void` | `null` | `deinit` が未返却のリースを待つ必要が生じたときに呼ばれる |
| `observer_ctx` | `?*anyopaque` | `null` | `on_deinit_wait` に渡す不透明なコンテキスト |

### `WaitPolicy`

| 値 | 挙動 |
|-------|-----------|
| `.wait` | 接続が返却されるまで (またはキャンセルトークンが発火するまで) ブロック |
| `.fail` | 即座に `error.PoolExhausted` を返す — キューに並ぶより負荷を落としたいリクエストハンドラ向け |

### メソッド

```zig
pub fn init(options: Options) Error!Pool
pub fn acquire(self: *Pool, cancel: ?*CancelToken) Error!Lease
pub fn snapshot(self: *Pool) Stats
pub fn deinit(self: *Pool) void
```

`acquire` はアイドル接続を取り出すか、`max_connections` 未満なら新規作成し (`Client` の作成は
I/O を行わず — ハンドシェイクは最初のクエリ時に遅延実行される — ロック下でも問題ない)、
さもなければ `wait_policy` を適用します。ループごとにキャンセルトークンを確認して
`error.Cancelled` を返し、`deinit` 後は `error.PoolClosed` を返します。

### リースのライフサイクル

```zig
pub const Lease = struct {
    pool: *Pool,
    client: *Client,
    released: bool = false,

    pub fn release(self: *Lease) void;
    pub fn discard(self: *Lease) void;
};
```

素の `*Client` ではなく明示的なハンドルとしてモデル化されているため、借用が呼び出し箇所で
可視になり `defer lease.release()` が自然に読めます。

- `release()` は接続をアイドル集合に戻し、待機者にシグナルします。
- `discard()` は返却*かつ退役*させます。接続が不正な状態にある (プロトコルの同期ずれ、
  トランスポート障害) と呼び出し側が分かっている場合のためです。スロットは即座に解放され、
  新しい接続がそこを使えます。
- どちらも `released` で保護されているため、**二重解放は安全な no-op** であり、フリーリストの
  破壊にはなりません。`deinit` が戻った後の解放も安全です。シャットダウン中の
  `releaseClient` は帳簿だけを更新し、クライアントを参照解除しません。

```zig
var lease = try pool.acquire(null);
defer lease.release();

var result = lease.client.query("SELECT 42") catch |err| {
    lease.discard();          // 同期のずれた接続は再利用しない
    return err;
};
defer result.deinit();
```

`defer lease.release()` と後続の `discard()` の併用は問題ありません。2 回目の呼び出しが
no-op になります。

### `deinit` はリースを待つ — そして自己デッドロック

`deinit` は `closed` を立て、`acquire` で待機中のスレッドを起こすためブロードキャストし、
その後**すべての未返却リースが返るまでブロックします**。`Lease` がまだ指している接続を破棄
すれば、そのリースがダングリングになるからです。各クライアントの `deinit` は `DISCONNECT` を
送るため、後片付けはロックの外で行われます。

> **自己デッドロックの危険。** 自らリースを保持したまま `pool.deinit()` を呼ぶスレッドは、
> 自分自身を永久に待ちます。プールを閉じる前にリースを解放してください。

プール内部からこれを移植性のある方法で検出することはできず、ライブラリが stderr に書くのは
筋違いなので、この状況は呼び出し側自身のフックを通じて表面化されます。

```zig
fn onDeinitWait(ctx: ?*anyopaque, outstanding: usize) void {
    _ = ctx;
    std.debug.panic("pool.deinit() blocked on {d} outstanding lease(s)", .{outstanding});
}

var pool = try quackling.Pool.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = http.transport(),
    .io = threaded.io(),
    .max_connections = 8,
    .on_deinit_wait = onDeinitWait,
});
```

`on_deinit_wait` は `deinit` 開始時点で `leased > 0` の場合にのみ、残数を伴って**1 回だけ**
呼ばれます。`null` のままなら `deinit` は静かに待ちます。正当な並行解放とリースの漏れを
区別できるのは呼び出し側だけなので、方針 (ログ、アサート、パニック) はあなたが決めます。

### `snapshot()`

ロック下で一貫した `Pool.Stats` を返します:

| フィールド | 意味 |
|-------|---------|
| `total` | プールが所有する接続数 (アイドルとリース中の合計) |
| `in_use` | 現在リースされている数 |
| `idle` | 渡せる状態にある数 |
| `acquires` | 累積の取得成功回数 |
| `creates` | 累積の接続作成数 |
| `discards` | 累積の `discard()` 呼び出し回数 |
| `waits` | `acquire` がブロックした回数 |
| `timeouts` | `.fail` の下で `acquire` が `error.PoolExhausted` を返した回数 |

### `Pool.Error`

`errors.QueryError || error{ PoolExhausted, PoolClosed }`。

---

## 7. `Transport`

プロトコルのコーデックはソケットに一切触れません。リクエスト本体を `Transport` に渡し、
レスポンス本体を受け取るだけです。この 1 段の間接化が、同じコーデックをネイティブ TCP、
ブラウザの `fetch()`、インメモリのモックで動かせる理由です。実行時に選んだトランスポートを
クライアントが保持できるように、そして `Client` がそれについてジェネリックにならない
(それは下流のあらゆる型シグネチャに漏れる) ように、comptime インターフェイスではなく
vtable にしています。

### 実装すべきインターフェイス

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response,
        close: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: Request) Error!Response;
    pub fn close(self: Transport) void;   // vtable スロットが null なら no-op
};

pub const Request = struct {
    url: []const u8,            // 絶対 URL、例: http://localhost:9494/quack
    body: []const u8,
    content_type: []const u8,   // "application/vnd.duckdb"
    headers: []const Header = &.{},
    timeout_ms: ?u32 = null,
    cancel: ?*CancelToken = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    owned: bool = false,
    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void;
};

pub const Header = struct { name: []const u8, value: []const u8 };
```

`Response.owned` が生存期間を明示します。自身のバッファの借用ビューを返せるトランスポートは
`owned = false` にしてコピーを避け、確保するトランスポートは `owned = true` にして呼び出し側が
解放します。これによりゼロコピー経路を、生存期間の曖昧さなしに利用できます。

実装チェックリスト: `req.content_type` を付けて `req.url` に POST のラウンドトリップを 1 回
行う。`req.headers` を尊重する。`req.cancel` を確認して `error.Cancelled` を返す。実際の
HTTP ステータスを返す (`Client` が自ら非 2xx を `error.HttpError` に写し、ステータスを
`last_error.http_status` に記録します)。`owned` を正しく設定する。`send` は
`transport.Error` のメンバを返さなければなりません。

```zig
const MyTransport = struct {
    fn sendFn(ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) transport.Error!Response {
        const self: *MyTransport = @ptrCast(@alignCast(ptr));
        _ = self; _ = allocator; _ = req;
        return .{ .status = 200, .body = "...", .owned = false };
    }
    pub fn transport(self: *MyTransport) quackling.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }
};
```

### `CancelToken`

```zig
pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),
    pub fn cancel(self: *CancelToken) void;
    pub fn isCancelled(self: *const CancelToken) bool;
    pub fn reset(self: *CancelToken) void;
};
```

意図的にただのアトミックな bool です。ランタイムなしで動作し、別スレッドやシグナルハンドラから
セットしても安全で、呼び出し側に非同期モデルを押しつけません。キャンセルは**協調的**です —
`Result.nextChunk`、`Pool.acquire`、およびトランスポートが確認する箇所で観測されます。
すでに発行済みのシステムコールを中断はしません。

```zig
var token = quackling.CancelToken{};
var result = try client.queryWithCancel("SELECT * FROM huge", &token);
defer result.deinit();
// 別スレッドから: token.cancel();
while (result.nextChunk() catch |e| switch (e) {
    error.Cancelled => null,
    else => return e,
}) |chunk| { _ = chunk; }
```

### `MockTransport`

あらかじめ用意したレスポンスを再生します。ゴールデンテストで使われており、ライブラリ利用者が
サーバなしで自分のコードをテストするためにも使えます。

| フィールド | 型 | 既定値 | 意味 |
|-------|------|---------|---------|
| `responses` | `[]const []const u8` | *必須* | `send` ごとに順に 1 つ渡す。尽きると `error.NetworkError` |
| `status` | `u16` | `200` | すべてのレスポンスに付与 |
| `sent` | `std.ArrayList([]const u8)` | `.empty` | `record_allocator` が設定されているとき、捕捉したリクエスト本体 |
| `record_allocator` | `?std.mem.Allocator` | `null` | 捕捉を有効化。`deinit` が解放 |
| `index` | `usize` | `0` | 次に渡すレスポンス |
| `fail_with` | `?Error` | `null` | 設定されていると `send` はレスポンスの代わりにこのエラーを返す |

```zig
var mock = quackling.MockTransport{
    .responses = &.{ connect_fixture, prepare_fixture },
    .record_allocator = allocator,
};
defer mock.deinit();

var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = mock.transport(),
});
defer client.deinit();
```

レスポンスは `owned = false` で返されます (フィクスチャがレスポンスより長生きするため)。
キャンセル済みトークンは、何も記録される前に短絡します。

### `NativeTransport`

`std.http.Client` によるネイティブ HTTP — 純粋な Zig 標準ライブラリで、libcurl も C 依存も
ありません。ライブラリ内でソケットの存在を知る唯一の場所であり、プロトコルコアが
これを import することはありません。

```zig
pub const Options = struct {
    max_response_bytes: usize = 256 * 1024 * 1024,
    timeout_ms: ?u32 = null,   // 予約。std.http.Client にまだ細粒度のフックがない
};

pub fn init(allocator: std.mem.Allocator, options: Options) !NativeTransport
pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, options: Options) NativeTransport
pub fn deinit(self: *NativeTransport) void
pub fn transport(self: *NativeTransport) Transport
```

`init` は `std.Io.Threaded` を作成し所有します。すでにイベントループを動かしている呼び出し側は
`initWithIo` で自分の `Io` を渡してください。これが io_uring/epoll/kqueue バックエンドが
入ってくる継ぎ目です。`timeout_ms` は現在予約されています。`std.http.Client` は細粒度の
タイムアウトフックを公開していないため、有界の待機には `CancelToken` を使ってください。

> **wasm:** `quackling.NativeTransport` は wasm ターゲット
> (`builtin.target.cpu.arch.isWasm()`) では `@compileError` になります。独自の `Transport` を
> 供給してください — 例えば `src/wasm` のブラウザ `fetch` ブリッジ。そうすればプロトコルコアは
> ネイティブ、WASI、freestanding wasm32 のいずれでもコンパイルできます。

---

## 8. エラー処理

エラーは*原因*でグループ化されており、「ネットワークが壊れた」「サーバが SQL を拒否した」
「このレスポンスは妥当な Quack ではない」に呼び出し側が別々に反応できます。Zig のエラー値は
ペイロードを持てないため、詳細なサーバテキストは `ErrorInfo` に併置され、
`client.lastError()` で取得できます。

`Client.Error` と `Result.Error` はどちらも `errors.QueryError` です:

```zig
pub const QueryError = TransportError || ProtocolError || SerializationError ||
    AuthenticationError || ServerError || UnsupportedError || UriError ||
    ParameterError || std.mem.Allocator.Error || error{ColumnOutOfRange};
```

各層で `||` で組み立てるのではなく 1 か所で定義されています。さもなければ 1 つバリアントを
追加するたびに、あらゆる中間シグネチャを追いかけることになります。

### `TransportError`

| エラー | 発生する状況 | 推奨される対応 |
|-------|------|---------------------|
| `ConnectionFailed` | DNS/TCP/connect の失敗 | バックオフ付きで再試行。プール利用時は `lease.discard()` |
| `Timeout` | トランスポートの期限切れ | 再試行、または `timeout_ms` を延ばす |
| `HttpError` | 非 2xx ステータス。`client.last_error.http_status` に保持 | ステータスを確認。4xx は通常設定／認証、5xx はサーバ側 |
| `ResponseTooLarge` | 本体が `max_response_bytes` 超過 | クエリを絞る、または意図して上限を上げる |
| `TlsError` | TLS ハンドシェイク／検証の失敗 | 証明書やプロキシ設定を修正。無闇に再試行しない |
| `InvalidUrl` | トランスポートが URL を解析できない | プログラミング／設定の誤り |
| `Cancelled` | `CancelToken` がセットされた | キャンセル時の想定動作。片付けて停止 |
| `Unsupported` | そのトランスポートでは実行できない操作 | トランスポート選択のプログラミング誤り |
| `NetworkError` | その他のネットワーク障害 (`MockTransport` のレスポンス枯渇を含む) | バックオフ付きで再試行 |

### `ProtocolError`

| エラー | 発生する状況 | 推奨される対応 |
|-------|------|---------------------|
| `UnexpectedMessageType` | やり取りが要求するメッセージ種別ではなかった (セッション id を含まない `CONNECTION_RESPONSE` も含む) | 接続を同期ずれとみなして破棄 |
| `UnknownMessageType` | 認識できないメッセージ種別バイト | バージョン不一致か破損。接続を破棄 |
| `UnsupportedProtocolVersion` | サーバの `quack_version` が `[1, 1]` の外 | クライアントかサーバを更新。再試行しない |
| `NotConnected` | 接続 id を必要とするリクエストだが保持していない | `connect()` を呼ぶ、または `query` に任せる |
| `ResultClosed` | すでにドレイン済み／クローズ済みの結果を使用 | プログラミング誤り |
| `ResultSuperseded` | 同じクライアントで新しいクエリがサーバ側カーソルをリセットした | 次のクエリの前に結果を完了させるか `deinit` する、または別接続を使う (`Pool` 参照) |
| `FetchLimitExceeded` | `Result.max_fetches` 超過のために予約 ([§3](#max_fetches) の注意点参照) | ピアが壊れているとみなして停止 |

### `SerializationError`

`UnexpectedEndOfBuffer`、`VarIntOverflow`、`LengthLimitExceeded`、
`UnexpectedFieldId`、`UnexpectedField`、`MalformedVector`、`RowCountTooLarge`。

バイト列そのものが不正だった場合です。本体の切り詰め、型に対して広すぎる varint、設定された
上限を超える長さ、その位置でデコーダがモデル化していないフィールド id、型と行数に整合しない
ベクタペイロード、幅と掛けたときにオーバーフローする行数など。**推奨される対応:** これは破損か
上流の形式変更なので、再試行するのではなく接続を破棄してバグとして報告してください。
`tests/fixtures/` のゴールデンフィクスチャは、形式変更が黙った誤読ではなくここでテスト失敗と
して表面化するために存在します。

### `AuthenticationError` と `ServerError`

| エラー | 発生する状況 | 推奨される対応 |
|-------|------|---------------------|
| `AuthenticationFailed` | サーバのエラーテキストが `"authenticat"` / `"invalid token"` / `"unauthorized"` に一致 | トークンを修正。再試行しない |
| `ServerError` | サーバがリクエストを実行し失敗を報告した (SQL 不正、制約違反、カタログエラー) | `client.lastError()` で DuckDB のメッセージをそのまま読み、表示する。接続は引き続き使用可能 |

認証失敗は通常のエラーレスポンスとして届くため、利用できる唯一の手がかりはテキストです。
照合は意図的に狭く、取りこぼしても `ServerError` と報告され、それも正確です。

### `UnsupportedError`

| エラー | 発生する状況 | 推奨される対応 |
|-------|------|---------------------|
| `UnsupportedType` | `getValue` で到達したネスト型、またはこのクライアントがモデル化していない型 id | ベクタのアクセサを使う ([TYPES.md §7](./TYPES.md#7-ネスト型))、または列をサーバ側でキャストする |
| `UnsupportedVectorType` | `VectorType.fsst`、または未知のエンコーディング | 起こりえないはず ([TYPES.md §8](./TYPES.md#fsst-を意図的に未実装にしている理由))。バグとして報告 |

### `UriError` と `ParameterError`

| エラー | 発生する状況 | 推奨される対応 |
|-------|------|---------------------|
| `InvalidUrl` | エンドポイントに埋め込み認証情報 (`@`)、不正な IPv6 ブラケット、ホスト中の制御文字／空白 | エンドポイント文字列を修正 |
| `EmptyHost` | 入力が空、またはホスト成分が空 | エンドポイント文字列を修正 |
| `InvalidPort` | ポートが空、非数値、`0`、または 65535 超 | エンドポイント文字列を修正 |
| `ParameterCountMismatch` | プレースホルダ数 ≠ 引数数 | プログラミング誤り |
| `UnsupportedParameter` | `.text` の値に NUL が含まれていた | 入力をサニタイズ |
| `InvalidUtf8` | `.text` の値が妥当な UTF-8 でなかった | バイナリデータには `.blob` を使う |

加えて `DataChunk.getValue` からの `error.ColumnOutOfRange` と
`std.mem.Allocator.Error` があります。

### `ErrorInfo`

```zig
pub const ErrorInfo = struct {
    allocator: ?std.mem.Allocator = null,
    message: []const u8 = "",        // サーバ提供。allocator が設定されていれば所有
    http_status: ?u16 = null,        // その層での失敗時に設定
    pub fn deinit(self: *ErrorInfo) void;
    pub fn set(self: *ErrorInfo, allocator: std.mem.Allocator, msg: []const u8) !void;
};
```

`client.last_error` として到達でき、`client.lastError()` はメッセージのみを返します。
`set` は以前のメッセージを (解放して) 置き換えます。

### 慣用的な処理

```zig
var result = client.query(sql) catch |err| switch (err) {
    error.ServerError => {
        // DuckDB 自身のメッセージ: カタログエラー、構文エラー、制約違反など
        std.log.err("query failed: {s}", .{client.lastError()});
        return err;
    },
    error.AuthenticationFailed => return err,             // 再試行しても無意味
    error.ResultSuperseded => unreachable,                // 呼び出し側のバグ
    error.ConnectionFailed, error.Timeout, error.NetworkError => {
        return retryLater(err);
    },
    else => return err,
};
defer result.deinit();
```

---

## 9. `Stats` と `Observer`

2 つの仕組みがあり、どちらも依存関係なしです。ロギングフレームワークは import されず、
既定では何もどこにも書き出されません。特にクライアントは**認証トークンを決してログに
出しません**。

### `Stats`

`client.stats` はいつでも読める素の構造体です。すべて `u64` です:

| フィールド | インクリメントされる条件 |
|-------|-----------------|
| `connects` | ハンドシェイクが成功した |
| `requests` | トランスポートのラウンドトリップがレスポンスを返した |
| `queries` | `PREPARE` が成功した |
| `fetches` | `FETCH` が成功した |
| `chunks_received` | `nextChunk` がチャンクを渡すたび |
| `rows_received` | 各チャンクの `row_count` の分だけ |
| `bytes_sent` | ラウンドトリップごとにリクエスト本体長の分だけ |
| `bytes_received` | ラウンドトリップごとにレスポンス本体長の分だけ |
| `server_errors` | PREPARE または FETCH に対して `ERROR_RESPONSE` が届いた |
| `transport_errors` | トランスポートが失敗、または非 2xx ステータスが届いた |
| `protocol_errors` | プロトコル層の失敗のために宣言されている |

```zig
pub fn reset(self: *Stats) void
pub fn format(self: Stats, w: *std.Io.Writer) std.Io.Writer.Error!void
```

`format` は 1 行を出力します:
`requests=… queries=… fetches=… chunks=… rows=… sent=…B recv=…B errors=s/t/p`。

```zig
std.debug.print("{f}\n", .{client.stats});
```

> **確認済みの注意点:** `protocol_errors` は宣言され表示もされますが、現在のソースでは
> インクリメントされることがありません。`connects` は*成功した*ハンドシェイクのみを数えます。

### `Observer`

リクエストごとのフックです。呼び出し側が関心のある 1 つだけを渡せるよう、インターフェイス
ではなく関数ポインタの構造体として保たれています。すべてのフィールドはオプショナルで、
クライアントは呼ぶ前に確認します。

```zig
pub const Observer = struct {
    ctx: ?*anyopaque = null,
    on_request_start: ?*const fn (ctx: ?*anyopaque, bytes: usize) void = null,
    on_request_end: ?*const fn (ctx: ?*anyopaque, bytes: usize, failed: bool) void = null,
    on_chunk: ?*const fn (ctx: ?*anyopaque, rows: usize) void = null,

    pub fn onRequestStart(self: Observer, bytes: usize) void;
    pub fn onRequestEnd(self: Observer, bytes: usize, failed: bool) void;
    pub fn onChunk(self: Observer, rows: usize) void;
};
```

| フック | 呼ばれるタイミング | 引数 |
|------|--------|-----------|
| `on_request_start` | すべてのトランスポート `send` の前 | リクエスト本体長 |
| `on_request_end` | すべてのトランスポート `send` の後 | レスポンス本体長 (失敗時は `0`) と `failed` |
| `on_chunk` | `nextChunk` がチャンクを渡すたび | そのチャンクの行数 |

フックは呼び出し元スレッド上で同期的に、リクエスト経路の内側で呼ばれます。軽量かつ
ノンブロッキングに保ってください。`Pool` は自身の `observer` をすべてのプール `Client` に
転送するため、共有される observer はスレッドセーフでなければなりません。

```zig
const Metrics = struct {
    requests: std.atomic.Value(u64) = .init(0),
    rows: std.atomic.Value(u64) = .init(0),

    fn onStart(ctx: ?*anyopaque, bytes: usize) void {
        _ = bytes;
        const self: *Metrics = @ptrCast(@alignCast(ctx.?));
        _ = self.requests.fetchAdd(1, .monotonic);
    }
    fn onChunk(ctx: ?*anyopaque, rows: usize) void {
        const self: *Metrics = @ptrCast(@alignCast(ctx.?));
        _ = self.rows.fetchAdd(rows, .monotonic);
    }
};

var metrics = Metrics{};
var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = http.transport(),
    .observer = .{
        .ctx = &metrics,
        .on_request_start = Metrics.onStart,
        .on_chunk = Metrics.onChunk,
    },
});
```

---

## 10. エンドポイントの形式

`Client.init` は `options.endpoint` に `uri.parse` を適用し、続いて `toHttpUrl` が
プロトコル固定のパス `/quack` を付加します。
[`../../src/uri.zig`](../../src/uri.zig) を参照してください。

### 受け付けられる形式

| 形式 | 結果 |
|------|------|
| `quack:host` | `http://host:9494/quack` |
| `quack://host` | 同上 |
| `quack:host:1234` | `http://host:1234/quack` |
| `http://host` | `http://host:9494/quack` |
| `http://host:9494` | `http://host:9494/quack` |
| `https://host` | `https://host:9494/quack` — スキームは尊重される |
| `host:9494` | `http://host:9494/quack` — スキームなしは `http` |
| `quack:[::1]:9494` | `http://[::1]:9494/quack` — ブラケットは保持される |
| `quack:::1` | コロンが複数でポートのない素の IPv6。文字列全体がホストとなり、出力時に再度ブラケットが付く |
| `http://host:9494/some/path?x=1` | パスとクエリは**破棄される** — エンドポイントのパスはプロトコルで固定 |

既定ポートは `9494`、既定スキームは `http` です。

### 拒否される形式

| 入力 | エラー | 理由 |
|-------|-------|-----|
| `""` | `EmptyHost` | |
| `quack:user:pass@host` | `InvalidUrl` | 埋め込み認証情報は黙って捨てられてしまい、認証済みに見えて実はそうでない URL はエラーより悪い |
| `quack:host:0` | `InvalidPort` | ポート `0` は有効な宛先ではない |
| `quack:host:99999` | `InvalidPort` | `u16` の範囲外 |
| `quack:host:abc` | `InvalidPort` | 数値でない |
| `quack:ho st` | `InvalidUrl` | ホストのバイトが `<= 0x20` または `0x7F` なら拒否 |
| `quack:host\nX` | `InvalidUrl` | 同じ規則 — 制御文字を URL に貼り込んではならない |
| `quack:[::1` | `InvalidUrl` | IPv6 ブラケットが閉じていない |
| `quack:[::1]x` | `InvalidUrl` | ブラケットの後に `:port` でないゴミがある |

検証は意図的に厳格です。制御文字、空白、埋め込み認証情報を含むホストは、URL に貼り込むのでは
なく拒否されます。

> **セキュリティに関する注意:** 認証トークンはプロトコル本体の*内部*を通り、Quack サーバ自身は
> TLS を終端しません。localhost 以外では、リバースプロキシ経由で `https://` を使ってください。
