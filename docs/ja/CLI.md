# quackling — コマンドラインリファレンス

[English](../en/CLI.md) · **日本語**

→ [ドキュメント目次](./README.md)

`quackling` は Quackling ライブラリの薄い利用者 (consumer) です。引数を解析し、
接続を 1 本開き、クエリを 1 本実行し、結果を整形します。その挙動はすべて
[`../../src/cli/main.zig`](../../src/cli/main.zig) に収まっています。

```sh
zig build                       # -> zig-out/bin/quackling
zig build run -- --help         # ビルドシステム経由で実行する場合
```

---

## 1. 書式

```
quackling [options] "<SQL>"
quackling [options] < query.sql
```

インストーラは同じバイナリへの別名として `qkl` も PATH に配置します。本ドキュメ
ントのすべての例は、どちらの名前でも同じように動作します。

```sh
qkl "SELECT 42"                 # `quackling "SELECT 42"` と同一
```

Unix では symlink、Windows では copy として配置します (Windows の symlink には
開発者モードまたは管理者権限が必要なため)。`--version` はどちらの名前で起動して
も正式名 (`quackling 0.1.0`) を出力するので、スクリプト側は 1 つの文字列だけを
解析すれば済みます。別名が不要な場合はインストーラに `--no-alias` を渡してくだ
さい。

SQL は `--` で始まらない最初の引数です。複数与えた場合は最後のものが有効になり
ます (パーサーは裸の引数ごとに `args.sql = a` を代入します)。ひとつも与えなけれ
ば標準入力 (stdin) から読み込みます。

---

## 2. フラグ一覧

以下のすべてのフラグは
[`../../src/cli/main.zig`](../../src/cli/main.zig) の `parseArgs` で解析されま
す。`-h` 以外の短縮形はなく、`--flag=value` 形式もサポートされません (値は常に
argv の**次の**要素です)。否定形もありません。

| Flag | Argument | Default | Meaning |
|---|---|---|---|
| `--url <endpoint>` | required | `quack:localhost:9494` | サーバーのエンドポイント。`quack:host[:port]`、`quack://host`、`http://host[:port]`、`https://host[:port]` を受け付けます。 |
| `--token <token>` | required | `""` (空) | 認証トークン。プロトコル本体 (body) の内部に入れて送られます。 |
| `--format <fmt>` | required | `table` | `table`、`csv`、`json`、`ndjson`、`markdown` のいずれか。それ以外は `error.UnknownFormat` になります。 |
| `--max-rows <n>` | required | 未設定 (全行) | `n` 行で打ち切ります。10 進の `u64` として解析され、数値でなければ解析エラーです。 |
| `--timing` | none | off | 結果の後に行数と実測経過時間を表示します。 |
| `--stats` | none | off | 結果の後に接続の `Stats` カウンターを表示します。 |
| `-h`, `--help` | none | off | 使用法を**標準出力 (stdout)** に表示して `0` で終了します。 |

既定値は `Args` 構造体に由来します。

```zig
const Args = struct {
    url: []const u8 = "quack:localhost:9494",
    token: []const u8 = "",
    sql: ?[]const u8 = null,
    format: Format = .table,
    timing: bool = false,
    stats: bool = false,
    help: bool = false,
    max_rows: ?u64 = null,
};
```

`--` で始まる未知の引数は黙って無視されるのではなく `error.UnknownOption` として
拒否されます。値を必要とするフラグが argv の末尾にある場合は `error.MissingValue`
になります。どちらもインラインテスト
`"unknown format and option are rejected"` で検証されています。

### エンドポイントの形式

解析は [`../../src/uri.zig`](../../src/uri.zig) にあり、プロトコル定数は
[`../../src/protocol/compat.zig`](../../src/protocol/compat.zig) にあります
(`default_port = 9494`、`http_path = "/quack"`、
`content_type = "application/vnd.duckdb"`)。

| `--url` value | Resolves to |
|---|---|
| `quack:localhost` | `http://localhost:9494/quack` |
| `quack:localhost:9494` | `http://localhost:9494/quack` |
| `quack:myhost:9000` | `http://myhost:9000/quack` |
| `quack://localhost` | `http://localhost:9494/quack` |
| `http://localhost:9494` | `http://localhost:9494/quack` |
| `https://db.example.com` | `https://db.example.com:9494/quack` |

指定したパス・クエリ・フラグメントは破棄されます。プロトコルがパスを `/quack`
に固定しているためです。埋め込み資格情報 (`user@host`) や制御文字を含むエンド
ポイントは、黙って書き換えられるのではなく拒否されます。

---

## 3. `QUACK_TOKEN` 環境変数

> **未検証 / 未実装。** `--help` が表示する使用法テキストにはこう書かれています。
>
> ```
> The token may also be supplied via the QUACK_TOKEN environment variable.
> ```
>
> しかし**この変数を読むコードは存在しません**。`parseArgs` は環境変数を一切参照
> せず、リポジトリ内の他の場所にも `QUACK_TOKEN` への参照はありません (この文字列
> は使用法リテラルの中にだけ現れます)。稼働中のサーバーに対する実測結果:
>
> ```console
> $ QUACK_TOKEN=super_secret quackling "SELECT 42 AS answer"
> connection failed: Authentication failed
> $ echo $?
> 1
> ```
>
> このヘルプテキストは機能ではなく願望として扱ってください。実装されるまでは
> `--token` がトークンを渡す唯一の手段です。

この「文書化されているが存在しない」機能の動機自体は述べておく価値があります。
今日どうトークンを渡すべきかを左右するからです。コマンドラインに書いたトークンは
シェル履歴、`ps` の出力、コマンドをエコーする CI ジョブのログに残ります。
`QUACK_TOKEN` が動くようになるまでは、リテラルを履歴に残さない間接化を選んで
ください。

```sh
# Read from a file that is not world-readable; the shell expands it, so the
# token still reaches argv - but it is not stored in history.
quackling --token "$(cat ~/.quack-token)" "SELECT 42"
```

```sh
# In CI, expand a masked secret at call time rather than hardcoding it.
quackling --token "$QUACK_SECRET" --format ndjson "SELECT * FROM metrics"
```

なおこの方法でもトークンはプロセスの argv に現れるため、同一ホストの他プロセス
から `ps` で見えることに注意してください。またトークンは HTTP ヘッダーではなく
プロトコル本体の**内部**を通るため、サーバーの手前で TLS を終端しない限り転送中
は保護されません。[`SERVER_SETUP.md`](./SERVER_SETUP.md) を参照してください。

---

## 4. 出力フォーマット

以下の例はすべて、`quack_serve` を実行している DuckDB v1.5.5 の実サーバーから
取得した実際の出力です。

### `table` (既定)

罫線素片 (box-drawing) による出力で、各列は最も広いセルに合わせて詰められます。

```console
$ quackling --token super_secret "SELECT 42 AS answer"
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

table フォーマッタは列幅を計算するために、整形済み文字列として最大 **1000** 行
(`max_buffered`) をバッファします。それを超えると、確定した列幅のままストリーミ
ングを続けるため、巨大な結果でもメモリは有界に保たれます。ただし最初の 1000 行の
どれよりも広い行が現れると列からあふれ、閉じ罫線が揃わなくなります。5 万行の結果
での実測:

```
│ 49998 │
│ 49999 │
└─────┘
```

大きな結果で整列した出力が必要なら `--max-rows 1000` で制限するか、機械可読な
フォーマットを使ってください。

列の詰め物は表示セル数ではなく UTF-8 の**コードポイント**を数えます
(`displayWidth` は継続バイトでないバイトを数えます)。したがって全角文字や絵文字は
1 セル狭く描かれます。

```console
$ quackling --token super_secret "SELECT 'wörld🦆' AS uni"
┌────────┐
│ uni    │
├────────┤
│ wörld🦆 │
└────────┘
```

列が存在しない結果では `(no columns)` と表示されます。

### `csv`

RFC 4180 準拠の引用符付けです。区切り文字、二重引用符、`\n`、`\r` を含む場合のみ
引用符で囲み、埋め込まれた引用符は二重化されます。**NULL は空フィールドとして
出力されます。**

```console
$ quackling --token super_secret --format csv \
    "SELECT i, i*1.5 AS d, 'text ,quoted' AS s, NULL AS n FROM range(3) t(i)"
i,d,s,n
0,0.0,"text ,quoted",
1,1.5,"text ,quoted",
2,3.0,"text ,quoted",
```

### `json`

オブジェクトの配列 1 個です。数値型は裸の JSON 数値として出力されますが、64 ビット
および 128 ビット整数 (`UBIGINT`、`HUGEINT`、`UHUGEINT`) は JSON が正確に表現でき
ないため**文字列**として出力されます。それ以外 — 日付、タイムスタンプ、10 進数、
すべての入れ子型 (nested type) — は引用符付き文字列になります。NULL は `null` です。

```console
$ quackling --token super_secret --format json \
    "SELECT i, i::VARCHAR AS s, NULL AS n FROM range(2) t(i)"
[
{"i":0,"s":"0","n":null},
{"i":1,"s":"1","n":null}
]
```

```console
$ quackling --token super_secret --format json \
    "SELECT {'a':1} AS s, [1,2] AS l, 9223372036854775807::BIGINT AS big, 18446744073709551615::UBIGINT AS ub"
[
{"s":"{'a': 1}","l":"[1, 2]","big":9223372036854775807,"ub":"18446744073709551615"}
]
```

キーと文字列値はエスケープされます (`"`、`\`、`\n`、`\r`、`\t`、その他の制御バイト
は `\u00XX`)。したがって JSON のように見える値が文書構造を壊すことはありません。
これはインラインテスト `"json output survives a string that looks like json"` と
`"json strings escape control characters and quotes"` で検証されています。

### `ndjson`

1 行 1 オブジェクトで、外側の配列もカンマもありません。`jq`、DuckDB の
`read_json`、ログパイプラインへ流し込むのに適します。

```console
$ quackling --token super_secret --format ndjson \
    "SELECT i, i::DOUBLE AS d FROM range(3) t(i)"
{"i":0,"d":0}
{"i":1,"d":1}
{"i":2,"d":2}
```

### `markdown`

GitHub 形式のパイプ表です。セル区切りの `|` は `\|` にエスケープされるため、値が
表構造を壊すことはありません。

```console
$ quackling --token super_secret --format markdown \
    "SELECT i, 'a|b' AS piped FROM range(2) t(i)"
| i | piped |
| --- | --- |
| 0 | a\|b |
| 1 | a\|b |
```

---

## 5. 値の表現

NULL、入れ子型 (nested type)、ENUM は
[`../../src/cli/main.zig`](../../src/cli/main.zig) の `renderCell` /
`writeNested` が描画し、DuckDB 自身のテキスト形式を踏襲します。以下の出力はすべて
実測値です。

```console
$ quackling --token super_secret \
    "SELECT {'a': 1, 'b': 2} AS s, [10,20,30] AS l, MAP{'a':1,'b':2} AS m, NULL AS n"
┌──────────────────┬──────────────┬────────────┬──────┐
│ s                │ l            │ m          │ n    │
├──────────────────┼──────────────┼────────────┼──────┤
│ {'a': 1, 'b': 2} │ [10, 20, 30] │ {a=1, b=2} │ NULL │
└──────────────────┴──────────────┴────────────┴──────┘
```

| Type | Rendering | Note |
|---|---|---|
| NULL | `table` では `NULL`、`json` では `null`、`csv`/`markdown` では**空** | |
| `STRUCT` | `{'a': 1, 'b': 2}` | フィールド名は引用符付き、区切りは `: ` |
| `LIST` / `ARRAY` | `[10, 20, 30]` | 空リストは `[]` |
| `MAP` | `{a=1, b=2}` | 区切りは `=`、キーは引用符**なし** — STRUCT とは意図的に異なります |
| `UNION` | 有効なメンバーの表現 | STRUCT 分岐より前に解決されます |
| `ENUM` | ラベル (例: `happy`) | 内部の整数値ではありません |

MAP と UNION は STRUCT や LIST より**先**に判定されます。どちらもワイヤー上は物理
的に LIST/STRUCT であるため、この順序でなければユーザーが要求した型ではなく内部
構造が描画されてしまいます。

入れ子は任意の深さまで合成できます。

```console
$ quackling --token super_secret "SELECT [[1,2],[3]] AS nested, {'x': [1,2]} AS sl"
┌───────────────┬───────────────┐
│ nested        │ sl            │
├───────────────┼───────────────┤
│ [[1, 2], [3]] │ {'x': [1, 2]} │
└───────────────┴───────────────┘
```

ENUM のラベルは正しく解決されます。

```console
$ quackling --token super_secret \
    "SELECT 'happy'::ENUM('happy','sad') AS mood, 'sad'::ENUM('happy','sad') AS m2"
┌───────┬─────┐
│ mood  │ m2  │
├───────┼─────┤
│ happy │ sad │
└───────┴─────┘
```

その他のスカラー型:

```console
$ quackling --token super_secret \
    "SELECT NULL::INT AS a, '' AS empty_str, TRUE AS b, DATE '2024-01-15' AS d, 1.25::DECIMAL(10,4) AS dec"
┌──────┬───────────┬──────┬────────────┬────────┐
│ a    │ empty_str │ b    │ d          │ dec    │
├──────┼───────────┼──────┼────────────┼────────┤
│ NULL │           │ true │ 2024-01-15 │ 1.2500 │
└──────┴───────────┴──────┴────────────┴────────┘
```

`csv` と `markdown` では、入れ子の値は構造的に描画されたうえで通常のフィールドと
してエスケープされるため、引用符が付くことがあります。

```console
$ quackling --token super_secret --format csv "SELECT {'a':1} AS s, [1,2] AS l"
s,l
{'a': 1},"[1, 2]"
```

`Value` も構造レンダラーも表現できないスカラー型は、クエリ全体を失敗させる代わりに
`<unsupported>` と表示されます。

---

## 6. 標準入力とファイルからの SQL

SQL 引数が存在しない場合、CLI は標準入力を読み、前後の空白を除去し、空でなければ
それを使用します。入力は **1 MiB** で上限が設けられています。

```console
$ echo "SELECT 42 AS from_stdin" | quackling --token super_secret
┌────────────┐
│ from_stdin │
├────────────┤
│ 42         │
└────────────┘
```

ファイルも同様に動作し、複数行の SQL も問題ありません。

```console
$ cat query.sql
SELECT i, i*i AS sq
FROM range(3) t(i)

$ quackling --token super_secret < query.sql
┌───┬────┐
│ i │ sq │
├───┼────┤
│ 0 │ 0  │
│ 1 │ 1  │
│ 2 │ 4  │
└───┴────┘
```

標準入力は SQL 引数が無いときにのみ参照されるため、明示的な引数が常に優先されま
す。SQL を既に持つコマンドへパイプしても、そのパイプは黙って無視されます。1 回の
起動で送られる文は 1 つだけで、SQL テキストはそのままサーバーへ渡されます。

---

## 7. `--timing` と `--stats`

```console
$ quackling --token super_secret --stats "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘

requests=2 queries=1 fetches=0 chunks=1 rows=1 sent=127B recv=168B errors=0/0/0
```

`--timing` は `connect()` の直前から最後の行の整形直後までを計測するため、接続時の
ハンドシェイク (handshake) を**含みます**。

```
49999 row(s) in 7777.620 ms
```

カウンター行は [`../../src/stats.zig`](../../src/stats.zig) の `Stats.format` が
生成します。

| Counter | Struct field | Meaning |
|---|---|---|
| `requests` | `requests` | CONNECTION ハンドシェイクを含む HTTP 往復回数。1 クエリのセッションでは `2` (connect + prepare)。 |
| `queries` | `queries` | 送信した `PREPARE_REQUEST` メッセージ数 — `query()` 呼び出しごとに 1。 |
| `fetches` | `fetches` | 最初の応答以降に必要となった `FETCH_REQUEST` 往復回数。結果全体が `PREPARE_RESPONSE` に収まれば `0`。 |
| `chunks` | `chunks_received` | デコードした DataChunk 数。サーバーは 1 応答あたり最大 `quack_fetch_batch_chunks` 個 (既定 12) をまとめます。 |
| `rows` | `rows_received` | デコードした全チャンクの行数。`--max-rows` で出力を早く止めた場合、表示した行数より多くなり得ます。 |
| `sent` | `bytes_sent` | 全メッセージを合計したリクエスト本体のバイト数。 |
| `recv` | `bytes_received` | 全メッセージを合計したレスポンス本体のバイト数。 |
| `errors=a/b/c` | `server_errors` / `transport_errors` / `protocol_errors` | エラーの三つ組。順序はこの通りです。 |

この三つ組は「**誰が**失敗したか」を区別します。

- **`server_errors`** — サーバーが `ERROR_RESPONSE` を返した。リクエストは理解され
  たうえで拒否された場合です。不正な SQL、存在しないテーブル、認証失敗など。
- **`transport_errors`** — HTTP 往復そのものが失敗した。接続拒否、タイムアウト、
  2xx 以外のステータスなど。
- **`protocol_errors`** — 応答は届いたがデコードできなかった、あるいは期待した
  メッセージ型でなかった。真にクライアント/サーバー間の不整合を示すもので、報告
  する価値があるのはこれです。

正常な実行では `errors=0/0/0` になります。カウンターは結果の**後**に表示されるた
め、失敗したクエリはそこへ到達する前に終了します。`--stats` が見せるのは、出力を
生成できるところまで到達したセッションの状態です。

5 万行の例の読み方: `requests=5` は connect 1 + prepare 1 + fetch 3 です。
`chunks=25` が 5 万行に対応しているのは、サーバーが `PREPARE_RESPONSE` で 12
チャンクを送り、残りを 3 回の FETCH バッチで送ったことを意味します。

---

## 8. 終了コードとエラー出力

診断メッセージはすべて**標準エラー出力 (stderr)** へ、結果のみが標準出力へ送られ
ます。したがって標準出力をリダイレクトすれば純粋なデータが得られます。

| Code | Condition | Message |
|---|---|---|
| `0` | 成功、または `--help` | — |
| `1` | 接続失敗、クエリ失敗、整形/IO エラー | `connection failed: …`、サーバー自身のテキスト、または `error: <Name>` |
| `2` | 引数解析の失敗、または SQL が与えられなかった | `error: <ErrorName>` に続いて使用法テキスト全文 |

実測した挙動:

```console
$ quackling --token wrong "SELECT 42"
connection failed: Authentication failed
$ echo $?
1
```

```console
$ quackling --token super_secret --url quack:localhost:9999 "SELECT 42"
connection failed: ConnectionFailed (quack:localhost:9999)
$ echo $?
1
```

```console
$ quackling --token super_secret "SELECT * FROM no_such_table"
Table with name no_such_table does not exist!
Did you mean "pg_tables"?

LINE 1: SELECT * FROM no_such_table
                      ^
$ echo $?
1
```

```console
$ quackling --format xml "SELECT 1"
error: UnknownFormat

quackling - query a remote DuckDB over the Quack protocol
… (full usage)
$ echo $?
2
```

```console
$ quackling --token super_secret < /dev/null
error: no SQL provided

… (full usage)
$ echo $?
2
```

2 つの失敗経路の形に注目してください。サーバーがメッセージを返した場合、CLI は
**サーバー自身の言葉**だけを表示します。クエリ失敗では DuckDB のエラーがそのまま、
`error:` の接頭辞なしで出力されるため、`duckdb` CLI のエラーのように読めます。
サーバーが何も言わなかった場合にのみ Zig のエラー名にフォールバックし、接続失敗
では実際に試した URL が分かるようエンドポイントを添えます。これらのどの経路でも
トークンがエコーされることはありません。

`--help` は標準出力へ書き出して `0` で終了するため `quackling --help | less` が
機能します。**エラー**の一部として表示される使用法は標準エラー出力へ送られ、終了
コードは `2` です。

---

## 9. レイヤリング

[`../../src/cli/main.zig`](../../src/cli/main.zig) のモジュール docstring が、この
ファイルが従う規則を述べています。

> Everything here is presentation and argument handling. No protocol logic
> lives in this file, and nothing in the core library knows the CLI exists.

具体的には、CLI 固有の挙動は `src/cli/` に**完全に**閉じており、ライブラリ側へ
漏れ出しません。

- 整形 (`table`、`csv`、`json`、`ndjson`、`markdown`)、エスケープ、列幅計算、
  入れ子型のテキスト描画は `src/cli/main.zig` にのみ存在します。ライブラリが公開
  するのは `DataChunk`、`Vector`、`Value` であり、それをテキストにするのは CLI の
  仕事です。
- [`../../build.zig`](../../build.zig) は `quackling` を、`quackling` モジュールを
  *import する*独立した実行可能ファイルとしてビルドします。ライブラリが CLI を
  import することはありません。CLI ターゲットは `NativeTransport` を必要とするため
  wasm ターゲットでは完全にスキップされますが、ライブラリはそこでもビルドできます
  (`zig build check`)。
- CLI 自身のテストは `test` ステップ上の独立したテスト成果物として登録されるため、
  ライブラリに組み込まれることなく実行されます。

実務上の帰結として、`quackling` でできることは同じ API に対する数行の Zig コード
でも可能であり、CLI に出力フォーマットを追加してもライブラリ利用者へ影響を与えられ
ません。最小の等価プログラムは
[`../../examples/query.zig`](../../examples/query.zig)、大きな結果をチャンク単位で
消費する例は [`../../examples/streaming.zig`](../../examples/streaming.zig)、行を
Zig の構造体へ対応付ける例は
[`../../examples/typed_result.zig`](../../examples/typed_result.zig)、束縛パラメータ
付きのコネクションプーリングは
[`../../examples/pooled.zig`](../../examples/pooled.zig) を参照してください。

---

## 10. クロスコンパイル

`quackling` は標準の Zig ターゲットフラグで、ソケットを持つ任意のターゲット向けに
ビルドできます。

```sh
zig build -Dtarget=x86_64-windows          # -> zig-out/bin/quackling.exe
zig build -Dtarget=aarch64-linux-musl      # static, no libc dependency
zig build -Dtarget=x86_64-macos
```

wasm ターゲットでは、ネイティブ HTTP トランスポートが存在しないため CLI は設計上
スキップされます ([`../../build.zig`](../../build.zig) の `target_is_wasm`)。その
ようなターゲットでもプロトコルコアがコンパイルできることを確認するには:

```sh
zig build check -Dtarget=wasm32-wasi       # library only
zig build wasm                             # the browser module
```

ブラウザ向けビルドは [`WASM.md`](./WASM.md)、`--url` の向き先となるサーバーの構築は
[`SERVER_SETUP.md`](./SERVER_SETUP.md) を参照してください。
