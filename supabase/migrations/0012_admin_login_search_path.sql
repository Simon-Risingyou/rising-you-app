-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0012: search_path-fix voor fn_check_admin_login/fn_zet_admin_wachtwoord
-- ----------------------------------------------------------------------------
-- Migratie 0006 miste `set search_path to 'public', 'extensions', 'pg_temp'`.
-- Zonder deze regel faalt crypt()/gen_salt() met "function does not exist"
-- omdat pgcrypto in het 'extensions'-schema van Supabase zit. Deze fix was al
-- rechtstreeks op de live database toegepast (zie CLAUDE.md "geleerde lessen"),
-- maar stond nog niet in een migratiebestand. Legt enkel vast wat al draait.
-- ============================================================================
create or replace function fn_check_admin_login(
    p_medewerker_id  uuid,
    p_wachtwoord     text
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
    v_hash text;
    v_admin boolean;
begin
    select wachtwoord_hash, is_admin
      into v_hash, v_admin
      from medewerkers
     where id = p_medewerker_id and actief;

    if not found or not v_admin or v_hash is null then
        return false;
    end if;

    return v_hash = crypt(p_wachtwoord, v_hash);
end;
$$;

comment on function fn_check_admin_login is
    'Controleert admin-rechten + wachtwoord van een medewerker. Geeft enkel true/false.';

create or replace function fn_zet_admin_wachtwoord(
    p_medewerker_id  uuid,
    p_nieuw          text
)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
begin
    update medewerkers
       set wachtwoord_hash = crypt(p_nieuw, gen_salt('bf'))
     where id = p_medewerker_id;
end;
$$;

comment on function fn_zet_admin_wachtwoord is
    'Stelt een gehasht admin-wachtwoord in voor een medewerker (bcrypt).';
