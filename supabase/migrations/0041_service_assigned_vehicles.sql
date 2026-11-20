-- La unidad se asigna al servicio (desde Operación del día) y se le muestra a cualquier conductor de la empresa,
-- sin importar quién maneje. Solo lectura: no cambia ninguna regla de iniciar servicio.
create or replace function public.service_assigned_vehicles(p_service uuid, p_date date)
returns table (departure_id uuid, vehicle_id uuid)
language sql stable security definer set search_path = public as $$
  select t.departure_id, t.vehicle_id
    from public.trips t
   where t.service_id = p_service and t.service_date = p_date
     and t.company_id = public.current_company_id()
     and t.status = 'scheduled' and t.published_at is not null and t.vehicle_id is not null;
$$;
revoke all on function public.service_assigned_vehicles(uuid, date) from public;
grant execute on function public.service_assigned_vehicles(uuid, date) to authenticated;
