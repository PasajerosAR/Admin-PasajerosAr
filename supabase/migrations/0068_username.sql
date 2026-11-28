-- 0068: nombre de usuario para ingresar (además del correo, que sigue siendo obligatorio).
-- Es único dentro de cada empresa (sin distinguir mayúsculas): el legajo "6" puede existir en varias empresas.
-- Para ingresar con usuario se indica también el código de la empresa (companies.slug).
alter table public.profiles add column username text;
alter table public.profiles add constraint profiles_username_check
  check (username is null or (username ~ '^[A-Za-z0-9._-]{1,30}$' and company_id is not null));
create unique index profiles_username_company_uq on public.profiles (company_id, lower(username)) where username is not null;

-- el administrador de empresa cambia el usuario de su gente; el administrador general, el de los administradores de empresa
create function public.set_username(p_profile uuid, p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare v_target public.profiles; v_name text := nullif(btrim(p_username), '');
begin
  select * into v_target from public.profiles where id = p_profile;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not ((public.is_company_admin() and v_target.company_id = public.current_company_id())
          or (public.is_platform_admin() and v_target.role = 'company_admin')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_name is not null and v_name !~ '^[A-Za-z0-9._-]{1,30}$' then
    raise exception 'USERNAME_INVALID: usá solo letras, números, punto, guion y guion bajo, sin espacios (hasta 30)';
  end if;
  begin
    update public.profiles set username = v_name where id = p_profile;
  exception when unique_violation then
    raise exception 'USERNAME_TAKEN: ese usuario ya lo tiene otra persona de la empresa';
  end;
end $$;
revoke all on function public.set_username(uuid, text) from public, anon;
grant execute on function public.set_username(uuid, text) to authenticated;
