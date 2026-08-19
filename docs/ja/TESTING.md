# Testing

[English](../en/TESTING.md) · **日本語**
→ [ドキュメント目次](./README.md)

Quackling はプロトコルクライアント (protocol client) である。つまり他者が生成した
バイト列を消費し、しかもまだベータ版であるプロトコルの DuckDB リリースをまたいで
動作し続けることが期待されている。ここから 2 つの帰結が導かれ、それがテスト戦略
全体を規定している。

1. 正しさは自前のエンコーダ (encoder) に対するテストでは確立できない。真の基準
   (ground truth) は実サーバから、しかもこのコードベース以外のものによって取得され
   なければならない。
2. テストが緑であることは、テストが*実行された*ことを証明するだけである。境界検査
   (bounds check) が消えたときにテストが気づくかどうかは証明しない。その問いには
   ミューテーションテスト (mutation testing) が別途答える。

以下の内容はすべて現在のツリーで実測したものである。テスト数は
`zig build test --summary all` の出力、時間は Apple aarch64 上の実時間である。

## 目次

- [スイート全体像](#スイート全体像)
- [レイヤ 1 — ユニットテスト](#レイヤ-1--ユニットテスト)
- [レイヤ 2 — ゴールデンテスト](#レイヤ-2--ゴールデンテスト)
- [レイヤ 3 — デコーダガードテスト](#レイヤ-3--デコーダガードテスト)
- [レイヤ 4 — クライアントテスト](#レイヤ-4--クライアントテスト)
- [レイヤ 5 — ファズテスト](#レイヤ-5--ファズテスト)
- [レイヤ 6 — 統合テストと WASM 境界テスト](#レイヤ-6--統合テストと-wasm-境界テスト)
- [ミューテーションテスト: メタレイヤ](#ミューテーションテスト-メタレイヤ)
- [スイートの実行](#スイートの実行)
- [ミューテーションテストのコスト](#ミューテーションテストのコスト)
- [ゴールデンフィクスチャの再生成](#ゴールデンフィクスチャの再生成)
- [適切なレイヤへのテスト追加](#適切なレイヤへのテスト追加)

## スイート全体像

`zig build test` は単一のステップで、[`../../build.zig`](../../build.zig) に配線され
た 6 つの独立したテストバイナリを実行する。

| # | レイヤ | バイナリ / ルート | テスト数 | サーバ要否 | `zig build test` に含まれるか |
|---|---|---|---|---|---|
| 1 | ユニット | `lib_tests` — `src/root.zig` | 122 | 不要 | 含まれる |
| 2 | ゴールデン | `golden` — `tests/golden_test.zig` | 31 | 不要 | 含まれる |
| 1 | ユニット (CLI) | `cli_tests` — `src/cli/main.zig` | 9 | 不要 | 含まれる (非 wasm のみ) |
| 3 | デコーダガード | `decoder_tests` — `tests/decoder_test.zig` | 21 | 不要 | 含まれる |
| 4 | クライアント / モック | `client_tests` — `tests/client_test.zig` | 37 | 不要 | 含まれる |
| 5 | ファズ | `fuzz_tests` — `tests/fuzz_test.zig` | 7 | 不要 | 含まれる (ReleaseSafe) |
| 6 | 統合 | `tests/integration_test.zig` | 29 | **必要** (無ければスキップ) | 含まれない — `test-integration` |
| 6 | WASM 境界 | `tests/wasm/boundary_test.mjs` | スクリプト 1 本 | 不要 (node が必要) | 含まれない — `test-wasm` |

`zig build test` は 14 ステップにわたって **227/227 tests passed** を報告し、キャッシュ
が温まった状態で約 **7.7 秒** かかる。29 個の統合テストは意図的にデフォルトステップ
から外されている ([`../../build.zig`](../../build.zig) のコメント: *"Kept off the
default `test` step so CI without a server stays green"*)。そのためリポジトリ内の
`test` ブロックの総数は 256 だが、デフォルトで実行されるのはそのうち 227 である。

モジュール別のユニットテスト分布 (見当をつけるため):

| モジュール | テスト数 | モジュール | テスト数 |
|---|---:|---|---:|
| `src/pool.zig` | 16 | `src/typed.zig` | 5 |
| `src/params.zig` | 13 | `src/types/validity.zig` | 4 |
| `src/types/vector.zig` | 12 | `src/types/logical_type.zig` | 4 |
| `src/serialization/reader.zig` | 12 | `src/transport/transport.zig` | 4 |
| `src/cli/main.zig` | 9 | `src/stats.zig` | 3 |
| `src/uri.zig` | 7 | `src/types/data_chunk.zig` | 2 |
| `src/serialization/writer.zig` | 7 | `src/transport/native.zig` | 2 |
| `src/protocol/message.zig` | 7 | `src/protocol/compat.zig` | 2 |
| `src/types/value.zig` | 5 | `src/error.zig` | 2 |

## レイヤ 1 — ユニットテスト

対象コードのすぐ隣に置かれたインライン (inline) の `test` ブロック。
`src/root.zig` の末尾には `std.testing.refAllDecls` を呼び、さらに全モジュールを
明示的に `_ = @import(...)` する `test` ブロックがある。そこへ配線せずにモジュール
を追加すると、そのテストは黙って一切実行されなくなる。ファイルを追加したときは
このリストを確認すること。

**何を証明するか。** 各プリミティブ (primitive) が単体で仕様どおりに振る舞うこと。
可変長整数 (varint) のエンコード/デコードの往復と境界値、文字列と BLOB の長さ処理、
有効性マスク (validity mask) のビット意味論、論理型 (logical type) のマッピング、値の
書式化、URI の解析と拒否、パラメータのエスケープ、プールの機構 (マルチスレッドの
競合テストおよび「同時に 2 者へ貸し出されない」テストを含む)、統計情報の集計、そして
CLI の引数解析・CSV/JSON エスケープ・列幅計算。

**何を証明できないか。** ワイヤフォーマット (wire format) に関することは何も証明でき
ない。ここでの入力はすべて自分たちが書いたものであり、ユニットテストは構成上、自分
たちのプロトコル理解と一致するだけである。また各部品がセッションとしてどう組み合わ
さるかについても何も証明しない。

**実行方法。** `zig build test` (全レイヤ)。上の表からどのバイナリに含まれるかが分かる。

**コスト。** 122 テストで約 63 ms、加えて CLI の 9 テストで約 17 ms。実質無料。

## レイヤ 2 — ゴールデンテスト

[`../../tests/golden_test.zig`](../../tests/golden_test.zig) — [`../../tests/fixtures/`](../../tests/fixtures/)
の `.bin` フィクスチャ (fixture) を対象とした 31 テスト。

フィクスチャは、`quack` 拡張を読み込んだ DuckDB v1.5.5 上で稼働する
`CALL quack_serve('quack:localhost:9494', token => 'super_secret')` から平文 HTTP 経由
で取得した実レスポンスのペイロードである。クエリ由来のフィクスチャが 29 個、加えて
`connection_response.bin` があり、合計 45,173 バイト。
[`../../tests/fixtures/manifest.json`](../../tests/fixtures/manifest.json) には各
フィクスチャの生成 SQL、レスポンスのメッセージ型、正確なバイト長が記録されている。
`@embedFile` されているためこれらのテストはファイルシステムを必要とせず、wasm 上でも
そのまま動く。

**このレイヤに価値がある決定的な理由:** フィクスチャは
[`../../scripts/capture_fixtures.py`](../../scripts/capture_fixtures.py) で取得されて
いる。このスクリプトは Quackling を一切介さず、Python で Quack プロトコル*自体*を
実装している — 独自の varint ライタ、独自の field-id フレーミング、ハンドシェイク応答
用の独自リーダを持つ。スクリプトの docstring より:

> This script speaks the protocol directly (no Quackling involved) so that the
> fixtures stay an *independent* check on the Zig implementation rather than a
> recording of its own behaviour.

これが回帰テスト (regression test) と適合性テスト (conformance test) の違いである。
もし Quackling 自身のデコーダ入力をダンプしてフィクスチャを作っていたなら、それは
現在の挙動 — 現在の誤解も含めて — を固定するだけになる。独立に取得されているため、
Zig デコーダとフィクスチャの不一致は「どちらかが DuckDB について間違っている」こと
を意味する。上流がフォーマットを変えたときに欲しいのは、まさにこのシグナルである。

**何を証明するか。** デコーダが実バイト列を正しく読むこと。各テストはデコード結果の
値 (42 は 42 であること、`'wörld🦆'` が UTF-8 として保たれること、HUGEINT が 128 ビット
の全域を運ぶこと、DECIMAL が格納幅をまたいでスケールを保つこと、UUID が正規テキスト形
で往復すること、ENUM がラベルへ解決されること、STRUCT/LIST/ARRAY/MAP/UNION/VARIANT が
子要素を公開すること) を検証し、**さらに**その後リーダがバッファ終端に到達している
こと — 全バイトが消費され、何も飛ばされていないこと — を検証する。末尾のフィールドを
誤って無視するデコーダは、値の検証は通るがバイト消費の検証で落ちる。1 つのテストは
テスト用アロケータ (allocator) で全フィクスチャをデコードしてリーク (leak) を検出し、
1 つは同一フィクスチャ上でゼロコピー (zero-copy) のスライス経路 (`asSlice`) と値ごとの
デコードを相互検証する。

**何を証明できないか。** 実サーバが生成しない入力については何も証明できない。正しく
振る舞うサーバは辞書の終端を超える辞書インデックスを送らないので、どのフィクスチャも
その境界検査に到達しない。その空白はレイヤ 3 の担当である。また*将来の* DuckDB につい
ても何も証明しない — それを行えるのは再取得だけである。

**実行方法。** `zig build test`。

**コスト。** 31 テストで約 28 ms。真のコストは保守側にある。新しい DuckDB リリースに
対してフィクスチャを再取得する必要があり、それには稼働中のサーバが必要である。

## レイヤ 3 — デコーダガードテスト

[`../../tests/decoder_test.zig`](../../tests/decoder_test.zig) — 21 テスト。

手作りの不正メッセージ群。各テストが 16 進数の山ではなく「記述している
メッセージそのもの」として読めるよう、小さなバイトレベル DSL で組み立てられている。
このレイヤはミューテーションテストが*きっかけで*生まれた。docstring には、スイートが
緑であるにもかかわらず、カバーするテストが全く存在しないガードが 4 つ見つかった
ことが記録されている (有効性マスク、リスト長と残余バイト数の照合、辞書インデックス
の境界、ENUM インデックスの境界)。

対象となる構造には次のものが含まれる。切り詰められた有効性マスク、残余バイト数より
大きいリスト件数、バイト数より多い列数を主張するチャンク、辞書の終端を超える辞書
インデックス、行数より短い選択ベクタ (selection vector)、ラベルリストを超える ENUM
コード、宣言された件数がラベルリストと食い違う ENUM、長さが誤った固定幅ペイロード、
`standard_vector_size` (2048) を超える行数、型数と食い違う列数、行数と異なる件数の
VARCHAR リスト、未知の field id (スキップせず拒否)、FSST ベクタ (推測せず未対応と
して報告)、深さ制限を超える入れ子。同時に正のコントロールも並んでいる — *有効な*
辞書ベクタ、有効な ENUM コード、正直なリスト件数、シーケンスベクタ、定数ベクタ — の
で、何でも拒否するだけのガードでは通らない。

**何を証明するか。** 各境界検査が、その存在理由となる入力を、固有の型付きエラー
(typed error) で正確に拒否し、かつ正当な入力を拒否しないこと。

**何を証明できないか。** 思いついた敵対的形状の集合が網羅的であること。これは手書き
のリストである。誰も思いつかなかった形状はレイヤ 5 が扱う。

**実行方法。** `zig build test`。

**コスト。** 21 テストで約 10 ms。

## レイヤ 4 — クライアントテスト

[`../../tests/client_test.zig`](../../tests/client_test.zig) — `MockTransport` 上での
37 テスト。

モックはネットワークを、スクリプト化されたレスポンス本体のリストで置き換え、送信内容
を記録する。これによりセッション層とストリーミング層が、DuckDB を一切使わずに完全に
カバーされる。さらに実サーバが容易には生成しないレスポンスも作れる — 切り詰められた
本体、誤ったメッセージ型、空バッチ、HTTP 5xx、ストリーム終端を決して通知しないサーバ。
合成レスポンスはライブラリ自身のエンコーダで構築されているが、これが健全なのは
まさにそのエンコーダがゴールデンフィクスチャと `src/protocol/message.zig` の
"connection request encodes the exact bytes the server accepted" テストによって独立
に固定されているからである。

関心事ごとのカバー範囲:

| 関心事 | 代表的な検証 |
|---|---|
| ハンドシェイク | セッション ID とサーバ識別情報が保存される。`connect` は冪等。セッション ID の無い応答は拒否される |
| バージョン交渉 | サポート範囲外のサーバは拒否される。広告したバージョンは受理される |
| エラー分類 | 認証失敗が他のサーバエラーと区別される。認証以外のハンドシェイクエラーは素の `ServerError`。予期しないメッセージ型はプロトコルエラー |
| トランスポート障害 | トランスポートエラーが表面化し計上される。非 2xx は `HttpError` でデコードを試みない。切り詰められた本体はクラッシュではなくデコードエラー。`max_response_bytes` 超過のレスポンスは拒否 |
| 複数バッチ FETCH | ストリーミングが複数の FETCH バッチを完走する。最初のバッチが空なら即座にストリーム終了。枯渇後も `nextChunk` は null を返し続ける。FETCH リクエストが result uuid をそのまま返す |
| ハング耐性 | *"a server that never signals end-of-stream cannot hang the client"* |
| 上書き検出 | 新しいクエリに上書きされた結果は `error.ResultSuperseded` を返す。FAILED なクエリでも未完了の結果を上書きする。完全に読み切った結果は後続クエリの影響を受けない |
| キャンセル | キャンセル済みトークンは送信前にクエリを止める。ストリーム途中のキャンセルは以降のチャンクを止める |
| トークン非漏洩 | トークンは `lastError()`、`client.url`、書式化した `Stats` のいずれにも現れない — そしてハンドシェイク本体には*存在する*ことを積極的に検証する。そこが唯一の正しい在り処だから |
| パラメータ | バインド済みパラメータは置換済みの形でサーバへ届く。パラメータエラーは何も送信する前に発生する |
| 可観測性 | オブザーバ (observer) がリクエストとチャンクのイベントを受け取る。バイトカウンタが双方向を追跡する |

**何を証明するか。** 状態機械 (state machine) が失敗経路を含めて正しいこと。そして
トークン秘匿性が意図にとどまらず強制されていること。

**何を証明できないか。** 実際の DuckDB がモックのスクリプトどおりに振る舞うこと。
モックは我々のサーバモデルであり、そのモデルを検査するのはレイヤ 6 である。

**実行方法。** `zig build test`。

**コスト。** 37 テストで約 71 ms。

## レイヤ 5 — ファズテスト

[`../../tests/fuzz_test.zig`](../../tests/fuzz_test.zig) — 7 テスト。

契約 (contract) をファイルの docstring からそのまま引用する。このレイヤ全体が
この 1 文の主張だからである。

> The decoder is the only component that consumes untrusted bytes, so the
> contract it must uphold is narrow and absolute: **arbitrary input produces
> either a successful decode or a typed error — never a panic, an
> out-of-bounds read, an integer overflow, or unbounded allocation.**

主張されて*いない*ことに注意。変異させた入力が失敗しなければならないとは書かれて
いない。変異後も偶然妥当なメッセージであれば、デコードは成功しうる。この性質は
未定義動作 (undefined behaviour) の不在についてのものであり、判定結果についてのもの
ではない。

コーパス (corpus) は 17 フィクスチャで、再帰的なデコード経路が代表されるよう選ばれて
いる — 平坦なものと並んで `struct`、`list`、`array`、`map`、`map_nested`、`enum`、
`union`、`nested_deep`、`variant` が入っている。不正な長さや深さが最も大きな損害を
与えるのがそこだからである。すべての入力は `decodeUntrusted` を通る。この関数は
ヘッダと本体を含む完全なデコードを、意図的に厳しい制限 (`max_byte_length` 1 MiB、
`max_list_length` 65536、`max_depth` 32) の下で走らせるので、敵対的な長さ指定が
テスト自身を遅くすることはない。さらに成功経路・エラー経路の両方でメモリを解放する
ので、テスト用アロケータのリーク検査がエラー経路の後始末の検証も兼ねる。

docstring が述べる 3 つの戦略:

1. **系統的な切り詰め (truncation)** — 全フィクスチャの全接頭辞、`len` を 0 から全長
   まで。切り詰めは最も頻出する不正入力であり、バッファ終端を踏み越えやすいもので
   もある。
2. **1 バイト破壊 (corruption)** — 全フィクスチャの全バイト位置を
   `0x00, 0x01, 0x7F, 0x80, 0xFF` のそれぞれに置き換える。これで長さ接頭辞、field id、
   型タグを網羅する。
3. **乱数入力と敵対的入力** — 固定シード (`0xDEADBEEF`、ゆえに再現可能) から生成した
   4000 個の擬似乱数バッファ、加えて妥当に見えるヘッダの後ろに置く手作りの敵対的
   本体: 2^32 要素を主張するリスト、2^40 バイトを主張する文字列、
   `standard_vector_size` を超える行数、終端しない varint、場違いな field id、深さ制限
   を突く 40 段の入れ子オブジェクト。

さらに 2 つのテストが、保証が最も強いプリミティブに対して直接検証を行う (過長な
varint が桁溢れで巻き戻らないこと、バッファを超える長さ接頭辞が確保前に失敗すること、
空バッファに対して `readFieldId`/`readByte`/`readF64`/`readHugeInt` が終端エラーを返す
こと)。もう 1 つは `max_depth` 16 に対して 200 段の入れ子 `LogicalType` を流し、再帰が
スタックで死ぬのではなくエラーで終了することを確認する。

合計でおよそ **25,000 回のデコード**/実行となる。最後のテストはカバレッジ誘導
(coverage-guided) のエントリポイントで、通常ビルドでは `std.testing.fuzz` が
決定的な入力 1 つで戻り、`--fuzz` ではループする。

**何を証明するか。** 機械的に生成された広大な空間のどの入力もパニック、境界外アクセス、
桁溢れ、リークを引き起こさないこと。

**何を証明できないか。** その空間の外の入力が安全であること。*妥当な*メッセージの
切り詰めと 1 バイト破壊は妥当入力の近傍を探索するもので、無から深い多フィールドの
敵対的メッセージを構築することはない。それにはカバレッジ誘導ファザ (fuzzer) が道具と
なるが、実際に走らせている間だけ探索する。

**実行方法。** 決定的パスは `zig build test`。同じエントリポイントを Zig のファザに
渡して無制限に探索させるには `zig build test --fuzz`。なお docstring が言及している
`zig build fuzz` ステップは古い記述である — `build.zig` に `fuzz` ステップは存在
しない。`--fuzz` を使うこと。

**コスト。** ReleaseSafe で 7 テストが約 1 秒、ピーク RSS は約 634 MB (40 KB の
`largeresult` フィクスチャに対する切り詰めループが両方を支配する)。桁違いに最も高価な
レイヤであり、`build.zig` がこれを最適化ビルドする理由でもある —
[ミューテーションテストのコスト](#ミューテーションテストのコスト) の注記を参照。

## レイヤ 6 — 統合テストと WASM 境界テスト

### 統合テスト

[`../../tests/integration_test.zig`](../../tests/integration_test.zig) — 稼働中の
サーバに対する 29 テスト。デフォルトの `test` ステップには**含まれない**。

```sh
duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
zig build test-integration
# 別の宛先を指定する場合:
zig build test-integration -Dquack-endpoint=quack:host:9494 -Dquack-token=...
```

エンドポイントとトークンは環境変数ではなく**ビルドオプション**として渡される。
これにより Windows や WASI を含むあらゆるターゲットで同一のコードが同じように動く。

**サーバに到達できないときは失敗ではなくスキップする。** ハーネスは `connect` から
の `ConnectionFailed`、`NetworkError`、`Timeout` を捕捉して `error.SkipZigTest` を返す。
それ以外のエラーは従来どおり失敗となる。これによりサーバがあるかどうか分からない CI
ジョブでもこのファイルを安全に走らせられる — そして同時にこれが留意すべき限界でもある。
サーバ無しでの `test-integration` は緑になるが、何も証明しない。

カバー範囲: ハンドシェイク (セッション ID が正確に 32 バイトであること、交渉された
`quack_version` が 1 であることを含む)、`SELECT 42`、NULL と VARCHAR を含むプリミティブ、
複数行の順序、FETCH 往復をまたぐ大結果のストリーミング、DuckDB 自身のメッセージを運ぶ
サーバエラー、構文エラー、スキーマ付き空結果、型付き struct マッピングと optional
フィールド、DDL/DML、幅広い型、統計情報の集計、不正トークン、
STRUCT/LIST/ARRAY/MAP/ENUM/UNION の往復、入れ子の NULL、型別のバインドパラメータ、
インジェクション耐性、送信前に捕まるパラメータ数不一致、プール接続、キャンセル、
ストリーミングのメモリが結果サイズではなくバッチサイズで抑えられることを検証するテスト、
そしてバルク append の 4 テスト: 単一チャンク、2048 行のフルチャンク、
存在しないテーブルでサーバのエラーが表面化すること、行単位 INSERT とのスループット比較。

**何を証明するか。** 他の 5 レイヤが符号化しているモデルが実際の DuckDB と一致すること。
上流のワイヤフォーマット変更を捕まえるのはこのレイヤである。CI は固定版の DuckDB
(1.4.1) と `latest` の両方に対して実行する。

**何を証明できないか。** サーバが存在しないときは何も。また TLS を通らない — すべて
ループバックへの平文 HTTP で実行される。

**コスト。** DuckDB のバイナリと稼働中のサーバが必要。いくつかのテストは 100,000 行を
動かす。

### WASM FFI 境界テスト

[`../../tests/wasm/boundary_test.mjs`](../../tests/wasm/boundary_test.mjs) — node
スクリプト 1 本、128 行。`zig build test-wasm` から実行される (wasm のインストール
ステップに依存)。

エクスポートされた関数は生のインデックスと長さを JavaScript から直接受け取るので、
ワイヤデコーダと同じ意味で攻撃面 (attack surface) である。すべての引数が信頼できない。
このスクリプトは全エクスポートを範囲外・順序違反・敵対的な引数で呼び出し、何もトラップ
せず、境界外を読まず、モジュールを使用不能にしないこと — それぞれが文書化された
センチネル値を返すこと — を検証する。7 つの段階:

1. クエリ実行前 (`current == null`) の全アクセサ呼び出し。`999999` や `0xFFFFFFF`
   のようなインデックスを使う。
2. connect 前の `quack_build_query` は `-1` を返さねばならない。
3. 過大な入力 (`0x7FFFFFFF` の長さ) が、バッファ溢れではなく長さによって拒否される。
4. 両方のレスポンスデコーダにゴミと切り詰め本体を与える: 空、1 バイト、擬似乱数、
   全 `0xFF`、妥当に見えるヘッダのみの本体。
5. `quack_response_capacity()` を超える宣言長。
6. **重要な事例:** 実際の `select42.bin` フィクスチャを読み込み、
   `quack_get_i64(0,0,0)` が `42n` であることを確認したうえで、17 通りの敵対的インデックス
   組み合わせを叩く。実結果が載っている状態ではアクセサに索引すべきチャンクと列が
   存在するので、境界検査の欠落は早期 null 復帰ではなく現実の境界外読み取りになる。
   返されたポインタは線形メモリ (linear memory) 内に収まらねばならない。
7. `quack_reset()` の後の再利用。

いずれかのプローブがトラップまたは誤動作すれば終了ステータスは非ゼロとなり、CI が
これをゲートにしている。

## ミューテーションテスト: メタレイヤ

[`../../scripts/mutation_test.py`](../../scripts/mutation_test.py)。その docstring に
ある思想:

> A passing test suite only proves the tests *run*; it does not prove they would
> notice if a bounds check disappeared. This script breaks each guard one at a
> time and asserts that `zig build test` fails. A guard whose mutant SURVIVES
> has no covering test, which is a real gap even though CI is green.

### ミュータント (mutant) の適用方法

カタログは `(name, file, original, replacement)` のタプルのリストである。各エントリは
ガードを厳密に **1 つ**だけ除去する。そして置換後もコンパイルが通らなければならない —
ビルドに失敗するミュータントはテストカバレッジについて何も語らない。それがガードを
削除するのではなく `if (false) return Error...` や
`if (cond) {} // detected but allowed` の形で無効化する理由である。

ミュータントごとにスクリプトは次を行う。ファイルを読む。`original` のパターンが無ければ
`INVALID (pattern not found - code moved?)` と報告して次へ進む。あれば
`<name>.zig.mutbak` へコピーし、`in_flight` マップへ登録し、変異後のテキストを書き、
`zig build test` を実行し、`finally` でバックアップを復元する。`zig build test` は
`start_new_session=True` で起動されるため独自のプロセスグループを持つ。`zig build` は
コンパイル済みテストバイナリを孫プロセスとして生成するので、直接の子だけを kill すると
テストバイナリが 100% CPU で永久に回り続ける — ループ境界を除去するミュータントが
生み出すのはまさにこれである。

復元は 3 重に守られている。ミュータントごとの `finally`、そして `SIGINT` (終了コード
130) と `SIGTERM` (終了コード 143) のハンドラである。ハンドラは*先に*稼働中のスイートを
kill し (コンパイラが走っている最中にソースを書き換えないため)、その後 `in_flight` の
全バックアップを戻す。中断された実行がツリーを変異したまま残すことはない。

何かを変異させる前に、スクリプトはスイートを 1 回ベースライン (baseline) として実行し、
緑でなければ続行を拒否する — ベースラインの失敗は以降のすべての判定を無意味にする。
同時にその実行時間を計測し、ミュータントごとのタイムアウトをそこから導出する。

### 3 つの判定

| 判定 | 意味 | 終了ステータスへの影響 |
|---|---|---|
| `CAUGHT` | スイートが失敗した、またはハングしてタイムアウトで kill された。何らかのテストがこのガードに依存している。 | なし — これが目標 |
| `SURVIVED` | ガードを除去してもスイートが通った。カバーするテストが無い。 | **終了コード 1** |
| `INVALID` | パターンが見つからない (コードが移動した)、またはミュータントがコンパイルできない。カバレッジについては何も語らない。カタログの更新が必要。 | なし。ただし報告される |

**ハングは CAUGHT として数える。** スクリプトはその理由を明示している:

> A hang counts as CAUGHT: a guard whose removal makes the suite spin forever is
> unambiguously load-bearing (this is how the unbounded FETCH loop was found).

タイムアウトは固定値ではなく導出値である。`TIMEOUT_FLOOR_S = 45.0` と
`TIMEOUT_MULTIPLIER = 6.0` により、ミュータントごとの上限は
`max(45, 6 × ベースライン)` となる。理由はスクリプト内に書かれている。スイート自身が
速くなると、余裕を持たせた固定上限を待ち切ることが実行全体を支配する — 約 8 秒の
スイートに対して 240 秒の上限は通常のミュータントの 30 倍のコストになる。実測ベース
ラインの小さな倍数でも「遅い」と「終わらない」を十分に区別できる。

### カタログのカバー範囲

10 ファイルにまたがる **51 ミュータント**:

| ファイル | ミュータント数 | 破壊する対象 |
|---|---:|---|
| `src/serialization/decoder.zig` | 10 | ペイロード長の整合、有効性マスクの代入、辞書境界、選択ベクタ長、列数一致、行数上限、VARCHAR 件数一致、ENUM 件数整合、FSST 拒否、未知フィールド拒否 |
| `src/serialization/reader.zig` | 8 | varint 桁溢れ、varint 容量、バイト長上限、長さ対残余、リスト件数上限、リスト件数対残余、`take` 境界、深さ制限 |
| `src/params.zig` | 8 | 引用符エスケープ、文字列リテラルのスキップ、行コメントのスキップ、ブロックコメントのスキップ、個数一致、個数超過、UTF-8 検証、NUL 拒否 |
| `src/client.zig` | 6 | 認証分類、プロトコルバージョン下限、プロトコルバージョン上限、HTTP ステータス、レスポンスサイズ上限、セッション ID 欠落 |
| `src/types/vector.zig` | 5 | ENUM インデックス境界、行境界、`readFixed` 境界、`asSlice` のアラインメント、`asSlice` の長さ |
| `src/pool.zig` | 4 | 相互排他、容量制限、deinit のリース待ち、二重 release ガード |
| `src/result.zig` | 3 | FETCH 上限、空バッチによるストリーム終端、キャンセル検査 |
| `src/uri.zig` | 3 | 埋め込み資格情報、制御文字、ポート 0 |
| `src/types/validity.zig` | 2 | NULL ビットの意味論 (除去ではなく反転)、マスク境界 |
| `src/protocol/message.zig` | 2 | ヘッダの未知フィールド拒否、connection id のデフォルト省略 |

1 つのミュータントは `EXPECTED_SURVIVORS` に入っており、実行を失敗させずに報告される:
`pool/deinit-waits-for-leases`。その除去は決定的には観測できず、スクリプトは黙認する
のではなく論拠を完全に記録している — このガードは `deinit` の後に `lease.client` を
参照する*呼び出し側*を守るものであり、ライブラリ自身の release 経路はシャットダウン中に
client を触らない。よってその不具合を観測するには、呼び出し側での use-after-free
(未定義動作) か、`deinit` を解除するために必要な releaser スレッドと競合するプローブ
のいずれかが必要になる。このリストは意図的に小さく保たれている。「テストが難しい」は
明確に理由として認められず、「未定義動作か競合に頼らずには観測できない」だけが認め
られる。

したがって得点板は「捕捉されねばならない 50 ミュータント + 文書化された想定生存 1」
となる。現状は 50/50 捕捉。*想定外*の生存があれば終了コードは非ゼロとなり CI が落ちる。

このプロセスが実際に見つけた欠陥。いずれもテストが緑の陰に隠れていたものである。

| 欠陥 | 本番でどう失敗したか |
|---|---|
| 無制限の FETCH ループ | 空バッチを送らないサーバがクライアントを永久にハングさせる |
| プールの use-after-free | リースが残っているプールを閉じると使用中の接続が解放される |
| 新クエリで無効化されない結果 | 古い結果が黙って*次の*クエリの行を流す |
| varint のシフト桁溢れ | 不正な長さ接頭辞がエラーではなくパニックを起こす |
| 入れ子型のエラー経路でのリーク | 不正な STRUCT/LIST レスポンスがメモリをリークする |
| 下限バージョン検査の欠落 | サポート範囲を下回るサーバが受理される |

## スイートの実行

[`../../build.zig`](../../build.zig) に定義された全ステップ:

```sh
zig build test                  # 227 tests, six binaries, ~7.7s, no server needed
zig build test-integration      # 29 tests against a live quack_serve() instance
zig build test-wasm             # WASM FFI boundary probe (requires node)
zig build bench                 # decode/encode benchmarks (forces ReleaseFast)
zig build check                 # build the core library only — works on every target
zig build wasm                  # wasm32-freestanding reactor module
zig build examples              # build all four examples
zig build run -- "SELECT 42"    # the CLI
```

有用な変種:

```sh
zig build test --summary all              # per-binary pass counts and timings
zig build test --fuzz                     # coverage-guided fuzzing of the decoder
zig build test -Dfuzz-optimize=Debug      # fuzz suite in Debug (see below)
zig build check -Dtarget=wasm32-freestanding   # any target; the CLI is skipped for wasm
zig build test-integration -Dquack-endpoint=quack:host:9494 -Dquack-token=secret
```

`check` が存在するのは、CLI がソケットを必要とし、ライブラリは必要としないからである。
`src/root.zig` を静的ライブラリとしてビルドするだけなので、x86_64/aarch64 Linux、macOS、
Windows、`wasm32-wasi`、`wasm32-freestanding` にわたってプロトコルコアがネイティブ専用
依存から自由であることを CI が証明できる。

ミューテーションテスト:

```sh
python3 scripts/mutation_test.py            # all 51 mutants, serially
python3 scripts/mutation_test.py --list     # print the catalogue and exit
python3 scripts/mutation_test.py -k params  # only mutants whose name contains "params"
python3 -u scripts/mutation_test.py         # unbuffered — what CI uses
```

`-k` はミュータント名に対する単純な部分文字列一致である。名前は領域で接頭辞付け
されているので (`reader/`、`decoder/`、`params/`、`client/`、`result/`、`pool/`、
`uri/`、`vector/`、`validity/`、`message/`)、そのまま領域フィルタとしても働く。
`--list` は `-k` を尊重するので、`--list -k reader` はその領域の 8 ミュータントと
ファイル名だけを表示する。想定外のミュータントが生存した場合の終了ステータスは非ゼロ
であり、これが CI のゲートを可能にしている。

## ミューテーションテストのコスト

ミューテーションテストはこのリポジトリで圧倒的に最も高価な処理である。このマシンでは
完全実行が **1 時間**規模になる。理由は偶発的ではなく構造的である。

- **ミュータント 1 つにつき `zig build test` を 1 回、厳密に直列で。** 51 ミュータント
  であれば、ベースラインを含めて 52 回のスイート実行となる。同時に 2 つ変異させると
  帰属が曖昧になるので、何もバッチ化されていない。
- **Zig のビルドキャッシュは必然的にミスする。** キャッシュは内容ハッシュで鍵付けされ
  ている。すべてのミュータントは `src/` 配下のファイルを編集するのでハッシュが変わり、
  影響する compilation はやり直しになる。これは調整可能なキャッシュではない — まさに
  正しい動作をしている。
- **1 行の編集で 6 つのテストバイナリが再ビルドされる。** 変異対象のファイルはすべて
  `src/root.zig` から到達可能で、`src/root.zig` は (直接またはインポート経由で)
  `lib_tests`、`golden`、`cli_tests`、`decoder_tests`、`client_tests`、**そして**
  `fuzz_tests` のルートモジュールである。ゆえに `src/serialization/reader.zig` の 1 行を
  触ると 6 つすべてが再コンパイルされる。
- **復元がキャッシュの利益を双方向で破壊する。** 各ミュータントの後にツリーは元の状態
  へ戻されるので、次のミュータントは再び元のハッシュから始まる — 連続するミュータント
  はコンパイル作業を共有できず、直前のミュータントの成果も再利用できない。

このマシンでの実測値: キャッシュが温まった `zig build test` は **7.7 秒**。
`src/params.zig` へコメント 1 行を追記した後の同じコマンドは **71 秒**。ミュータントが
実際に費やすのは、約 8 秒のテストではなく、この約 63 秒の再ビルドである。
51 × 約 71 秒 ≈ 60 分 — ハングを除いて。

そしてハングがある。スイートを無限ループにするミュータントは、kill されて (正しく)
CAUGHT と記録されるまで、ミュータントごとのタイムアウト `max(45, 6 × ベースライン)`
秒を**丸ごと**費やす。既知の候補:

| ミュータント | なぜ回り続けるか |
|---|---|
| `result/fetch-ceiling` | `max_fetches` の上限を除去するので、空バッチを送らないモックサーバから永久に FETCH し続ける |
| `result/empty-batch-terminates` | ストリーム終端シグナルを除去するので、ストリームが終わらない |
| `pool/deinit-waits-for-leases` | シャットダウン待ちを除去する (これは想定生存だが、`deinit` が有界であるのはこの待ちのおかげである) |
| `pool/mutual-exclusion` | プールの状態を守るミューテックスを除去するので、マルチスレッドテストがデッドロックまたはスピンしうる |

緩和策、試す価値の高い順:

1. **開発中は `-k` を使う。** `src/params.zig` を変更したなら
   `python3 scripts/mutation_test.py -k params` を実行する — 51 ではなく 8 ミュータント
   で、おおよそ 12 分の 1 の時間になる。完全実行は CI かリリース前チェックに回す。
2. **ミュータントごとにテストステップを絞る。** `src/uri.zig` のミュータントは
   `fuzz_tests` では捕まえられず、`src/params.zig` のミュータントは `golden` では
   捕まえられない。バイナリ単位のビルドステップ (たとえば `test-lib`、`test-golden`)
   を追加し、カタログの各エントリがどれを実行するか宣言できるようにすれば、ほとんどの
   ミュータントについてコンパイルと実行の両方を削減できる。これは厳密さを少し犠牲に
   する — 誤ったバイナリに絞られたミュータントは誤って SURVIVED と報告される — ので、
   対応付けは保守的でなければならない。
3. **git worktree で並列化する。** 各ミュータントは独立で、触るファイルは厳密に 1 つ
   なので、それぞれ独自の `.zig-cache` を持つ N 個の worktree なら干渉なしに N ミュー
   タントを同時実行できる。利用可能な中で最大の効果があり、コア数に応じてスケールする。
   代償はキャッシュ用のディスク N 倍である。
4. **既知のハング対象だけタイムアウトを短くする。** 上記 4 つはハングすることが分かって
   いる。エントリ単位のタイムアウト上書き (これらには数秒、他は導出上限) を用意すれば、
   他で偽の CAUGHT を招くことなくタイムアウトコストの大半を除去できる。なお現在の導出
   タイムアウトは、以前の固定 240 秒上限から見ればすでに大きな改善である。
5. **スイートを速く保つ。** ファズレイヤの ReleaseSafe ビルドはまさにこのレバーであり、
   理解しておく価値がある。ファズスイートは変異入力に対して約 25,000 回のデコードを
   行い、Debug では約 14 秒、最適化ビルドでは約 0.2 秒かかる — 約 680 倍の差であり、
   作業量ではなくアロケータの帳簿処理とインライン化の不在が原因である。Debug では
   テスト実行全体の約 80% を占めていた。ReleaseSafe はファジングが依拠する検査
   (境界、桁溢れ、`unreachable`) をすべて保持しており、これは元の varint 桁溢れバグを
   再導入して依然パニックすることを確認して検証済みである。外側のビルドが Debug の
   ときは `build.zig` が自動的に選択し、`-Dfuzz-optimize=Debug` で上書きして Debug
   レベルの調査ができる。

## ゴールデンフィクスチャの再生成

新しい DuckDB リリースに対して検証する場合:

```sh
duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
python3 scripts/capture_fixtures.py
```

スクリプトは `localhost:9494` にそのトークンで稼働するサーバを必要とする。どちらも
ハードコードされているので、環境が異なる場合はスクリプトを編集するかポートを転送する。
スクリプトは自前のハンドシェイクを行い、セッション ID を表示し、
`connection_response.bin` を書き、続いて `QUERIES` マップの 29 クエリを順に発行して
生のレスポンスバイト列を `<name>.bin` へ書く。最後に各フィクスチャの SQL、バイト長、
レスポンスのメッセージ型を `manifest.json` へ書き直す。これにより、そのファイルの diff
が上流で何が変わったかの読みやすい要約になる。

その後 `zig build test` を実行する。`.bin` に差分がありテストが緑なら、DuckDB は我々が
許容できる何かを変えたということ。テストが赤なら、まだ扱えていない何かを変えたという
ことである。

**独立性が重要な理由。** このスクリプトはプロトコルを一から実装している — 独自の
ULEB128 ライタ、独自の `<H` field-id フレーミング、独自の終端定数、ハンドシェイク応答
用の独自の最小リーダ。Quackling をインポートも呼び出しもしない。もしこれを Zig
クライアントのラッパ — たとえ薄いものでも — に置き換えれば、フィクスチャは DuckDB に
関する証拠であることをやめ、自分たちの挙動のスナップショットになる。そしてゴールデン
レイヤは適合性テストから回帰テストへ格下げされる。varint エンコーダを重複させる代償を
払ってでも、独立性を保つこと。

次に取得作業を行う人向けの注意 2 点:

- `capture_fixtures.py` はハンドシェイクで*クライアント*バージョン文字列として
  `"v1.4.1"` を広告する。これは `src/protocol/compat.zig` の `client_version_string`
  と一致する。これはクライアントの自己申告であってサーババージョンとは無関係であり、
  現在のフィクスチャは DuckDB v1.5.5 のサーバから取得されている。
- クエリが失敗した場合、スクリプトは `<name> ERR <exception>` を表示して続行し、
  以前の `.bin` をそのまま残したまま、新しい manifest からそのエントリを省く。
  クリーンに完走したと仮定せず、出力の `ERR` 行を確認し、manifest のエントリ数
  (現在 29) を比較すること。

## 適切なレイヤへのテスト追加

その性質を実際に観測できる中で、最も安価なレイヤを選ぶ。

| テストしたいもの | レイヤ | どこに |
|---|---|---|
| 純関数、境界値、エンコード規則 | 1 — ユニット | モジュール内のインライン `test`。新規モジュールなら `src/root.zig` の `_ = @import(...)` リストに追加する |
| 実 DuckDB のペイロードを正しく読むこと、または新たに対応した型 | 2 — ゴールデン | `capture_fixtures.py` に新クエリ + 再取得 + `golden_test.zig` にテスト。値*および* `isAtEnd()` を検証する |
| 実サーバが送らない構造を境界検査が拒否すること | 3 — デコーダガード | `decoder_test.zig`、バイト DSL `B` を使う。正のコントロールも併せて追加する |
| セッション状態、エラー分類、ストリーミング、キャンセル、非漏洩 | 4 — クライアント | `client_test.zig`、モックレスポンスの `Script` を使う |
| *任意の*入力が未定義動作なく処理されること | 5 — ファズ | 通常は `corpus` 配列にフィクスチャを追加するだけ。特定の形状なら `bodies` リストに敵対的本体を追加する |
| 実 DuckDB が我々と一致すること | 6 — 統合 | `integration_test.zig`。`Harness.init` 経由にすればサーバ無しでスキップされる |
| 新しい WASM エクスポート | 6 — WASM | `boundary_test.mjs` のクエリ前段階と実結果ロード段階の両方に敵対的引数のプローブを追加する |

そして追加したものが**ガード** — 境界検査、エスケープ規則、上限、バージョン検査 —
であれば、`scripts/mutation_test.py` の `MUTANTS` に対応するミュータントを追加し、
CAUGHT になることを確認する。

```sh
python3 scripts/mutation_test.py -k your-new-mutant-name
```

ミュータントの無いガードは、誰も「効いている」ことを検証していないガードである。
ミュータントが生存した場合、いま書いたテストは実際にはそのガードに依存していない。
直すべきはカタログではなくテストである。
