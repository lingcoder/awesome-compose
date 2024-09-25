-- hexagon function
CREATE OR REPLACE FUNCTION public.hexagon(i integer, j integer, edge double precision)
    RETURNS geometry
    LANGUAGE plpgsql
    IMMUTABLE PARALLEL SAFE STRICT
AS $function$
DECLARE
    h float8 := edge*cos(pi()/6.0);
    cx float8 := 1.5*i*edge;
    cy float8 := h*(2*j+abs(i%2));
BEGIN
    RETURN ST_MakePolygon(ST_MakeLine(ARRAY[
        ST_MakePoint(cx - 1.0*edge, cy + 0),
        ST_MakePoint(cx - 0.5*edge, cy + -1*h),
        ST_MakePoint(cx + 0.5*edge, cy + -1*h),
        ST_MakePoint(cx + 1.0*edge, cy + 0),
        ST_MakePoint(cx + 0.5*edge, cy + h),
        ST_MakePoint(cx - 0.5*edge, cy + h),
        ST_MakePoint(cx - 1.0*edge, cy + 0)
        ]));
END;
$function$
;


-- hexagoncoordinates function
CREATE OR REPLACE FUNCTION public.hexagoncoordinates(bounds geometry, edge double precision, OUT i integer, OUT j integer)
    RETURNS SETOF record
    LANGUAGE plpgsql
    IMMUTABLE PARALLEL SAFE STRICT
AS $function$
DECLARE
    h float8 := edge*cos(pi()/6);
    mini integer := floor(st_xmin(bounds) / (1.5*edge));
    minj integer := floor(st_ymin(bounds) / (2*h));
    maxi integer := ceil(st_xmax(bounds) / (1.5*edge));
    maxj integer := ceil(st_ymax(bounds) / (2*h));
BEGIN
    FOR i, j IN
        SELECT a, b
        FROM generate_series(mini, maxi) a,
             generate_series(minj, maxj) b
        LOOP
            RETURN NEXT;
        END LOOP;
END;
$function$
;


-- tilehexagons function
CREATE OR REPLACE FUNCTION public.tilehexagons(z integer, x integer, y integer, step integer, OUT geom geometry, OUT i integer, OUT j integer)
    RETURNS SETOF record
    LANGUAGE plpgsql
    IMMUTABLE PARALLEL SAFE STRICT
AS $function$
DECLARE
    bounds geometry;
    maxbounds geometry := ST_TileEnvelope(0, 0, 0);
    edge float8;
BEGIN
    bounds := ST_TileEnvelope(z, x, y);
    edge := (ST_XMax(bounds) - ST_XMin(bounds)) / pow(2, step);
    FOR geom, i, j IN
        SELECT ST_SetSRID(hexagon(h.i, h.j, edge), 3857), h.i, h.j
        FROM hexagoncoordinates(bounds, edge) h
        LOOP
            IF maxbounds ~ geom AND bounds && geom THEN
                RETURN NEXT;
            END IF;
        END LOOP;
END;
$function$
;

-- h3 function
CREATE OR REPLACE FUNCTION public.mapview_h3(z integer, x integer, y integer, step integer DEFAULT 4)
    RETURNS bytea
    LANGUAGE sql
    STABLE PARALLEL SAFE STRICT
AS $function$
WITH
    bounds AS (
        -- Convert tile coordinates to web mercator tile bounds
        SELECT ST_TileEnvelope(z, x, y) AS geom
    ),
    rows AS (
        -- Summary of populated places grouped by hex
        SELECT Count(id) AS num,h.i, h.j, h.geom
        -- All the hexes that interact with this tile
        FROM TileHexagons(z, x, y, step) h
                 -- All the populated places
                 JOIN miner_info n
            -- Transform the hex into the SRS (4326 in this case)
            -- of the table of interest
                      ON ST_Intersects(n.geom, ST_Transform(h.geom, 4326))
        GROUP BY h.i, h.j, h.geom
    ),
    mvt AS (
        -- Usual tile processing, ST_AsMVTGeom simplifies, quantizes,
        -- and clips to tile boundary
        SELECT ST_AsMVTGeom(rows.geom, bounds.geom) AS geom,
               rows.i, rows.j,rows.num
        FROM rows, bounds
    )

SELECT ST_AsMVT(mvt, 'default') FROM mvt
$function$
;


CREATE OR REPLACE function public.miner_h3(z integer, x integer, y integer, query_params json DEFAULT '{"step": 4}'::json) returns bytea
    stable
    strict
    parallel safe
    language sql
as
$function$
WITH
    bounds AS (
        -- Convert tile coordinates to web mercator tile bounds
        SELECT ST_TileEnvelope(z, x, y) AS geom
    ),
    datas AS (
        -- Summary of populated places grouped by hex
        SELECT Count(id) AS num,h.i, h.j, h.geom
        -- All the hexes that interact with this tile
        FROM TileHexagons(z, x, y, (query_params->>'step')::int) h
                 -- All the populated places
                 JOIN miner_info n
            -- Transform the hex into the SRS (4326 in this case)
            -- of the table of interest
                      ON ST_Intersects(n.geom, ST_Transform(h.geom, 4326))
        GROUP BY h.i, h.j, h.geom
    ),
    mvt AS (
        -- Usual tile processing, ST_AsMVTGeom simplifies, quantizes,
        -- and clips to tile boundary
        SELECT ST_AsMVTGeom(datas.geom, bounds.geom) AS geom,
               datas.i, datas.j,datas.num
        FROM datas, bounds
    )

SELECT ST_AsMVT(mvt, 'default') FROM mvt
$function$;


--
CREATE EXTENSION h3;
CREATE EXTENSION h3_postgis CASCADE;


CREATE INDEX idx_miner_info_geom
    ON miner_info USING GIST (geom);
