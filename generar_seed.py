"""Lee config.json y genera: seed.sql (para Supabase) y web/config.publico.json (sin respuestas ni códigos).
Uso:  python3 generar_seed.py"""
import json, os, math
cfg = json.load(open("config.json", encoding="utf-8"))
q = lambda s: "null" if s is None else "'" + str(s).replace("'", "''") + "'"
codigo = cfg.get("codigo_partida", "PLAZA-2026")
P = cfg["puntos"]

def dist_rumbo(a, b, c, d):
    R = 6371000; la, lc, dl = map(math.radians, (a, c, d - b))
    h = math.sin((lc - la) / 2) ** 2 + math.cos(la) * math.cos(lc) * math.sin(math.radians(d - b) / 2) ** 2
    y = math.sin(dl) * math.cos(lc); x = math.cos(la) * math.sin(lc) - math.sin(la) * math.cos(lc) * math.cos(dl)
    return 2 * R * math.asin(math.sqrt(h)), (math.degrees(math.atan2(y, x)) + 360) % 360

VIENTOS = ["norte", "noreste", "este", "sureste", "sur", "suroeste", "oeste", "noroeste"]
prev = (sum(p["latitud"] for p in P) / len(P), sum(p["longitud"] for p in P) / len(P))
sql = ["truncate puntos cascade;"]
for i, p in enumerate(P):
    dist, rum = dist_rumbo(prev[0], prev[1], p["latitud"], p["longitud"])
    extra = p.get("pista_extra") or "Desde %s, este punto queda hacia el %s, a unos %d m." % (
        "el centro de la plaza" if i == 0 else "el punto anterior", VIENTOS[round(rum / 45) % 8], max(5, round(dist / 5) * 5))
    prev = (p["latitud"], p["longitud"])
    sql.append("insert into puntos(id,nombre,pista,latitud,longitud,radio_metros,codigo_respaldo,relato,pista_extra) values (%d,%s,%s,%s,%s,%d,%s,%s,%s);" % (
        p["id"], q(p["nombre"]), q(p["pista"]), p["latitud"], p["longitud"], p["radio_metros"],
        q(p["codigo_respaldo_manual"]), q(p.get("relato")), q(extra)))
    for k, d in enumerate(p["desafios"]):
        ops = d.get("opciones") or (["Verdadero", "Falso"] if d["tipo"] == "verdadero_falso" else None)
        sql.append("insert into desafios(punto_id,idx,tipo,pregunta,opciones,respuesta_correcta) values (%d,%d,%s,%s,%s,%s);" % (
            p["id"], k, q(d["tipo"]), q(d["pregunta"]), q(json.dumps(ops, ensure_ascii=False)) + "::jsonb" if ops else "null", q(d["respuesta_correcta"])))
data = {"duracion_minutos": cfg["duracion_minutos"], "puntaje": cfg["puntaje"], "final": cfg.get("final", "")}
sql.append("insert into juego_config(id,data) values (1,%s::jsonb) on conflict (id) do update set data=excluded.data;" % q(json.dumps(data, ensure_ascii=False)))
sql.append("insert into partidas(codigo) values (%s) on conflict (codigo) do nothing;" % q(codigo))
open("seed.sql", "w", encoding="utf-8").write("\n".join(sql) + "\n")
pub = {k: cfg[k] for k in ("nombre_juego", "duracion_minutos", "plaza_nombre", "brujula", "simulacion_inicio", "puntaje")}
os.makedirs("web", exist_ok=True)
json.dump(pub, open("web/config.publico.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("OK:", len(P), "puntos. Código de partida:", codigo)
