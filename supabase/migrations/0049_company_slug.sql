-- Enlace corto de cada empresa: /?empresa=Transporte_Emanuel (en lugar del UUID).
-- Se genera del nombre (sin tildes ni simbolos, espacios = _), sin repetirse (sin distinguir mayusculas): _2, _3...
-- El nombre puede cambiar despues sin romper los enlaces ya compartidos; el enlace con UUID sigue funcionando.
alter table public.companies add column slug text;

create function public._company_slug(p_name text, p_exclude uuid default null) returns text
language plpgsql stable set search_path = public as $$
declare
  v_base text;
  v_slug text;
  v_n int := 1;
begin
  v_base := regexp_replace(translate(trim(p_name), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'), '[^A-Za-z0-9]+', '_', 'g');
  v_base := trim(both '_' from v_base);
  if v_base = '' then v_base := 'Empresa'; end if;
  v_slug := v_base;
  while exists (select 1 from public.companies c where lower(c.slug) = lower(v_slug) and c.id is distinct from p_exclude) loop
    v_n := v_n + 1;
    v_slug := v_base || '_' || v_n;
  end loop;
  return v_slug;
end $$;
revoke all on function public._company_slug(text, uuid) from public, anon, authenticated;

-- empresas existentes (la mas antigua se queda con el nombre limpio)
do $$
declare r record;
begin
  for r in select id, name from public.companies order by created_at, id loop
    update public.companies set slug = public._company_slug(r.name, r.id) where id = r.id;
  end loop;
end $$;
alter table public.companies alter column slug set not null;
create unique index companies_slug_key on public.companies (lower(slug));

create function public.set_company_slug() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.slug is null or trim(new.slug) = '' then new.slug := public._company_slug(new.name, new.id); end if;
  return new;
end $$;
create trigger companies_set_slug before insert on public.companies
  for each row execute function public.set_company_slug();

-- el directorio de la web incluye el enlace
drop function public.passenger_companies();
drop function public._passenger_companies_impl();
create function public._passenger_companies_impl()
returns table (company_id uuid, company_name text, logo_path text, slug text)
language sql stable security definer set search_path = public as $$
  select company.id, company.name, company.logo_path, company.slug
    from public.companies company
   where company.active
   order by company.name;
$$;
revoke all on function public._passenger_companies_impl() from public, anon, authenticated;
create function public.passenger_companies()
returns table (company_id uuid, company_name text, logo_path text, slug text)
language sql stable security definer set search_path = public as $$
  select listed.* from public._passenger_companies_impl() listed
   where public.company_feature_enabled(listed.company_id, 'web');
$$;
revoke all on function public.passenger_companies() from public, anon, authenticated;
grant execute on function public.passenger_companies() to anon, authenticated;
notify pgrst, 'reload schema';
