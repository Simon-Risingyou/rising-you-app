-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0013: visuele kaart-editor (layout van het lidkaartje)
-- ----------------------------------------------------------------------------
-- Het kaartontwerp (85 x 54 mm, liggend) was hardgecodeerd in jsPDF. Deze
-- migratie maakt het instelbaar: één rij met de achtergrondafbeelding en de
-- positie/grootte van de QR-box en de naam-box, aan te passen via een
-- visuele editor in het admin portaal en toegepast bij het printen.
--
-- De achtergrond wordt bewaard als data-URL (base64) in een tekstkolom i.p.v.
-- via Supabase Storage: er is nog geen bucket opgezet, het gaat om één
-- zelden wijzigende afbeelding, en dit houdt de infrastructuur eenvoudig
-- voor een VZW met beperkt budget.
-- ============================================================================
create table kaart_layout (
    id                  boolean primary key default true check (id),
    achtergrond_data    text,               -- data-URL (base64) van de achtergrond, of null
    qr_x                numeric not null default 8,
    qr_y                numeric not null default 10,
    qr_grootte          numeric not null default 34,
    naam_x              numeric not null default 48,
    naam_y              numeric not null default 26,
    naam_lettergrootte  numeric not null default 15,
    ondertitel          text not null default 'Rising You — lidkaart',
    ondertitel_y        numeric not null default 33,
    bijgewerkt_op       timestamptz not null default now(),
    bijgewerkt_door     uuid references medewerkers(id)
);

comment on table kaart_layout is
    'Eén rij (singleton): het instelbare ontwerp van het lidkaartje (85x54mm), bewerkt via de visuele editor in het admin portaal.';

-- Startrij, zodat fn_haal_kaart_layout altijd iets teruggeeft (met de
-- huidige hardgecodeerde waarden uit doePrint() als standaard).
insert into kaart_layout (id) values (true);


-- ----------------------------------------------------------------------------
-- fn_haal_kaart_layout
-- ----------------------------------------------------------------------------
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
        'ondertitel', ondertitel, 'ondertitel_y', ondertitel_y
    )
    from kaart_layout where id = true;
$$;

comment on function fn_haal_kaart_layout is
    'Geeft het huidige kaartontwerp terug (achtergrond + positie/grootte van QR- en naam-box), voor de editor en het printen.';


-- ----------------------------------------------------------------------------
-- fn_bewaar_kaart_layout
-- ----------------------------------------------------------------------------
create or replace function fn_bewaar_kaart_layout(
    p_achtergrond_data    text,
    p_qr_x                numeric,
    p_qr_y                numeric,
    p_qr_grootte          numeric,
    p_naam_x              numeric,
    p_naam_y              numeric,
    p_naam_lettergrootte  numeric,
    p_ondertitel          text,
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
        ondertitel         = coalesce(nullif(trim(p_ondertitel), ''), ondertitel),
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
    'Bewaart het kaartontwerp (achtergrond + positie/grootte van QR- en naam-box), via de visuele editor.';

grant execute on function fn_haal_kaart_layout() to anon;
grant execute on function fn_bewaar_kaart_layout(text, numeric, numeric, numeric, numeric, numeric, numeric, text, numeric, uuid) to anon;
