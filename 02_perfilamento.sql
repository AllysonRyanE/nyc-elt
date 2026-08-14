-- ============================================================
-- PERFILAMENTO — raw_trips (NYC Yellow Taxi, Jan/2024)
-- Queries exatamente como executadas, com achados comentados.
-- ============================================================

SUMMARIZE raw_trips;
--Quartis e std indicam presença forte ou fraca de outliers
--Quartil 75 distante do max ou std maior que a média
-- ACHADO: trip_distance tem avg=3,65 e std=225,46 (std é 62x o avg) — outlier violento confirmado.
-- fare_amount tem avg=18,18 e std=18,95 (parecidos) — outliers existem mas muito menos extremos.
-- passenger_count, RatecodeID, store_and_fwd_flag, congestion_surcharge, Airport_fee: todos com null_percentage=4,73% — mesmo padrão de nulo (ver bloco de correlação mais abaixo).
select * from raw_trips limit 100;

--Mostra quantidade, mas não linhas ou nvl de discrepância
SELECT
    COUNT(*) AS total, -- ACHADO: 2.964.624 linhas
    SUM(CASE WHEN fare_amount < 0 THEN 1 ELSE 0 END)         AS fare_negativo, --Preço por distância (captura negativos, mas não altissimos)
    -- ACHADO: 37.448 negativos. Cruzando com "Outliers monetários" abaixo, só 3.893 são < -50 — maioria é negativo pequeno (estorno/ajuste plausível, não erro grosseiro)
    SUM(CASE WHEN total_amount < 0 THEN 1 ELSE 0 END)        AS total_negativo, --Mesma lacuna do campo à esquerda
    -- ACHADO: 35.504 negativos; só 4.643 são < -50 (mesmo padrão do fare_amount)
    SUM(CASE WHEN trip_distance = 0 THEN 1 ELSE 0 END)       AS distancia_zero, --Distâncias ridiculamente altas ou negativas não capturadas
    -- ACHADO: 60.371 com distância zero — bem mais frequente que distância implausivelmente alta (só 59, ver bloco de distância abaixo)
    SUM(CASE WHEN passenger_count = 0 OR passenger_count IS NULL THEN 1 ELSE 0 END) AS sem_passageiro,
    -- ACHADO: 171.627 (31.465 com passenger_count=0 + 140.162 nulos, conferindo com a distribuição de passageiros abaixo)
    SUM(CASE WHEN tpep_dropoff_datetime < tpep_pickup_datetime THEN 1 ELSE 0 END)   AS dropoff_antes_pickup,
    -- ACHADO: 56 linhas — logicamente inválidas, candidatas fortes a exclusão/flag
    SUM(CASE WHEN date_trunc('month', tpep_pickup_datetime) <> DATE '2024-01-01' THEN 1 ELSE 0 END) AS fora_de_janeiro,
    -- ACHADO: 18 linhas — detalhado no bloco de datas: inclui 2002 (2x), 2009 (3x), dez/2023 (10x) e fev/2024 (3x)
    SUM(CASE WHEN RatecodeID IS NULL THEN 1 ELSE 0 END)      AS ratecode_nulo
    -- ACHADO: 140.162 — número idêntico ao de sem_passageiro por nulo, store_and_fwd_flag nulo etc. (mesmo grupo de linhas, ver correlação)
FROM raw_trips;

--Categoricos precisam visualizar distribuição
SELECT VendorID, COUNT(*) AS qtd FROM raw_trips GROUP BY VendorID ORDER BY qtd DESC;
-- ACHADO: 2=2.234.632 | 1=729.732 | 6=260 — vendor 6 é residual (0,009% da base), mas 100% dessas 260 linhas têm RatecodeID nulo (ver correlação por vendor)

SELECT payment_type, COUNT(*) AS qtd FROM raw_trips GROUP BY payment_type ORDER BY qtd DESC;
-- ACHADO: 1=2.319.046 | 2=439.191 | 0=140.162 | 4=46.628 | 3=19.597 — nenhum valor fora do domínio documentado (0-6); códigos 5 e 6 simplesmente não ocorrem nesse mês

SELECT RatecodeID, COUNT(*) AS qtd FROM raw_trips GROUP BY RatecodeID ORDER BY qtd DESC;
-- ACHADO: 1=2.663.350 | nulo=140.162 | 2=98.713 | 99=28.663 | 5=19.410 | 3=7.954 | 4=6.365 | 6=7 — 99 (Nulo/desconhecido) é documentado oficialmente, não é código estranho

SELECT store_and_fwd_flag, COUNT(*) AS qtd FROM raw_trips GROUP BY store_and_fwd_flag ORDER BY qtd DESC;
-- ACHADO: N=2.813.126 | nulo=140.162 | Y=11.336 — mesmo número de nulo de novo, reforça o padrão

--Duplicatas (observa-se critérios para considerar um duplicata, quais colunas precisam repetir-se)
-- Vale avaliar se registrada duas vezes, mas com divergência de preço
SELECT COUNT(*) AS linhas_em_duplicatas FROM (
SELECT *, COUNT(*) OVER (PARTITION BY VendorID, tpep_pickup_datetime, tpep_dropoff_datetime, PULocationID) AS cnt
FROM raw_trips
QUALIFY cnt > 1
);
-- ACHADO: 71.080 linhas. MAS: inspecionando a amostra salva, as primeiras linhas retornadas têm DOLocationID e fare_amount diferentes entre si —
-- ou seja, essa chave (só 4 colunas) estava gerando falso positivo: pega corridas diferentes que só coincidem no horário/zona de embarque.
-- CONFIRMADO como falso positivo pela query "Duplicata mais restrita" logo abaixo (resultado = 0).

SELECT *, COUNT(*) OVER (PARTITION BY VendorID, tpep_pickup_datetime, tpep_dropoff_datetime, PULocationID) AS cnt
FROM raw_trips
QUALIFY cnt > 1
ORDER BY VendorID, tpep_pickup_datetime
LIMIT 50;
-- ACHADO: confirma o problema acima — ver por exemplo a corrida das 2024-01-11 19:48:56, que aparece 2x com fare_amount 17.7 e 18.4 (diferentes) e DOLocationID 249 e 262 (diferentes)

-- Duplicata mais restrita
SELECT COUNT(*) AS linhas_em_duplicata_exata
FROM (
SELECT COUNT(*) OVER (
PARTITION BY VendorID, tpep_pickup_datetime, tpep_dropoff_datetime,
passenger_count, trip_distance, RatecodeID,
PULocationID, DOLocationID, payment_type, fare_amount, total_amount
) AS cnt
FROM raw_trips
QUALIFY cnt > 1
);
-- ACHADO: 0. Com a chave completa (11 colunas relevantes), a base NÃO TEM nenhuma duplicata exata.
-- Conclusão do ponto "duplicidade": a base está limpa nesse quesito — os 71.080 da chave frouxa eram majoritariamente falso positivo, não duplicidade real.

-- Outlier de distância
SELECT COUNT(*) AS distancia_implausivel FROM raw_trips WHERE trip_distance > 100;
-- ACHADO: 59 linhas — bem menos frequente que distância zero (60.371), mas mais grave em magnitude (chega a 312.722 milhas no extremo, visto no SUMMARIZE)

-- Distribuição de distância:
SELECT
CASE
WHEN trip_distance = 0 THEN '1 - Zero'
WHEN trip_distance <= 1 THEN '2 - Até 1 milha'
WHEN trip_distance <= 3 THEN '3 - 1 a 3 milhas'
WHEN trip_distance <= 5 THEN '4 - 3 a 5 milhas'
WHEN trip_distance <= 10 THEN '5 - 5 a 10 milhas'
WHEN trip_distance <= 50 THEN '6 - 10 a 50 milhas'
WHEN trip_distance <= 100 THEN '7 - 50 a 100 milhas'
WHEN trip_distance is NULL THEN 'NULO'
ELSE '8 - Acima de 100 (implausível)'
END AS faixa_distancia,
COUNT(*) AS qtd
FROM raw_trips
GROUP BY faixa_distancia
ORDER BY faixa_distancia;
-- ACHADO: Zero=60.371 | até 1mi=717.705 | 1-3mi=1.416.215 (maior faixa, bate com a mediana de 1,67mi vista no SUMMARIZE) | 3-5mi=308.574 |
-- 5-10mi=233.505 | 10-50mi=227.842 | 50-100mi=353 | >100mi=59. Soma bate exatamente com o total (2.964.624) — confirma que trip_distance não tem nulo.
-- A faixa 10-50mi é grande, mas plausível: coincide com o volume de corridas RatecodeID=2 (JFK) e 3 (Newark) — corrida de aeroporto é naturalmente mais longa.

-- Códigos de localização fora do domínio
SELECT COUNT(*) AS pickup_sem_zona_correspondente
FROM raw_trips t
LEFT JOIN raw_zones z ON t.PULocationID = z.LocationID
WHERE z.LocationID IS NULL;

SELECT COUNT(*) AS dropoff_sem_zona_correspondente
FROM raw_trips t
LEFT JOIN raw_zones z ON t.DOLocationID = z.LocationID
WHERE z.LocationID IS NULL;
-- ACHADO: Tudo limpo por aqui


-- Tempo de corrida anômalo
SELECT
SUM(CASE WHEN date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) = 0 AND trip_distance > 0 THEN 1 ELSE 0 END) AS duracao_zero_com_distancia,
SUM(CASE WHEN date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) > 180 THEN 1 ELSE 0 END) AS duracao_acima_3h,
MAX(date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime)) AS duracao_maxima_min
FROM raw_trips
WHERE tpep_dropoff_datetime >= tpep_pickup_datetime;
-- ACHADO: duracao_zero_com_distancia=6.265 (pode incluir corridas genuinamente curtas, <1min completo, não só erro) |
-- duracao_acima_3h=1.982 (alto o suficiente pra merecer regra própria) |
-- duracao_maxima_min=9.455 minutos (~6,6 DIAS) — claramente erro de dado, no mesmo nível de gravidade das datas de 2002/2009.

-- Maiores distâncias de corridas
SELECT date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) AS duracao 
FROM raw_trips ORDER BY duracao DESC;


-- Reconciliação interna da própria linha (total_amount bate com a soma dos componentes?)
SELECT
COUNT(*) AS linhas_com_total_incoerente
FROM raw_trips
WHERE ABS(
total_amount - (
COALESCE(fare_amount,0) + COALESCE(extra,0) + COALESCE(mta_tax,0) +
COALESCE(tip_amount,0) + COALESCE(tolls_amount,0) + COALESCE(improvement_surcharge,0) +
COALESCE(congestion_surcharge,0) + COALESCE(Airport_fee,0)
)
) > 0.01;
-- ACHADO: 761838 inconsistências

-- Discrepância de valores
SELECT
MIN(diff) AS diff_minima,
MAX(diff) AS diff_maxima,
AVG(diff) AS diff_media,                          
SUM(CASE WHEN diff > 1 THEN 1 ELSE 0 END)  AS diff_maior_que_1_dolar,
SUM(CASE WHEN diff > 10 THEN 1 ELSE 0 END) AS diff_maior_que_10_dolares
FROM (
SELECT ABS(total_amount - (
COALESCE(fare_amount,0) + COALESCE(extra,0) + COALESCE(mta_tax,0) +
COALESCE(tip_amount,0) + COALESCE(tolls_amount,0) + COALESCE(improvement_surcharge,0) +
COALESCE(congestion_surcharge,0) + COALESCE(Airport_fee,0)
)) AS diff
FROM raw_trips
) t
WHERE diff > 0.01;
-- ACHADO: 2,50 -> 720.377 | 4,25 -> 22.451 | 1,75 -> 18.150 | 4,50 -> 792 | 2,00 -> 42 | 1,95 -> 23 | 1,00 -> 2 | 0,30 -> 1
-- CONCLUSÃO: não é ruído de arredondamento — são valores redondos e explicáveis. 2,50 = congestion_surcharge; 1,75 = Airport_fee;
-- 4,25 = soma dos dois (2,50+1,75). O total_amount inclui esses valores mesmo quando as colunas itemizadas
-- congestion_surcharge/Airport_fee aparecem zeradas/nulas para a mesma linha — total_amount é a fonte confiável,
-- as colunas itemizadas de sobretaxa é que estão sub-reportadas em ~25% da base.

-- mta_tax fora do valor fixo esperado ($0,50)
SELECT mta_tax, COUNT(*) AS qtd FROM raw_trips GROUP BY mta_tax ORDER BY qtd DESC;
-- ACHADO: 0,5 -> 2.900.474 (97,8%, esperado) | -0,5 -> 34.434 (estorno) | 0,0 -> 29.707 | 4,0 -> 5 | 1,4/3,0/0,8/1,6 -> 1 cada (ruído irrelevante)

-- Outliers monetários
SELECT
SUM(CASE WHEN fare_amount < -50 THEN 1 ELSE 0 END)  AS fare_muito_negativo,
SUM(CASE WHEN fare_amount > 500 THEN 1 ELSE 0 END)  AS fare_muito_alto,
SUM(CASE WHEN total_amount < -50 THEN 1 ELSE 0 END) AS total_muito_negativo,
SUM(CASE WHEN total_amount > 500 THEN 1 ELSE 0 END) AS total_muito_alto
FROM raw_trips;
-- ACHADO: fare_muito_negativo=3.893 | fare_muito_alto=46 | total_muito_negativo=4.643 | total_muito_alto=62
-- Confirma: a maior parte dos negativos é "leve" (não passa de -50); os extremos de verdade (como o -899 visto no SUMMARIZE) são raríssimos

-- Gorjeta indevida (não deveria haver registro em dinheiro)
SELECT COUNT(*) AS gorjeta_em_dinheiro_indevida
FROM raw_trips
WHERE payment_type = 2 AND tip_amount > 0;
-- ACHADO: 128 inconsistências

SELECT fare_amount, trip_distance, ROUND(fare_amount/trip_distance,2) as preco_por_milha, tpep_pickup_datetime, tpep_dropoff_datetime, date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) as duracao
from raw_trips 
WHERE RateCodeID = 1 AND trip_distance > 0.1 AND preco_por_milha >0 AND duracao > 0
ORDER BY preco_por_milha ASC;

SELECT AVG(t.preco_por_milha) from
(SELECT ROUND(fare_amount/trip_distance,2) as preco_por_milha from raw_trips where trip_distance>0) t;

-- Preço muito alto por milha na tarifa normal
SELECT COUNT(*) AS preco_por_milha_estranho
FROM raw_trips
WHERE RatecodeID = 1 AND trip_distance > 0.1 AND (fare_amount / trip_distance) > 50;
-- ACHADO: 332 linhas

SELECT fare_amount, trip_distance, ROUND(fare_amount/trip_distance,2) AS preco_por_milha, tpep_pickup_datetime, tpep_dropoff_datetime
FROM raw_trips
WHERE RatecodeID = 1 AND trip_distance > 0.1 AND (fare_amount / trip_distance) > 50
ORDER BY preco_por_milha DESC;
-- ACHADO: casos como $150,70 por 0,32 milha, com 3h30 de duração — sugere tempo parado/trânsito, não erro de tarifa

--- Correlação entre tempo e milha mais cara?
SELECT COUNT(*) AS sobreposicao
FROM raw_trips
WHERE RatecodeID = 1 AND trip_distance > 0.1 AND (fare_amount / trip_distance) > 50
AND date_diff('minute', tpep_pickup_datetime, tpep_dropoff_datetime) > 180;
-- ACHADO: só 6 — a maioria dos 332 casos de preço/milha alto NÃO se explica por duração longa; são fenômenos parcialmente distintos

-- Fare_amount negativo: correlaciona com payment_type de disputa/estorno?
SELECT payment_type, COUNT(*) AS qtd_negativos FROM raw_trips WHERE fare_amount < 0 GROUP BY payment_type ORDER BY qtd_negativos DESC;
-- ACHADO: 4 (Disputa) -> 21.406 | 2 (Dinheiro) -> 8.208 | 3 (Sem cobrança) -> 5.740 | 0 (Flex) -> 2.066 | 1 (Cartão) -> 28
-- CONFIRMA a hipótese: negativo se concentra em "Disputa", quase não aparece em pagamento normal de cartão — é estorno legítimo, não erro de digitação

-- Distribuição de improvement_surcharge
SELECT improvement_surcharge, COUNT(*) AS qtd FROM raw_trips GROUP BY improvement_surcharge ORDER BY qtd DESC;
-- ACHADO: 1,0 -> 2.927.710 (98,8%, valor vigente em 2024) | -1,0 -> 35.500 (estorno) | 0,0 -> 838 |
-- 0,3 -> 574 (valor HISTÓRICO antigo dessa taxa, anterior ao reajuste — resquício de sistema desatualizado) | -0,3 -> 2

-- Fare_amount > 100
SELECT fare_amount, trip_distance, RatecodeID, payment_type, COUNT(*) AS qtd
FROM raw_trips WHERE fare_amount > 100 GROUP BY 1,2,3,4 ORDER BY fare_amount DESC;

-- Distribuição de fare_amount em faixas baseadas nos quartis
SELECT
CASE
    WHEN fare_amount < 0 THEN '0 - Valor negativo'
    WHEN fare_amount BETWEEN 0 AND 8 THEN '1 - Até $8'
    WHEN fare_amount BETWEEN 8.01 AND 12 THEN '2 - Acima de $8 até $12'
    WHEN fare_amount BETWEEN 12.01 AND 20 THEN '3 - Acima de $12 até $20'
    WHEN fare_amount BETWEEN 20.01 AND 40 THEN '4 - Acima de $20 até $40'
    WHEN fare_amount BETWEEN 40.01 AND 60 THEN '5 - Acima de $40 até $60'
    WHEN fare_amount BETWEEN 60.01 AND 80 THEN '6 - Acima de $60 até $80'
    WHEN fare_amount BETWEEN 80.01 AND 100 THEN '7 - Acima de $80 até $100'
    WHEN fare_amount BETWEEN 100.01 AND 120 THEN '8 - Acima de $100 até $120'
    WHEN fare_amount BETWEEN 120.01 AND 140 THEN '9 - Acima de $120 até $140'
    WHEN fare_amount BETWEEN 140.01 AND 160 THEN '10 - Acima de $140 até $160'
    WHEN fare_amount BETWEEN 160.01 AND 180 THEN '11 - Acima de $160 até $180'
    WHEN fare_amount BETWEEN 180.01 AND 200 THEN '12 - Acima de $180 até $200'
    WHEN fare_amount > 200 THEN '13 - Acima de $200'
    ELSE 'NULO'
END AS faixa_fare_amount,
COUNT(*) as qtd,
ROUND(quantile_cont(trip_distance, 0.5), 2) AS distancia_mediana,
ROUND(AVG(trip_distance), 2) AS distancia_media,
ROUND(MAX(trip_distance), 2) AS distancia_maxima,
ROUND(quantile_cont(fare_amount / NULLIF(trip_distance, 0), 0.5), 2) AS preco_mediano_por_milha,
ROUND(AVG(fare_amount / NULLIF(trip_distance, 0)), 2) AS preco_medio_por_milha
FROM raw_trips
GROUP BY faixa_fare_amount
ORDER BY qtd DESC;



-- RatecodeID=2 (JFK): a tarifa fixa realmente se comporta como fixa?
SELECT MIN(fare_amount) AS min_fare, MAX(fare_amount) AS max_fare, AVG(fare_amount) AS avg_fare,
quantile_cont(fare_amount, 0.5) AS mediana
FROM raw_trips WHERE RatecodeID = 2;
-- ACHADO: min=-70, max=82,69, avg=67,09, mediana=70 — mediana bate exatamente com a tarifa fixa oficial do JFK ($70)

SELECT fare_amount, COUNT(*) AS qtd FROM raw_trips WHERE RatecodeID = 2 GROUP BY fare_amount ORDER BY qtd DESC LIMIT 10;
-- ACHADO: 70,0 -> 96.608 (o valor oficial, disparado o mais comum) | -70,0 -> 2.010 (estorno EXATO da tarifa fixa — confirma de vez que negativo = estorno legítimo)
-- Restante são pequenos desvios plausíveis (73,25 / 74,0 / 82,69 etc.), poucos casos cada

-- trip_distance=0: essas corridas realmente têm tarifa zerada, ou foram cobradas mesmo assim?
SELECT
  SUM(CASE WHEN fare_amount = 0 THEN 1 ELSE 0 END) AS fare_tambem_zero,
  SUM(CASE WHEN fare_amount > 0 THEN 1 ELSE 0 END) AS fare_positivo_apesar_disso,
  COUNT(*) AS total
FROM raw_trips WHERE trip_distance = 0;
-- ACHADO: fare_tambem_zero=419 (plausível: cancelada sem cobrança) | fare_positivo_apesar_disso=56.569 (quase 2% da base inteira!) —
-- corridas cobradas (provavelmente por tempo de espera) sem nenhuma distância registrada. Merece regra de tratamento própria.

-- Distribuição de passageiros
SELECT passenger_count, COUNT(*) AS qtd
FROM raw_trips GROUP BY passenger_count ORDER BY passenger_count;
-- ACHADO: 0=31.465 | 1=2.188.739 | 2=405.103 | 3=91.262 | 4=51.974 | 5=33.506 | 6=22.353 | 7=8 | 8=51 | 9=1 | nulo=140.162
-- 7, 8 e 9 passageiros são extremamente raros (juntos, 60 linhas) — improvável mas não necessariamente erro (van/grupo grande)

-- Datas fora do intervalo
SELECT
EXTRACT(year FROM tpep_pickup_datetime)  AS ano,
EXTRACT(month FROM tpep_pickup_datetime) AS mes,
COUNT(*) AS qtd
FROM raw_trips
GROUP BY ano, mes
ORDER BY ano, mes;
-- ACHADO: 2002-12=2 | 2009-01=3 | 2023-12=10 | 2024-01=2.964.606 | 2024-02=3
-- As linhas de 2002 e 2009 são o achado mais grave do perfilamento inteiro — datas completamente fora do universo do desafio, claramente erro de origem

-- Correlação dos nulos padrões
SELECT COUNT(*) AS linhas_com_tudo_nulo_junto
FROM raw_trips
WHERE passenger_count IS NULL
AND RatecodeID IS NULL
AND store_and_fwd_flag IS NULL
AND congestion_surcharge IS NULL
AND Airport_fee IS NULL;
-- ACHADO: 140.162 — bate exatamente com ratecode_nulo, sem_passageiro (parte nula) e store_and_fwd_flag nulo. Confirmado: é o MESMO conjunto de linhas com múltiplos campos ausentes juntos, não nulo espalhado aleatoriamente.

---- Confirma se está concentrado num VendorID específico
SELECT VendorID, COUNT(*) AS qtd
FROM raw_trips
WHERE RatecodeID IS NULL
GROUP BY VendorID
ORDER BY qtd DESC;
-- ACHADO: VendorID 2=91.447 | VendorID 1=48.455 | VendorID 6=260
-- Achado importante: os 260 nulos do VendorID 6 correspondem a 100% das corridas desse vendor (ele tem só 260 no total) —
-- ou seja, o sistema do vendor 6 aparentemente NUNCA preenche RatecodeID. Já os vendors 1 e 2 têm nulo parcial (proporção bem menor do total de cada um).