-- 0069: código de empresa para ingresar con usuario (independiente del slug de la web pública).
-- Se asigna solo (número correlativo desde 100) y el administrador general lo puede personalizar.
create sequence public.company_login_code_seq start 100;
alter table public.companies add column login_code text;
do $$
declare r record;
begin
  for r in select id from public.companies order by created_at, id loop
    update public.companies set login_code = nextval('public.company_login_code_seq')::text where id = r.id;
  end loop;
end $$;
alter table public.companies alter column login_code set not null;
alter table public.companies add constraint companies_login_code_check check (login_code ~ '^[A-Za-z0-9]{2,12}$');
create unique index companies_login_code_key on public.companies (lower(login_code));

create function public.set_company_login_code() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.login_code is null or btrim(new.login_code) = '' then
    loop
      new.login_code := nextval('public.company_login_code_seq')::text;
      exit when not exists (select 1 from public.companies c where lower(c.login_code) = lower(new.login_code));
    end loop;
  end if;
  return new;
end $$;
create trigger companies_set_login_code before insert on public.companies
  for each row execute function public.set_company_login_code();

-- solo el administrador general lo cambia (cambiarlo obliga a avisar a la empresa)
create function public.set_company_login_code(p_company uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare v_code text := btrim(coalesce(p_code, ''));
begin
  if not public.is_platform_admin() then raise exception 'FORBIDDEN'; end if;
  if v_code !~ '^[A-Za-z0-9]{2,12}$' then
    raise exception 'CODE_INVALID: el código lleva de 2 a 12 letras o números, sin espacios';
  end if;
  begin
    update public.companies set login_code = v_code where id = p_company;
  exception when unique_violation then
    raise exception 'CODE_TAKEN: ese código ya lo usa otra empresa';
  end;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function public.set_company_login_code(uuid, text) from public, anon;
grant execute on function public.set_company_login_code(uuid, text) to authenticated;
