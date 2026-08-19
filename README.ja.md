# Quackling

[English](README.md) · **日本語**

Zig で書かれた軽量かつ独立した **DuckDB Quack プロトコルクライアント**。
ネイティブ環境と WebAssembly 環境の両方を対象としています。

```zig
var result = try client.query("SELECT 42 AS answer");
defer result.deinit();

while (try result.nextChunk()) |chunk| {
    // ベクトル化処理
}
```

- **Zig のみ** — 標準ライブラリだけを使用。`libduckdb`、C/C++ ランタイム、libcurl は不要。
- **独立実装** — ワイヤプロトコル (wire protocol) を DuckDB に委譲せず、本ライブラリ内で実装。
- **ネイティブ + WASM** — プロトコルコアは同一ソースから Linux、macOS、Windows、WASI、
  `wasm32-freestanding` 向けにコンパイルできます。
- **ストリーミング、DataChunk 指向** — 結果は行オブジェクトではなくベクトルとして届きます。
- **低アロケーション** — 大量データのペイロードはレスポンスバッファから借用 (borrow) されます。
  5,000 行の `BIGINT` のデコードに要するアロケーションは 9 回です。
- **トランスポート非依存** — HTTP、ブラウザの `fetch()`、モックのいずれかを呼び出し側が選択します。

---

## ドキュメント

| ガイド | 内容 |
|--------|------|
| [サーバ構築](docs/ja/SERVER_SETUP.md) | `quack_serve()` の実行、URI、TLS、トラブルシューティング |
| [API リファレンス](docs/ja/API.md) | `Client`、`Result`、`typed`、`params`、`Pool`、`Transport`、エラー |
| [型サポート](docs/ja/TYPES.md) | DuckDB の全型、NULL の扱い、入れ子型アクセス、ゼロコピー規則 |
| [アーキテクチャ](docs/ja/ARCHITECTURE.md) | 階層構造、セッション状態機械、所有権、ストリーミングモデル |
| [ワイヤプロトコル](docs/ja/PROTOCOL.md) | バイト単位の Quack フォーマットリファレンス |
| [CLI](docs/ja/CLI.md) | `quackling` のフラグと出力フォーマット |
| [WASM](docs/ja/WASM.md) | wasm32 向けビルド、FFI 面、ブラウザでの利用 |
| [性能](docs/ja/PERFORMANCE.md) | ベンチマーク、測定方法、アロケーション挙動、落とし穴 |
| [テスト](docs/ja/TESTING.md) | 6層のテスト戦略とミューテーションテスト |
| [セキュリティ](docs/ja/SECURITY.md) | 脅威モデル、リソース制限、インジェクション境界 |

英語版のドキュメントは [docs/en/](docs/en/) にあります。

## これは何か

[Quack](https://duckdb.org/quack/) は DuckDB のクライアント/サーバプロトコルです。
HTTP 上の RPC 層であり、クライアントからリモートの DuckDB インスタンスに対して
SQL を実行できます。Quackling はこのプロトコルを Zig から直接話します。

具体的には次の位置に入ります。

```
Zig アプリケーション
      │
      ▼
Quack クライアント  (本ライブラリ)
      │  HTTP / HTTPS
      ▼
DuckDB Quack サーバ
```

## DuckDB-Wasm ではなく、なぜこれか

両者は異なる問題を解決するもので、競合関係にはありません。

|                | DuckDB-Wasm                       | Quackling                              |
|----------------|-----------------------------------|----------------------------------------|
| 正体            | ブラウザ内で動く DuckDB **エンジン**   | リモート DuckDB 向けの **クライアント**   |
| SQL の実行場所   | ローカル (ブラウザ内)               | サーバ側                                |
| 配信サイズ       | エンジン数十 MB                     | 約 73 KB の WASM モジュール              |
| データの所在     | ブラウザまで転送が必要               | サーバ側に留まる                          |
| 使うべき場面     | ローカルかつオフラインの分析          | 共有された、あるいは大規模なリモート DB    |

ブラウザ内でデータベースを動かしたいなら DuckDB-Wasm を選んでください。
CLI、サーバ、組み込みターゲット、あるいはエンジンをダウンロードさせたくない
ブラウザタブから、データベースと*会話*したいなら Quackling を選んでください。

## なぜ Quack か

Quack は HTTP ベースで、専用ドライバを必要とせず、DuckDB の型システムを
無損失で保持し、1クエリあたり1往復で完結するよう設計されています。
そのため、小さく依存関係のないクライアントに適しています。

## インストール

### CLI

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.ps1 | iex
```

プラットフォームに合った静的バイナリをダウンロードし、SHA-256 を検証してユーザー
所有のディレクトリへ配置します。`sudo` もコンパイラも不要です。Linux 向けは静的
musl ビルドなので、1 つのバイナリで glibc 系と musl 系の両方をカバーします。

1 つのバイナリに 2 つの名前が入ります。正式名の `quackling` と、入力を短くするた
めの別名 `qkl` です。`--version` はどちらで起動しても正式名を出力するため、スク
リプト側が解析する文字列は 1 つだけです。

```sh
quackling "SELECT 42"
qkl "SELECT 42"                  # 同じコマンド。3 文字
```

```sh
# バージョン指定、配置先の変更、ソースからのビルド
sh install.sh --version v0.1.0
sh install.sh --bin-dir ~/bin
sh install.sh --build            # Zig 0.16 が必要
sh install.sh --dry-run          # 実行内容の確認のみ
sh install.sh --no-alias         # `quackling` のみを配置
```

チェックサムが一致しない場合はインストールを中止します。検証『できなかった』場合
も、できたふりをせずにその旨を明示します。配置後にバイナリを 1 度実行してプラット
フォームが正しいことを確認し、`sudo` を勝手に実行することはありません。root 権限
が必要な場合は、実行すべきコマンドをそのまま表示します。

配布物を作る場合は `zig build release -Dversion=v0.1.0` で 6 プラットフォーム分を
クロスコンパイルし、`SHA256SUMS` とともに `zig-out/release/` へ出力します。

### ライブラリ

**Zig 0.16.0** が必要です。

```sh
zig fetch --save git+https://github.com/<you>/quackling
```

```zig
// build.zig
const quackling = b.dependency("quackling", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("quackling", quackling.module("quackling"));
```

## クイックスタート

サーバを起動します。`quack` 拡張はプレリリース段階の拡張で、
**DuckDB v1.5.5** で現時点で動作します。DuckDB 2.0 は必要ありません。

```sh
duckdb
```

```sql
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

このセッションは開いたままにしてください。サーバは DuckDB プロセスが生きている間だけ
存在します。常駐させる手順、TLS、トラブルシューティングは
[サーバ構築](docs/ja/SERVER_SETUP.md) を参照してください。

次にクライアント側です。

```zig
const std = @import("std");
const quackling = @import("quackling");

pub fn main(init: std.process.Init) !void {
    // トランスポートは呼び出し側が渡す。ライブラリが自分でソケットを開くことはない。
    var http = quackling.NativeTransport.initWithIo(init.gpa, init.io, .{});
    defer http.deinit();

    var client = try quackling.Client.init(.{
        .allocator = init.gpa,
        .endpoint = "quack:localhost:9494",
        .token = "super_secret",
        .transport = http.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 42 AS answer");
    defer result.deinit();

    const answer = (try result.scalar()).?;
    std.debug.print("answer = {f}\n", .{answer});
}
```

コマンドラインから直接実行することもできます。

```sh
quackling --token super_secret "SELECT 42 AS answer"
```

```
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

### DataChunk が第一級の API

DuckDB はベクトル化されているため、第一級の API もベクトル指向です。
行 (row) はその上に乗る利便レイヤであり、逆ではありません。

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;

    if (col.asSlice(i64)) |slice| {
        // 真のゼロコピー: `slice` はレスポンスバッファを参照している。
        for (slice) |v| consume(v);
    } else if (col.isFlat(i64)) {
        // ワイヤ上のペイロードはアラインメントが保証されない。`at` は常に安全。
        for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
    }
}
```

チャンク境界を透過的に跨いで1行ずつ処理する場合。

```zig
var rows = result.rows();
while (try rows.next()) |row| {
    const id = (try row.get(0)).asI64().?;
}
```

comptime リフレクションで構造体にマッピングする場合。

```zig
const User = struct { id: i64, name: []const u8, score: f64, nickname: ?[]const u8 };

var it = try quackling.typed.iterator(User, &result);
while (try it.next()) |user| { ... }
```

`?T` のフィールドは NULL を受け付けます。非 optional なフィールドに NULL が来た場合は
エラーになり、暗黙のゼロ値になることはありません。

借用したデータが有効なのは次の `nextChunk()` までです。所有権の規則の全体は
[型サポート](docs/ja/TYPES.md) にあります。

### クエリパラメータ

```zig
var result = try client.queryParams(
    "SELECT * FROM users WHERE id = ? AND name = ?",
    &.{ .{ .integer = 42 }, .{ .text = "o'brien" } },
);
```

Quack v1 には**パラメータ用のワイヤフォーマットが存在しません**。
`PrepareRequestMessage` は SQL 文字列のみを運びます。そのため Quackling は
クライアント側で [`src/params.zig`](src/params.zig) においてパラメータを SQL テキストへ
展開します。この設計は安全性の責任をすべて1つの小さな、集中的にテストされたファイルに
負わせるため、その処理は厳格です。`''` によるエスケープ、UTF-8 検証、NUL の拒否、
プレースホルダと引数の個数の厳密一致を行い、文字列リテラル・引用符付き識別子・
ドル引用文字列・`--` および `/* */` コメントの内側にある `?` は
プレースホルダとして**扱いません**。

> [!WARNING]
> `.raw_sql` は設計上そのまま挿入されます。信頼できない入力から構築しないでください。

サーバ側のプリペアドステートメントが必要な場合は、SQL レベルの `PREPARE` / `EXECUTE` が
プロトコル上で通常どおり動作します。詳細と `Param` union の全体は
[API リファレンス](docs/ja/API.md) を参照してください。

### 1接続につき同時に1つの結果のみ

Quack の接続はサーバ側の結果カーソル (result cursor) を厳密に1つだけ持ちます。
サーバは次の `PREPARE` を受理した時点で前のカーソルを破棄します。
そのクエリがその後成功するかどうかは関係ありません。したがって2つ目のクエリを
開始すると、まだストリーミング中の結果は無効になります。

```zig
var a = try client.query("SELECT * FROM big");
var b = try client.query("SELECT 1");   // サーバ側で a のカーソルが破棄される
_ = try a.nextChunk();                  // error.ResultSuperseded
```

Quackling はこれを検出します。古い結果が新しいクエリの行を黙って取得してしまう
ことはありません。次のクエリの前に結果を読み切るか `deinit` してください。
あるいは同時実行するクエリごとに専用の接続を与えてください。

### コネクションプール

Quack の接続は結果カーソルを1つ持つサーバ側セッションそのものなので、
クエリを同時実行するには接続も同時に必要です。

```zig
var pool = try quackling.Pool.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .token = token,
    .transport = http.transport(),
    .io = threaded.io(),
    .max_connections = 8,
});
defer pool.deinit();

var lease = try pool.acquire(null);
defer lease.release();
var result = try lease.client.query("SELECT 42");
```

プールは mutex で保護されており、スレッド間で共有しても安全です。
飽和時の挙動は `wait_policy` でブロックと負荷の切り捨て (`error.PoolExhausted`) を
選択できます。`lease.discard()` は接続を再利用せず破棄します。

`Pool.deinit` は貸し出し中のリース (lease) がすべて返却されるまで待機します。
リースが指している接続を解放すれば、その参照が宙に浮くからです。
プールを閉じる前にリースを返却してください。リースを保持したまま `deinit` を呼ぶと、
呼び出し側は自分自身を待つことになります。これが起きたことを知るには
`on_deinit_wait` を設定してください。ライブラリはログを出力しないため、
これがそれを表面化させる唯一のフックです。詳細は
[API リファレンス](docs/ja/API.md) にあります。

## CLI

```sh
quackling --url quack:localhost:9494 --token secret "SELECT 42"
quackling --format json     "SELECT * FROM t"   # csv, ndjson, markdown も可
quackling --timing --stats  "SELECT 1"
echo "SELECT 42" | quackling                    # 標準入力から SQL
```

`qkl` は同じバイナリへの別名なので、上の例はすべて `qkl ...` でも動作します。

CLI 固有の挙動はすべて `src/cli/` に閉じており、ライブラリ側に漏れ出しません。
フラグとフォーマットの完全なリファレンスは [CLI](docs/ja/CLI.md) にあります。

## WASM

```sh
zig build wasm      # -> zig-out/bin/quackling.wasm  (約 73 KB)
```

プロトコルコアは OS、libc、スレッド、ファイルシステムのいずれにも依存しないため、
JavaScript が `fetch()` を提供すれば、同じデコーダがブラウザ内で動作します。

`web/` は公開可能な npm パッケージです。ESM エントリポイント、TypeScript 用の
`quack.d.ts`、そしてビルドがその場に書き出す `.wasm` を含みます。

```js
import { Quack } from 'quackling';
import wasmUrl from 'quackling/quackling.wasm?url';   // Vite

const db = await Quack.connect({ wasm: wasmUrl, url: 'quack:localhost:9494', token });

await db.queryValue('SELECT 42');                     // 42

// 大きな結果は FETCH でストリームされるため、黙って切り詰められることはない。
const result = await db.query('SELECT * FROM events');
for await (const row of result) render(row);
```

バインドパラメータと入れ子型も JS から使えます。

```js
await db.queryAll('SELECT * FROM users WHERE id = ?', [42]);
const [row] = await db.queryAll("SELECT {'a':1} s, [1,2] l, MAP{'k':1} m");
// row.s -> {a: 1}   row.l -> [1, 2]   row.m -> Map { 'k' => 1 }
```

入れ子の値は WASM 側で実体化せず、不透明なベクトルハンドル (vector handle) を通じて
walk されるため、追加のメモリを消費しません。パラメータのエスケープはネイティブ
クライアントと共有された Zig 側で行われるため、監査対象の実装は 2 つではなく 1 つです。

`wasm` は `Response`、生のバイト列、コンパイル済みの `WebAssembly.Module` も受け付けます。
アプリがパスをハードコードするのではなく、バンドラがアセット解決を担う形です。
モジュールは共有バッファを 1 組しか持たないため、1 接続上の操作は内部で直列化されます。

バンドラ別の手順、型マッピング、現時点の制限は [`web/README.md`](web/README.md) を
参照してください。

FFI 境界は意図的に狭く保たれています。JS は線形メモリ (linear memory) に対して
バイト列を出し入れするだけで、JSON を見ることはありません。数値カラムは
**WASM メモリ上の TypedArray ビュー**として直接読み出され、コピーも
値ごとのマーシャリングも発生しません。エクスポート面の全体は
[WASM](docs/ja/WASM.md) に記載しています。

動作するブラウザ PoC が `examples/browser/` にあります。ビルドはこのディレクトリに
書き込まないため、モジュールのコピーを更新し、HTTP 経由で配信してください。
`file://` では ES モジュールと `.wasm` を読み込めません。

```sh
zig build wasm
cp web/quackling.wasm examples/browser/
python3 -m http.server 8080          # 次を開く
                                     # http://127.0.0.1:8080/examples/browser/
```

DuckDB サーバは `Access-Control-Allow-Origin: *` を返すため、別ポートから配信された
ページでも追加設定なしに到達できます。

## アーキテクチャ

各層は自分のすぐ下の層にのみ依存します。プロトコル層がソケットに触れることはなく、
これが `wasm32-freestanding` ビルドを可能にしています。

```
             公開 API            client.zig, result.zig, typed.zig
                  ↓
        セッション / 状態機械      client.zig
                  ↓
          Quack メッセージ        protocol/message.zig, protocol/compat.zig
                  ↓
  DuckDB シリアライゼーション     serialization/{reader,writer,decoder}.zig
                  ↓
        トランスポート抽象化       transport/transport.zig
                  ↓
      HTTP · fetch() · モック     transport/native.zig, src/wasm/exports.zig
```

```
src/
├── root.zig            公開インタフェース
├── client.zig          接続とセッション
├── result.zig          ストリーミング結果 (チャンク、行)
├── typed.zig           comptime 構造体マッピング
├── uri.zig             quack:/http:/https: の解析と検証
├── error.zig           エラー分類
├── stats.zig           カウンタとフック
├── protocol/
│   ├── message.zig     メッセージのエンコード/デコード
│   └── compat.zig      プロトコル定数を1ファイルに集約
├── serialization/
│   ├── reader.zig      境界検査付きのプリミティブデコード
│   ├── writer.zig      プリミティブのエンコード
│   └── decoder.zig     LogicalType / Vector / DataChunk
├── types/
│   ├── logical_type.zig, value.zig, vector.zig,
│   └── data_chunk.zig, validity.zig
├── transport/
│   ├── transport.zig   Transport インタフェースと MockTransport
│   └── native.zig      std.http.Client
├── cli/main.zig
└── wasm/exports.zig
```

プロトコル定数 (メッセージ ID、フィールド ID、バージョン) は
[`src/protocol/compat.zig`](src/protocol/compat.zig) と `serialization/decoder.zig` に
限定されているため、上流の変更を追う作業は局所的な編集で済みます。
全体の解説は [アーキテクチャ](docs/ja/ARCHITECTURE.md) に、ワイヤフォーマット自体は
[ワイヤプロトコル](docs/ja/PROTOCOL.md) にあります。

## サポートする型

DuckDB のスカラ型はすべて `Value` にデコードされます。128 ビットを含む符号付き・
符号なしの全整数幅、`FLOAT` / `DOUBLE` / `DECIMAL`、`VARCHAR` / `BLOB` / `BIT` /
`BIGNUM`、時間関連の全ファミリ (`DATE`、`TIME`、`TIME_TZ`、s/ms/us/ns の
`TIMESTAMP` と `TIMESTAMP_TZ`、`INTERVAL`)、`UUID`、`ENUM`、`NULL`。
そのすべてについて NULL と有効性マスク (validity mask) の処理を含みます。

`ENUM` は生の辞書インデックスではなくラベルに解決されます。

```zig
const v = try chunk.getValue(0, 0);
v.@"enum".label;   // "happy"
v.@"enum".index;   // 2
```

`STRUCT`、`LIST`、`ARRAY`、`MAP`、`UNION`、`VARIANT` は構造的にデコードされます。
フラットな `Value` union は入れ子の記憶域を所有できないため、これらには
ベクトルアクセサ (`children`、`listEntry`、`listChild`、`mapEntry`、`unionValue`) を
通じてアクセスします。それぞれの実例は [型サポート](docs/ja/TYPES.md) にあります。

MAP と UNION に専用のデコード経路は必要ありません。DuckDB は MAP を
`LIST(STRUCT(key, value))` として、UNION を隠れた `UTINYINT` タグを持つ STRUCT として
格納するため、LIST と STRUCT の機構をそのまま再利用できます。

ベクトルエンコーディングは `FLAT`、`CONSTANT`、`DICTIONARY`、`SEQUENCE` のすべてを
デコードします。圧縮された形式を展開することはありません。

**FSST** は意図的に未実装です。DuckDB の `Vector::Serialize` に FSST の分岐は存在せず、
そのようなベクトルは `ToUnifiedFormat` に落ちてワイヤに乗る前にフラット化されるため、
FSST エンコードされたベクトルが到着することはありません。文書化されていない
シンボルテーブル形式を推測するのではなく、万一到着した場合はデコーダが
`error.UnsupportedVectorType` を返します。

本クライアントがモデル化していないものは `error.UnsupportedType` を返します。
黙って誤ってデコードされることは決してありません。

## サポートする DuckDB バージョン

**DuckDB v1.5.5** (`quack` 拡張、Quack プロトコルバージョン 1) に対して検証済みです。
クライアントはプロトコルバージョン 1 を提示し、その範囲外のサーバに対しては
推測せず接続を拒否します。

## プロトコルの状態

Quack は**ベータ**であり、上流は破壊的変更を想定しています。安定版となるのは
DuckDB 2.0 (「Cyanoptera」) で、2026年秋に予定されており、まだリリースされていません。
拡張自体は DuckDB v1.5.5 で現時点で利用可能です。

本クライアントは DuckDB のソース (`duckdb/duckdb-quack` および DuckDB の
`BinarySerializer`) に対して書かれ、稼働中のサーバに対してバイト単位で検証されています。
ブログ記事や推測に基づいて書かれた部分はありません。実サーバから採取した
ゴールデンフィクスチャ (golden fixture) が `tests/fixtures/` にコミットされているため、
上流のフォーマット変更は静かな誤読ではなくテストの失敗として現れます。

## セキュリティ

本クライアントはネットワークから信頼できないバイト列を受け取るため、
デコーダが攻撃面のすべてです。その契約は次のとおりです。
**任意の入力に対して、デコード成功か型付きエラーのいずれかを返す。
panic、範囲外読み取り、整数オーバーフロー、無制限のアロケーションは決して起こさない。**

- すべてのデコードで境界検査 (bounds check) を行います。ワイヤデータを構造体へ
  `@ptrCast` することは**決してありません**。固定幅の値は明示的な
  リトルエンディアン読み出しで取得します。
- 長さと個数の前置値は、設定可能な上限と実際に残っているバイト数の**両方**に対して、
  アロケーションの前に検証されます。悪意ある長さフィールドが巨大なアロケーションを
  引き起こすことはありません。
- 入れ子の深さは制限されているため、深く入れ子になったメッセージでスタックを
  枯渇させることはできません。
- レスポンスサイズは `max_response_bytes` で制限され、1つの結果あたりの FETCH 往復は
  `Result.max_fetches` で制限されます。ストリーム終端は*サーバ*からの信号
  (空のバッチ) であるため、上限がなければ、それを送らないピアがクライアントを
  無期限にハングさせられます。
- URL は検証され、埋め込み資格情報と制御文字は拒否されます。
- トークンがログ出力、表示、エラーメッセージに含まれることはありません。
  これはテストで検証されています。

> [!IMPORTANT]
> 認証トークンはプロトコル本体の**内部**を通ります。また DuckDB サーバ自身は
> TLS を終端しません。localhost を超える用途では前段にリバースプロキシを
> 置いてください。

デコーダはファズテスト (`tests/fuzz_test.zig`) されています。全フィクスチャの
あらゆる長さでの切り詰めと単一バイト破損、加えてランダムかつ敵対的な入力に対し、
panic ではなく型付きエラーを返さなければなりません。

脅威モデル、各制限のデフォルト値、対象外事項の率直な一覧は
[セキュリティ](docs/ja/SECURITY.md) にあります。

## 性能

コーデックのみ、ネットワークなし、`ReleaseFast`、Apple aarch64 での測定です。
`zig build bench` で再現できます。

2026-08-19 実施、3回実行の中央値です。

| ベンチマーク            |   ns/op |     MB/s |        rows/s | allocs/op |
|------------------------|--------:|---------:|--------------:|----------:|
| decode `SELECT 42`     |     156 |    583.1 |     6 408 896 |         5 |
| decode 5k-row BIGINT   |     320 |119 732.4 |15 634 160 641 |         9 |
| decode+values 5k-row   |  16 535 |  2 315.8 |   302 391 158 |         9 |
| decode+flat 5k-row     |   9 142 |  4 188.5 |   546 913 831 |         9 |
| decode VARCHAR         |     252 |    511.4 |     3 972 458 |         7 |
| decode NULL-heavy      |     166 |    784.9 |    60 071 183 |         5 |
| decode STRUCT          |     363 |    477.8 |     2 753 054 |         9 |
| decode MAP             |     509 |    470.5 |     1 965 541 |        13 |
| encode PREPARE request |      20 |  4 446.4 |    49 077 755 |         1 |
| bind 4 parameters      |     142 |    637.6 |     7 038 051 |         1 |

この表から読み取るべき点が3つあります。

- **アロケーション回数は行数に比例しません。** 5,000 行で 9 回、1 行で 5 回です。
  大量データのペイロードをコピーせず、レスポンスバッファから借用しているためです。
  アロケーションは結果のサイズではなく*構造*に比例します。
- **型付き経路 (`at`/`asSlice`) は `Value` 経路より約 1.8 倍高速です。**
  同じ 5,000 行で 9,142 ns 対 16,535 ns。扱いやすさを取るなら `Value`、
  スループットを取るなら型付きアクセサを使ってください。
- **入れ子型も低コストのままです。** MAP は保持するエントリ数に関係なく
  13 回のアロケーションで済みます。キーと値が借用された子ベクトルだからです。

エンドツーエンドでは、ループバック HTTP 上で 1,000,000 行のストリーミングに
**0.49 秒**かかります。489 チャンク、41 回の FETCH 往復で、約 16 MB の
ワイヤデータを受信します。
[`examples/streaming.zig`](examples/streaming.zig) を参照してください。

CLI でストリーミング中のピーク RSS を測定すると、ストリーミングの契約が裏付けられます。
**100k 行、1M 行、5M 行のいずれもピークは 2.8 MB です。**
データ量が 50 倍になってもメモリは増えません。一度に常駐するのが
1つの FETCH バッチだけだからです。

本ライブラリにおいて、測定なしに行われた最適化はありません。測定方法の全体、
ベンチマークごとの分析、性能上の落とし穴、そして*測定していない*ことの明示は
[性能](docs/ja/PERFORMANCE.md) にあります。

## テスト

```sh
zig build test                  # 227 テスト、約10秒、サーバ不要
zig build test-integration      # 29 テスト、稼働中の quack_serve() に対して実行
zig build test-wasm             # WASM FFI 境界 (node が必要)
zig build bench
zig build check -Dtarget=...    # 任意ターゲットへのライブラリのみのビルド

python3 scripts/mutation_test.py            # テストが実際に破壊を捕まえるかを検証
python3 scripts/mutation_test.py -k params  # 特定領域のみ
python3 scripts/mutation_test.py --list     # ミュータント一覧
```

クライアントは6層で覆われています。**単体テスト** (プリミティブ、境界値、不正入力、
URI 検証、パラメータエスケープ、マルチスレッド競合テストを含むプール機構)、
実サーバから採取した実ペイロードを再生し、デコード結果*および*全バイトが消費される
ことを検証する**ゴールデンテスト**、実サーバが決して送らない敵対的な構造から
組み立てた**デコーダ防御テスト**、モックトランスポート上の**クライアントテスト**、
切り詰め・破損・敵対的入力を約 25,000 回デコードする**ファズテスト**、
そしてサーバが到達できない場合は失敗ではなくスキップする、稼働サーバに対する
**統合テスト**です。

フィクスチャは [`scripts/capture_fixtures.py`](scripts/capture_fixtures.py) が
採取します。このスクリプトはプロトコルを Python で独立に実装しているため、
フィクスチャは Zig コード自身の出力の録音ではなく、真の相互検証として機能します。

テストスイート自体は**ミューテーションテスト (mutation testing)**
([`scripts/mutation_test.py`](scripts/mutation_test.py)) によって検証されています。
安全ガードを1つずつ取り除き、テストが失敗することを確認します。
ミュータントが*生き残った* (survive) ガードには、CI が緑であってもそれを
カバーするテストが存在しないということです。カタログには 51 個のミュータントがあり、
すべての境界検査、すべてのインジェクションエスケープ規則、プロトコルバージョン範囲、
FETCH 上限、プールのロックを網羅します。CI で実行され、予期しない生存者が出れば
ビルドを失敗させます。文書化された `EXPECTED_SURVIVORS` の項目が1つ
(`pool/deinit-waits-for-leases`) あり、これは未定義動作に依存しなければ
観測できないものです。その理由はスクリプト内に記録されており、
黙って合格扱いにはしていません。

テストスイートの速度について。ミューテーションテストはミュータントごとに
スイート全体を1回実行するため、ファズスイートは Debug ではなく **ReleaseSafe** で
ビルドされています。約 25,000 回の変異入力のデコードを行い、Debug では約 14 秒、
最適化時は約 0.2 秒です。この約 680 倍の差は、処理量ではなくアロケータの
簿記処理とインライン化の欠如によるものです。ReleaseSafe はファジングが依拠する
検査 (境界、オーバーフロー、`unreachable`) をすべて維持しており、
これは元の varint オーバーフローのバグを再導入して依然 panic することを
確認して検証済みです。`-Dfuzz-optimize=Debug` で上書きできます。

このプロセスは、緑のテスト結果が隠していた実際の欠陥を発見し修正しました。

| 欠陥 | 本番でどう失敗していたか |
|---|---|
| 無制限の FETCH ループ | 空バッチを送らないサーバがクライアントを永久にハングさせる |
| プールの use-after-free | リース貸し出し中にプールを閉じると使用中の接続が解放される |
| 新クエリで結果が無効化されない | 古い結果が黙って*次の*クエリの行をストリームする |
| varint のシフトオーバーフロー | 不正な長さ前置値がエラーではなく panic を起こす |
| 入れ子型のエラー経路でのリーク | 不正な STRUCT/LIST 応答がメモリをリークする |
| バージョン下限チェックの欠落 | サポート範囲を下回るサーバが受理される |

ミューテーションテストはミュータントごとにスイート全体を実行するため低速です。
その理由と実行範囲を絞る方法は [テスト](docs/ja/TESTING.md) で説明しています。

新しい DuckDB に対してフィクスチャを再生成するには
`python3 scripts/capture_fixtures.py` を実行します。

## バルク挿入

`APPEND_REQUEST` は INSERT 文ではなく DataChunk 全体を送ります。

```zig
const ids = [_]quackling.Value{ .{ .integer = 1 }, .{ .integer = 2 } };
const names = [_]quackling.Value{ .{ .varchar = "a" }, .null };
try client.append("events", &.{
    .{ .type = .{ .id = .integer }, .values = &ids },
    .{ .type = .{ .id = .varchar }, .values = &names },
});
```

同一サーバに対して1行ごとのパラメータ付き INSERT と比較した実測値:
**20,480 行を 10 ms (1.97M rows/s、10 リクエスト) 対 3,821 ms
(5.4k rows/s、20,480 リクエスト) — 約 370 倍。** データは既に型付けされているため
SQL の解析が不要で、1リクエストがチャンク全体を運びます。値はバイナリで送られるので、
この経路では SQL エスケープが一切発生しません。

エンコーダ (`serialization/encoder.zig`) はデコーダの鏡像であり、そのテストは
出力したものが同一にデコードし直せることを検証します。これが両者の乖離を防いでいます。

## ロードマップ

- 非同期 I/O: `Transport` インタフェースと `std.Io` の接合部は既に用意済み
- プールされた接続をまたぐ並行 FETCH
- Arrow 相互運用 / Arrow IPC 出力 (`web/` からは意図的に除外: `apache-arrow` は
  約 8 MB あり、当パッケージは依存ゼロを維持している)
- サーバ側プリペアドステートメントと明示的トランザクション
- 対話型 CLI シェル
- Akamata アダプタ (別パッケージとして) — transport アダプタと `am.db.Db` シムは
  実物の Akamata に対して **構築・検証済み** (Cloudflare Workers 含む)。残るのは
  パッケージングのみ。[docs/ja/AKAMATA.md](docs/ja/AKAMATA.md) 参照

## 設計上の制約

このコードベースを形作った2つの規則は、明示しておく価値があります。

1. **コアライブラリは自分より上の層に依存しない。** CLI、WASM、フレームワークの
   関心事が `src/protocol`、`src/serialization`、`src/types` に入り込むことはありません。
   Akamata (およびその他のもの) は本ライブラリの*利用者*になれますが、
   本ライブラリがそれらの利用者になることはありません。
2. **信頼できないバイト列は信頼できないものとして扱う。** デコーダは値か
   型付きエラーのいずれかを返します。推測はせず、ワイヤデータを
   ネイティブの構造体として再解釈することもありません。

## ライセンス

MIT
