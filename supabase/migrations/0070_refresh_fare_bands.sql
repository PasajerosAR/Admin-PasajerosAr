-- 0070: al cambiar la semana base o las excepciones de franja, los viajes futuros que todavía no tienen ventas
-- toman la franja nueva. Los viajes con ventas, o que ya salieron, conservan la suya.
-- (Un feriado de día completo se carga en "Feriados": define el tipo de día; las excepciones de franja son para rangos de horas.)
create function public._refresh_fare_bands(p_company uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.trips t
     set fare_band = public.fare_band_for(t.company_id, t.scheduled_departure, t.service_date, t.day_type)
   where t.company_id = p_company and t.status = 'scheduled'
     and (p_date is null and t.service_date >= (now() at time zone 'America/Argentina/Buenos_Aires')::date or t.service_date = p_date)
     and not exists (select 1 from public.sale_tickets x where x.trip_id = t.id)
     and not exists (select 1 from public.tickets x where x.trip_id = t.id)
     and t.fare_band is distinct from public.fare_band_for(t.company_id, t.scheduled_departure, t.service_date, t.day_type);
end $$;
revoke all on function public._refresh_fare_bands(uuid, date) from public, anon, authenticated;

create function public._fare_exception_refresh() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._refresh_fare_bands(coalesce(new.company_id, old.company_id), coalesce(new.on_date, old.on_date));
  return null;
end $$;
create trigger fare_exception_refresh after insert or delete on public.fare_band_exceptions
  for each row execute function public._fare_exception_refresh();

create or replace function public.save_fare_week(p_grid jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := public.current_company_id(); d int; h int; v_code text; v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_grid) <> 'array' or jsonb_array_length(p_grid) <> 7 then raise exception 'GRID_INVALID: la semana tiene que tener 7 días'; end if;
  for d in 1..7 loop
    if jsonb_typeof(p_grid -> (d - 1)) <> 'array' or jsonb_array_length(p_grid -> (d - 1)) <> 24 then
      raise exception 'GRID_INVALID: cada día tiene que tener 24 horas';
    end if;
    for h in 0..23 loop
      v_code := p_grid -> (d - 1) ->> h;
      select id into v_id from public.fare_bands where company_id = v_company and code = v_code;
      if v_id is null then raise exception 'GRID_INVALID: franja inexistente (%)', v_code; end if;
      insert into public.fare_band_weekly (company_id, dow, hour, band_id) values (v_company, d, h, v_id)
      on conflict (company_id, dow, hour) do update set band_id = excluded.band_id;
    end loop;
  end loop;
  perform public._refresh_fare_bands(v_company, null);
end $$;

revoke all on function public.save_fare_week(jsonb) from public, anon;
grant execute on function public.save_fare_week(jsonb) to authenticated;
