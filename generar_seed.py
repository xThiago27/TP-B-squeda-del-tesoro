"""Lee config.json y genera: seed.sql (para Supabase) y web/config.publico.json (sin respuestas ni códigos).
Uso:  python3 generar_seed.py"""
import json, os
cfg = json.load(open("config.json", encoding="utf-8"))
q = lambda s: "'" + str(s).replace("'", "''") + "'"
codigo = cfg.get("codigo_partida", "PLAZA-2026")
sql = ["truncate puntos;"]
for p in cfg["puntos"]:
    d = p["desafio"]
    sql.append("insert into puntos values (%d,%s,%s,%s,%s,%d,%s,%s::jsonb,%s,%s);" % (
        p["id"], q(p["nombre"]), q(p["pista"]), p["latitud"], p["longitud"], p["radio_metros"],
        q(d["pregunta"]), q(json.dumps(d["opciones"], ensure_ascii=False)),
        q(d["respuesta_correcta"]), q(p["codigo_respaldo_manual"])))
data = {"duracion_minutos": cfg["duracion_minutos"], "puntaje": cfg["puntaje"]}
sql.append("insert into juego_config(id,data) values (1,%s::jsonb) on conflict (id) do update set data=excluded.data;" % q(json.dumps(data)))
sql.append("insert into partidas(codigo) values (%s) on conflict (codigo) do nothing;" % q(codigo))
open("seed.sql", "w", encoding="utf-8").write("\n".join(sql) + "\n")
pub = {k: cfg[k] for k in ("nombre_juego", "duracion_minutos", "plaza_nombre", "brujula", "simulacion_inicio")}
os.makedirs("web", exist_ok=True)
json.dump(pub, open("web/config.publico.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("OK:", len(cfg["puntos"]), "puntos. Código de partida:", codigo)
