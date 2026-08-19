# 型システムリファレンス

[English](../en/TYPES.md) · **日本語**

→ [ドキュメント目次](./README.md)

Quackling が Quack のワイヤ形式 (wire format) から DuckDB の値をどうデコードするか、
そして型ごとにどの Zig アクセサを使うべきかを説明します。

参照元: [`../../src/types/logical_type.zig`](../../src/types/logical_type.zig),
[`../../src/types/value.zig`](../../src/types/value.zig),
[`../../src/types/vector.zig`](../../src/types/vector.zig),
[`../../src/types/validity.zig`](../../src/types/validity.zig),
[`../../src/types/data_chunk.zig`](../../src/types/data_chunk.zig),
[`../../src/serialization/decoder.zig`](../../src/serialization/decoder.zig)。

---

## 1. 3 つの層

| 層 | 型 | 所有 (ownership) するもの | 役割 |
|-------|------|------|---------|
| チャンク | `DataChunk` | 自身の `Vector` 配列と列の型ツリー全体 | 最大 2048 行 × N 列 |
| 列 | `Vector` | 自身の子ベクタ・インデックス配列・文字列テーブル | チャンクの 1 列 |
| セル | `Value` | 何も所有しない (スライスは借用) | デコード済みのスカラー 1 個 |

`DataChunk.types` が `LogicalType` ツリーの唯一の所有者です。ネスト型の子を含むすべての
`Vector` はそこを*借用 (borrow)* するだけです。ネストしたベクタは部分ツリーを共有するため、
ベクタが自分の型を解放することは決してありません。

ベクタ内のバルクペイロードは `Result` が保持する HTTP レスポンスバッファを借用します。
そのため `DataChunk.deinit` は軽量で、行サイズのコピーは一切発生しません。

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;        // ?*const Vector
    const v = try chunk.getValue(0, 0);   // Value
}
```

---

## 2. 型の同定: `LogicalType` と `LogicalTypeId`

`LogicalTypeId` は DuckDB の `common/types.hpp` にあるワイヤ上の列挙型です。明示的な `_`
非網羅 (non-exhaustive) 末尾を持つ `enum(u8)` として宣言されているため、将来のサーバから
未知の id が来ても列挙型が壊れることはなく、`name()` は単に `"UNKNOWN"` を返します。

```zig
pub const LogicalType = struct {
    id: LogicalTypeId,
    decimal: ?Decimal = null,              // width + scale、DECIMAL のみ
    alias: ?[]const u8 = null,             // レスポンスバッファから借用
    children: []Child = &.{},              // STRUCT/LIST/MAP/ARRAY/UNION、所有
    array_size: ?u64 = null,               // ARRAY の宣言された長さ
    enum_values: []const []const u8 = &.{},// ENUM 辞書、宣言順
    enum_count_hint: ?u64 = null,          // サーバ申告の件数、照合に使う
};
```

有用なメソッド:

| メソッド | 戻り値 | 備考 |
|--------|---------|-------|
| `id.name()` | `[]const u8` | SQL 風の名前。モデル化していない id は `"UNKNOWN"` |
| `id.fixedWidth()` | `?usize` | 固定幅 id の物理幅。`null` は可変長かモデル化外 |
| `name()` | `[]const u8` | サーバが送った `alias`、なければ `id.name()` |
| `fixedWidth()` | `?usize` | 上に加えて DECIMAL の精度と ENUM 辞書幅を解決する |
| `unionMembers()` | `[]Child` | `children[1..]` — 隠しタグを飛ばす。UNION 以外では空 |
| `mapEntryType()` | `?LogicalType` | MAP の裏にある LIST の要素型 `STRUCT(key, value)` |
| `mapKeyValue()` | `?struct { key, value }` | MAP の宣言されたキー型と値型 |
| `physicalShape()` | `PhysicalShape` | `.fixed`/`.variable`/`.@"struct"`/`.list`/`.array`/`.unsupported` |

`PhysicalShape` こそが MAP と UNION が特別でなくなる場所です。MAP は LIST とまったく同じ
レイアウト、UNION は STRUCT とまったく同じレイアウトなので、デコーダは専用の経路を持たず
それらを再利用します。

---

## 3. 型の全一覧

`Value` のバリアント (variant) は
[`../../src/types/value.zig`](../../src/types/value.zig) の `Value` union のメンバです。
「高速経路」は、存在する場合のボクシング (boxing) なしのアクセサです。

### スカラー型

| DuckDB 型 | `LogicalTypeId` | ワイヤ幅 | デコード方法 | `Value` バリアント | 高速経路 |
|-------------|-----------------|-----------|------------|-----------------|-----------|
| `BOOLEAN` | `.boolean` | 1 | バイトが `!= 0` | `.boolean: bool` | `at(u8, i) != 0` |
| `TINYINT` | `.tinyint` | 1 | LE i8 | `.tinyint: i8` | `at(i8, i)` |
| `SMALLINT` | `.smallint` | 2 | LE i16 | `.smallint: i16` | `at(i16, i)` |
| `INTEGER` | `.integer` | 4 | LE i32 | `.integer: i32` | `at(i32, i)` |
| `BIGINT` | `.bigint` | 8 | LE i64 | `.bigint: i64` | `at(i64, i)` |
| `HUGEINT` | `.hugeint` | 16 | LE i128 | `.hugeint: i128` | `at(i128, i)` |
| `UTINYINT` | `.utinyint` | 1 | LE u8 | `.utinyint: u8` | `at(u8, i)` |
| `USMALLINT` | `.usmallint` | 2 | LE u16 | `.usmallint: u16` | `at(u16, i)` |
| `UINTEGER` | `.uinteger` | 4 | LE u32 | `.uinteger: u32` | `at(u32, i)` |
| `UBIGINT` | `.ubigint` | 8 | LE u64 | `.ubigint: u64` | `at(u64, i)` |
| `UHUGEINT` | `.uhugeint` | 16 | LE u128 | `.uhugeint: u128` | `at(u128, i)` |
| `FLOAT` | `.float` | 4 | LE u32 のビットパターンを `@bitCast` | `.float: f32` | `at(f32, i)` |
| `DOUBLE` | `.double` | 8 | LE u64 のビットパターンを `@bitCast` | `.double: f64` | `at(f64, i)` |
| `DECIMAL(w,s)` | `.decimal` | `w` に応じ 2/4/8/16 | `w` が収まる最小の符号付き整数 + 型からの `w`/`s` | `.decimal: Value.Decimal` | `at(i16/i32/i64/i128, i)` |
| `VARCHAR` | `.varchar` | 可変 | 長さ前置のバイト列、スライスは借用 | `.varchar: []const u8` | — (`.strings` ストレージ) |
| *(文字列リテラル)* | `.string_literal` | 可変 | VARCHAR と同じ | `.varchar` | — |
| `CHAR` | `.char` | 可変 | VARCHAR と同じ | `.varchar` | — |
| `BLOB` | `.blob` | 可変 | 長さ前置のバイト列 | `.blob: []const u8` | — |
| `BIT` | `.bit` | 可変 | 長さ前置のバイト列、**生バイトのまま、展開しない** | `.blob` | — |
| `BIGNUM` | `.bignum` | 可変 | 長さ前置のバイト列、**DuckDB の生エンコーディング** | `.blob` | — |
| `DATE` | `.date` | 4 | LE i32 | `.date: i32` | `at(i32, i)` |
| `TIME` | `.time` | 8 | LE i64 | `.time: i64` | `at(i64, i)` |
| `TIME WITH TIME ZONE` | `.time_tz` | 4 | LE i64 として読む (後述の注意) | `.time: i64` | — |
| `TIMESTAMP` (µs) | `.timestamp` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_S` | `.timestamp_sec` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_MS` | `.timestamp_ms` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_NS` | `.timestamp_ns` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP WITH TIME ZONE` | `.timestamp_tz` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `INTERVAL` | `.interval` | 16 | i32 months, i32 days, i64 micros | `.interval: Interval` | — |
| `UUID` | `.uuid` | 16 | LE i128 を u128 へ `@bitCast` | `.uuid: u128` | `at(i128, i)` |
| `ENUM` | `.@"enum"` | 辞書サイズに応じ 1/2/4 | 辞書インデックス → ラベルに解決 | `.@"enum": Value.Enum` | — |
| `NULL` | `.sqlnull` | — | 常に `.null` | `.null` | — |

**`TIME_TZ` に関する注意 (ソースで確認済み)。** `LogicalTypeId.time_tz.fixedWidth()` は
`4` を返す一方、`Vector.getValue` は `.time_tz` を `readFixed(i64, i)` でデコードします。
`readFixed` は `@sizeOf(T)` 単位でインデックスし、境界チェックはペイロード長に対してのみ
行うため、1 行 4 バイトのペイロードに対してストライド 8 で 8 バイト読むと、
`error.MalformedVector` になる (ペイロードが短い場合) か、行境界をまたいで読むことになります。

**稼働中のサーバに対して確認済み:** `SELECT TIMETZ '12:34:56+09'` は
`error.MalformedVector` で失敗し、一方でプレーンな `TIME` は正しくデコードされます。
DuckDB は `TIME_TZ` を 64 ビット (マイクロ秒と UTC オフセットをパックしたもの) で
格納するため、デコーダ側の `readFixed(i64, …)` が正しく、`fixedWidth()` が返す
`4` が欠陥です。

修正されるまでは、サーバ側で `TIME_TZ` を `VARCHAR` か `TIME` にキャストしてください。

```sql
SELECT my_timetz::VARCHAR FROM t;
```

型テーブルで見つかった不整合はこの 1 件のみで、本ドキュメントの
それ以外の記述はデコーダと整合しています。

### ネスト型

| DuckDB 型 | `LogicalTypeId` | `physicalShape()` | `Vector.storage` | アクセス手段 |
|-------------|-----------------|-------------------|------------------|-----------|
| `STRUCT` | `.@"struct"` | `.@"struct"` | `.children: []Vector` | `children()` |
| `LIST` | `.list` | `.list` | `.list{ entries, child }` | `listEntry(row)` + `listChild()` |
| `ARRAY` | `.array` | `.array` | `.array{ size, child }` | `arraySize()` + `listChild()` |
| `MAP` | `.map` | `.list` | `.list{ entries, child }`、child は `STRUCT(key,value)` | `mapEntry(row)` |
| `UNION` | `.@"union"` | `.@"struct"` | `.children` — child 0 は隠し `UTINYINT` タグ | `unionValue(row)` |
| `VARIANT` | `.variant` | `.@"struct"` | `.children` (keys / children / values の struct) | `children()` |

これ以外でこのクライアントがモデル化していないものは、`getValue` から
`error.UnsupportedType` が返ります。黙って誤デコードすることは決してありません。

---

## 4. NULL と有効性マスク

有効性マスク (validity mask) は LSB 先頭の `u64` ワード列によるビットセットで、
レスポンスバッファから直接借用されます。

> **ビットが 1 (SET) なら、その行は有効 (VALID = 非 NULL) です。** ビットが 0 なら NULL です。
> これは一部の形式が使う「null ビットマップ」の慣習とは逆であり、逆に解釈すると結果全体が
> 静かに反転します。

ベクタがマスクをまったく持たない場合、すべての行が有効です。`ValidityMask.bytes` が `null`
になり `allValid()` が `true` を返します。`ValidityMask.maskSizeFor(count)` は `u64` ワード
単位に切り上げ、`ValidityMask::ValidityMaskSize` と一致します。

```zig
const m = quackling.ValidityMask.init(bytes, row_count);
m.isValid(3);   // true = 非 NULL
m.isNull(3);    // 逆を返す便利関数
m.allValid();   // マスクが送られなかったとき true
m.nullCount();  // 先頭 `count` 行を線形走査
```

マスクバッファの末尾を越えるインデックスは、境界外を読むのではなく*無効*と報告します。
切り詰められたマスクは NULL に劣化するだけで、バッファオーバーランにはなりません。

圧縮エンコーディングでは有効性が外側のベクタではなくデコード済みの子に載るため、それも
処理してくれるベクタ層・チャンク層のヘルパを優先してください:

```zig
vec.isNull(row);              // FLAT / CONSTANT / DICTIONARY / SEQUENCE を処理
chunk.isNull(col, row);       // 範囲外の列はエラーではなく null を報告
row_view.isNull(col);         // Row のヘルパ
```

`Vector.isNull(i)` は `i >= count` でも `true` を返すため、範囲外の行がメモリを読むことは
ありません。

`getValue` は有効性を自動的に参照して `.null` を返します:

```zig
const v = try chunk.getValue(0, row);
if (v.isNull()) { ... }       // Value.isNull(): `self == .null`
```

生の高速経路が**しないこと**に注意してください。`asSlice`、`at`、`copySlice` は有効性を
まったく参照せず、物理ペイロードをそのまま渡します。併せて `isNull` を確認してください。

---

## 5. `Value`: 平坦なスカラービュー

`Value` は `Vector` の上に載る利便性のための層で、ベクタ化された経路がこれを実体化することは
ありません。スライスのペイロード (`.varchar`、`.blob`、および ENUM の `.label`) はチャンクの
バッファを**借用**し、由来する `DataChunk` が生きているあいだだけ有効です。

変換ヘルパ:

| メソッド | 戻り値 | 挙動 |
|--------|---------|-----------|
| `isNull()` | `bool` | `self == .null` |
| `asI64()` | `?i64` | bool → 0/1、全整数幅、`date`/`time`/`timestamp` は生の単位。`ubigint`/`hugeint`/`uhugeint` は `std.math.cast` を通るため、範囲外はラップせず `null`。非数値 (と NULL) は `null` |
| `asF64()` | `?f64` | `float`/`double` はそのまま、`decimal` は `toFloat()` 経由、それ以外は `asI64()` の結果を `@floatFromInt` |
| `asSlice()` | `?[]const u8` | `varchar`/`blob` のペイロード、または ENUM の `label` (ENUM は自然にラベルとして読める) |
| `format(w)` | — | CLI / デバッグ向けの SQL 風テキスト |

`Value.Decimal` はスケールなしの整数と、型の width・scale を保持します。実際の数値は
`value / 10^scale` です。`toFloat()` はその除算を `f64` で行うため、有効数字 15〜17 桁を超える
精度は失われます。厳密さが必要な場合は `value` と `scale` を直接使ってください。

```zig
pub const Decimal = struct { value: i128, width: u8, scale: u8 };
pub const Interval = struct { months: i32, days: i32, micros: i64 };
pub const Enum = struct { index: u32, label: []const u8 };
```

---

## 6. ENUM はラベルに解決される

ワイヤ上の ENUM セルは辞書インデックスにすぎず、辞書を指せる最小の符号なし整数
(`EnumTypeInfo::DictType`) に格納されます。255 件までは 1 バイト、65535 件までは 2 バイト、
それを超えると 4 バイトです。`enumDictWidth(count)` を参照してください。
`LogicalType.fixedWidth()` がこの規則を適用します。

`getValue` はインデックスを読み、`type.enum_values` に対して境界チェックを行い
(範囲外のインデックスは `error.MalformedVector` であり、決して不正な読み出しにはなりません)、
インデックスと解決済みラベルの**両方**を返します:

```zig
const v = try chunk.getValue(0, row);
switch (v) {
    .@"enum" => |e| {
        std.debug.print("{s} (#{d})\n", .{ e.label, e.index });
    },
    else => {},
}

// あるいは、ENUM は自然にラベルとして読めるので:
const label = v.asSlice().?;   // "happy"
```

ラベルのバイト列は `LogicalType.enum_values` を介してレスポンスバッファを借用しており、
そのスライス自体もバッファを借用しています。デコーダはサーバが申告した `values_count`
(フィールド 200) と実際に読んだラベル一覧 (フィールド 201) を照合し、不一致なら
`error.MalformedVector` で拒否します。物理インデックス幅がその件数から導かれるためです。

---

## 7. ネスト型

平坦な `Value` union はネストしたストレージを所有できないため、STRUCT / LIST / ARRAY /
MAP / UNION / VARIANT 列に対する `getValue` は設計上 `error.UnsupportedType` を返します。
損失のあるスカラー表現をでっち上げるより、明示的なエラーを返すほうが優れています。
ネストしたデータにはベクタのアクセサ経由でアクセスしてください。

| アクセサ | シグネチャ | 有効な型 |
|----------|-----------|-----------|
| `children()` | `?[]Vector` | STRUCT, UNION, VARIANT (`.children` ストレージ全般) |
| `listEntry(i)` | `?ListEntry` = `{ offset: u64, length: u64 }` | LIST, MAP (`.list` ストレージ) |
| `listChild()` | `?*Vector` | LIST, MAP **および** ARRAY (`.list` または `.array` ストレージ) |
| `arraySize()` | `?u64` | ARRAY のみ |
| `mapEntry(i)` | `?MapEntry` = `{ offset, length, keys: *Vector, values: *Vector }` | MAP のみ (`type.id == .map` を確認) |
| `unionValue(i)` | `?UnionMember` = `{ tag: u8, name: []const u8, vector: *Vector }` | UNION のみ (`type.id == .@"union"` を確認) |

順序に関する落とし穴に注意してください。MAP は物理的に LIST、UNION は物理的に STRUCT なので、
MAP に対して `listEntry`/`listChild` が成功し、UNION に対して `children()` が成功します。
汎用的にディスパッチするなら、[`../../src/cli/main.zig`](../../src/cli/main.zig) の CLI
レンダラと同様に、**先に `mapEntry` と `unionValue` を確認**してください。さもなければ宣言
された型ではなく内部形状を描画してしまいます。

### STRUCT

```zig
const vec = chunk.column(0).?;
if (vec.children()) |fields| {
    for (fields, 0..) |*f, i| {
        const name = if (i < vec.type.children.len) vec.type.children[i].name else "";
        const v = try f.getValue(row);           // 親と同じ行インデックス
        std.debug.print("{s} = {f}\n", .{ name, v });
    }
}
```

子ベクタは**親の**行インデックスで参照します。STRUCT はフィールドごとに 1 本の子ベクタを
持ち、それぞれ struct と同じ行数です。

### LIST

```zig
if (vec.listEntry(row)) |e| {
    const child = vec.listChild().?;
    for (0..e.length) |k| {
        const v = try child.getValue(@intCast(e.offset + k));
        use(v);
    }
}
```

子は全行が共有する 1 本の平坦化されたベクタで、各行の窓が `listEntry` の
`(offset, length)` の組です。

### ARRAY

ARRAY には行ごとのエントリがありません。長さが固定なので窓は計算されます:

```zig
if (vec.arraySize()) |size| {
    const child = vec.listChild().?;
    for (0..size) |k| {
        const v = try child.getValue(row * @as(usize, @intCast(size)) + k);
        use(v);
    }
}
```

子ベクタの行数は `array_size * parent_count` で、デコーダはその大きさで確保します。

### MAP

```zig
if (vec.mapEntry(row)) |m| {
    for (0..m.length) |k| {
        const key = try m.keys.getValue(@intCast(m.offset + k));
        const val = try m.values.getValue(@intCast(m.offset + k));
        use(key, val);
    }
}

// 物理的な STRUCT を挟まずに、宣言されたキー型・値型を得る:
if (vec.type.mapKeyValue()) |kv| {
    std.debug.print("MAP({s} -> {s})\n", .{ kv.key.name(), kv.value.name() });
}
```

### UNION

```zig
if (vec.unionValue(row)) |u| {
    // u.tag    - この行の UTINYINT タグバイト
    // u.name   - メンバの宣言名 (型ツリーが短い場合は "")
    // u.vector - メンバのベクタ。タグが指すメンバのみ有効
    const v = try u.vector.getValue(row);
    use(u.name, v);
}

for (vec.type.unionMembers()) |m| {
    std.debug.print("member {s}: {s}\n", .{ m.name, m.type.name() });
}
```

`unionValue` は `kids[0].at(u8, i)` でタグを読み `kids[tag + 1]` に対応づけ、タグが範囲外なら
`null` を返します。壊れたタグが子配列の外を指すことはありません。

### VARIANT

VARIANT は物理的に STRUCT (keys / children / values) なので struct 経路でデコードされ、
`children()` で到達します。Quackling はその構造を忠実に公開しますが、VARIANT の
エンコーディングを型付きの値へ**解釈はしません**。VARIANT をスカラーとして扱いたい場合は
サーバ側でキャストしてください (例: `CAST(v AS VARCHAR)`)。

### 表現に関する洞察

DuckDB は次のように格納します。

- **MAP** は `LIST(STRUCT(key, value))` として。`LogicalType.children[0]` がそのエントリ
  struct であり、`mapEntryType()` がそれを返し、`mapKeyValue()` が宣言されたキー型・値型に
  展開します。
- **UNION** は child 0 が隠し `UTINYINT` タグ、残りの子がメンバである STRUCT として。
  `unionMembers()` はタグを飛ばして `children[1..]` を返します。

つまりどちらも専用のデコード経路を必要としません。`physicalShape()` が MAP → `.list`、
UNION → `.@"struct"` に対応づけ、LIST と STRUCT の機構を再利用します。上記のアクセサが
その表現を呼び出し側から隠します。

---

## 8. ベクタのエンコーディング

`VectorType` は DuckDB の列挙型を写したものです。フィールド 90 として届き、
**存在しない場合は FLAT** を意味します。

| エンコーディング | 値 | デコード後の `Vector.storage` | コスト |
|----------|-------|------------------------------|------|
| `flat` | 0 | `.fixed: []const u8` / `.strings` / `.children` / `.list` / `.array` | ペイロード 1 個 |
| `fsst` | 1 | — | 拒否。後述 |
| `constant` | 2 | `.constant: *Vector` (1 行の子) | 行数に関係なく値 1 個 |
| `dictionary` | 3 | `.dictionary { indices: []const u32, child: *Vector }` | 辞書 + 1 行あたり u32 1 個 |
| `sequence` | 4 | `.sequence { start: i64, increment: i64 }` | ペイロードなし |

**圧縮形式は展開せずにデコードされます。** 2048 行の CONSTANT ベクタでもコストは値 1 個分、
SEQUENCE ベクタは何も確保せず必要に応じて `start + increment * i` を計算します。

読み手にとっての意味:

- `getValue(i)` と `isNull(i)` は 4 種すべてで一様に動作します。`physicalIndex` が
  CONSTANT/DICTIONARY の間接参照を内部で解決し、それらの有効性はデコード済みの子から
  読み取られます。
- `isFlat`、`asSlice`、`at`、`copySlice` が成功するのは `.fixed` ストレージのときだけです。
  CONSTANT / DICTIONARY / SEQUENCE の列では `null` を返します。したがってバルクループには
  常に `getValue` のフォールバックが必要で、さもないと黙って 0 行を処理してしまいます:

  ```zig
  if (col.asSlice(i64)) |slice| {
      for (slice) |v| consume(v);              // ゼロコピー
  } else if (col.isFlat(i64)) {
      for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
  } else {
      for (0..chunk.row_count) |i| {           // 圧縮形式または固定幅でない
          consume((try col.getValue(i)).asI64().?);
      }
  }
  ```
- SEQUENCE ベクタでは、`getValue` が計算した `i64` を列の宣言された整数型へ写し戻します
  (`intValueFromI64`)。したがって `.integer`、`.date`、`.ubigint` などが適切に得られ、
  既定は `.bigint` です。要素計算中の算術オーバーフローはラップではなく
  `error.MalformedVector` です。
- DICTIONARY のインデックスはデコード時に検証されます。すべての選択インデックスは
  `< dict_count` でなければならず、さもなければ `error.MalformedVector` です。

### FSST を意図的に未実装にしている理由

DuckDB の `Vector::Serialize` には **FSST の分岐がありません**。FSST エンコードされた
ベクタは `ToUnifiedFormat` にフォールスルーし、ワイヤに出る前に平坦化されます
(`duckdb/src/common/types/vector.cpp` の *"TODO: other compressed vector types (FSST)"*
のフォールスルー箇所)。つまり FSST ベクタが正当に届くことはありえません。

文書化されていないシンボルテーブル形式を推測するのではなく、万一届いた場合はデコーダが
`error.UnsupportedVectorType` を返します。`fsst = 1` メンバは、値を上流と一致させ、
想定外のエンコーディングを誤読ではなく*報告*するために列挙型に残されています。将来の
DuckDB が FSST を送出し始めたら、まさに正しい場所で大きなエラーが出ます。

---

## 9. ゼロコピーアクセスの規則

固定幅データは**レスポンスバッファの借用スライス**として保持されます。値ごとのコピーも、
値ごとの確保もありません。4 つのアクセサがこれを公開し、保証はそれぞれ異なります。

| アクセサ | シグネチャ | 成功する条件 | コピー |
|----------|-----------|---------------|--------|
| `isFlat(T)` | `bool` | `.fixed` ストレージ、`type.fixedWidth() == @sizeOf(T)`、ペイロードが `count * @sizeOf(T)` を満たす | — |
| `asSlice(T)` | `?[]const T` | `isFlat(T)` **かつ**借用ポインタが `T` に自然にアラインしている | なし — ワイヤバッファをエイリアスする |
| `at(T, i)` | `?T` | `isFlat(T)` かつ `i < count` | 1 要素、明示的なリトルエンディアン読み出し |
| `copySlice(T, out)` | `?usize` | `isFlat(T)` | リトルエンディアンホストではバルク `@memcpy`、ビッグエンディアンでは要素ごとにバイトスワップ |

ここから 3 つの規則が導かれます。

1. **`asSlice` は最適化であって通常経路ではありません。** ワイヤ形式はアラインメントを
   何も保証しません。ペイロードの位置はその前にある varint 長に依存するため、固定幅の並びは
   任意のオフセットに落ちます。そこで `asSlice` は
   `@intFromPtr(ptr) % @alignOf(T)` を確認し、条件を満たさなければ `null` を返します。
   幅の不一致でも `null` です。`INTEGER` 列に `i64` を要求すれば `null` が返り、決して
   誤読はしません。非 null が返ったらおまけだと考えてください。

2. **`at` は常に動作します。** 明示的な `std.mem.readInt` / `@bitCast` のリトルエンディアン
   読み出しを行うため、アラインメントは無関係であり、ワイヤバイトが struct へ `@ptrCast`
   されることはありません。アラインメントが合わないときのバルク版が `copySlice` です。
   こちらも 1 パスで値ごとの分岐がなく、コピー先バッファは呼び出し側が所有します。

3. **3 つのいずれも有効性を参照しません。** 物理ペイロードをそのまま渡します。併せて
   `isNull(i)` を確認してください。

これらを安全にしているのが `isFlat` です。どのアクセサがバッファをインデックスする前にも
`bytes.len >= count * @sizeOf(T)` を検証するので、切り詰められたペイロードは末尾を越えて
読まれる前に拒否されます。

### 生存期間の落とし穴

> 借用したデータは次の `nextChunk()` で死にます。

借用するものすべて — `asSlice` の結果、`Value.varchar` / `Value.blob` のスライス、
ENUM の `.label`、`LogicalType.alias`、`typed.iterator` が生成する `[]const u8` フィールド —
は現在のバッチが所有する HTTP レスポンスバッファを指しています。`Result` は次を要求する前に
直前の FETCH バッチを解放するため、常駐するバッチはちょうど 1 個であり、`nextChunk` が返した
チャンクポインタは**次の `nextChunk` 呼び出しで無効化されます**。

```zig
// 誤り: ループが進んだ瞬間に `names` はダングリングになる。
var names: std.ArrayList([]const u8) = .empty;
while (try result.nextChunk()) |chunk| {
    var it = chunk.rows();
    while (it.next()) |row| try names.append(alloc, (try row.get(1)).asSlice().?);
}

// 正しい: チャンクより長生きさせるものはコピーする。
while (try result.nextChunk()) |chunk| {
    var it = chunk.rows();
    while (it.next()) |row| {
        const s = (try row.get(1)).asSlice().?;
        try names.append(alloc, try alloc.dupe(u8, s));
    }
}
```

`copySlice` にも同じことが当てはまります。数値をチャンクより長生きさせたいときにこそ
使ってください。

---

## 10. 時刻・日付・INTERVAL の単位規約

単位は DuckDB が格納しているそのままで、Quackling は変換を行いません。

| 型 | `Value` バリアント | 単位とエポック |
|------|-----------------|----------------|
| `DATE` | `.date: i32` | 1970-01-01 からの**日数** (それより前は負) |
| `TIME` | `.time: i64` | 深夜 0 時からの**マイクロ秒** |
| `TIMESTAMP` | `.timestamp: i64` | 1970-01-01 からの**マイクロ秒** |
| `TIMESTAMP_S` | `.timestamp: i64` | 1970-01-01 からの**秒** |
| `TIMESTAMP_MS` | `.timestamp: i64` | 1970-01-01 からの**ミリ秒** |
| `TIMESTAMP_NS` | `.timestamp: i64` | 1970-01-01 からの**ナノ秒** |
| `TIMESTAMP_TZ` | `.timestamp: i64` | 1970-01-01 からの**マイクロ秒**、UTC 時点 |
| `INTERVAL` | `.interval: Interval` | `months: i32`、`days: i32`、`micros: i64` を分離保持 |

> **`Value` のバリアントはどの単位かを記録しません。** 5 つのタイムスタンプ id はすべて
> `.timestamp: i64` にデコードされます。数値を解釈するには
> `result.columnType(i).?.id` (または `chunk.columnType(i)`) を参照する必要があります。
> さらに `Value.format` — ひいては CLI — は `.timestamp` を常にマイクロ秒として描画するため、
> `TIMESTAMP_S` や `TIMESTAMP_NS` の列は桁が誤って表示されます。生の整数を読んで自分で
> スケールするか、サーバ側で `TIMESTAMP` にキャストしてください。

`INTERVAL` は正規化せず 3 成分を分離して保持します。月と日は固定長ではなく、DuckDB 自身の
演算も暦に依存するためです。16 バイトのペイロードはオフセット 0 / 4 / 8 で明示的な
リトルエンディアン読み出しによりフィールドごとにデコードされます。

`UUID` は DuckDB が符号ビットを反転した `hugeint` として格納します。`getValue` は
`@bitCast` により生の `u128` を返し、`value.writeUuid` が正規の `8-4-4-4-12` 16 進形式を
描画する際に反転を戻します (`v ^ (1 << 127)`)。UUID を数値として比較する場合は、生の
`u128` を一貫して比較するか、先に反転を戻してください。

パラメータのエンコードと値の描画が食い違わないよう公開されている整形ヘルパ
([`../../src/params.zig`](../../src/params.zig) を参照):

```zig
pub fn writeDate(w: anytype, days: i32) !void;      // YYYY-MM-DD、civil-from-days
pub fn writeTime(w: anytype, micros: i64) !void;    // HH:MM:SS[.ffffff]
pub fn writeTimestamp(w: anytype, micros: i64) !void;
pub fn writeDecimal(w: anytype, d: Value.Decimal) !void;
pub fn writeUuid(w: anytype, v: u128) !void;
```

`writeDate` は Howard Hinnant の `civil_from_days` を用い、西暦 1 年より前も扱えます
(`+0000` ではなく先頭に `-` を出力)。`writeTime` は `[0, 1 日)` に正規化するため、負の値も
妥当に描画されます。

---

## 11. 型層から出るエラー

| エラー | 発生源 | 意味 |
|-------|-----------|---------|
| `error.UnsupportedType` | `Vector.getValue` | ネスト型 (アクセサ経由でアクセスすること)、またはこのクライアントがモデル化していない型 id |
| `error.UnsupportedVectorType` | デコーダ | `VectorType.fsst`、または未知のエンコーディング |
| `error.MalformedVector` | `Vector.getValue`、デコーダ | 型と行数が示す長さよりペイロードが短い、行インデックスが範囲外、ENUM インデックスが辞書を越える、DICTIONARY インデックスが辞書件数を越える、SEQUENCE の算術オーバーフロー、申告された ENUM 件数がラベル一覧と不一致 |
| `error.ColumnOutOfRange` | `DataChunk.getValue` | `col >= columns.len` |
| `error.RowCountTooLarge` | デコーダ | `width * count` または `array_size * count` が `usize` をオーバーフロー |

デコーダは信頼できないバイト列を扱うため、2 つの規則を例外なく守ります。すべての読み出しは
境界チェック付きの `Reader` を通ること、そしてワイヤデータを struct へ `@ptrCast` しないこと
— 固定幅ペイロードはバイトスライスのままで、明示的なリトルエンディアン読み出しで扱われます。

---

## 12. クイックリファレンス

```zig
// 型の同定
const t = result.columnType(0).?;         // LogicalType
t.id;                                     // LogicalTypeId
t.name();                                 // alias、なければ SQL 名
t.fixedWidth();                           // ?usize、DECIMAL/ENUM 対応

// 列
const col = chunk.column(0).?;            // ?*const Vector
col.isNull(row);                          // 有効性ビットが 1 = 有効
col.isFlat(i32);                          // at()/copySlice() が使えるか?
col.asSlice(i32);                         // ?[]const i32、ワイヤバッファをエイリアス
col.at(i32, row);                         // ?i32、常に安全
col.copySlice(i32, &out);                 // 書き込んだ要素数 ?usize

// セル
const v = try col.getValue(row);          // Value、ネスト型なら error.UnsupportedType
v.isNull(); v.asI64(); v.asF64(); v.asSlice();

// ネスト
col.children();                           // STRUCT / UNION / VARIANT
col.listEntry(row); col.listChild();      // LIST / MAP
col.arraySize();                          // ARRAY
col.mapEntry(row);                        // MAP  (listEntry より先に確認)
col.unionValue(row);                      // UNION (children より先に確認)
```
