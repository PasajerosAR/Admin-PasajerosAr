-- 0063: publicar de una vez todos los viajes sin publicar (de hoy en adelante) de la empresa.
create or replace function public.publish_all_trips() returns integer
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  update public.trips set published_at = now()
   where company_id = public.current_company_id() and published_at is null and status = 'scheduled'
     and service_date >= (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.publish_all_trips() from public, anon;
grant execute on function public.publish_all_trips() to authenticated;
