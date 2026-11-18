-- Eliminar empresas y servicios sin perder el historial: desaparecen de las listas
-- y de la web, pero sus viajes, ventas y registros quedan guardados.

alter table public.companies add column if not exists deleted_at timestamptz;
alter table public.services  add column if not exists deleted_at timestamptz;

-- Servicio: si nunca tuvo viajes se borra del todo; si tuvo, se oculta y se conserva.
create or replace function public.remove_service(p_service uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_service public.services;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_service from public.services
   where id = p_service and company_id = v_company and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if not exists (select 1 from public.trips where service_id = p_service) then
    delete from public.services where id = p_service;
    return jsonb_build_object('deleted', true, 'kept_history', false);
  end if;

  if exists (select 1 from public.trips where service_id = p_service and status = 'in_progress') then
    raise exception 'SERVICE_IN_PROGRESS: El servicio tiene un viaje en curso.';
  end if;
  if exists (select 1 from public.sale_tickets k join public.trips t on t.id = k.trip_id
              where t.service_id = p_service and t.status = 'scheduled'
                and t.service_date >= current_date and k.status = 'valid') then
    raise exception 'SERVICE_HAS_SALES: Hay pasajes vendidos para viajes futuros de este servicio. Cancelá esos viajes antes de eliminarlo.';
  end if;

  update public.trips set status = 'cancelled'
   where service_id = p_service and status = 'scheduled' and service_date >= current_date;
  -- libera el número para poder reutilizarlo
  update public.services
     set deleted_at = now(), active = false,
         code = code || ' (eliminado ' || left(id::text, 4) || ')'
   where id = p_service;
  update public.service_departures set active = false where service_id = p_service;
  return jsonb_build_object('deleted', true, 'kept_history', true);
end $$;
revoke all on function public.remove_service(uuid) from public, anon;
grant execute on function public.remove_service(uuid) to authenticated;

-- Empresa: solo el administrador general. Queda suspendida y oculta, con todo su historial.
create or replace function public.remove_company(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'FORBIDDEN'; end if;
  if exists (select 1 from public.trips t where t.company_id = p_company and t.status = 'in_progress') then
    raise exception 'COMPANY_IN_PROGRESS: La empresa tiene viajes en curso.';
  end if;
  update public.companies set deleted_at = now(), active = false
   where id = p_company and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.trips set status = 'cancelled'
   where company_id = p_company and status = 'scheduled' and service_date >= current_date;
end $$;
revoke all on function public.remove_company(uuid) from public, anon;
grant execute on function public.remove_company(uuid) to authenticated;
