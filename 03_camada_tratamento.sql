-- ============================================================
-- PASSO 3 -- CAMADA DE TRATAMENTO (stg_trips): flags
-- ============================================================
CREATE OR REPLACE TABLE stg_trips AS
WITH base AS(
SELECT VendorID, tpep_pickup_datetime as pickup_datetime, tpep_dropoff_datetime as dropoff_datetime,
passeger_count, trip_distance, RateCodeID, store_and_fwd_flag, PULocationID as pickup_location_id,
DOLocationID as dropoff_location_id, payment_type, fare_amount, extra, mta_taxi, Airport_fee as airport_fee,
tolls_amount, tip_amount, improvement_surcharge, congestion_surcharge, total_amount, 
date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) AS duracao_minutos,
ABS(total_amount - (COALESCE(fare_amount,0) + COALESCE(extra,0)
+ COALESCE(mta_tax,0) + COALESCE(tip_amount,0) + COALESCE(tolls_amount,0) + COALESCE(improvement_surcharge,0) 
+ COALESCE(congestion_surcharge,0) + COALESCE(Airport_fee,0))) AS diff_sobretaxa, 
from raw_trips), 

CREATE OR REPLACE TABLE stg_trips AS
WITH base AS (
    SELECT
        VendorID,
        tpep_pickup_datetime  AS pickup_datetime,
        tpep_dropoff_datetime AS dropoff_datetime,
        passenger_count,
        trip_distance,
        RatecodeID,
        store_and_fwd_flag,
        PULocationID AS pickup_location_id,
        DOLocationID AS dropoff_location_id,
        payment_type,
        fare_amount,
        extra,
        mta_tax,
        tip_amount,
        tolls_amount,
        improvement_surcharge,
        congestion_surcharge,
        Airport_fee AS airport_fee,
        total_amount,
        date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) AS duracao_minutos,
        ABS(total_amount - (COALESCE(fare_amount,0) + COALESCE(extra,0) + COALESCE(mta_tax,0) + COALESCE(tip_amount,0) + COALESCE(tolls_amount,0) + COALESCE(improvement_surcharge,0) + COALESCE(congestion_surcharge,0) + COALESCE(Airport_fee,0))) AS diff_sobretaxa
    FROM raw_trips
),
flags AS (
    SELECT
        *,
        (payment_type = 0) AS is_flex_fare,
        COALESCE(CAST(RatecodeID AS VARCHAR), CASE WHEN payment_type = 0 THEN 'Flex Fare' END) AS ratecode_resolvido, -- preenche o nulo sistematico com categoria explicita, em vez de deixar em branco
        COALESCE(store_and_fwd_flag, CASE WHEN payment_type = 0 THEN 'N/A (Flex Fare)' END) AS store_and_fwd_flag_resolvido, -- conceito de "guardado no veiculo por falta de conexao" nao existe pra corrida via app
        (passenger_count IS NULL AND payment_type = 0) AS flag_passageiro_nao_aplicavel, -- documenta o motivo do nulo, sem inventar um numero de passageiro que nao existe na fonte

        (improvement_surcharge IN (0.3, -0.3)) AS flag_tarifa_historica, -- resquicio da sobretaxa antiga ($0,30, antes do reajuste pra $1,00), sistema desatualizado, nao e erro

        (fare_amount < 0 OR total_amount < 0) AS flag_provavel_estorno, -- confirmado: estorno/disputa legitimo, nao e erro
        (fare_amount < -50 OR total_amount < -50) AS flag_estorno_extremo, -- separado por magnitude, revisar os casos mais extremos manualmente

        NOT (
            date_trunc('month', pickup_datetime) = DATE '2024-01-01'
            OR (date_trunc('month', pickup_datetime) = DATE '2023-12-01' AND date_trunc('month', dropoff_datetime) = DATE '2024-01-01')
        ) AS flag_data_invalida, -- mantem jan/2024 inteiro + a fronteira dez/23->jan/24; exclui 2002/2009/etc

        (dropoff_datetime < pickup_datetime) AS flag_duracao_negativa, -- logicamente invalido

        (dropoff_datetime >= pickup_datetime AND duracao_minutos > 180 AND duracao_minutos <= 1440) AS flag_duracao_longa, -- 3h a 24h, plausivel
        (duracao_minutos > 1440) AS flag_duracao_extrema, -- mais de 1 dia, separado por ser praticamente impossivel

        (trip_distance > 100) AS flag_distancia_implausivel, -- tarifa associada e normal, defeito isolado no sensor
        (trip_distance = 0 AND fare_amount > 0) AS flag_distancia_zero_com_cobranca, -- provavel cobranca por tempo parado
        (fare_amount > 1000 AND trip_distance = 0 AND RatecodeID = 99) AS flag_teste_placeholder, -- sem correspondencia com corrida real
        (RatecodeID = 1 AND trip_distance > 0.1 AND (fare_amount / trip_distance) > 50) AS flag_preco_milha_suspeito, -- ver view casos_preco_milha_suspeito abaixo
        (payment_type = 2 AND tip_amount > 0) AS flag_gorjeta_dinheiro_indevida, -- viola regra documentada, baixo volume

        (diff_sobretaxa > 0.01) AS flag_sobretaxa_subreportada, -- total_amount confiavel; colunas itemizadas sub-reportam ~25%

        CASE
            WHEN ABS(diff_sobretaxa - 2.50) < 0.01 OR ABS(diff_sobretaxa - 4.25) < 0.01 THEN 2.50
            ELSE congestion_surcharge
        END AS congestion_surcharge_corrigido, -- backfill quando a diferenca bate exatamente com o valor padrao da sobretaxa

        CASE
            WHEN ABS(diff_sobretaxa - 1.75) < 0.01 OR ABS(diff_sobretaxa - 4.25) < 0.01 THEN 1.75
            ELSE airport_fee
        END AS airport_fee_corrigido -- idem, para Airport_fee

    FROM base
)
SELECT
    *,
    NOT (flag_data_invalida OR flag_duracao_negativa OR flag_duracao_extrema OR flag_teste_placeholder) AS registro_valido -- so exclui os achados mais graves e sem explicacao de negocio
FROM flags;

-- ============================================================
-- TABELA DE VERIFICACOES DE QUALIDADE (dq_checks)
-- ============================================================
select * from dq_checks;
CREATE OR REPLACE TABLE dq_checks AS
SELECT 'data_invalida' AS check_nome, SUM(CASE WHEN flag_data_invalida THEN 1 ELSE 0 END) AS qtd, 'Flag e exclusao -- mantem jan/2024 inteiro e a fronteira dez/23->jan/24; exclui 2002, 2009 e demais fora do padrao.' AS justificativa FROM stg_trips
UNION ALL
SELECT 'duracao_negativa', SUM(CASE WHEN flag_duracao_negativa THEN 1 ELSE 0 END), 'Exclusao recomendada -- dropoff antes de pickup e logicamente invalido.' FROM stg_trips
UNION ALL
SELECT 'duracao_longa_3h_a_24h', SUM(CASE WHEN flag_duracao_longa THEN 1 ELSE 0 END), 'Flag, nao exclui -- corrida longa de verdade e possivel dentro de 1 dia.' FROM stg_trips
UNION ALL
SELECT 'duracao_extrema_acima_1_dia', SUM(CASE WHEN flag_duracao_extrema THEN 1 ELSE 0 END), 'Exclusao recomendada -- duracao acima de 1 dia e praticamente impossivel para uma corrida de taxi.' FROM stg_trips
UNION ALL
SELECT 'distancia_implausivel', SUM(CASE WHEN flag_distancia_implausivel THEN 1 ELSE 0 END), 'Flag, nao exclui -- tarifa associada e normal, defeito isolado no sensor de distancia.' FROM stg_trips
UNION ALL
SELECT 'distancia_zero_com_cobranca', SUM(CASE WHEN flag_distancia_zero_com_cobranca THEN 1 ELSE 0 END), 'Flag, nao exclui -- provavel cobranca por tempo parado.' FROM stg_trips
UNION ALL
SELECT 'teste_placeholder', SUM(CASE WHEN flag_teste_placeholder THEN 1 ELSE 0 END), 'Exclusao recomendada -- sem correspondencia com corrida real.' FROM stg_trips
UNION ALL
SELECT 'preco_milha_suspeito', SUM(CASE WHEN flag_preco_milha_suspeito THEN 1 ELSE 0 END), 'Flag, nao exclui -- causa nao totalmente explicada; casos isolados na view casos_preco_milha_suspeito para investigacao/apresentacao continuada.' FROM stg_trips
UNION ALL
SELECT 'gorjeta_dinheiro_indevida', SUM(CASE WHEN flag_gorjeta_dinheiro_indevida THEN 1 ELSE 0 END), 'Flag, nao exclui -- viola regra documentada, baixo volume.' FROM stg_trips
UNION ALL
SELECT 'provavel_estorno', SUM(CASE WHEN flag_provavel_estorno THEN 1 ELSE 0 END), 'Nao e erro -- confirmado como estorno/disputa legitimo.' FROM stg_trips
UNION ALL
SELECT 'estorno_extremo', SUM(CASE WHEN flag_estorno_extremo THEN 1 ELSE 0 END), 'Separado por magnitude (< -50) dentro do grupo de estornos -- revisar os mais extremos manualmente.' FROM stg_trips
UNION ALL
SELECT 'sobretaxa_subreportada', SUM(CASE WHEN flag_sobretaxa_subreportada THEN 1 ELSE 0 END), 'Corrigido -- colunas congestion_surcharge_corrigido/airport_fee_corrigido preenchem o valor quando a diferenca bate com o padrao conhecido da sobretaxa.' FROM stg_trips
UNION ALL
SELECT 'flex_fare_nulos', SUM(CASE WHEN is_flex_fare THEN 1 ELSE 0 END), 'Preenchido -- ratecode_resolvido e store_and_fwd_flag_resolvido usam categoria explicita. passenger_count fica nulo (nao ha numero honesto pra inventar), mas documentado via flag_passageiro_nao_aplicavel.' FROM stg_trips
UNION ALL
SELECT 'tarifa_historica_improvement_surcharge', SUM(CASE WHEN flag_tarifa_historica THEN 1 ELSE 0 END), 'Nao e erro -- resquicio da sobretaxa antiga ($0,30 antes do reajuste pra $1,00), sistema desatualizado.' FROM stg_trips
UNION ALL
SELECT 'registros_invalidos_total', SUM(CASE WHEN NOT registro_valido THEN 1 ELSE 0 END), 'Candidatos a exclusao da fato: data invalida, duracao negativa, duracao extrema (>1 dia) ou teste/placeholder.' FROM stg_trips;

-- ============================================================
-- CHECAGEM DE INTEGRIDADE -- prova de que nada foi perdido
-- ============================================================
SELECT
  (SELECT COUNT(*) FROM raw_trips) AS raw_count,
  (SELECT COUNT(*) FROM stg_trips) AS stg_count,
  (SELECT COUNT(*) FROM raw_trips) = (SELECT COUNT(*) FROM stg_trips) AS nenhuma_linha_perdida;