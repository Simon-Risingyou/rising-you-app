-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0002: kernlogica als databasefuncties
-- ----------------------------------------------------------------------------
-- We zetten de belangrijkste beslissingen in de database zelf:
--   - fn_verwerk_scan       : neemt een QR-token, bepaalt groen/rood, trekt
--                             eventueel een beurt af, maakt de check-in aan.
--   - fn_nieuw_kaartje      : maakt een nieuw kaartje (failsafe via trigger).
--   - fn_rond_wachtkamer_af : controleert afvinkjes en wijst toe aan sessie.
--
-- Voordeel: de kassa-app en de website krijgen exact hetzelfde gedrag, en
-- gelijktijdige acties kunnen elkaar niet in de war sturen.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- fn_verwerk_scan
-- Input : qr_token (uit de QR-code), medewerker_id (wie scant)
-- Output: één rij met de info die de kassabediende nodig heeft in de pop-up.
--
-- Beslissingsregels (in deze volgorde):
--   1. Token onbekend of kaartje ongeldig  -> fout (lid niet gevonden).
--   2. Geldig abonnement vandaag            -> GROEN, geen beurt afgetrokken.
--   3. Geen abonnement, wel beurt over      -> GROEN, beurt afgetrokken.
--   4. Niets geldig                         -> ROOD (lid moet bijbetalen),
--                                              check-in wordt toch aangemaakt
--                                              (komt rood in de wachtkamer).
-- ----------------------------------------------------------------------------
create or replace function fn_verwerk_scan(
    p_qr_token       text,
    p_medewerker_id  uuid
)
returns table (
    checkin_id          uuid,
    lid_id              uuid,
    voornaam            text,
    achternaam          text,
    foto_pad            text,
    sociaal_tarief      boolean,
    resultaat           checkin_resultaat,
    beurten_resterend   integer,    -- na deze scan; null indien n.v.t.
    abonnement_geldig   boolean,
    abonnement_tot      date,
    moet_akaart         boolean,    -- true als sociaal tarief -> A-Kaart nodig
    gevonden            boolean     -- false = token onbekend/ongeldig
)
language plpgsql
as $$
declare
    v_lid           leden%rowtype;
    v_kaartje_id    uuid;
    v_abo           abonnementen%rowtype;
    v_kaart         beurtenkaarten%rowtype;
    v_resultaat     checkin_resultaat;
    v_beurt_af      boolean := false;
    v_kaart_id      uuid := null;
    v_rest          integer := null;
    v_abo_geldig    boolean := false;
    v_abo_tot       date := null;
    v_checkin_id    uuid;
begin
    -- 1. Zoek het geldige kaartje bij dit token.
    select n.id, l.*
      into v_kaartje_id, v_lid
      from naamkaartjes n
      join leden l on l.id = n.lid_id
     where n.qr_token = p_qr_token
       and n.geldig
       and l.actief
     limit 1;

    if not found then
        -- Onbekend of ongeldig kaartje: niets aanmaken, gevonden = false.
        return query
            select null::uuid, null::uuid, null::text, null::text, null::text,
                   null::boolean, null::checkin_resultaat, null::integer,
                   null::boolean, null::date, null::boolean, false;
        return;
    end if;

    -- 2. Geldig abonnement vandaag?
    select * into v_abo
      from abonnementen
     where lid_id = v_lid.id
       and actief
       and current_date between start_datum and eind_datum
     order by eind_datum desc
     limit 1;

    if found then
        v_abo_geldig := true;
        v_abo_tot    := v_abo.eind_datum;
        v_resultaat  := 'groen';
        -- Geen beurt aftrekken bij geldig abonnement.
    else
        -- 3. Geen abonnement: probeer een beurt af te trekken.
        --    'for update' vergrendelt de rij kort zodat twee scans tegelijk
        --    niet dezelfde laatste beurt aftrekken.
        select * into v_kaart
          from beurtenkaarten
         where lid_id = v_lid.id
           and actief
           and beurten_resterend > 0
         order by aangemaakt_op asc
         limit 1
         for update;

        if found then
            update beurtenkaarten
               set beurten_resterend = beurten_resterend - 1
             where id = v_kaart.id
            returning beurten_resterend into v_rest;

            v_beurt_af  := true;
            v_kaart_id  := v_kaart.id;
            v_resultaat := 'groen';
        else
            -- 4. Niets geldig -> rood.
            v_resultaat := 'rood';
        end if;
    end if;

    -- Maak de check-in aan (komt in de wachtkamer).
    insert into checkins (
        lid_id, naamkaartje_id, medewerker_id, resultaat,
        beurtenkaart_id, beurt_afgetrokken,
        betaling_ok, akaart_ok, status
    )
    values (
        v_lid.id, v_kaartje_id, p_medewerker_id, v_resultaat,
        v_kaart_id, v_beurt_af,
        -- betaling_ok start true bij groen (al geldig), false bij rood.
        (v_resultaat = 'groen'),
        -- akaart_ok: null als geen sociaal tarief, anders false (nog afvinken).
        case when v_lid.sociaal_tarief then false else null end,
        'in_wachtkamer'
    )
    returning id into v_checkin_id;

    -- Log de handeling.
    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (
        p_medewerker_id,
        'checkin',
        'Scan: ' || v_resultaat::text || case when v_beurt_af then ' (beurt afgetrokken)' else '' end,
        v_lid.id, v_checkin_id
    );

    return query
        select v_checkin_id, v_lid.id, v_lid.voornaam, v_lid.achternaam, v_lid.foto_pad,
               v_lid.sociaal_tarief, v_resultaat, v_rest,
               v_abo_geldig, v_abo_tot, v_lid.sociaal_tarief, true;
end;
$$;

comment on function fn_verwerk_scan is
    'Verwerkt een QR-scan: bepaalt groen/rood, trekt evt. een beurt af, maakt de check-in in de wachtkamer.';


-- ----------------------------------------------------------------------------
-- fn_nieuw_kaartje
-- Maakt een nieuw geldig kaartje voor een lid en geeft het token terug.
-- De trigger trg_kaartje_failsafe maakt automatisch oude kaartjes ongeldig.
-- Het token is willekeurig en niet-raadbaar (geen lidgegevens erin).
-- ----------------------------------------------------------------------------
create or replace function fn_nieuw_kaartje(
    p_lid_id         uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
declare
    v_token text;
begin
    -- Willekeurige token: 'RY-' + 24 hex-tekens. Uniek door de unique-constraint;
    -- bij de zeldzame botsing probeert de aanroeper gewoon opnieuw.
    v_token := 'RY-' || encode(gen_random_bytes(12), 'hex');

    insert into naamkaartjes (lid_id, qr_token, geldig, aangemaakt_door)
    values (p_lid_id, v_token, true, p_medewerker_id);

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'kaartje_aangemaakt',
            'Nieuw kaartje aangemaakt; oude kaartjes zijn nu ongeldig.', p_lid_id);

    return v_token;
end;
$$;

comment on function fn_nieuw_kaartje is
    'Maakt een nieuw geldig QR-kaartje. Oude kaartjes worden automatisch ongeldig (failsafe).';


-- ----------------------------------------------------------------------------
-- fn_rond_wachtkamer_af
-- Wijst een check-in toe aan een losse klimsessie of clubsessie, maar enkel
-- als aan alle voorwaarden is voldaan:
--   - betaling_ok = true
--   - als sociaal tarief: akaart_ok = true
-- Anders weigert de functie met een duidelijke melding.
-- ----------------------------------------------------------------------------
create or replace function fn_rond_wachtkamer_af(
    p_checkin_id     uuid,
    p_toewijzing     toewijzing_type,
    p_clubsessie_id  uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
as $$
declare
    v_checkin checkins%rowtype;
begin
    select * into v_checkin from checkins where id = p_checkin_id for update;

    if not found then
        return 'Check-in niet gevonden.';
    end if;

    if not v_checkin.betaling_ok then
        return 'Betaling is nog niet afgevinkt.';
    end if;

    -- akaart_ok is null bij geen sociaal tarief; dan is de A-Kaart niet nodig.
    if v_checkin.akaart_ok is not null and v_checkin.akaart_ok = false then
        return 'A-Kaart-check is nog niet afgevinkt.';
    end if;

    if p_toewijzing = 'clubsessie' and p_clubsessie_id is null then
        return 'Kies eerst een clubsessie.';
    end if;

    update checkins
       set status        = 'toegewezen',
           toewijzing    = p_toewijzing,
           clubsessie_id = case when p_toewijzing = 'clubsessie' then p_clubsessie_id else null end,
           toegewezen_op = now()
     where id = p_checkin_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id, checkin_id)
    values (p_medewerker_id, 'toegewezen',
            'Lid toegewezen aan ' || p_toewijzing::text, v_checkin.lid_id, p_checkin_id);

    return 'ok';
end;
$$;

comment on function fn_rond_wachtkamer_af is
    'Wijst een check-in toe aan een sessie, mits betaling (en evt. A-Kaart) zijn afgevinkt.';
