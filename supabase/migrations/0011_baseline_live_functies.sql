-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0011: baseline — vastleggen van functies die rechtstreeks via de
-- Supabase SQL-editor zijn aangemaakt tijdens eerdere sessies (admin portaal,
-- activiteitenbeheer, medewerkersbeheer, offline-cache).
-- ----------------------------------------------------------------------------
-- Deze migratie voegt niets nieuws toe aan de live database — ze legt enkel
-- vast wat er al draait, zodat repo en live weer gelijklopen. Elke functie
-- hieronder is 1-op-1 overgenomen via `pg_get_functiondef` van de live DB.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ACTIVITEITEN: kolom 'gratis' (werd al gebruikt door fn_alle_activiteiten
-- en het admin-portaal, maar stond nog niet in een migratie).
-- ----------------------------------------------------------------------------
alter table activiteiten
    add column if not exists gratis boolean not null default false;

comment on column activiteiten.gratis is
    'Gratis activiteiten (bv. conversatietafel) lopen zonder afrekening: geen beurt, geen betaalwijze, geen A-Kaart-check.';


-- ----------------------------------------------------------------------------
-- 2. LEDEN
-- ----------------------------------------------------------------------------
create or replace function fn_haal_lid(p_lid_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', l.id,
    'voornaam', l.voornaam,
    'achternaam', l.achternaam,
    'foto_pad', l.foto_pad,
    'sociaal_tarief', l.sociaal_tarief,
    'geboortejaar', l.geboortejaar,
    'postcode', l.postcode,
    'herkomst', l.herkomst,
    'tarieftype_handmatig', l.tarieftype_handmatig,
    'tarieftype_effectief', fn_tarieftype(l.id),
    'actief', l.actief,
    'goedkeuring', l.goedkeuring,
    'beurtenkaarten', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'activiteit', b.activiteit, 'tarief', b.tarief,
        'beurten_resterend', b.beurten_resterend, 'actief', b.actief))
      from beurtenkaarten b
      where b.lid_id = l.id and b.actief), '[]'::jsonb),
    'abonnementen', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'activiteit', a.activiteit, 'tarief', a.tarief,
        'start_datum', a.start_datum, 'eind_datum', a.eind_datum, 'actief', a.actief))
      from abonnementen a
      where a.lid_id = l.id and a.actief), '[]'::jsonb),
    'gezinsleden', coalesce((
      select jsonb_agg(jsonb_build_object(
        'gezin_id', g.gezin_id, 'rol', g.rol))
      from gezinsleden g
      where g.lid_id = l.id), '[]'::jsonb)
  )
  from leden l
  where l.id = p_lid_id;
$$;

comment on function fn_haal_lid is
    'Haalt alle gegevens van een lid op (tarief, tegoed, gezin) als jsonb voor ledenbeheer.';

create or replace function fn_wijzig_lid(
    p_lid_id        uuid,
    p_voornaam      text,
    p_achternaam    text,
    p_geboortejaar  integer,
    p_postcode      text,
    p_herkomst      text,
    p_medewerker_id uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_oud leden%rowtype;
    v_wijzigingen text[] := '{}';
    v_nieuw_voornaam text;
    v_nieuw_achternaam text;
    v_nieuw_postcode text;
    v_nieuw_herkomst text;
begin
    select * into v_oud from leden where id = p_lid_id;
    if not found then return 'Lid niet gevonden.'; end if;

    v_nieuw_voornaam   := coalesce(nullif(trim(p_voornaam), ''), v_oud.voornaam);
    v_nieuw_achternaam := coalesce(nullif(trim(p_achternaam), ''), v_oud.achternaam);
    v_nieuw_postcode   := nullif(trim(p_postcode), '');
    v_nieuw_herkomst   := nullif(trim(p_herkomst), '');

    -- Verzamel wat er echt verandert, met oude EN nieuwe waarde.
    if v_nieuw_voornaam is distinct from v_oud.voornaam then
        v_wijzigingen := v_wijzigingen || ('voornaam van "' || coalesce(v_oud.voornaam,'leeg') || '" naar "' || v_nieuw_voornaam || '"'); end if;
    if v_nieuw_achternaam is distinct from v_oud.achternaam then
        v_wijzigingen := v_wijzigingen || ('achternaam van "' || coalesce(v_oud.achternaam,'leeg') || '" naar "' || v_nieuw_achternaam || '"'); end if;
    if p_geboortejaar is distinct from v_oud.geboortejaar then
        v_wijzigingen := v_wijzigingen || ('geboortejaar van "' || coalesce(v_oud.geboortejaar::text,'leeg') || '" naar "' || coalesce(p_geboortejaar::text,'leeg') || '"'); end if;
    if v_nieuw_postcode is distinct from v_oud.postcode then
        v_wijzigingen := v_wijzigingen || ('postcode van "' || coalesce(v_oud.postcode,'leeg') || '" naar "' || coalesce(v_nieuw_postcode,'leeg') || '"'); end if;
    if v_nieuw_herkomst is distinct from v_oud.herkomst then
        v_wijzigingen := v_wijzigingen || ('herkomst van "' || coalesce(v_oud.herkomst,'leeg') || '" naar "' || coalesce(v_nieuw_herkomst,'leeg') || '"'); end if;

    update leden set
        voornaam = v_nieuw_voornaam,
        achternaam = v_nieuw_achternaam,
        geboortejaar = p_geboortejaar,
        postcode = v_nieuw_postcode,
        herkomst = v_nieuw_herkomst,
        bijgewerkt_op = now()
     where id = p_lid_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'gegevens_gewijzigd',
            case when array_length(v_wijzigingen,1) is null
                 then 'Gegevens opgeslagen (geen wijziging).'
                 else 'Gewijzigd: ' || array_to_string(v_wijzigingen, '; ') || '.' end,
            p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_wijzig_lid is
    'Wijzigt gegevens van een lid en logt "van X naar Y" per effectief gewijzigd veld.';

create or replace function fn_zet_tarieftype(p_lid_id uuid, p_tarief tarieftype, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_lid leden%rowtype;
begin
    select * into v_lid from leden where id = p_lid_id;
    if not found then return 'Lid niet gevonden.'; end if;

    update leden set tarieftype_handmatig = p_tarief, bijgewerkt_op = now()
     where id = p_lid_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'tarief_gewijzigd',
            'Tarieftype gezet op ' || p_tarief::text || '.', p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_zet_tarieftype is
    'Zet het handmatige tarieftype van een lid (bv. student -> volwassene) door een admin.';

create or replace function fn_zet_sociaal_tarief(p_lid_id uuid, p_sociaal boolean, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_lid leden%rowtype;
begin
    select * into v_lid from leden where id = p_lid_id;
    if not found then return 'Lid niet gevonden.'; end if;

    update leden set sociaal_tarief = p_sociaal, bijgewerkt_op = now()
     where id = p_lid_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'sociaal_gewijzigd',
            'Sociaal tarief ' || case when p_sociaal then 'aangezet' else 'uitgezet' end || '.', p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_zet_sociaal_tarief is
    'Zet of verwijdert het sociaal tarief van een lid (vereist A-Kaart-check bij check-in).';


-- ----------------------------------------------------------------------------
-- 3. ACTIVITEITEN (admin)
-- ----------------------------------------------------------------------------
create or replace function fn_alle_activiteiten()
returns table (code text, naam text, actief boolean, volgorde integer, gratis boolean)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select a.code, a.naam, a.actief, a.volgorde, a.gratis
    from activiteiten a
    where a.actief
    order by a.volgorde, a.naam;
$$;

comment on function fn_alle_activiteiten is
    'Geeft alle actieve activiteiten terug (incl. gratis-vlag), gebruikt door alle drie de schermen.';

create or replace function fn_maak_activiteit(p_naam text, p_gratis boolean, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_code text;
    v_volgorde integer;
begin
    -- Code: kleine letters, spaties/rare tekens weg.
    v_code := lower(regexp_replace(trim(p_naam), '[^a-zA-Z0-9]+', '_', 'g'));
    v_code := trim(both '_' from v_code);
    if v_code = '' then return 'Ongeldige naam.'; end if;
    if exists(select 1 from activiteiten where code = v_code) then
        return 'Er bestaat al een activiteit met deze naam.';
    end if;
    select coalesce(max(volgorde),0)+1 into v_volgorde from activiteiten;

    insert into activiteiten (code, naam, actief, volgorde, gratis)
    values (v_code, trim(p_naam), true, v_volgorde, coalesce(p_gratis,false));

    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'activiteit_aangemaakt', 'Activiteit aangemaakt: ' || trim(p_naam) || case when p_gratis then ' (gratis).' else '.' end);
    return 'ok';
end;
$$;

comment on function fn_maak_activiteit is
    'Maakt een nieuwe activiteit aan (code afgeleid van de naam), optioneel gratis.';

create or replace function fn_wijzig_activiteit(p_code text, p_naam text, p_gratis boolean, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    update activiteiten set naam = trim(p_naam), gratis = coalesce(p_gratis, gratis)
     where code = p_code;
    if not found then return 'Activiteit niet gevonden.'; end if;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'activiteit_gewijzigd', 'Activiteit gewijzigd: ' || trim(p_naam) || '.');
    return 'ok';
end;
$$;

comment on function fn_wijzig_activiteit is
    'Wijzigt naam en/of gratis-vlag van een bestaande activiteit.';

create or replace function fn_deactiveer_activiteit(p_code text, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    update activiteiten set actief = false where code = p_code;
    if not found then return 'Activiteit niet gevonden.'; end if;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'activiteit_gedeactiveerd', 'Activiteit gedeactiveerd: ' || p_code || '.');
    return 'ok';
end;
$$;

comment on function fn_deactiveer_activiteit is
    'Deactiveert een activiteit (blijft bestaan voor historiek, verschijnt niet meer als actief).';


-- ----------------------------------------------------------------------------
-- 4. SESSIES (admin)
-- ----------------------------------------------------------------------------
create or replace function fn_alle_clubsessies()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'naam', c.naam,
        'activiteit', c.activiteit,
        'momenten', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', m.id, 'weekdag', m.weekdag,
                'start_tijd', to_char(m.start_tijd,'HH24:MI'),
                'eind_tijd', to_char(m.eind_tijd,'HH24:MI'))
            order by m.weekdag, m.start_tijd)
            from sessie_momenten m where m.clubsessie_id = c.id and m.actief), '[]'::jsonb)
    ) order by c.naam), '[]'::jsonb)
    from clubsessies c where c.actief;
$$;

comment on function fn_alle_clubsessies is
    'Geeft alle actieve clubsessies met hun momenten terug als jsonb, voor het admin-portaal.';

create or replace function fn_maak_clubsessie(p_naam text, p_activiteit text, p_medewerker_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
    insert into clubsessies (naam, activiteit, datum, actief, aangemaakt_door)
    values (p_naam, p_activiteit, current_date, true, p_medewerker_id)
    returning id into v_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'clubsessie_aangemaakt', 'Clubsessie aangemaakt: ' || p_naam || ' (' || p_activiteit || ').');
    return v_id;
end;
$$;

comment on function fn_maak_clubsessie is
    'Maakt een nieuwe clubsessie aan (naam + activiteit); momenten worden apart toegevoegd.';

create or replace function fn_wijzig_clubsessie(p_sessie_id uuid, p_naam text, p_activiteit text, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    update clubsessies set naam = p_naam, activiteit = coalesce(p_activiteit, activiteit)
     where id = p_sessie_id;
    if not found then return 'Clubsessie niet gevonden.'; end if;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'clubsessie_gewijzigd', 'Clubsessie gewijzigd: ' || p_naam || '.');
    return 'ok';
end;
$$;

comment on function fn_wijzig_clubsessie is
    'Wijzigt naam en/of activiteit van een bestaande clubsessie.';

create or replace function fn_verwijder_clubsessie(p_sessie_id uuid, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    delete from sessie_momenten where clubsessie_id = p_sessie_id;
    delete from clubsessies where id = p_sessie_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'clubsessie_verwijderd', 'Clubsessie verwijderd.');
    return 'ok';
end;
$$;

comment on function fn_verwijder_clubsessie is
    'Verwijdert een clubsessie en al haar momenten.';

create or replace function fn_voeg_moment_toe(
    p_sessie_id     uuid,
    p_weekdag       integer,
    p_start         time,
    p_eind          time,
    p_medewerker_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
    insert into sessie_momenten (clubsessie_id, weekdag, start_tijd, eind_tijd, actief)
    values (p_sessie_id, p_weekdag, p_start, p_eind, true)
    returning id into v_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'moment_toegevoegd', 'Moment toegevoegd aan clubsessie.');
    return v_id;
end;
$$;

comment on function fn_voeg_moment_toe is
    'Voegt een terugkerend moment (weekdag + tijd) toe aan een clubsessie.';

create or replace function fn_verwijder_moment(p_moment_id uuid, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    delete from sessie_momenten where id = p_moment_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'moment_verwijderd', 'Moment verwijderd.');
    return 'ok';
end;
$$;

comment on function fn_verwijder_moment is
    'Verwijdert één moment van een clubsessie.';


-- ----------------------------------------------------------------------------
-- 5. WIJZIGINGEN & ACCOUNTS (admin)
-- ----------------------------------------------------------------------------
create or replace function fn_recente_wijzigingen(p_limiet integer default 100)
returns table (
    gebeurd_op       timestamptz,
    handeling        text,
    omschrijving     text,
    lid_naam         text,
    medewerker_naam  text
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select h.gebeurd_op, h.handeling, h.omschrijving,
         (l.voornaam || ' ' || l.achternaam) as lid_naam,
         (m.voornaam || ' ' || m.achternaam) as medewerker_naam
  from handelingen_log h
  left join leden l on l.id = h.lid_id
  left join medewerkers m on m.id = h.medewerker_id
  order by h.gebeurd_op desc
  limit p_limiet;
$$;

comment on function fn_recente_wijzigingen is
    'Geeft de recentste gelogde handelingen terug (recentste eerst), voor het admin-portaal.';

create or replace function fn_nieuwe_accounts()
returns table (
    id             uuid,
    voornaam       text,
    achternaam     text,
    geboortejaar   integer,
    postcode       text,
    herkomst       text,
    aangemaakt_op  timestamptz
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select l.id, l.voornaam, l.achternaam, l.geboortejaar, l.postcode, l.herkomst, l.aangemaakt_op
    from leden l
    where l.goedkeuring = 'nieuw'
    order by l.aangemaakt_op;
$$;

comment on function fn_nieuwe_accounts is
    'Geeft alle accounts met goedkeuringsstatus ''nieuw'' terug, voor het admin-portaal.';


-- ----------------------------------------------------------------------------
-- 6. MEDEWERKERS (admin)
-- ----------------------------------------------------------------------------
create or replace function fn_actieve_medewerkers()
returns table (id uuid, voornaam text, achternaam text, is_admin boolean)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select m.id, m.voornaam, m.achternaam, m.is_admin
    from medewerkers m
    where m.actief
    order by m.voornaam;
$$;

comment on function fn_actieve_medewerkers is
    'Geeft actieve medewerkers terug, voor de "Wie werkt nu?"-dropdown.';

create or replace function fn_alle_medewerkers()
returns table (
    id                uuid,
    voornaam          text,
    achternaam        text,
    is_admin          boolean,
    actief            boolean,
    heeft_wachtwoord  boolean
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select m.id, m.voornaam, m.achternaam, m.is_admin, m.actief,
           (m.wachtwoord_hash is not null) as heeft_wachtwoord
    from medewerkers m
    order by m.actief desc, m.voornaam;
$$;

comment on function fn_alle_medewerkers is
    'Geeft alle medewerkers terug (ook inactieve), incl. of ze al een wachtwoord hebben, voor het medewerkersbeheer.';

create or replace function fn_maak_medewerker(
    p_voornaam      text,
    p_achternaam    text,
    p_is_admin      boolean,
    p_medewerker_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
    if trim(coalesce(p_voornaam,'')) = '' then
        raise exception 'Voornaam is verplicht.';
    end if;
    insert into medewerkers (voornaam, achternaam, is_admin, actief)
    values (trim(p_voornaam), nullif(trim(p_achternaam),''), coalesce(p_is_admin,false), true)
    returning id into v_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'medewerker_toegevoegd',
            'Medewerker toegevoegd: ' || trim(p_voornaam) || case when p_is_admin then ' (admin).' else '.' end);
    return v_id;
end;
$$;

comment on function fn_maak_medewerker is
    'Maakt een nieuwe medewerker aan (nog zonder wachtwoord); admin-vlag optioneel.';

create or replace function fn_deactiveer_medewerker(p_doel_id uuid, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_aantal_admins integer;
begin
    -- Voorkom dat de laatste actieve admin verdwijnt.
    if exists(select 1 from medewerkers where id = p_doel_id and is_admin and actief) then
        select count(*) into v_aantal_admins from medewerkers where is_admin and actief;
        if v_aantal_admins <= 1 then
            return 'Dit is de laatste actieve admin en kan niet verwijderd worden.';
        end if;
    end if;
    update medewerkers set actief = false where id = p_doel_id;
    if not found then return 'Medewerker niet gevonden.'; end if;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'medewerker_gedeactiveerd', 'Medewerker gedeactiveerd.');
    return 'ok';
end;
$$;

comment on function fn_deactiveer_medewerker is
    'Deactiveert een medewerker; beschermt de laatste actieve admin.';

create or replace function fn_zet_admin_rechten(p_doel_id uuid, p_is_admin boolean, p_medewerker_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_aantal_admins integer;
begin
    -- Voorkom dat de laatste actieve admin zijn rechten verliest.
    if not p_is_admin and exists(select 1 from medewerkers where id = p_doel_id and is_admin and actief) then
        select count(*) into v_aantal_admins from medewerkers where is_admin and actief;
        if v_aantal_admins <= 1 then
            return 'Dit is de laatste actieve admin; rechten kunnen niet uitgezet worden.';
        end if;
    end if;
    update medewerkers set is_admin = coalesce(p_is_admin,false) where id = p_doel_id;
    if not found then return 'Medewerker niet gevonden.'; end if;
    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'adminrechten_gewijzigd',
            'Admin-rechten ' || case when p_is_admin then 'aangezet.' else 'uitgezet.' end);
    return 'ok';
end;
$$;

comment on function fn_zet_admin_rechten is
    'Zet of verwijdert admin-rechten van een medewerker; beschermt de laatste actieve admin.';


-- ----------------------------------------------------------------------------
-- 7. OFFLINE-CACHE (kassa)
-- ----------------------------------------------------------------------------
create or replace function fn_cache_leden()
returns table (
    id              uuid,
    voornaam        text,
    achternaam      text,
    qr              text,
    sociaal_tarief  boolean,
    geboortejaar    integer
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select l.id, l.voornaam, l.achternaam, k.qr_token as qr,
         l.sociaal_tarief, l.geboortejaar
  from leden l
  left join naamkaartjes k on k.lid_id = l.id and k.geldig
  where l.actief;
$$;

comment on function fn_cache_leden is
    'Minimale ledenlijst (incl. geldig QR-token) voor de lokale offline-cache van de kassa (zie vulCache() in databron.js).';


-- ----------------------------------------------------------------------------
-- 8. GRANTS — alle functies hierboven volgen de bestaande conventie.
-- ----------------------------------------------------------------------------
grant execute on function fn_haal_lid(uuid) to anon;
grant execute on function fn_wijzig_lid(uuid, text, text, integer, text, text, uuid) to anon;
grant execute on function fn_zet_tarieftype(uuid, tarieftype, uuid) to anon;
grant execute on function fn_zet_sociaal_tarief(uuid, boolean, uuid) to anon;

grant execute on function fn_alle_activiteiten() to anon;
grant execute on function fn_maak_activiteit(text, boolean, uuid) to anon;
grant execute on function fn_wijzig_activiteit(text, text, boolean, uuid) to anon;
grant execute on function fn_deactiveer_activiteit(text, uuid) to anon;

grant execute on function fn_alle_clubsessies() to anon;
grant execute on function fn_maak_clubsessie(text, text, uuid) to anon;
grant execute on function fn_wijzig_clubsessie(uuid, text, text, uuid) to anon;
grant execute on function fn_verwijder_clubsessie(uuid, uuid) to anon;
grant execute on function fn_voeg_moment_toe(uuid, integer, time, time, uuid) to anon;
grant execute on function fn_verwijder_moment(uuid, uuid) to anon;

grant execute on function fn_recente_wijzigingen(integer) to anon;
grant execute on function fn_nieuwe_accounts() to anon;

grant execute on function fn_actieve_medewerkers() to anon;
grant execute on function fn_alle_medewerkers() to anon;
grant execute on function fn_maak_medewerker(text, text, boolean, uuid) to anon;
grant execute on function fn_deactiveer_medewerker(uuid, uuid) to anon;
grant execute on function fn_zet_admin_rechten(uuid, boolean, uuid) to anon;

grant execute on function fn_cache_leden() to anon;
