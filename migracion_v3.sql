-- ===== v3: el organizador puede mover un equipo a cualquier punto (emergencias y pruebas) =====
create or replace function mover_equipo(p_equipo uuid, p_punto int)
returns void language plpgsql security definer set search_path=public as $$
declare v_total int;
begin
 select count(*) into v_total from puntos;
 if p_punto<1 or p_punto>v_total then raise exception 'Punto inválido (de 1 a %)', v_total; end if;
 update equipos set punto_actual=p_punto, completados=p_punto-1, llegada_validada=false, uso_respaldo=false,
  pista_usada=false, desbloqueado_en=now(), tiempo_fin=null where id=p_equipo;
end $$;
revoke execute on function mover_equipo(uuid,int) from public, anon;
grant execute on function mover_equipo(uuid,int) to authenticated;
