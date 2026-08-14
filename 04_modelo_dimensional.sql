-- ============================================================
-- PASSO 4 -- MODELO DIMENSIONAL OLAP (star schema)
-- Fonte: stg_trips (so registro_valido = true entra na fato)
-- ============================================================
-- ---- dim_date
CREATE OR REPLACE TABLE dim_date AS
WITH datas AS (
    SELECT unnest(generate_series(DATE '2023-12-01', DATE '2024-02-29', INTERVAL 1 DAY)) AS full_date
)
SELECT
    CAST(strftime(full_date, '%Y%m%d') AS INTEGER) AS date_key,
    full_date,
    year(full_date)  AS year,
    quarter(full_date) AS quarter, -- trimestre
    CASE WHEN month(full_date) <= 6 THEN 1 ELSE 2 END AS semester, -- semestre
    month(full_date) AS month,
    week(full_date) AS week_of_year, -- semana ISO do ano
    CAST(CEIL(day(full_date) / 7.0) AS INTEGER) AS week_of_month, -- semana dentro do mes (1 a 5)
    day(full_date)   AS day,
    dayname(full_date) AS day_name,
    dayofweek(full_date) IN (0, 6) AS is_weekend,
    (full_date IN (DATE '2023-12-25', DATE '2024-01-01', DATE '2024-01-15')) AS is_feriado, -- Natal, Ano Novo, MLK Day
    (full_date = DATE '2023-12-31') AS is_vespera_ano_novo -- nao e feriado oficial, mas dia de demanda atipica relevante pra analise
FROM datas;

-- ---- dim_hour
CREATE OR REPLACE TABLE dim_hour AS
SELECT
    h AS hour_key,
    h AS hour_24,
    CASE
        WHEN h BETWEEN 0 AND 5   THEN 'Madrugada'
        WHEN h BETWEEN 6 AND 11  THEN 'Manha'
        WHEN h BETWEEN 12 AND 17 THEN 'Tarde'
        ELSE 'Noite'
    END AS period_of_day,
    (h >= 16 AND h < 20) AS is_janela_pico_horario, 
    (h >= 20 OR h < 6) AS is_janela_noturna
FROM range(0, 24) AS t(h);

-- ---- dim_location
CREATE OR REPLACE TABLE dim_location AS
SELECT LocationID AS location_id, Borough AS borough, Zone AS zone, service_zone
FROM raw_zones
UNION ALL
SELECT -1, 'Desconhecido', 'Desconhecido', 'Desconhecido';

-- ---- dim_vendor
CREATE OR REPLACE TABLE dim_vendor AS
SELECT * FROM (VALUES
    (1, 'Creative Mobile Technologies'),
    (2, 'Curb Mobility'),
    (6, 'Myle Technologies'),
    (-1, 'Desconhecido')
) AS t(vendor_id, vendor_name);

-- ---- dim_rate_code
CREATE OR REPLACE TABLE dim_rate_code AS
SELECT * FROM (VALUES
    ('1', 'Padrao', false, false),
    ('2', 'JFK', true, true),
    ('3', 'Newark', true, true),
    ('4', 'Nassau ou Westchester', false, true),
    ('5', 'Tarifa negociada', false, true),
    ('6', 'Corrida em grupo', false, true),
    ('99', 'Nulo/desconhecido', false, false),
    ('Flex Fare', 'Flex Fare (tarifa fechada via app, upfront)', false, false)
) AS t(rate_code_key, rate_code_desc, is_aeroporto, is_tarifa_fixa);

-- ---- dim_payment_type ----
CREATE OR REPLACE TABLE dim_payment_type AS
SELECT * FROM (VALUES
    (0, 'Flex Fare'),
    (1, 'Cartao de credito'),
    (2, 'Dinheiro'),
    (3, 'Sem cobranca'),
    (4, 'Disputa'),
    (5, 'Desconhecido'),
    (6, 'Corrida anulada')
) AS t(payment_type_id, payment_desc);

-- ============================================================
-- fact_trips -- grao: 1 linha = 1 corrida valida
-- ============================================================
CREATE OR REPLACE TABLE fact_trips AS
SELECT
    CAST(strftime(pickup_datetime,  '%Y%m%d') AS INTEGER) AS pickup_date_key,
    CAST(strftime(dropoff_datetime, '%Y%m%d') AS INTEGER) AS dropoff_date_key,
    hour(pickup_datetime)  AS pickup_hour_key,
    hour(dropoff_datetime) AS dropoff_hour_key,
    pickup_location_id,
    dropoff_location_id,
    VendorID AS vendor_id,
    ratecode_resolvido AS rate_code_key,
    payment_type AS payment_type_id,
    passenger_count,
    trip_distance,
    fare_amount,
    extra,
    mta_tax,
    tip_amount,
    tolls_amount,
    improvement_surcharge,
    congestion_surcharge_corrigido AS congestion_surcharge,
    airport_fee_corrigido AS airport_fee,
    total_amount,
    duracao_minutos,
    store_and_fwd_flag_resolvido AS store_and_fwd_flag, 
    ROUND(fare_amount / NULLIF(trip_distance, 0), 2) AS preco_por_milha, 
    ROUND(trip_distance / NULLIF(duracao_minutos / 60.0, 0), 2) AS velocidade_media_mph, 
    (date_trunc('month', pickup_datetime) <> date_trunc('month', dropoff_datetime)) AS is_fronteira_mes, 
    flag_provavel_estorno,
    flag_estorno_extremo,
    flag_distancia_implausivel,
    flag_distancia_zero_com_cobranca,
    flag_preco_milha_suspeito,
    flag_gorjeta_dinheiro_indevida,
    flag_duracao_longa,
    flag_tarifa_historica
FROM stg_trips
WHERE registro_valido = true;

-- ============================================================
-- Checagem: quantas linhas ficaram de fora, e se bate com a exclusao esperada
-- ============================================================
SELECT
  (SELECT COUNT(*) FROM stg_trips) AS stg_total,
  (SELECT COUNT(*) FROM fact_trips) AS fact_total,
  (SELECT COUNT(*) FROM stg_trips WHERE NOT registro_valido) AS excluidas,
  (SELECT COUNT(*) FROM stg_trips) - (SELECT COUNT(*) FROM fact_trips) = (SELECT COUNT(*) FROM stg_trips WHERE NOT registro_valido) AS contas_batem;