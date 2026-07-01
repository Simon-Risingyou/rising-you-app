-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0019: nieuw lid aanmaken aan de kassa
-- ----------------------------------------------------------------------------
-- Ontbrak volledig: "Nieuw profiel" op de check-in-pagina maakte tot nu toe
-- enkel een lokaal, niet-bewaard nep-profiel aan (geen databankfunctie
-- bestond hiervoor). fn_maak_lid voegt een echt lid toe.
--
-- goedkeuring = 'nieuw' (expliciet, niet de kolom-default 'goedgekeurd'):
-- zelfde afspraak als bij zelfregistratie (zie migratie 0010) — een admin
-- keurt het profiel later goed via "Nieuwe accounts". Dit blokkeert het
-- inchecken zelf niet: fn_checkin_lid filtert enkel op leden.actief, niet
-- op goedkeuring, dus het lid kan METEEN in de wachtkamer.
-- ============================================================================
create or replace function fn_maak_lid(
    p_voornaam       text,
    p_achternaam     text,
    p_geboortejaar   integer,
    p_postcode       text,
    p_herkomst       text,
    p_sociaal_tarief boolean,
    p_medewerker_id  uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_id uuid;
begin
    if trim(coalesce(p_voornaam, '')) = '' then
        raise exception 'Voornaam is verplicht.';
    end if;

    insert into leden (
        voornaam, achternaam, geboortejaar, postcode, herkomst,
        sociaal_tarief, actief, goedkeuring
    )
    values (
        trim(p_voornaam), nullif(trim(coalesce(p_achternaam, '')), ''), p_geboortejaar,
        nullif(trim(coalesce(p_postcode, '')), ''), nullif(trim(coalesce(p_herkomst, '')), ''),
        coalesce(p_sociaal_tarief, false), true, 'nieuw'
    )
    returning id into v_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'lid_aangemaakt',
            'Nieuw profiel aangemaakt aan de kassa: ' || trim(p_voornaam) || '.', v_id);

    return v_id;
end;
$$;

comment on function fn_maak_lid is
    'Maakt een nieuw lid aan de kassa aan (goedkeuring=nieuw, admin keurt later goed via Nieuwe accounts). Blokkeert het meteen inchecken niet.';

grant execute on function fn_maak_lid(text, text, integer, text, text, boolean, uuid) to anon;
