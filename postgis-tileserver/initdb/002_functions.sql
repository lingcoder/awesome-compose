
CREATE EXTENSION IF NOT EXISTS postgis;


CREATE EXTENSION IF NOT EXISTS h3;


CREATE EXTENSION IF NOT EXISTS h3_postgis CASCADE;



-- auto-generated definition
create table if not exists miner_info
(
    id         integer,
    name       varchar(100),
    longitude  double precision,
    latitude   double precision,
    created_at timestamptz(6)
);


ALTER TABLE miner_info ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326);


CREATE INDEX IF NOT EXISTS idx_miner_info_geom ON miner_info USING GIST (geom);


CREATE OR REPLACE FUNCTION update_geom_if_valid()
    RETURNS TRIGGER AS $$
BEGIN
    -- 仅在latitude和longitude均大于0时更新geom字段
    IF NEW.latitude > 0 AND NEW.longitude > 0 THEN
        NEW.geom := ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER update_geom_trigger
    BEFORE INSERT OR UPDATE ON miner_info
    FOR EACH ROW
EXECUTE FUNCTION update_geom_if_valid();


UPDATE miner_info
SET geom = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)
WHERE latitude > 0 AND longitude > 0;



CREATE OR REPLACE FUNCTION public.wifi_h3(z integer, x integer, y integer, query_params json DEFAULT '{"step": 4}'::json)
    RETURNS bytea
    STABLE
    STRICT
    PARALLEL SAFE
    LANGUAGE sql
AS
$function$
WITH
    bounds AS (
        -- Convert tile coordinates to web mercator tile bounds
        SELECT ST_TileEnvelope(z, x, y) AS geom
    ),

    hex_size AS (
        -- Calculate the size of the hexagons based on the tile bounds and the step
        SELECT (ST_XMax(geom) - ST_XMin(geom)) / pow(2, (query_params->>'step')::int) AS size
        FROM bounds
    ),
    hexagons AS (
        -- Generate hexagons within the tile bounds using ST_HexagonGrid
        SELECT (ST_HexagonGrid((SELECT size FROM hex_size), geom)).*
        FROM bounds
    ),
    datas AS (
        -- Summary of populated places grouped by hex
        SELECT COUNT(n.id) AS num, h.i, h.j, h.geom
        FROM hexagons h
                 JOIN miner_info n
            -- Transform the hexagon to 4326 for intersection with the populated places
                      ON ST_Intersects(n.geom, ST_Transform(h.geom, 4326))
        where ST_Contains(ST_TileEnvelope(0, 0, 0), h.geom)
        GROUP BY h.i, h.j, h.geom
    ),
    mvt AS (
        -- Usual tile processing, ST_AsMVTGeom simplifies, quantizes,
        -- and clips to tile boundary
        SELECT ST_AsMVTGeom(datas.geom, bounds.geom) AS geom,
               datas.i, datas.j, datas.num
        FROM datas, bounds
    )

SELECT ST_AsMVT(mvt, 'default') FROM mvt
$function$;





