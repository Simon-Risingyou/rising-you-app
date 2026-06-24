-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0006: admin-login per medewerker
-- ----------------------------------------------------------------------------
-- De lokale 'wie werkt nu?'-selectie blijft laagdrempelig (geen wachtwoord).
-- Maar om in ADMIN-MODUS te gaan moet de geselecteerde medewerker:
--   1. admin-rechten hebben (is_admin = true), en
--   2. zijn/haar wachtwoord ingeven.
--
-- BELANGRIJK (veiligheid): we slaan NOOIT een wachtwoord in platte tekst op.
-- In de echte app gebeurt de controle via Supabase Auth (server-side, gehasht).
-- Dit veld is enkel een gehashte waarde als vangnet/voor lokale controle.
-- De app stuurt het ingetypte wachtwoord nooit door als platte tekst en
-- bewaart het nergens.
-- ============================================================================

-- Gehasht wachtwoord voor admin-login (bv. bcrypt-hash). Leeg = kan niet als
-- admin inloggen, ook al is is_admin true (dan moet er eerst een wachtwoord
-- ingesteld worden).
alter table medewerkers
    add column if not exists wachtwoord_hash text;

comment on column medewerkers.wachtwoord_hash is
    'Gehasht admin-wachtwoord (nooit platte tekst). Enkel relevant als is_admin = true.';


-- ----------------------------------------------------------------------------
-- fn_check_admin_login
-- Controleert of een medewerker admin is en of het wachtwoord klopt.
-- Geeft enkel true/false terug (lekt geen info over welke voorwaarde faalde).
-- De wachtwoordvergelijking gebruikt crypt() uit de pgcrypto-extensie.
-- In de echte app is dit bij voorkeur volledig via Supabase Auth.
-- ----------------------------------------------------------------------------
create or replace function fn_check_admin_login(
    p_medewerker_id  uuid,
    p_wachtwoord     text
)
returns boolean
language plpgsql
security definer
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

    -- crypt() hasht het ingegeven wachtwoord met dezelfde salt als de opgeslagen
    -- hash; matcht het, dan is het wachtwoord correct.
    return v_hash = crypt(p_wachtwoord, v_hash);
end;
$$;

comment on function fn_check_admin_login is
    'Controleert admin-rechten + wachtwoord van een medewerker. Geeft enkel true/false.';


-- ----------------------------------------------------------------------------
-- Hulpfunctie om een wachtwoord veilig in te stellen (genereert een bcrypt-hash).
-- Gebruik: select fn_zet_admin_wachtwoord('<medewerker-uuid>', 'nieuwwachtwoord');
-- ----------------------------------------------------------------------------
create or replace function fn_zet_admin_wachtwoord(
    p_medewerker_id  uuid,
    p_nieuw          text
)
returns void
language plpgsql
as $$
begin
    update medewerkers
       set wachtwoord_hash = crypt(p_nieuw, gen_salt('bf'))
     where id = p_medewerker_id;
end;
$$;

comment on function fn_zet_admin_wachtwoord is
    'Stelt een gehasht admin-wachtwoord in voor een medewerker (bcrypt).';
