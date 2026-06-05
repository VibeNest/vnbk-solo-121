import os
from fastapi import FastAPI
import psycopg
import httpx

app = FastAPI()

PG = dict(
    host=os.getenv("PG_HOST", "postgres"),
    port=os.getenv("PG_PORT", "5432"),
    user=os.getenv("PG_USER", "test"),
    password=os.getenv("PG_PASSWORD", "test"),
    dbname=os.getenv("PG_DB", "test"),
)
QDRANT = os.getenv("QDRANT_URL", "")  # e.g. http://qdrant:6333 ; empty => qdrant endpoints disabled


def _pg():
    return psycopg.connect(**PG)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"app": "vibenest-backup-e2e", "qdrant": bool(QDRANT)}


@app.post("/pg/write")
def pg_write(v: str):
    with _pg() as c, c.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS t(id int primary key, v text)")
        cur.execute(
            "INSERT INTO t(id, v) VALUES (1, %s) ON CONFLICT (id) DO UPDATE SET v = EXCLUDED.v",
            (v,),
        )
        c.commit()
    return {"ok": True, "v": v}


@app.get("/pg/read")
def pg_read():
    with _pg() as c, c.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS t(id int primary key, v text)")
        cur.execute("SELECT v FROM t WHERE id = 1")
        row = cur.fetchone()
    return {"v": row[0] if row else None}


@app.post("/pg/clear")
def pg_clear():
    with _pg() as c, c.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS t")
        c.commit()
    return {"ok": True}


@app.post("/qd/write")
def qd_write(v: str):
    if not QDRANT:
        return {"ok": False, "error": "qdrant not configured"}
    httpx.put(f"{QDRANT}/collections/c", json={"vectors": {"size": 2, "distance": "Cosine"}})
    httpx.put(
        f"{QDRANT}/collections/c/points?wait=true",
        json={"points": [{"id": 1, "vector": [0.1, 0.2], "payload": {"v": v}}]},
    )
    return {"ok": True, "v": v}


@app.get("/qd/read")
def qd_read():
    if not QDRANT:
        return {"ok": False, "error": "qdrant not configured"}
    cnt = httpx.post(f"{QDRANT}/collections/c/points/count", json={})
    count = cnt.json().get("result", {}).get("count") if cnt.status_code == 200 else None
    p = httpx.get(f"{QDRANT}/collections/c/points/1")
    payload = p.json().get("result", {}).get("payload", {}) if p.status_code == 200 else {}
    return {"count": count, "v": payload.get("v")}


@app.post("/qd/clear")
def qd_clear():
    if not QDRANT:
        return {"ok": False, "error": "qdrant not configured"}
    httpx.delete(f"{QDRANT}/collections/c")
    return {"ok": True}
