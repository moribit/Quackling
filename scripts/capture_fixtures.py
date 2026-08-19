#!/usr/bin/env python3
"""Capture golden wire fixtures from a live DuckDB Quack server.

The fixtures in tests/fixtures/ are the ground truth for protocol
compatibility. Regenerate them when validating against a new DuckDB release:

    duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
    python3 scripts/capture_fixtures.py

This script speaks the protocol directly (no Quackling involved) so that the
fixtures stay an *independent* check on the Zig implementation rather than a
recording of its own behaviour.
"""
import struct, urllib.request, os, json, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "fixtures")
def u_leb(v):
    out=bytearray()
    while True:
        b=v&0x7F; v>>=7
        if v: out.append(b|0x80)
        else: out.append(b); return bytes(out)
def F(i): return struct.pack('<H', i)
TERM=F(0xFFFF); INVALID=(1<<64)-1
def wstr(s):
    b=s.encode(); return u_leb(len(b))+b
def post(p):
    req=urllib.request.Request("http://localhost:9494/quack", data=p,
        headers={"Content-Type":"application/vnd.duckdb"})
    return urllib.request.urlopen(req,timeout=30).read()
class R:
    def __init__(s,b): s.b=b; s.p=0
    def fid(s): v=struct.unpack_from('<H',s.b,s.p)[0]; s.p+=2; return v
    def uleb(s):
        r=0; sh=0
        while True:
            byte=s.b[s.p]; s.p+=1; r|=(byte&0x7F)<<sh; sh+=7
            if not (byte&0x80): return r
    def strv(s):
        n=s.uleb(); v=s.b[s.p:s.p+n]; s.p+=n; return v.decode('utf8','replace')
def read_header(r):
    t=None; cid=""
    while True:
        f=r.fid()
        if f==0xFFFF: break
        if f==1: t=r.uleb()
        elif f==2: cid=r.strv()
        elif f==3: r.uleb()
    return t,cid

hdr=F(1)+u_leb(1)+F(3)+u_leb(INVALID)+TERM
body=(F(1)+wstr("super_secret")+F(2)+wstr("v1.4.1")+F(3)+wstr("osx_arm64")
     +F(4)+u_leb(1)+F(5)+u_leb(1)+TERM)
resp=post(hdr+body)
r=R(resp); _,cid=read_header(r)
print("connected:",cid)
os.makedirs(OUT, exist_ok=True)
# also save the raw connection response
open(os.path.join(OUT,"connection_response.bin"),"wb").write(resp)

QUERIES={
 "select42":"SELECT 42 AS answer",
 "bool":"SELECT true AS t, false AS f",
 "nulls":"SELECT NULL::INTEGER AS a, 1::INTEGER AS b",
 "varchar":"SELECT 'hello' AS greeting, 'wörld🦆' AS unicode",
 "mixed":"SELECT 1::TINYINT a,2::SMALLINT b,3::INTEGER c,4::BIGINT d,5.5::FLOAT e,6.25::DOUBLE f,'x' g",
 "multirow":"SELECT i, i*2 AS double_i FROM range(5) t(i)",
 "unsigned":"SELECT 1::UTINYINT a,2::USMALLINT b,3::UINTEGER c,4::UBIGINT d",
 "hugeint":"SELECT 170141183460469231731687303715884105727::HUGEINT AS h",
 "largeresult":"SELECT i FROM range(5000) t(i)",
 "nullmix":"SELECT CASE WHEN i%2=0 THEN NULL ELSE i END::INTEGER AS v FROM range(10) t(i)",
 "error":"SELECT * FROM nonexistent_table_xyz",
 "emptyresult":"SELECT 1 AS a WHERE false",
 # --- nested and extended types ---
 "struct":"SELECT {'a': 1, 'b': 'x'} AS s",
 "list":"SELECT [10,20,30] AS l",
 "list_nulls":"SELECT [1,NULL,3] AS l",
 "array":"SELECT [1,2,3]::INTEGER[3] AS arr",
 "map":"SELECT MAP{'a': 1, 'b': 2} AS m",
 "enum":"SELECT 'happy'::ENUM('sad','ok','happy') AS mood",
 "union":"SELECT union_value(num := 2) AS u",
 "nested_deep":"SELECT {'inner': [1,2], 'name': 'x'} AS s",
 "temporal":"SELECT DATE '2024-03-15' d, TIME '12:34:56' t, TIMESTAMP '2024-03-15 12:34:56' ts, INTERVAL 3 DAY iv",
 "decimal":"SELECT 12.34::DECIMAL(10,2) a, 1.5::DECIMAL(4,1) b, 123456789012345678.99::DECIMAL(30,2) c",
 "uuid":"SELECT '0cc7435c-7cc0-4836-b03d-53aed12d1006'::UUID AS u",
 "blob":"SELECT 'abc'::BLOB AS b, encode('hi') AS raw",
 "variant":"SELECT {'a': 1, 'b': 'two'}::VARIANT AS v",
 "bignum":"SELECT 123456789012345678901234567890123456789012::BIGNUM AS b",
 "enum_large":"SELECT ('v'||(i%300))::VARCHAR AS e FROM range(3) t(i)",
 "map_nested":"SELECT MAP{'k': [1,2]} AS m",
 "union_multi":"SELECT union_value(s := 'txt') AS u",
}
meta={}
for name,sql in QUERIES.items():
    h=F(1)+u_leb(3)+F(2)+wstr(cid)+F(3)+u_leb(INVALID)+TERM
    b=F(1)+wstr(sql)+TERM
    try:
        resp=post(h+b)
        open(os.path.join(OUT,"%s.bin"%name),"wb").write(resp)
        rr=R(resp); t,_=read_header(rr)
        meta[name]={"sql":sql,"len":len(resp),"msgtype":t}
        print("%-14s type=%-3s len=%d"%(name,t,len(resp)))
    except Exception as e:
        print(name,"ERR",e)
json.dump(meta,open(os.path.join(OUT,"manifest.json"),"w"),indent=2)
