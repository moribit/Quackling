# Akamata との統合

[English](../en/AKAMATA.md) · **日本語**

→ [ドキュメント目次](./README.md)

Quackling は Akamata に依存しません。今後も依存させません。Akamata は本ライブラリ
の *利用者* であり、構成要素ではありません ([todo.md §17](../../todo.md))。

本ドキュメントは、実際にアダプタを書いて検証した結果の記録です。以下の内容はすべ
て実物の Akamata (v0.0.2, Zig 0.16.0) に対してコンパイルし、稼働中の
`quack_serve()` に対して実行して確認しました。仕様書を読んだ推測ではなく、コンパイ
ラとサーバーが出した結果です。

---

## 1. すでに一致している点

| 項目 | Akamata | Quackling | 判定 |
|---|---|---|---|
| Zig バージョン | `minimum_zig_version = "0.16.0"` | 0.16.0 | 一致 |
| 依存関係 | `.dependencies = .{}` | なし | 両方ゼロ依存 |
| モジュール公開 | `dep.module("akamata")` | `dep.module("quackling")` | 両方利用可能 |
| Workers ターゲット | `wasm32-freestanding` | ビルド可能 | 一致 |
| Transport 注入 | 自前の HTTP client を使わせたい | `transport` は必須フィールド | 一致 |
| グローバル状態 | 禁止 | なし | 一致 |

重要なのは最後の 2 行です。`quackling.Client.init` には **transport のデフォルト値
がありません**。必ず注入が必要です。これがフォークせずにアダプタを書ける理由です。

---

## 2. Transport アダプタ

Akamata はバックエンドに `am.http_client` を使わせる設計です。native (TLS) と
Workers (JS `fetch` ブリッジ) の両方で動くのがこれだからです。その `send()` は
arena を受け取り借用スライスを返すので、Quackling の `Response.owned = false`
の経路とコピーなしで噛み合います。

```zig
const std = @import("std");
const am = @import("akamata");
const quackling = @import("quackling");

pub const AkamataTransport = struct {
    arena: std.mem.Allocator,
    max_response_bytes: usize = 16 * 1024 * 1024,

    pub fn transport(self: *AkamataTransport) quackling.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }

    fn sendFn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: quackling.transport.Request,
    ) quackling.transport.Error!quackling.transport.Response {
        const self: *AkamataTransport = @ptrCast(@alignCast(ptr));
        _ = allocator; // Akamata は自身の arena から確保する。

        if (req.cancel) |c| if (c.isCancelled()) return error.Cancelled;

        // 2 つの Header 型は構造は同一だが名前が別なので、@ptrCast せず変換する。
        var headers: [8]am.http_client.Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "content-type", .value = req.content_type };
        n += 1;
        for (req.headers) |h| {
            if (n == headers.len) break;
            headers[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }

        const resp = am.http_client.send(self.arena, .{
            .method = .POST,
            .url = req.url,
            .headers = headers[0..n],
            .body = req.body,
            .max_response_bytes = self.max_response_bytes,
            .timeout_ms = req.timeout_ms,
        }) catch |err| return mapError(err);

        return .{ .status = resp.status, .body = resp.body, .owned = false };
    }

    fn mapError(err: am.http_client.HttpClientError) quackling.transport.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectFailed => error.ConnectionFailed,
            error.TlsCertVerifyFailed, error.TlsHandshakeFailed => error.TlsError,
            error.InvalidUrl => error.InvalidUrl,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.UnsupportedOnTarget => error.Unsupported,
            error.HttpProtocolError => error.HttpError,
            error.ReadFailed, error.WriteFailed => error.NetworkError,
        };
    }
};
```

transport 層はこれで全部です。約 60 行、どちらのプロジェクトにも変更なしです。

### Workers ターゲットで検証済み

Akamata の `-Dbackend=workers` を付けて `wasm32-freestanding` 向けにビルドすると、
リンク後のモジュールの import は次の 2 つだけになります。

```
akamata_env.akamata_monotonic_ns
akamata_http.akamata_fetch
```

libc なし、WASI なし、socket なし。Quackling のプロトコルコーデックが Akamata 自身
の fetch ブリッジ経由で Cloudflare Workers 上で動きます。

> 補足: 最初に書いた確認コードは型を *参照* するだけだったため、リンカがモジュール
> を 79 バイトまで削り落とし、何も証明できていませんでした。上記はアダプタを実際に
> 呼び出すコードでのビルド結果 (実コード 63 KB) です。

### 注意点が 1 つ

`am.http_client.Request` は `timeout_ms` を受け取りますが、`HttpClientError` に
**`Timeout` が存在しません**。期限切れは `ReadFailed`/`WriteFailed` として現れま
す。Quackling のエラー分類には独立した `Timeout` があるのに、このアダプタ経由では
「タイムアウト」と「接続が壊れた」を呼び出し側が区別できません。この区別が必要な場
合は Akamata 側の変更が必要です。

---

## 3. `am.db.Db` の問題

ここは 2 つの設計が本質的に食い違う箇所なので、楽観せず正確に書きます。

Akamata の `am.db.Db` は **行指向の pull カーソル** です。位置指定の `bind` →
`step()` → 列ごとの getter (`column_int`, `column_text` …)。Turso、D1、SQLite の各
バックエンドがこの vtable を実装しています。

Quackling は設計上 **チャンク指向** です。`todo.md §7` が「row-only な API にする
な」と明示的に要求した結果です。インターフェースの水準で両者は正反対です。

それでもシムは可能で、実際に作って検証しました。

- `bind()` は値をステージし、`step()` の時点で Quackling 自身の監査済みエスケーパ
  が SQL に埋め込みます (Quack v1 にパラメータのワイヤ形式が無いため)。エスケーパ
  を二重に持ちません。
- `step()` は現在の DataChunk を走査し、尽きたときだけ FETCH を発行します。つまり
  行単位インターフェースでも **ストリーミングが保たれます**。

稼働中サーバーに対する検証結果:

| テスト | 結果 |
|---|---|
| `am.db.Stmt` 経由の `SELECT 42, 'hi'` | pass |
| `stmt.bindAll(.{20, 22})` → `42` | pass |
| `while (step() == .row)` で 100,000 行 | pass — `fetches > 0`, `chunks_received > 1` |
| `stmt.fetchOne(struct { id: i64, name: []const u8 })` | pass |

100k のケースは `client.stats` を検証しているので、単一チャンクで済んでしまった場合
や暗黙のスキップが「通った」ことにはなりません。

**代償は実在します。** このファサードはベクトル化アクセスを捨てます。それは
Quackling の主な性能上の利点です。他のバックエンドと同じ扱いにしたいコードのための
ものだと理解してください。

### より良い経路

`ctx.db()` は `State.db` に対してジェネリックです。

```zig
pub fn db(self: *Self) if (@TypeOf(self.app_state.db) == db_mod.Db)
    db_mod.Db
else
    @TypeOf(self.app_state.db)
```

独自の型は **そのまま通過します**。つまり `quackling.Client` (または `Pool`) を
`State` に直接置けば、シムなし・性能劣化なしでハンドラ内からチャンク API が使えま
す。

```zig
const State = struct {
    db: *quackling.Pool,   // am.db.Db ではない
    cfg: Config,
};

fn handler(c: *Ctx) !void {
    var lease = try c.db().acquire();
    defer lease.release();

    var result = try lease.client.query("SELECT ...");
    defer result.deinit();

    while (try result.nextChunk()) |chunk| {
        // ベクトル化したまま、そのままレスポンスストリームへ
    }
}
```

こちらが推奨する統合方法です。`am.db.Db` シムは、スループットより他バックエンドと
の統一性が重要な場合にのみ使ってください。

---

## 4. 残る課題

いずれも統合の障害にはなりませんが、正直な制約として挙げます。

- **トランザクション。** `am.db.Transaction` は `BEGIN`/`COMMIT` を SQL として発行
  するので動作はしますが、Quackling に明示的なトランザクション API はなく、Quack
  v1 にトランザクションメッセージもありません。D1 はすでにここで
  `TransactionsUnsupported` として fail closed しており、前例があります。
- **タイムアウトの粒度。** §2 参照。
- **可観測性。** Akamata は `trace.recordDb` で DB スパンを記録し、Quackling は独自
  の `Observer`/`Stats` を持ちます。アダプタは両者を橋渡しすべきですが、PoC では未
  実装です。
- **パッケージング。** アダプタは両者に依存する独立パッケージに置くべきです。そう
  すればどちらのプロジェクトも依存を増やしません。

---

## 5. 検証コマンド

```sh
# 両方を path 依存で参照するスクラッチプロジェクトから:
zig build test    # 稼働中の quack_serve() に対して 6/6 pass
zig build wasm    # wasm32-freestanding + -Dbackend=workers でリンク成功
```

Akamata 依存は wasm ターゲットを渡すだけでは不十分で、Akamata 自身の backend
オプションを指定する必要があります。指定しないと同梱 SQLite が libc を要求します。

```zig
const wa = b.dependency("akamata", .{
    .backend = @as([]const u8, "workers"),
    .optimize = .ReleaseSmall,
});
```
