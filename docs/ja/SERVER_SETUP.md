# サーバー構築 — 運用ガイド

[English](../en/SERVER_SETUP.md) · **日本語**

→ [ドキュメント目次](./README.md)

Quackling が通信できる DuckDB Quack サーバーを立ち上げる手順です。開発用のローカル
構成と、それ以外の用途で逆プロキシ (reverse proxy) の背後に置く構成を扱います。
本書の内容はすべて `quack` 拡張を入れた DuckDB **v1.5.5** で検証しています。

---

## 1. 前提条件

`quack` 拡張を入れた DuckDB が必要です。依存関係はそれだけです。サーバーは拡張機能
そのものであり、別途インストールするデーモンはありません。

### バージョンに関する事実確認

| Fact | Status |
|---|---|
| `quack` は DuckDB **v1.5.5** で動作する | 本日、ここで検証済み |
| `quack` はプレリリース / 実験的な拡張である | はい — Quack はベータであり、上流は破壊的変更を想定しています |
| DuckDB 2.0 が必要か? | **いいえ。** core リポジトリから v1.5.x にインストールして動作します |
| `duckdb/duckdb-quack` の既定ブランチ | `v1.5-variegata` |
| DuckDB 2.0 ("Cyanoptera") | **2026 年秋に予告されており、未リリース。** Quack はそこで安定版に昇格します |

曖昧さを残さないために明記します。DuckDB 2.0 はリリースとして存在しないため、本書の
内容がそれに依存することはありません。プロトコルは version 1 で、拡張は v1.5.x 上で
今すぐ利用可能です。ただし実験的であり、リリース間でワイヤー形式が変わる可能性がある
という留保が付きます。Quackling はプロトコル version 1 に固定し、その範囲外のサーバー
を推測せず拒否します。[`../../src/protocol/compat.zig`](../../src/protocol/compat.zig)
を参照してください。

ローカルでの実測:

```console
$ duckdb -c "SELECT version();"
┌─────────────┐
│ "version"() │
├─────────────┤
│ v1.5.5      │
└─────────────┘
```

```console
$ duckdb -c "SELECT extension_name, installed, extension_version, installed_from
             FROM duckdb_extensions() WHERE extension_name='quack';"
┌────────────────┬───────────┬───────────────────┬────────────────┐
│ extension_name │ installed │ extension_version │ installed_from │
├────────────────┼───────────┼───────────────────┼────────────────┤
│ quack          │ true      │ c154811           │ core           │
└────────────────┴───────────┴───────────────────┴────────────────┘
```

---

## 2. インストールとロード

```sql
INSTALL quack;
LOAD quack;
```

`INSTALL` は `~/.duckdb/extensions/<version>/<platform>/` への一度だけのダウンロード
で、`LOAD` はセッションごとです。この拡張は**初回使用時に自動インストール/自動ロード
もされる**ため、新しいセッションで `quack_serve(...)` を呼べば通常はどちらの文もなしで
動作します。それでもスクリプトでは明示するほうが優れています。最初の実呼び出し中では
なく予測可能な地点で明確に失敗し、自動ロードが有効かどうかに依存しないからです。

手元の状態を確認します。

```sql
SELECT function_name, function_type FROM duckdb_functions()
WHERE function_name LIKE 'quack%' ORDER BY 1;
```

拡張をロードした v1.5.5 での実際の出力:

```
┌──────────────────────────┬───────────────┐
│      function_name       │ function_type │
├──────────────────────────┼───────────────┤
│ quack_active_connections │ table         │
│ quack_check_token        │ scalar        │
│ quack_clear_cache        │ table         │
│ quack_identify           │ table         │
│ quack_nop_authorization  │ scalar        │
│ quack_query              │ table         │
│ quack_query_by_name      │ table         │
│ quack_serve              │ table         │
│ quack_serve              │ table         │
│ quack_server_list        │ table         │
│ quack_stop               │ table         │
│ quack_uri_parser         │ scalar        │
└──────────────────────────┴───────────────┘
```

この一覧が、あなたのビルドにおける権威ある目録です。本書を含めどの文書も信用せず、
自分で実行してください。

---

## 3. サーバーの起動

```sql
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

返される行 (実測):

```
┌──────────────────────┬───────────────────────┬──────────────┐
│      listen_uri      │      listen_url       │  auth_token  │
├──────────────────────┼───────────────────────┼──────────────┤
│ quack:localhost:9599 │ http://localhost:9599 │ super_secret │
└──────────────────────┴───────────────────────┴──────────────┘
```

| Field | Meaning |
|---|---|
| `listen_uri` | クライアントへ渡す `quack:` URI — `quackling --url` が求めるものそのまま |
| `listen_url` | 解決済みの HTTP URL。`disable_ssl` が効いたかはここのスキームで確認します |
| `auth_token` | 有効なトークン。**`token =>` を渡していない場合はこれが生成されたトークンなので、今すぐ控えてください。**これがないとクライアントは接続できません |

### 引数

`duckdb_functions()` から検証済み:

```
quack_serve(col0 VARCHAR, token VARCHAR, allow_other_hostname BOOLEAN, disable_ssl BOOLEAN)
```

| Argument | Type | Meaning |
|---|---|---|
| 第 1、位置引数 | `VARCHAR` | 待ち受け URI (例 `'quack:localhost:9494'`)。ホスト、ポート、および (`disable_ssl` と併せて) 広告されるスキームを決めます |
| `token` | `VARCHAR` | `CONNECTION_REQUEST.auth_string` と比較される共有秘密。省略すると 128 ビットのランダムな 16 進トークンが生成されます。最低 4 文字 |
| `allow_other_hostname` | `BOOLEAN` | ローカル以外のホスト名への bind を許可します。URI が明らかにローカルでないアドレスを指す場合に必要です |
| `disable_ssl` | `BOOLEAN` | `listen_url` で `https://` ではなく `http://` を広告します。localhost 開発では `true` にします |

URI を取らず名前付き引数のみ (`disable_ssl`、`allow_other_hostname`、`token`) を取る
オーバーロードも存在し、待ち受けアドレスには既定値が使われます。

`disable_ssl => true` は見た目以上に重要です。URI パーサーの既定は SSL 有効です。
実測:

```console
$ duckdb -c "LOAD quack; SELECT quack_uri_parser('quack:localhost', true);"
{'host': localhost, 'port': 9494, 'ipv6': false, 'ssl': true, 'url': 'https://localhost:9494'}
```

つまり素の `quack:localhost` は **`https://`** に解決されます。サーバー自身は TLS を
終端しない (§7) ため、`disable_ssl => true` なしでは、提供できないスキームを広告する
サーバーができてしまい、`listen_url` を信じたクライアントは接続に失敗します。
Quackling 自身のパーサー ([`../../src/uri.zig`](../../src/uri.zig)) は `quack:` を
**http** へ対応付け、TLS には明示的な `https://` を要求するため、
`quackling --url quack:localhost:9494` はいずれの場合も平文 HTTP で通信します。

### URI の形式

| URI | Host | Port | Note |
|---|---|---|---|
| `quack:localhost` | `localhost` | **9494** | `compat.default_port` による既定ポート |
| `quack:localhost:9494` | `localhost` | 9494 | 明示指定、上と等価 |
| `quack:myhost:9000` | `myhost` | 9000 | 既定以外のポート |
| `quack:127.0.0.1` | `127.0.0.1` | 9494 | ループバックのリテラル |
| `quack:[::1]:1234` | `::1` | 1234 | IPv6 — ポートを分離するため角括弧が**必須** |
| `quack://localhost` | `localhost` | 9494 | `quack://` 形式、結果は同じ |

拡張自身のパーサーに対する実測:

```console
$ duckdb -c "LOAD quack; SELECT quack_uri_parser('quack:[::1]:1234', true);"
{'host': '::1', 'port': 1234, 'ipv6': true, 'ssl': true, 'url': 'https://[::1]:1234'}
```

bind するアドレスは重要です。`quack:localhost` はローカルマシンからのみ到達可能で、
開発では望ましい形です。ルーティング可能なアドレスへ bind すると、そのポートへ到達
できるすべてのものにサーバーが露出し、唯一の門はトークンだけになります。そうする前に
§7 と §8 を読んでください。

---

## 4. サーバーを生かし続ける

**`duckdb -c "..."` はコマンドの完了時に終了し、サーバーもプロセスとともに死にます。**
待ち受け処理はそのプロセス内のスレッドであってデーモンではないため、接続を受け付ける
ものは何も残りません。これは、成功したように見える `quack_serve` に何も接続できない、
という混乱を招く最も一般的な原因です。

対処は、プロセスが生き続けるよう標準入力を開いたままにすることです。

### 対話セッション (最も簡単)

```console
$ duckdb
v1.5.5
D LOAD quack;
D CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

端末を開いたままにしてください。`.exit` するか閉じるまでサーバーは動き続けます。ここ
で入力したクエリは同じプロセスを共有するため、作成したテーブルは直ちにクライアントから
見えます。

### 長期稼働のローカル開発サーバー

端末より長生きさせるには、決して閉じないものへ標準入力を繋いだままにします。

```sh
# Persistent database, server stays up until you kill it.
duckdb dev.db <<'EOF' &
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
CREATE TABLE IF NOT EXISTS t AS SELECT i, i*i AS sq FROM range(1000) t(i);
EOF
```

このヒアドキュメント形式は手軽ですが、ヒアドキュメントを読み終えると同時に終了します。
開いたままにするには FIFO を使ってください。おまけに制御チャネルも手に入ります。

```sh
mkfifo /tmp/quack.in
duckdb dev.db < /tmp/quack.in > /tmp/quack.log 2>&1 &
exec 3> /tmp/quack.in          # holds the FIFO open; the server stays up

# Configure the running server by writing SQL into the FIFO.
echo "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);" >&3
echo "CREATE TABLE t AS SELECT i, i*i AS sq FROM range(1000) t(i);" >&3

# Later, shut it down cleanly:
echo ".exit" >&3
exec 3>&-
rm /tmp/quack.in
```

この方法を覚えておく価値があるのは 2 つの性質のためです。プロセスがシェルコマンドより
長生きすること、そしてなお SQL を送れること。つまり**待ち受けているのと同じプロセス内**
でテーブルを作成できます。これは §5 に関わる重要な点です。生成されたトークンを含む
`quack_serve` の出力は `/tmp/quack.log` を確認してください。

制御チャネルなしで開いたままのセッションが欲しいだけなら
`tail -f /dev/null | duckdb dev.db` でも構いませんし、長期運用ならスーパーバイザー
(`systemd`、`launchd`、`tmux`) の下で動かしてください。

テーブルをプロセスと一緒に消したいのでなければ、インメモリではなく**永続的な**
データベースファイル (`duckdb dev.db`) を使ってください。

---

## 5. 運用上の警告: 1 ポートに 1 サーバー

**複数の DuckDB プロセスが同じポートで `quack_serve` を呼ぶと、そのすべてが待ち受け
状態になり得ます。そしてどのプロセスが特定の接続を受け付けるかは非決定的です。**
2 度目の `quack_serve` でエラーは発生せず、ポートは新参者を拒否する形で排他的に保持
されません。

これは仮定の話ではありません。本書を書いたマシンでの実測:

```console
$ lsof -nP -iTCP:9494
COMMAND   PID  USER  FD  TYPE  DEVICE   SIZE/OFF NODE NAME
duckdb   7837  ...   6u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
duckdb  25633  ...   5u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
duckdb  83309  ...   5u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
```

3 つの別々の DuckDB プロセスが、すべて 9494 で待ち受けています。

これが生む症状は、原因を知らなければ本当に不可解です。各プロセスは**自分のカタログ**を
持ちます。あるプロセスでテーブルを作成した場合、そのプロセスが応答したときはクエリが
成功し、別のプロセスが応答したときは*テーブルが見つからない*で失敗します — 同じ SQL、
同じ URL に対して、断続的に。同じ仕組みは、プロセスごとにテーブルの版が異なるときに
古いデータや不整合なデータも生みます。

### 確認

```sh
lsof -nP -iTCP:9494
```

**ちょうど 1 行**であることを期待してください。Linux では
`ss -ltnp 'sport = :9494'` も使えます。

### 対処

```sh
# See who is listening, then stop the extras.
lsof -nP -iTCP:9494 -t | xargs -r kill

# Or, from inside a server session, stop just its own listener:
```
```sql
CALL quack_stop('quack:localhost:9494');
```

そのうえでサーバーをちょうど 1 つ起動し、テーブルは**そのプロセス内で**作成してくださ
い。同じセッションで対話的に行うか、§4 の FIFO 経由で行います。別の `duckdb` 起動が
作成したテーブルは別のカタログにあり、同じデータベースファイルであってもサーバーからは
見えません (そして同一ファイルへの 2 番目の書き込み者はいずれにせよ拒否されます)。

この確認を起動手順の一部にしてください。`quack_serve` の前に `lsof -nP -iTCP:9494` を
実行するのは無償であり、デバッグ作業のまるごと一クラスを消し去ります。

---

## 6. サーバーの停止と状態の確認

以下の関数はすべて v1.5.5 上で実際に呼び出し、出力を読んで検証したものです。この節に
推測は含まれていません。

### `quack_stop(uri)`

```sql
CALL quack_stop('quack:localhost:9599');
```

```
┌───────────────────────────────────────────┐
│                  status                   │
├───────────────────────────────────────────┤
│ Stopped listening on quack:localhost:9599 │
└───────────────────────────────────────────┘
```

シグネチャは `quack_stop(col0 VARCHAR)` — 位置引数の URI 1 つです。**呼び出し元プロセス
が所有する**待ち受けを停止します。他人のサーバーを止める手段ではありません。

> 名前は `quack_stop` です。このビルドに **`rpc_stop` は存在しません** — §2 の完全な
> 一覧が実在するものです。どこかで `rpc_*` という名前を見たなら、それは別バージョンか
> 別の拡張のものです。使う前に `duckdb_functions()` のクエリで確認してください。

### `quack_server_list()`

このプロセスが所有する待ち受けの一覧:

```sql
SELECT * FROM quack_server_list();
```

```
┌──────────────────────┬───────────────────────┬───────────┬────────┬────────────────────┬───────────────┐
│      listen_uri      │      listen_url       │   host    │  port  │ active_connections │     info      │
├──────────────────────┼───────────────────────┼───────────┼────────┼────────────────────┼───────────────┤
│ quack:localhost:9599 │ http://localhost:9599 │ localhost │   9599 │                  0 │ {ipv6=false}  │
└──────────────────────┴───────────────────────┴───────────┴────────┴────────────────────┴───────────────┘
```

列は `listen_uri`、`listen_url`、`host`、`port` (`UINT16`)、`active_connections`
(`UINT64`)、`info` (`MAP(VARCHAR, VARCHAR)`) です。そのプロセスが待ち受けを持たない
場合は 0 行を返します。これはまさに「自分のサーバーが死んだ」と「他人のサーバーが自分の
ポートにいる」を区別する方法です。§5 の `lsof` と組み合わせてください。`lsof` は待ち受け
を示すのに `quack_server_list()` が空なら、その待ち受けは別プロセスのものです。

`quack_stop` が成功した後、`SELECT count(*) FROM quack_server_list()` は `0` を返します
(検証済み)。

### `quack_active_connections()`

```sql
SELECT * FROM quack_active_connections();
```

```
┌───────────┬───────────────┬─────────┬─────────┬──────────────────┐
│ server_id │ connection_id │  query  │  state  │ query_started_at │
├───────────┼───────────────┼─────────┼─────────┼──────────────────┤
└───────────┴───────────────┴─────────┴─────────┴──────────────────┘
```

列は `server_id`、`connection_id`、`query`、`state` (すべて `VARCHAR`) と
`query_started_at` (`TIMESTAMP`) です。`connection_id` はプロトコルのメッセージ
ヘッダー内の id と一致する (実サーバーは 32 文字の大文字 16 進文字列を送ります) ため、
クライアントのセッションとサーバー側の行を対応付けられます。「あのクライアントは実際に
何を実行しているのか」を知るための道具です。

### その他の検証済み関数

関数一覧に存在し、示したシグネチャで*存在すること*のみを検証したものです。詳細な
セマンティクスは**ここでは未検証**です。

| Function | Signature | Notes |
|---|---|---|
| `quack_uri_parser(uri, bool)` | scalar → `STRUCT(host VARCHAR, port USMALLINT, ipv6 BOOLEAN, ssl BOOLEAN, url VARCHAR)` | 直接呼び出しで検証済み。§3 を参照 |
| `quack_check_token(a, b, c)` | scalar `(VARCHAR, VARCHAR, VARCHAR) → BOOLEAN` | 既定の認証コールバック。引数の意味は未検証 |
| `quack_nop_authorization(...)` | scalar | 名前からすべてを許可する認可フックと推測されます。**未検証** |
| `quack_clear_cache()` | table | **未検証** |
| `quack_identify(name, hostname, region, provider, meta)` | table、すべて `VARCHAR` | サーバーの識別メタデータを設定します。シグネチャ以上は未検証 |
| `quack_query(...)`、`quack_query_by_name(...)` | table | クライアント側のクエリ関数。未検証 |

必要な関数がここに無い場合は、推測せず `duckdb_functions()` から実際のシグネチャを
取得してください。

---

## 7. TLS

**DuckDB Quack サーバーは TLS を終端しません。** `quack_serve` に証明書のオプションは
なく、`disable_ssl` は `listen_url` で広告するスキームを変えるだけです。localhost を
超える用途では、手前に逆プロキシ (reverse proxy) を置かなければなりません。

これは任意の強化策ではありません。認証トークンは HTTP ヘッダーではなく**プロトコル
メッセージ本体の内部**を通ります (`CONNECTION_REQUEST.auth_string`)。
[`PROTOCOL.md`](./PROTOCOL.md) §9 を参照してください。平文 HTTP では、新しい接続ごとに
トークンが平文でワイヤーに乗り、すべてのクエリと結果行も同様です。頼れるプロトコル
レベルの暗号化は存在しません。

### 最小構成の nginx 逆プロキシ

```nginx
server {
    listen 443 ssl;
    server_name db.example.com;

    ssl_certificate     /etc/letsencrypt/live/db.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/db.example.com/privkey.pem;

    location /quack {
        proxy_pass http://127.0.0.1:9494/quack;
        proxy_http_version 1.1;

        # The body is a binary protocol message: pass it through untouched.
        proxy_set_header Content-Type $http_content_type;
        proxy_request_buffering off;
        proxy_buffering off;
        client_max_body_size 0;          # no cap on request size
        proxy_read_timeout 300s;         # long queries must not be cut off

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

自明でない行がそれぞれ存在する理由:

- **`proxy_set_header Content-Type $http_content_type`** — クライアントは
  `application/vnd.duckdb` を送り、サーバーはそれを要求します。逐語的に保持してくだ
  さい。
- **`proxy_request_buffering off`** と **`proxy_buffering off`** — 本体はバイナリで
  大きくなり得ます。ストリーミングにすれば結果全体をディスクへバッファすることを避け、
  レイテンシも抑えられます。
- **`client_max_body_size 0`** — nginx の既定 1 MB は、大きな `APPEND` や長い SQL 文を
  413 で拒否してしまいます。
- **`proxy_read_timeout 300s`** — 既定の 60 秒は長時間の分析クエリを途中で打ち切り、
  クライアントには明確なエラーではなく途切れた応答として現れます。
- **内容の変換を行わないこと** — `gzip` の書き換え、`sub_filter`、その他本体に触れる
  ものを有効にしないでください。1 バイト変わればメッセージはデコード不能になります。

Quackling を明示的な `https://` でプロキシへ向けます。

```sh
quackling --url https://db.example.com --token super_secret "SELECT 42"
```

ポートなしの `https://` はポート **9494** に解決されます
([`../../src/uri.zig`](../../src/uri.zig) はスキームに関係なく `default_port` を適用し
ます)。したがって 443 で待ち受けている場合はポートを明記する必要があります。

```sh
quackling --url https://db.example.com:443 --token super_secret "SELECT 42"
```

DuckDB サーバーはループバックのみに bind し (`quack:127.0.0.1:9494`)、平文 HTTP の
ポートを外部から到達不能にして、プロキシを唯一の入口にしてください。

Caddy はより短い等価物です。

```caddy
db.example.com {
    reverse_proxy /quack 127.0.0.1:9494 {
        flush_interval -1
    }
}
```

Caddy は証明書を自動的にプロビジョニングし、本体を無変更で通します。
`flush_interval -1` はレスポンスのバッファリングを無効にします。

---

## 8. 認証

トークンベースであり、それがアクセス制御モデルの全体です。トークンを持つクライアントは、
そのサーバーの DuckDB セッションが実行できるあらゆる SQL を実行できます。プロトコル
レベルにユーザー、ロール、テーブル単位の権限はありません。

```sql
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

実サーバーとプロトコルリファレンスに対して検証した規則:

- トークンは差し替え可能な `quack_authentication_function` を通じて
  `CONNECTION_REQUEST.auth_string` と比較されます。
- 最小長は **4 文字**です。
- `token =>` を省略すると 128 ビットのランダムな 16 進トークンが生成され、`auth_token`
  として返ります。控えなければ接続できません。
- ハンドシェイク (handshake) の失敗は `ERROR_RESPONSE` になり、CLI には次のように届き
  ます。

  ```console
  $ quackling --token wrong "SELECT 42"
  connection failed: Authentication failed
  $ echo $?
  1
  ```

Quackling がトークンをログ出力・表示・エラーメッセージへ含めることはありません。
クライアント側での露出はシェル履歴と `ps` の出力です。[`CLI.md`](./CLI.md) §3 を参照
してください。

### `quack` シークレットによる追加 HTTP ヘッダー

プロトコルに **HTTP 認証ヘッダーは存在しない**ため、独自のヘッダーベースの資格情報を
求めるプロキシやロードバランサーには別の経路が必要です。DuckDB クライアントは
`quack` シークレットの `EXTRA_HTTP_HEADERS` を通じて帯域外 (out-of-band) で供給します。

```sql
CREATE SECRET my_quack (
    TYPE quack,
    TOKEN 'super_secret',
    EXTRA_HTTP_HEADERS MAP {'X-Api-Key': 'proxy-side-credential'}
);
```

v1.5.5 で受理されることを検証済み:

```console
$ duckdb -c "CREATE SECRET tmpq (TYPE quack, TOKEN 'abc',
             EXTRA_HTTP_HEADERS MAP {'X-Api-Key':'k'});
             SELECT name, type FROM duckdb_secrets();"
┌─────────┬─────────┐
│  name   │  type   │
├─────────┼─────────┤
│ tmpq    │ quack   │
└─────────┴─────────┘
```

これは **DuckDB クライアント**がゲートウェイを通じて認証する方法です。ヘッダーは外向き
の接続 (例 `ATTACH 'quack:...'`) に適用され、自分がホストしているサーバーには適用され
ません。明確にすべき帰結が 2 つあります。

- このシークレットを設定しても、*自分のサーバー*がヘッダーを要求するようにはなりません。
  ヘッダーの強制はプロキシの役割です。
- `quackling` に相当するフラグはありません。送るのは `Content-Type` だけなので、独自
  ヘッダーを要求するプロキシに対して現状は認証できません。その経路には DuckDB
  クライアントを使うか、ヘッダー検査を Quackling が到達できる場所で終端してください。

nginx が `X-Api-Key` を検査し、DuckDB がプロトコルトークンを検査する多層構成にすると、
エッジで回転 (rotate) できる門と、ポートへ直接到達しても迂回できない門の両方が得られ
ます。

---

## 9. サーバーの動作確認

3 つの確認で、それぞれ別の層を切り分けます。

**1. 何かが待ち受けているか、そしてそれは Quack エンドポイントか?**

```console
$ curl -s http://localhost:9494/
This is a DuckDB Quack RPC endpoint. Use ATTACH 'quack:...' to connect here.
```

`GET /` は平文のバナーを返し、トークンは不要です。これが得られればプロセスは起動して
到達可能です。接続が拒否される場合は §4 と §5 を参照してください。

**2. CORS は動作するか (ブラウザから接続する場合のみ)?**

```console
$ curl -s -i -X OPTIONS http://localhost:9494/quack
HTTP/1.1 204 No Content
Access-Control-Allow-Headers: *
Access-Control-Allow-Origin: *
Content-Length: 0
Access-Control-Allow-Methods: GET, POST, OPTIONS
```

**3. プロトコルとトークンは端から端まで動作するか?**

```console
$ quackling --token super_secret "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘
```

列名を付けた場合:

```console
$ quackling --token super_secret "SELECT 42 AS answer"
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

`--stats` を付けると往復回数が見え、経路全体を確認できます。

```console
$ quackling --token super_secret --stats "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘

requests=2 queries=1 fetches=0 chunks=1 rows=1 sent=127B recv=168B errors=0/0/0
```

`errors=0/0/0` と `requests=2` (connect + prepare) が健全なセッションです。カウンター
については [`CLI.md`](./CLI.md) §7 を参照してください。

手順 1 は成功するのに手順 3 が *"Authentication failed"* と言う場合、サーバーは正常で
トークンが誤っています。手順 3 が断続的にテーブルを見つけられない場合は、直ちに §5 へ。

---

## 10. 統合テスト

統合テスト一式は稼働中のサーバーを必要とします。DuckDB のない CI が green を保てるよう、
意図的に既定の `test` ステップには**含まれていません**
([`../../build.zig`](../../build.zig))。

```sh
zig build test-integration
```

`build.zig` で検証したオプション名:

| Option | Default | Meaning |
|---|---|---|
| `-Dquack-endpoint=<uri>` | `quack:localhost:9494` | サーバーのエンドポイント |
| `-Dquack-token=<token>` | `super_secret` | 認証トークン |

```sh
zig build test-integration \
  -Dquack-endpoint=quack:localhost:9494 \
  -Dquack-token=super_secret
```

既定値は本書全体で使っている `quack_serve` の呼び出しと一致するため、§4 のローカル開発
サーバーがあれば素の `zig build test-integration` で動作します。これらは**環境変数では
なくビルドオプション**です。Windows や WASI を含むあらゆるターゲットで同じコードが同一
に動くようにするための意図的な選択です。コンパイル時に埋め込まれるため、値を変えると
キャッシュ結果ではなくテストが再実行されます。

**サーバーへ到達できない場合、テストはスキップされます。** `ConnectionFailed` または
`NetworkError` で失敗した接続は、失敗ではなく `error.SkipZigTest` を返します。したがって
何も待ち受けていない状態で一式を実行するとスキップが報告され、赤くはなりません。CI では
便利ですが、ローカルでは罠です。「成功した」実行が何もテストしていない可能性があります。
まず §9 で確認し、全部スキップされる一式はセットアップの問題として扱ってください。

### ゴールデンフィクスチャの再生成

`tests/fixtures/` のフィクスチャは実サーバーから採取したワイヤーバイト列であり、
プロトコル互換性の基準となる真値です。再生成には**稼働中のサーバーが必要**です。

```sh
# One terminal: a server on the default endpoint.
duckdb
```
```sql
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```
```sh
# Another terminal:
python3 scripts/capture_fixtures.py
```

このスクリプトは Quackling を一切介さずプロトコルを直接話すため、フィクスチャは Zig
実装自身の挙動の記録ではなく、それに対する*独立した*検査であり続けます。新しい DuckDB
リリースに対する検証時に再生成してください。コミット済みフィクスチャの差分は上流の形式
変更を意味するので、盲目的にコミットせずそのように査読してください。

---

## 11. トラブルシューティング

| Symptom | Cause | Fix |
|---|---|---|
| `connection failed: Authentication failed` | トークンが誤っている、または未指定 | `quack_serve` の出力の `auth_token` を使ってください。`QUACK_TOKEN` は**未実装**です ([`CLI.md`](./CLI.md) §3) — `--token` を渡してください |
| `connection failed: ConnectionFailed (quack:localhost:9494)` | 何も待ち受けていない: `duckdb -c` が既に終了した、ポートが違う、別のインターフェイスに bind している | `lsof -nP -iTCP:9494`。空なら標準入力を開いたままにするサーバーを起動 (§4)。ポートが `--url` と一致するか確認 |
| `Table with name X does not exist!` — 同じクエリで**断続的** | 1 ポートに複数の DuckDB プロセス。そのテーブルを持たないプロセスへリクエストが届いている | `lsof -nP -iTCP:9494` がちょうど **1 行**であること。余分なものを kill し、待ち受けているプロセス内でテーブルを作成 (§5) |
| `Table with name X does not exist!` — 一貫して発生 | テーブルが別プロセス/カタログにある、または終了したセッションのインメモリで作成された | 待ち受けセッション内で作成 (§4 の FIFO 手順)。永続的なデータベースファイルを使用 |
| `curl` では動くがブラウザから失敗する | `OPTIONS` を落とすプロキシがクロスオリジンのプリフライトを阻害している | サーバーは `OPTIONS /quack` に 204 と `Access-Control-Allow-Origin: *` を返します。プロキシが `OPTIONS` を無変更で転送するように ([`WASM.md`](./WASM.md) §8) |
| 予期しないフィールドで **HTTP 500** | プロトコル不整合 — サーバーは予期しないフィールドを拒否します (例: 未知の `PREPARE_REQUEST` フィールド) | クライアントとサーバーのバージョンを合わせてください。Quackling はプロトコル version 1 に固定。フィクスチャを再生成し、新しい DuckDB に対して一式を実行 ([`PROTOCOL.md`](./PROTOCOL.md) §10) |
| 接続時に `UnsupportedProtocolVersion` | サーバーがサポート対象のプロトコル範囲外 | Quackling は推測せず拒否します。拡張のバージョンを確認。`compat.zig` を参照 |
| TLS/スキームの混乱: サーバーは起動したのにクライアントが接続できない | `disable_ssl` を省略したため、`listen_url` がサーバーに提供できない `https://` を広告している | 平文 HTTP には `disable_ssl => true` を渡すか、手前に本物の TLS プロキシを置く (§7)。Quackling では `quack:` は **http** に対応。TLS には明示的な `https://` を使用 |
| `https://host` が誤ったポートへ接続する | ポートなしの `https://` は 443 ではなく **9494** に既定される | ポートを明記: `--url https://host:443` |
| クライアントがハングした後、応答が途切れる | プロキシの read timeout が長いクエリを打ち切った | `proxy_read_timeout` を引き上げる (§7) |
| 大きなリクエストが 413 で拒否される | nginx の `client_max_body_size` の既定 1 MB | `client_max_body_size 0` (§7) |
| プロキシ経由のときのみクエリが失敗する | プロキシが本体を変更した、または `Content-Type: application/vnd.duckdb` を落とした | 本体の変換を無効化し、ヘッダーを逐語的に転送 (§7) |
| `zig build test-integration` が不審なほど速く成功する | サーバーへ到達できずテストがスキップされた | §9 で確認。スキップは成功ではありません |
| サーバーを起動したのに `lsof` は待ち受けを示すが `quack_server_list()` が空 | その待ち受けは**別の**プロセスのもの | 他人のサーバーを見ています。§5 を参照 |

---

## 関連項目

- [`CLI.md`](./CLI.md) — フラグ、出力フォーマット、終了コード、`--stats` のカウンター
- [`WASM.md`](./WASM.md) — ブラウザビルド、CORS、FFI 境界
- [`PROTOCOL.md`](./PROTOCOL.md) — ワイヤー形式、認証、カーソルのライフタイム
- [`../../examples/query.zig`](../../examples/query.zig) — 最小の Zig クライアント
- [`../../scripts/capture_fixtures.py`](../../scripts/capture_fixtures.py) — フィクスチャ採取
