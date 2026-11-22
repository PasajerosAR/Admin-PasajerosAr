-- 0051: eliminar conductor sin bloqueos.
-- Antes se negaba si tenía un viaje en curso o una jornada abierta. Ahora siempre se elimina:
--  * los viajes programados y el viaje en curso quedan SIN conductor (el admin los cubre);
--  * la jornada abierta se cierra;
--  * el historial (viajes finalizados, ventas, jornadas) se conserva.
create or replace function public.remove_driver(p_driver uuid) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_company uuid := public.current_company_id();
  v_driver  public.profiles;
  v_orphans int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_driver from public.profiles
   where id = p_driver and company_id = v_company and role = 'driver' and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- el viaje en curso necesita el RPC autorizado para cambiar de conductor
  perform set_config('app.trip_rpc', 'on', true);
  update public.trips set driver_id = null
   where driver_id = p_driver and status in ('scheduled', 'in_progress');
  get diagnostics v_orphans = row_count;
  perform set_config('app.trip_rpc', 'off', true);

  update public.shifts set ended_at = now() where driver_id = p_driver and ended_at is null;

  begin
    delete from public.profiles where id = p_driver;
    delete from auth.users where id = p_driver;
    return jsonb_build_object('deleted', true, 'kept_history', false, 'trips_without_driver', v_orphans);
  exception when foreign_key_violation then
    update public.profiles set active = false, deleted_at = now() where id = p_driver;
    update auth.users
       set email = 'eliminado-' || p_driver::text || '@eliminado.invalid',
           banned_until = 'infinity'
     where id = p_driver;
    return jsonb_build_object('deleted', true, 'kept_history', true, 'trips_without_driver', v_orphans);
  end;
end $$;
revoke all on function public.remove_driver(uuid) from public, anon;
grant execute on function public.remove_driver(uuid) to authenticated;

notify pgrst, 'reload schema';
