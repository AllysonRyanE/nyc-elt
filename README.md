# NYC Yellow Taxi ELT (DuckDB)

Pipeline de referência para o Desafio ELT SQL da Liga de Engenharia de Dados (CIn/UFPE), usando a base pública NYC Yellow Taxi Trip Records (janeiro/2024) e DuckDB.

## Scripts

1. `02_perfilamento.sql` — investigação da base bruta (tipos, nulos, cardinalidade, distribuições, duplicidade, valores implausíveis), com os achados comentados junto de cada consulta.
2. `03_camada_tratamento.sql` — constrói `stg_trips`, sem apagar nenhuma linha do bruto: cada regra de qualidade vira uma coluna de flag, documentada e justificada. Inclui `dq_checks`, que recalcula sozinha as contagens de cada verificação.
3. `04_modelo_dimensional.sql` — esquema estrela (fato + dimensões) construído a partir de `stg_trips`, com o grão da fato declarado explicitamente e membro desconhecido nas dimensões.

## Como reproduzir

Pré-requisito: [DuckDB](https://duckdb.org/) instalado, com acesso ao `yellow_tripdata_2024-01.parquet` e `taxi_zone_lookup.csv` (fonte: NYC TLC).

Rodar os scripts nessa ordem, apontando pro banco `.duckdb` já com `raw_trips` e `raw_zones` carregados.
