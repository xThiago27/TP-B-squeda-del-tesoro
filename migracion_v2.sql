-- ===== MIGRACIÓN v2: relato por punto, desafíos variados por equipo y pista extra =====
alter table puntos add column if not exists relato text;
alter table puntos add column if not exists pista_extra text;
alter table equipos add column if not exists pista_usada boolean not null default false;

create table if not exists desafios(
  punto_id int not null references puntos(id) on delete cascade,
  idx int not null, tipo text not null, pregunta text not null,
  opciones jsonb, respuesta_correcta text not null,
  primary key(punto_id, idx));
alter table desafios enable row level security;
drop policy if exists organizador_lee on desafios;
create policy organizador_lee on desafios for select to authenticated using (true);

-- Texto en minúsculas, sin tildes y sin espacios de más (para comparar respuestas escritas)
create or replace function normaliza(t text) returns text language sql immutable as $$
 select regexp_replace(translate(lower(trim(coalesce(t,''))),'áéíóúüñ','aeiouun'),'\s+',' ','g') $$;

-- A cada equipo le toca una variante distinta de desafío en cada punto (según su token)
create or replace function desafio_de(p_token uuid, p_punto int)
returns desafios language plpgsql stable security definer set search_path=public as $$
declare n int; r desafios;
begin
 select count(*) into n from desafios where punto_id=p_punto;
 if n=0 then return null; end if;
 select * into r from desafios where punto_id=p_punto order by idx
  offset (abs(hashtext(p_token::text||':'||p_punto::text)::bigint) % n) limit 1;
 return r;
end $$;

create or replace function estado_equipo(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; d desafios; v_total int; v_punto jsonb := null; v_rel jsonb; v_final text;
begin
 select * into e from equipos where token=p_token;
 if not found then raise exception 'Equipo no encontrado'; end if;
 select count(*) into v_total from puntos;
 select coalesce(jsonb_agg(jsonb_build_object('n',id,'texto',relato) order by id),'[]'::jsonb)
  into v_rel from puntos where id<=e.completados;
 select data->>'final' into v_final from juego_config where id=1;
 if e.tiempo_fin is null then
  select * into p from puntos where id=e.punto_actual;
  d := desafio_de(p_token,p.id);
  v_punto := jsonb_build_object('id',p.id,'pista',p.pista,'latitud',p.latitud,'longitud',p.longitud,
    'radio_metros',p.radio_metros,'tiene_pista_extra',p.pista_extra is not null,
    'pista_extra', case when e.pista_usada then p.pista_extra end,
    'tipo', case when e.llegada_validada then d.tipo end,
    'pregunta', case when e.llegada_validada then d.pregunta end,
    'opciones', case when e.llegada_validada then d.opciones end);
 end if;
 return jsonb_build_object('equipo',e.nombre,'puntaje',e.puntaje,'completados',e.completados,'total',v_total,
   'terminado',e.tiempo_fin is not null,'llegada_validada',e.llegada_validada,
   'segundos',floor(extract(epoch from coalesce(e.tiempo_fin,now())-e.tiempo_inicio)),
   'relatos',v_rel,'final',case when e.tiempo_fin is not null then v_final end,'punto',v_punto);
end $$;

create or replace function responder(p_token uuid, p_respuesta text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; d desafios; c jsonb; v_fin text;
        v_total int; v_bonus int; v_gain int; v_ok boolean;
begin
 select * into e from equipos where token=p_token for update;
 if not found then raise exception 'Equipo no encontrado'; end if;
 if e.tiempo_fin is not null or not e.llegada_validada then
   return jsonb_build_object('error','Primero hay que validar la llegada'); end if;
 select data->'puntaje', data->>'final' into c, v_fin from juego_config where id=1;
 select * into p from puntos where id=e.punto_actual;
 d := desafio_de(p_token,p.id);
 select coalesce(bool_or(normaliza(x)=normaliza(p_respuesta)),false) into v_ok
  from unnest(string_to_array(d.respuesta_correcta,'|')) x;
 select count(*) into v_total from puntos;
 if not v_ok then
  update equipos set puntaje=greatest(0,puntaje-(c->>'penal_error')::int) where id=e.id returning puntaje into e.puntaje;
  return jsonb_build_object('correcta',false,'puntaje',e.puntaje);
 end if;
 v_bonus := greatest(0,(c->>'bonus_max_velocidad')::int - floor(extract(epoch from now()-e.desbloqueado_en)/10)::int);
 v_gain := (c->>'por_acierto')::int + v_bonus - case when e.uso_respaldo then (c->>'penal_respaldo')::int else 0 end;
 if e.punto_actual>=v_total then
  update equipos set puntaje=puntaje+v_gain, completados=completados+1, llegada_validada=false, tiempo_fin=now() where id=e.id;
 else
  update equipos set puntaje=puntaje+v_gain, completados=completados+1, punto_actual=punto_actual+1,
   llegada_validada=false, uso_respaldo=false, pista_usada=false, desbloqueado_en=now() where id=e.id;
 end if;
 return jsonb_build_object('correcta',true,'ganado',v_gain,'bonus',v_bonus,'n',p.id,'relato',p.relato,
   'terminado',e.punto_actual>=v_total);
end $$;

-- Pista opcional que cuesta puntos (se cobra una sola vez por punto)
create or replace function pedir_pista(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; c jsonb;
begin
 select * into e from equipos where token=p_token for update;
 if not found then raise exception 'Equipo no encontrado'; end if;
 if e.tiempo_fin is not null or e.llegada_validada then return jsonb_build_object('error','No disponible ahora'); end if;
 select * into p from puntos where id=e.punto_actual;
 if p.pista_extra is null then return jsonb_build_object('error','Este punto no tiene pista extra'); end if;
 if not e.pista_usada then
  select data->'puntaje' into c from juego_config where id=1;
  update equipos set pista_usada=true, puntaje=greatest(0,puntaje-coalesce((c->>'penal_pista')::int,15)) where id=e.id;
 end if;
 return jsonb_build_object('ok',true,'pista_extra',p.pista_extra);
end $$;

revoke execute on function normaliza(text), desafio_de(uuid,int) from public, anon, authenticated;
revoke execute on function pedir_pista(uuid) from public;
grant execute on function pedir_pista(uuid) to anon, authenticated;
