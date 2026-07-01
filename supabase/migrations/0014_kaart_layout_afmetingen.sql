-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0014: kaart-editor — grootte van de vakken + losse ondertitel-box
-- ----------------------------------------------------------------------------
-- Feedback na het testen van de kaart-editor (migratie 0013):
--   - De naam-box had geen instelbare breedte: bij een groter lettertype
--     paste de naam niet meer in de (impliciet berekende) breedte.
--   - De ondertitel was geen los verschuifbaar tekstvak, enkel een vaste
--     y-positie gekoppeld aan de naam-x.
-- Deze migratie voegt naam_breedte (mm, = jsPDF maxWidth) en ondertitel_x
-- toe, zodat de naam-box in breedte versleepbaar is en de ondertitel een
-- eigen, los verplaatsbaar vak wordt. (De QR-box had al een instelbare
-- grootte; de editor krijgt er een sleep-handvat bij, geen kolomwijziging.)
-- ============================================================================
alter table kaart_layout
    add column if not exists naam_breedte numeric not null default 33,
    add column if not exists ondertitel_x numeric not null default 48;

comment on column kaart_layout.naam_breedte is
    'Breedte (mm) van het naam-tekstvak; bepaalt waar de naam automatisch afbreekt (jsPDF maxWidth). Versleepbaar via een handvat rechts.';
comment on column kaart_layout.ondertitel_x is
    'x-positie (mm) van de ondertitel — los van de naam-positie versleepbaar.';

create or replace function fn_haal_kaart_layout()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    select jsonb_build_object(
        'achtergrond_data', achtergrond_data,
        'qr_x', qr_x, 'qr_y', qr_y, 'qr_grootte', qr_grootte,
        'naam_x', naam_x, 'naam_y', naam_y, 'naam_lettergrootte', naam_lettergrootte,
        'naam_breedte', naam_breedte,
        'ondertitel', ondertitel, 'ondertitel_x', ondertitel_x, 'ondertitel_y', ondertitel_y
    )
    from kaart_layout where id = true;
$$;

comment on function fn_haal_kaart_layout is
    'Geeft het huidige kaartontwerp terug (achtergrond + positie/grootte van QR-, naam- en ondertitel-box), voor de editor en het printen.';

-- Parameterlijst wijzigt (2 extra parameters) -> eerst de oude functie weg,
-- anders blijft de oude overload naast de nieuwe bestaan.
drop function if exists fn_bewaar_kaart_layout(text, numeric, numeric, numeric, numeric, numeric, numeric, text, numeric, uuid);

create function fn_bewaar_kaart_layout(
    p_achtergrond_data    text,
    p_qr_x                numeric,
    p_qr_y                numeric,
    p_qr_grootte          numeric,
    p_naam_x              numeric,
    p_naam_y              numeric,
    p_naam_lettergrootte  numeric,
    p_naam_breedte        numeric,
    p_ondertitel          text,
    p_ondertitel_x        numeric,
    p_ondertitel_y        numeric,
    p_medewerker_id       uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
    update kaart_layout set
        achtergrond_data   = p_achtergrond_data,
        qr_x               = p_qr_x,
        qr_y               = p_qr_y,
        qr_grootte         = p_qr_grootte,
        naam_x             = p_naam_x,
        naam_y             = p_naam_y,
        naam_lettergrootte = p_naam_lettergrootte,
        naam_breedte       = p_naam_breedte,
        ondertitel         = coalesce(nullif(trim(p_ondertitel), ''), ondertitel),
        ondertitel_x       = p_ondertitel_x,
        ondertitel_y       = p_ondertitel_y,
        bijgewerkt_op      = now(),
        bijgewerkt_door    = p_medewerker_id
    where id = true;

    insert into handelingen_log (medewerker_id, handeling, omschrijving)
    values (p_medewerker_id, 'kaartontwerp_gewijzigd', 'Kaartontwerp (lidkaartje) bijgewerkt.');
    return 'ok';
end;
$$;

comment on function fn_bewaar_kaart_layout is
    'Bewaart het kaartontwerp (achtergrond + positie/grootte van QR-, naam- en ondertitel-box), via de visuele editor.';

grant execute on function fn_bewaar_kaart_layout(text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, numeric, numeric, uuid) to anon;
