-- ============ TABLAS ============
create table if not exists partidas(
  id uuid primary key default gen_random_uuid(),
  codigo text unique not null,
  estado text not null default 'en_curso' check (estado in ('creada','en_curso','finalizada')),
  creado_en timestamptz not null default now());

create table if not exists juego_config(   -- se llena con seed.sql (puntaje, duración)
  id int primary key default 1, data jsonb not null);

create table if not exists puntos(          -- SECRETOS: sin acceso público (RLS sin políticas)
  id int primary key, nombre text, pista text,
  latitud float8 not null, longitud float8 not null, radio_metros int not null default 30,
  pregunta text, opciones jsonb, respuesta_correcta text, codigo_respaldo text);

create table if not exists equipos(
  id uuid primary key default gen_random_uuid(),
  partida_id uuid not null references partidas(id) on delete cascade,
  nombre text not null,
  token uuid not null unique default gen_random_uuid(),   -- "codigo_acceso": restaura sesión
  punto_actual int not null default 1,
  completados int not null default 0,
  puntaje int not null default 0,
  llegada_validada boolean not null default false,
  uso_respaldo boolean not null default false,
  tiempo_inicio timestamptz not null default now(),
  desbloqueado_en timestamptz not null default now(),
  tiempo_fin timestamptz,
  unique(partida_id, nombre));

create table if not exists participantes(
  id uuid primary key default gen_random_uuid(),
  equipo_id uuid not null references equipos(id) on delete cascade,
  nombre text not null, apellido text not null, edad int not null,
  telefono text not null, instagram text,
  consentimiento_expreso boolean not null check (consentimiento_expreso),
  autorizacion_tutor boolean);

create table if not exists registros_llegada(
  id uuid primary key default gen_random_uuid(),
  equipo_id uuid not null references equipos(id) on delete cascade,
  punto_id int not null, fecha_hora timestamptz not null default now(),
  latitud_enviada float8, longitud_enviada float8, precision_m float8,
  distancia_m float8, es_valido boolean not null,
  intento_codigo boolean not null default false,
  uso_codigo_respaldo boolean not null default false);

-- ============ SEGURIDAD (RLS) ============
alter table partidas enable row level security;
alter table juego_config enable row level security;
alter table puntos enable row level security;
alter table equipos enable row level security;
alter table participantes enable row level security;
alter table registros_llegada enable row level security;
-- Solo el organizador (usuario autenticado) lee las tablas. Los jugadores (anon) usan únicamente las funciones.
do $$ declare t text; begin
 foreach t in array array['partidas','equipos','participantes','registros_llegada','puntos','juego_config'] loop
  execute format('drop policy if exists organizador_lee on %I', t);
  execute format('create policy organizador_lee on %I for select to authenticated using (true)', t);
 end loop; end $$;

-- ============ FUNCIONES ============
create or replace function haversine(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable as $$
 select 2*6371000*asin(sqrt(power(sin(radians(lat2-lat1)/2),2)
  + cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2))) $$;

create or replace function registrar_equipo(p_codigo text, p_nombre text, p_participantes jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_part partidas%rowtype; v_eq equipos%rowtype; j jsonb;
begin
 select * into v_part from partidas where codigo=upper(trim(p_codigo));
 if not found then raise exception 'Código de partida inválido'; end if;
 if v_part.estado<>'en_curso' then raise exception 'La partida no está abierta'; end if;
 if length(trim(coalesce(p_nombre,'')))<2 then raise exception 'Nombre de equipo inválido'; end if;
 if jsonb_array_length(p_participantes) not between 3 and 5 then raise exception 'El equipo debe tener de 3 a 5 participantes'; end if;
 for j in select * from jsonb_array_elements(p_participantes) loop
  if coalesce((j->>'consentimiento')::boolean,false) is not true then raise exception 'Falta el consentimiento de un participante'; end if;
  if (j->>'edad')::int < 18 and coalesce((j->>'autorizacion_tutor')::boolean,false) is not true then
    raise exception 'Un menor de 18 requiere autorización de madre, padre o tutor'; end if;
 end loop;
 insert into equipos(partida_id,nombre) values (v_part.id, trim(p_nombre)) returning * into v_eq;
 insert into participantes(equipo_id,nombre,apellido,edad,telefono,instagram,consentimiento_expreso,autorizacion_tutor)
  select v_eq.id, x->>'nombre', x->>'apellido', (x->>'edad')::int, x->>'telefono', x->>'instagram', true,
         (x->>'autorizacion_tutor')::boolean
  from jsonb_array_elements(p_participantes) x;
 return v_eq.token;
end $$;

create or replace function estado_equipo(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; v_total int; v_punto jsonb := null;
begin
 select * into e from equipos where token=p_token;
 if not found then raise exception 'Equipo no encontrado'; end if;
 select count(*) into v_total from puntos;
 if e.tiempo_fin is null then
  select * into p from puntos where id=e.punto_actual;
  v_punto := jsonb_build_object('id',p.id,'pista',p.pista,'latitud',p.latitud,'longitud',p.longitud,
    'radio_metros',p.radio_metros,
    'pregunta', case when e.llegada_validada then p.pregunta end,
    'opciones', case when e.llegada_validada then p.opciones end);
 end if;
 return jsonb_build_object('equipo',e.nombre,'puntaje',e.puntaje,'completados',e.completados,'total',v_total,
   'terminado',e.tiempo_fin is not null,'llegada_validada',e.llegada_validada,
   'segundos',floor(extract(epoch from coalesce(e.tiempo_fin,now())-e.tiempo_inicio)),'punto',v_punto);
end $$;

create or replace function validar_llegada(p_token uuid, p_lat float8, p_lng float8, p_precision float8 default null, p_codigo text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; d float8; v_resp boolean; v_ok boolean; v_dur int; v_fallos int;
begin
 select * into e from equipos where token=p_token for update;   -- bloquea: evita envíos simultáneos
 if not found then raise exception 'Equipo no encontrado'; end if;
 select coalesce((data->>'duracion_minutos')::int,240) into v_dur from juego_config where id=1;
 if e.tiempo_fin is not null then return jsonb_build_object('ok',false,'motivo','Ya terminaron'); end if;
 if now() > e.tiempo_inicio + make_interval(mins => coalesce(v_dur,240)) then
   return jsonb_build_object('ok',false,'motivo','Se acabó el tiempo'); end if;
 if e.llegada_validada then return jsonb_build_object('ok',true,'motivo','Ya validado'); end if;
 select * into p from puntos where id=e.punto_actual;
 d := haversine(p_lat,p_lng,p.latitud,p.longitud);
 if p_codigo is not null then   -- freno a la adivinanza de códigos
  select count(*) into v_fallos from registros_llegada
   where equipo_id=e.id and intento_codigo and not es_valido and fecha_hora>now()-interval '5 minutes';
  if v_fallos>=5 then return jsonb_build_object('ok',false,'motivo','Demasiados intentos, esperá unos minutos'); end if;
 end if;
 v_resp := p_codigo is not null and upper(trim(p_codigo))=upper(p.codigo_respaldo);
 v_ok := v_resp or d<=p.radio_metros;
 if v_ok or p_codigo is not null then
  insert into registros_llegada(equipo_id,punto_id,latitud_enviada,longitud_enviada,precision_m,distancia_m,es_valido,intento_codigo,uso_codigo_respaldo)
  values (e.id,p.id,p_lat,p_lng,p_precision,d,v_ok,p_codigo is not null,v_resp);
 end if;
 if v_ok then update equipos set llegada_validada=true, uso_respaldo=v_resp where id=e.id; end if;
 return jsonb_build_object('ok',v_ok,'distancia',round(d),'motivo',case when v_ok then 'Llegada válida' else 'Todavía fuera del radio' end);
end $$;

create or replace function responder(p_token uuid, p_respuesta text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e equipos%rowtype; p puntos%rowtype; c jsonb; v_total int; v_bonus int; v_gain int;
begin
 select * into e from equipos where token=p_token for update;
 if not found then raise exception 'Equipo no encontrado'; end if;
 if e.tiempo_fin is not null or not e.llegada_validada then
   return jsonb_build_object('error','Primero hay que validar la llegada'); end if;
 select data->'puntaje' into c from juego_config where id=1;
 select * into p from puntos where id=e.punto_actual;
 select count(*) into v_total from puntos;
 if upper(trim(p_respuesta)) <> upper(trim(p.respuesta_correcta)) then
  update equipos set puntaje=greatest(0,puntaje-(c->>'penal_error')::int) where id=e.id returning puntaje into e.puntaje;
  return jsonb_build_object('correcta',false,'puntaje',e.puntaje);
 end if;
 v_bonus := greatest(0,(c->>'bonus_max_velocidad')::int - floor(extract(epoch from now()-e.desbloqueado_en)/10)::int);
 v_gain := (c->>'por_acierto')::int + v_bonus - case when e.uso_respaldo then (c->>'penal_respaldo')::int else 0 end;
 if e.punto_actual>=v_total then
  update equipos set puntaje=puntaje+v_gain, completados=completados+1, llegada_validada=false, tiempo_fin=now() where id=e.id;
 else
  update equipos set puntaje=puntaje+v_gain, completados=completados+1, punto_actual=punto_actual+1,
   llegada_validada=false, uso_respaldo=false, desbloqueado_en=now() where id=e.id;
 end if;
 return jsonb_build_object('correcta',true,'ganado',v_gain,'bonus',v_bonus,'terminado',e.punto_actual>=v_total);
end $$;

create or replace function ranking(p_codigo text)
returns table(nombre text, completados int, puntaje int, segundos int)
language sql security definer set search_path=public as $$
 select e.nombre, e.completados, e.puntaje,
        floor(extract(epoch from coalesce(e.tiempo_fin,now())-e.tiempo_inicio))::int
 from equipos e join partidas pa on pa.id=e.partida_id
 where pa.codigo=upper(trim(p_codigo))
 order by e.completados desc, e.puntaje desc, 4 asc $$;

create or replace function reiniciar_partida(p_codigo text)   -- solo organizador
returns void language sql security definer set search_path=public as $$
 delete from equipos where partida_id=(select id from partidas where codigo=upper(trim(p_codigo))) $$;

-- ============ PERMISOS ============
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function registrar_equipo(text,text,jsonb), estado_equipo(uuid),
  validar_llegada(uuid,float8,float8,float8,text), responder(uuid,text), ranking(text) to anon, authenticated;
grant execute on function reiniciar_partida(text) to authenticated;

-- ===== Borrar un solo equipo (solo organizador) =====
create or replace function borrar_equipo(p_equipo uuid)
returns void language sql security definer set search_path=public as $$
 delete from equipos where id=p_equipo $$;
revoke execute on function borrar_equipo(uuid) from public, anon;
grant execute on function borrar_equipo(uuid) to authenticated;

