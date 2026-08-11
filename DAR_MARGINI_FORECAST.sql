CREATE OR REPLACE PROCEDURE `a2a-labrrclab-prd.L0.DAR_MARGINI_FORECAST`()
BEGIN


DECLARE campi_comuni STRING; #per facilitare l'accodamento delle proiezione alla tabella delle code, la lista dei campi è stata resa dinamica. A questo parametro NON deve essere assegnato un valore.
DECLARE TOLLERANZA INT64; #da 0 a 100. Se è impostato su 15, il volume delle proiezioni deve essere almeno quello della coda-15% per essere accettato. A questo parametro DEVE essere assegnato un valore.
DECLARE fine_scenario DATE; #determina l'ultima competenza dello scenario. Se uguale a 2029-01-01, lo scenario includerà competenze fino al 2028-12-31 incluso. A questo parametro NON deve essere assegnato un valore.
DECLARE MESI_CESSATI INT64; #di quanti mesi la max data_delivery deve essere precedente al mese corrente perchè un cliente sia considerato attivo. Se è uguale a 3 e oggi siamo a giu26, saranno considerati cessati tutti i clienti la cui max data_delivery <= mar26. A questo parametro DEVE essere assegnato un valore.


SET TOLLERANZA = 15;
SET MESI_CESSATI = 3;
SET FINE_SCENARIO = Date(DATE_TRUNC(DATE_ADD(CURRENT_DATE(), INTERVAL 2 YEAR), YEAR) + INTERVAL 12 MONTH); #al momento coincide con 2029-01-01 quindi sono inclusi tutti i mesi < o = al 2028-12-01


# 0. Creo tabella di output con tutti i record pubblicati nel report margini che abbiano competenza < fine scenario. Creo i campi calcolati:
# - PIVA_CFISC_FORECAST contiene la chiave per individuare ciascun cliente secondo quest'ordine di priorità: piva/cfisc off > piva/cfisc titolare > ragsoc off
# - NOTE_PIVA_CFISC_FORECAST riporta l'informazione inserita nel campo precedente
# - campi vuoti che verranno popolati successivamente solo per le proiezioni: TIPO_PIVA_CFISC_FORECAST,PROIEZIONE_RANK, PROIEZIONE_NOTE, PROIEZIONE_DATA_DELIVERY, CODE_MIN_DATA_DELIVERY, CHIAVE_CLIENTE_FORECAST,
# - il campo NOTE_FORECAST che indica il tipo di record. In questa fase è valorizzato a 'Coda' per tutti i record
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
  PARTITION BY DATA_DELIVERY
  CLUSTER BY COMMODITY_G_E, P_IVA_OFFERTABILE, MACROAREA_NEW, MACRO_AREA
AS
SELECT
  *,
  CASE
    WHEN
      COALESCE(P_IVA_OFFERTABILE, COD_FISC_OFFERTABILE) IS NULL
      OR COALESCE(P_IVA_OFFERTABILE, COD_FISC_OFFERTABILE)
        IN ('ND', '00000000000', '***')
      THEN
        CASE
          WHEN
            COALESCE(P_IVA_TITOLARE, COD_FISC_TITOLARE) IS NULL
            OR COALESCE(P_IVA_TITOLARE, COD_FISC_TITOLARE)
              IN ('ND', '00000000000', '***')
            THEN COALESCE(RAG_SOC_OFFERTABILE, CLIENTE)
          ELSE COALESCE(P_IVA_TITOLARE, COD_FISC_TITOLARE)
          END
    ELSE COALESCE(P_IVA_OFFERTABILE, COD_FISC_OFFERTABILE)
    END AS PIVA_CFISC_FORECAST,
  CASE
    WHEN
      COALESCE(P_IVA_OFFERTABILE, COD_FISC_OFFERTABILE) IS NULL
      OR COALESCE(P_IVA_OFFERTABILE, COD_FISC_OFFERTABILE)
        IN ('ND', '00000000000', '***')
      THEN
        CASE
          WHEN
            COALESCE(P_IVA_TITOLARE, COD_FISC_TITOLARE) IS NULL
            OR COALESCE(P_IVA_TITOLARE, COD_FISC_TITOLARE)
              IN ('ND', '00000000000', '***')
            THEN 'RAG_SOC_OFFERTABILE o CLIENTE'
          ELSE 'PIVA_TITOLARE o CFISC_TITOLARE'
          END
    ELSE 'PIVA_OFFERTABILE o CFISC_OFFERTABILE'
    END AS NOTE_PIVA_CFISC_FORECAST,
  CAST(NULL AS string) AS TIPO_PIVA_CFISC_FORECAST,
  CAST(NULL AS INT64) AS PROIEZIONE_RANK,
  CAST(NULL AS STRING) AS PROIEZIONE_NOTE,
  CAST(NULL AS DATETIME) AS PROIEZIONE_DATA_DELIVERY,
  CAST(NULL AS DATETIME) AS CODE_MIN_DATA_DELIVERY,
  CAST(NULL AS STRING) AS CHIAVE_CLIENTE_FORECAST,
  'Coda' AS NOTE_FORECAST
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_MASTER_PBI` PBI
WHERE
  PBI.DATA_DELIVERY < FINE_SCENARIO
  AND PBI.FLG_PUBBLICATO_S_N = 'S';

# 1. Creo tabella d'appoggio per distinguere clienti che hanno sempre il pdp da quelli che non l'hanno sempre o non l'hanno mai.
# Trasferisco l'informazione nel campo TIPO_PIVA_CFISC_FORECAST della tabella di output.
# Inoltre, calcolo la chiave per identificare ogni cliente o pdp in base al tipo. Scrivo l'informazione nel campo CHIAVE_CLIENTE_FORECAST.
# In questo passaggio, evito di considerare i fixing e gli storni perchè non verranno proiettati quindi la loro granularità non rileva.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_TIPO`
AS
WITH
  costruisci_check AS (
    SELECT
      COMMODITY_G_E,
      PIVA_CFISC_FORECAST,
      check,
      COUNT(DISTINCT check)
        OVER (PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST) AS conteggio
    FROM
      (
        SELECT DISTINCT
          M.COMMODITY_G_E,
          PIVA_CFISC_FORECAST,
          SUM(M.VOLUME_COPERTO_MC_MWH) AS MC_MWH,
          COUNT(DISTINCT M.COD_OFFERTA),
          CASE
            WHEN
              M.PDP IS NOT NULL
              AND M.PDP NOT IN ('00000000000000', '***', 'ND')
              AND M.PDP NOT LIKE 'DSB%'
              THEN 'HA IL PUNTO'
            ELSE 'NON HA IL PUNTO'
            END AS CHECK
        FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` M
        WHERE
          M.COD_OFFERTA NOT LIKE '%F%'
          AND M.COD_OFFERTA NOT LIKE 'S-%'
          AND M.DATA_DELIVERY < FINE_SCENARIO
          AND M.FLG_PUBBLICATO_S_N = 'S'
        GROUP BY ALL
        ORDER BY M.PIVA_CFISC_FORECAST ASC
      )
  )
SELECT DISTINCT
  COMMODITY_G_E,
  PIVA_CFISC_FORECAST,
  CASE
    WHEN conteggio = 1 AND check = 'HA IL PUNTO'
      THEN 'PIVA_CFISC_FORECAST ha sempre il pdp'
    WHEN CONTEGGIO = 1 AND CHECK = 'NON HA IL PUNTO'
      THEN 'PIVA_CFISC_FORECAST non ha mai il pdp'
    ELSE 'PIVA_CFISC_FORECAST non ha sempre il pdp'
    END AS TIPO
FROM costruisci_check;

MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * 
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_TIPO` PBI
) AS tipo_
ON
  mar.PIVA_CFISC_FORECAST = tipo_.PIVA_CFISC_FORECAST
  AND mar.commodity_g_E
    = tipo_.COMMODITY_G_E
      WHEN MATCHED
        THEN
          UPDATE
SET
  mar.tipo_PIVA_CFISC_FORECAST = tipo_.tipo,
  mar.CHIAVE_CLIENTE_FORECAST = case when tipo_.tipo = 'PIVA_CFISC_FORECAST ha sempre il pdp' then MAR.PDP ELSE MAR.PIVA_CFISC_FORECAST END
  ;


# Per ogni chiave calcolo la minima data delivery e la scrivo nel campo MIN_DATA_DELIVERY dell'output.
# Servirà per impedire che le proiezioni aggiungano competenze antecedenti alla minima data delivery per chiave.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_MIN_DATA_DELIVERY_CODE` AS
SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST,
MIN(DATA_DELIVERY) AS MIN_DATA_DELIVERY
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
GROUP BY ALL
;

MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_MIN_DATA_DELIVERY_CODE` PBI
) AS MIN_CODE
ON
  mar.CHIAVE_CLIENTE_FORECAST = MIN_CODE.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E
    = MIN_CODE.COMMODITY_G_E
      WHEN MATCHED
        THEN
          UPDATE
SET
  mar.CODE_MIN_DATA_DELIVERY = MIN_CODE.MIN_DATA_DELIVERY;


# 2. Definisco i cessati quali clienti la cui massima competenza è < mese corrente - mesi_cessati. Sovrascrivo il campo NOTE_FORECAST della tabella di output con l'etichetta "Coda di cliente cessato".
MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT
    PBI.COMMODITY_G_E,
    PBI.PIVA_CFISC_FORECAST,
    MAX(DATA_DELIVERY) AS MAX_DATA_DELIVERY
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` PBI
  GROUP BY ALL
  HAVING
    MAX_DATA_DELIVERY <= date_Add(
      DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL - MESI_CESSATI month)
  ORDER BY MAX_DATA_DELIVERY DESC
) AS cessati
ON
  mar.PIVA_CFISC_FORECAST = cessati.PIVA_CFISC_FORECAST
  AND mar.COMMODITY_G_E
    = cessati.COMMODITY_G_E
      WHEN MATCHED
        THEN
          UPDATE
SET
  mar.note_forecast = 'Coda di cliente cessato';


# 3. Costruisco un calendario rolling che includa tutti i mesi da quello in corso fino al mese precedente alla fine_scenario.

CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CALENDARIO_PROIEZIONI`
AS (
  SELECT
  date_trunc(date, month) AS DATA_DELIVERY
FROM
  UNNEST(
    GENERATE_DATE_ARRAY(
      date(DATE_ADD(CURRENT_DATE(), INTERVAL 1 MONTH)),
      FINE_SCENARIO,
      INTERVAL 1 MONTH
    )
  ) AS date
ORDER BY
  date
)
;


# Individuo i buchi tra offerte coperte sulla stessa chiave. Li distinguo tra "buchi da proiettare" che devono essere riempiti con le proiezioni e "buchi da NON proiettare" da non riempire.
# Costruisco la tabella d'appoggio DAR_MARGINI_FORECAST_BUCHI_CODE.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_BUCHI_CODE`
AS
WITH
TROVA_BUCHI AS (
SELECT DISTINCT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY,
       LAG(DATA_DELIVERY) OVER (PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST ORDER BY DATA_DELIVERY) AS PREV_DATA_DELIVERY
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` F
ORDER BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY
)

SELECT TROVA_BUCHI.COMMODITY_G_E, TROVA_BUCHI.CHIAVE_CLIENTE_FORECAST, C.DATA_DELIVERY, PREV_DATA_DELIVERY,
       CASE WHEN DATE_DIFF(TROVA_BUCHI.DATA_DELIVERY, PREV_DATA_DELIVERY, MONTH) BETWEEN 2 AND MESI_CESSATI + 1 THEN 'Buchi da proiettare' else 'Buchi da NON proiettare' END AS TIPO_BUCHI FROM TROVA_BUCHI
CROSS JOIN `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CALENDARIO_PROIEZIONI` C
WHERE TROVA_BUCHI.DATA_DELIVERY <> PREV_DATA_DELIVERY AND C.DATA_DELIVERY < TROVA_BUCHI.DATA_DELIVERY AND C.DATA_DELIVERY > PREV_DATA_DELIVERY
ORDER BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, C.DATA_DELIVERY
;


# 4. Costruisco le proiezioni per i clienti che hanno sempre il punto.

# 4.1 Seleziono per ogni mese dell'anno e pdp il record con data delivery più recente. Escludo storni e fixing e i clienti cessati dalle proiezioni.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PDP_MESE`
AS
SELECT * EXCEPT(PROIEZIONE_RANK, PROIEZIONE_NOTE), EXTRACT(month FROM data_delivery) AS MESE, 1 AS PROIEZIONE_RANK, 'SI perchè il record ha la massima competenza per mese dell anno e pdp' as PROIEZIONE_NOTE
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
WHERE TIPO_PIVA_CFISC_FORECAST = 'PIVA_CFISC_FORECAST ha sempre il pdp'
  AND note_forecast <> 'Coda di cliente cessato'
  AND COD_OFFERTA NOT LIKE '%F%'
  AND COD_OFFERTA NOT LIKE 'S-%'
QUALIFY
  dense_rank()
    OVER (
      PARTITION BY PDP, EXTRACT(month FROM data_delivery), COMMODITY_G_E
      ORDER BY data_delivery DESC
    )
  = 1
ORDER BY PDP, MESE ASC;



# 4.2 Proietto tutte le indicazioni di volume mensile del per tutti i mesi del calendario rolling. Non è ammessa l'ipotesi di rinnovo parziale perchè trattasi di record puntuali (un pdp o è rinnovato o non lo è)
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_PDP`
AS (
SELECT distinct BP.* EXCEPT(DATA_DELIVERY, NOTE_FORECAST, MESE, PROIEZIONE_DATA_DELIVERY), c.DATA_DELIVERY, BP.DATA_DELIVERY AS PROIEZIONE_DATA_DELIVERY, 'Proiezione' as NOTE_FORECAST
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PDP_MESE` bp
inner join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CALENDARIO_PROIEZIONI` c on bp.mese = extract(month from date(c.DATA_DELIVERY))
left join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` f on concat(f.data_delivery, f.PDP) = concat(C.data_delivery, BP.PDP)
WHERE F.ID_OFFERTA IS NULL AND C.DATA_DELIVERY >= bp.CODE_MIN_DATA_DELIVERY
ORDER BY BP.COMMODITY_G_E, BP.PDP, c.data_delivery asc
)
;

# 4.3. Accoda il risultato di 4.2 alla tabella di output `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
SET campi_comuni = (
  SELECT STRING_AGG(column_name, ', ')
  FROM (
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST'
    INTERSECT DISTINCT
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST_PROIEZIONI_PDP'
  )
);


EXECUTE IMMEDIATE FORMAT("""
  INSERT INTO `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` (%s)
  SELECT %s
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_PDP` ts
  ;
""", campi_comuni, campi_comuni);


# 5. Costruisco le proiezioni per i clienti che non sempre hanno il punto o non l'hanno mai. Lo scopo è:
# - trovare le indicazioni di volume per ogni combinazione di commodity, PIVA_CFISC_FORECAST, mese considerando le diverse casistiche
# - unirle in un'unica tabella chiamata `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_MESE`
# - proiettarle per tutte le competenza future
# - accodare le proiezioni alla tabella di output

# 5.1 Costruisco un rank a parità di commodity, PIVA_CFISC_FORECAST e mese delivery, assegnando il rank 1 alla data delivery più recente. Escludo storni e fixing e i clienti cessati dalle proiezioni.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_MESE`
AS
SELECT
   COMMODITY_G_E, PIVA_CFISC_FORECAST,
  EXTRACT(MONTH FROM DATA_DELIVERY) AS MESE,
  DATA_DELIVERY,PDP, 
  dense_Rank()
    OVER (
      PARTITION BY
        EXTRACT(MONTH FROM DATA_DELIVERY),
        PIVA_CFISC_FORECAST,
        COMMODITY_G_E
      ORDER BY EXTRACT(YEAR FROM DATA_DELIVERY) DESC
    ) AS PROIEZIONE_RANK,
  * EXCEPT (PIVA_CFISC_FORECAST, DATA_DELIVERY, PDP, COMMODITY_G_E, PROIEZIONE_RANK, PROIEZIONE_NOTE)
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` m
WHERE
  TIPO_PIVA_CFISC_FORECAST <> 'PIVA_CFISC_FORECAST ha sempre il pdp' AND note_forecast <> 'Coda di cliente cessato'
  AND M.COD_OFFERTA NOT LIKE '%F%'
  AND M.COD_OFFERTA NOT LIKE 'S-%'
ORDER BY
  COMMODITY_G_E, PIVA_CFISC_FORECAST,EXTRACT(MONTH FROM DATA_DELIVERY) ASC,  m.PROIEZIONE_RANK DESC, PDP
;


# 5.2 Costruiamo un'aggregazione di volume per commodity, PIVA_CFISC_FORECAST, mese, data_delivery.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_PIVA` 
AS (
  WITH 
aggregazione as (
  SELECT COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, DATA_DELIVERY, PROIEZIONE_RANK, SUM(VOLUME_COPERTO_MC_MWH) AS VOLUME_COPERTO_MC_MWH, COUNT(DISTINCT PROIEZIONE_RANK) OVER(PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE) AS CONTEGGIO_UNICI_RANK
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_MESE` 
GROUP BY ALL
ORDER BY PIVA_CFISC_FORECAST, MESE ASC, PROIEZIONE_RANK DESC, COMMODITY_G_E
)
,


# 5.3 Gestiamo le combinazioni di commodity, PIVA_CFISC_FORECAST, mese la cui massima competenza è futura.

# 5.3.1 Costruiamo campi calcolati: 
# PREV_VOLUME che riporta il volume del record con rank immediatamente successivo
# PREV_RANK che riporta il rank immediatamente successivo.
appoggio_per_3_casistica as (
SELECT COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, DATA_DELIVERY, PROIEZIONE_RANK, VOLUME_COPERTO_MC_MWH,
    LAG(VOLUME_COPERTO_MC_MWH) OVER (PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST, mese ORDER BY PROIEZIONE_rank desc) AS prev_volume,
    LAG(PROIEZIONE_rank) OVER (PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST, mese ORDER BY PROIEZIONE_rank desc) AS prev_rank
FROM aggregazione
WHERE CONTEGGIO_UNICI_RANK <> 1
QUALIFY MAX(DATA_DELIVERY) OVER(PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE) > CURRENT_DATETIME()
ORDER BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE ASC, PROIEZIONE_RANK DESC
)
,

# 5.3.2 Costruiamo un campo calcolato DIFF_PERC cha calcola la differenza percentuale tra il volume di un record e quello del rank immediatamente successivo.
# Filtriamo per record la cui DIFF_PERC è maggiore uguale del 15% rispetto il volume del rank successivo o la diff_perc è nulla o la competenza è passata. 
appoggio1_per_3_casistica as (
  SELECT COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, DATA_DELIVERY, PROIEZIONE_RANK, VOLUME_COPERTO_MC_MWH, prev_volume, prev_rank, VOLUME_COPERTO_MC_MWH - prev_volume, 
round(case when prev_volume = 0 then 0 else (VOLUME_COPERTO_MC_MWH - prev_volume)/prev_volume end, 2) as diff_perc 
FROM appoggio_per_3_casistica
group by all
having diff_perc >= - TOLLERANZA/100 or diff_perc is null or data_delivery <= current_datetime()
ORDER BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE ASC, PROIEZIONE_RANK DESC
)
,

# 5.3.3 Selezioniamo il record con rank minimo a parità di commodity, PIVA_CFISC_FORECAST, mese.
unione_piva_cfisc_mese as (
  select COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, PROIEZIONE_rank, DATA_DELIVERY, VOLUME_COPERTO_MC_MWH, 'SI perchè rank 1 ha competenza futura e il record ha passato il check sui volumi' as PROIEZIONE_NOTE from appoggio1_per_3_casistica
qualify PROIEZIONE_rank = min(PROIEZIONE_rank) over(partition by COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE)

UNION ALL

# 5.4 Gestiamo le combinazioni di commodity, PIVA_CFISC_FORECAST, mese che hanno solo un rank.
SELECT COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, PROIEZIONE_rank, DATA_DELIVERY, VOLUME_COPERTO_MC_MWH, 'SI perchè ha solo rank 1' as PROIEZIONE_NOTE
FROM aggregazione
WHERE CONTEGGIO_UNICI_RANK = 1

UNION ALL 

# 5.5 Gestiamo le combinazioni di commodity, PIVA_CFISC_FORECAST, mese che hanno massima competenza passata. Di questi record selezioneremo i record con rank 1.
SELECT COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE, PROIEZIONE_rank, DATA_DELIVERY, VOLUME_COPERTO_MC_MWH, 'SI perchè rank 1 ha competenza passata' as PROIEZIONE_NOTE
FROM aggregazione
WHERE PROIEZIONE_RANK = 1 AND CONTEGGIO_UNICI_RANK <> 1
QUALIFY MAX(DATA_DELIVERY) OVER(PARTITION BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE) <= CURRENT_DATETIME()


ORDER BY COMMODITY_G_E, PIVA_CFISC_FORECAST, MESE ASC

)
,

# 5.6. Ritroviamo nella `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PIVA_CFISC_MESE` i record prescelti per le proiezioni
ripescaggio as (
SELECT m.* EXCEPT (PROIEZIONE_RANK, PROIEZIONE_NOTE), U.MESE, u.PROIEZIONE_RANK, u.PROIEZIONE_NOTE
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` m
INNER JOIN unione_PIVA_CFISC_MESE u on m.PIVA_CFISC_FORECAST = u.PIVA_CFISC_FORECAST AND M.DATA_DELIVERY = U.DATA_DELIVERY AND U.COMMODITY_G_E = M.COMMODITY_G_E
WHERE M.COD_OFFERTA NOT LIKE '%F%'
  AND M.COD_OFFERTA NOT LIKE 'S-%'
  AND TIPO_PIVA_CFISC_FORECAST <> 'PIVA_CFISC_FORECAST ha sempre il pdp' AND note_forecast <> 'Coda di cliente cessato'

)


# 5.7 Proietto tutte le indicazioni di volume mensile del per tutti i mesi del calendario rolling. Se non vuoi applicare la logica del rinnovo parziale, scommenta il left join e il where.
SELECT distinct BP.* EXCEPT(DATA_DELIVERY, NOTE_FORECAST, MESE, PROIEZIONE_DATA_DELIVERY), c.DATA_DELIVERY, bp.DATA_DELIVERY AS PROIEZIONE_DATA_DELIVERY, 'Proiezione' as NOTE_FORECAST
FROM ripescaggio bp
inner join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CALENDARIO_PROIEZIONI` c on bp.mese = extract(month from date(c.DATA_DELIVERY)) AND C.DATA_DELIVERY<>BP.DATA_DELIVERY
#left join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` f on concat(f.data_delivery, f.PIVA_CFISC_FORECAST) = concat(C.data_delivery, BP.PIVA_CFISC_FORECAST)
WHERE c.DATA_DELIVERY >= bp.CODE_MIN_DATA_DELIVERY
# AND F.ID_OFFERTA IS NULL
ORDER BY BP.COMMODITY_G_E, BP.PIVA_CFISC_FORECAST, c.data_delivery asc
)
;


# 5.8 Accoda il risultato di 5.7 alla tabella di output `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
SET campi_comuni = (
  SELECT STRING_AGG(column_name, ', ')
  FROM (
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST'
    INTERSECT DISTINCT
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST_PROIEZIONI_PIVA'
  )
);


EXECUTE IMMEDIATE FORMAT("""
  INSERT INTO `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` (%s)
  SELECT %s
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_PIVA` ts
  ;
""", campi_comuni, campi_comuni);


# Gestiamo le chiavi che non hanno serie di 12 volumi mensili proiettati. E' il caso in cui una chiave non è stata mai coperta a gennaio, ad esempio.
# Svolgiamo i seguenti passaggi:
# - costruiamo una tabella d'appoggio in cui ogni chiave proiettata si ripete per ogni mese dell'anno.
# - Estraiamo per ogni chiave e mese disponibile una media di volume, margine mp e margine totale.
# - Sulla base del risultato del punto precedente, calcoliamo per ogni chiabe la media di volume, margine mp e margine totale
# - Li proiettiamo per il calendario e li aggiungiamo alla tabella di output.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CHIAVE_CLIENTE_MESE_BUCHI` AS 
with 
tabella as (
SELECT distinct
  commodity_g_E, 
  o.CHIAVE_CLIENTE_FORECAST AS CHIAVE_CLIENTE_FORECAST,
  n AS NUMERO_MESE,
FROM
  `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` o
CROSS JOIN
  UNNEST(GENERATE_ARRAY(1, 12)) AS n
WHERE NOTE_FORECAST = 'Proiezione'
)
,

calcola_consumi_medi_unit_appoggio as
(
  SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, CODE_MIN_DATA_DELIVERY, EXTRACT(MONTH FROM DATA_DELIVERY) AS MESE, 
  SUM(VOLUME_COPERTO_MC_MWH) / COUNT(DISTINCT DATA_DELIVERY) AS VOLUME_COPERTO_MC_MWH, 
  SUM(MARGINE_MP_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS MARGINE_MP_EUR,
  SUM(QF_MARGINE_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS QF_MARGINE_EUR,
  SUM(QVD_FIX_PCV_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS QVD_FIX_PCV_EUR,
  SUM(QVD_VAR_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS QVD_VAR_EUR,
  SUM(CCR_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS CCR_EUR,
  SUM(QTT_CRV_CV_MARGINANTE_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS QTT_CRV_CV_MARGINANTE_EUR,
  SUM(QTINT_PSV_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS QTINT_PSV_EUR,
  SUM(MARGINE_ENVE_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS MARGINE_ENVE_EUR,
  SUM(BONUS_TOTALE_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS BONUS_TOTALE_EUR,
  SUM(MARGINE_EXTRA_EUR) / COUNT(DISTINCT DATA_DELIVERY) AS MARGINE_EXTRA_EUR,
  SUM(coalesce(MARGINE_MP_EUR, 0) + coalesce(QF_MARGINE_EUR, 0) + coalesce(QVD_FIX_PCV_EUR, 0) + coalesce(QVD_VAR_EUR, 0) + coalesce(CCR_EUR, 0) + coalesce(QTT_CRV_CV_MARGINANTE_EUR, 0) + coalesce(QTINT_PSV_EUR, 0) + coalesce(MARGINE_ENVE_EUR, 0) - coalesce(BONUS_TOTALE_EUR, 0) + coalesce(MARGINE_EXTRA_EUR, 0)) / COUNT(DISTINCT DATA_DELIVERY) AS MARGINE_TOTALE_EUR
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
  WHERE NOTE_FORECAST = 'Coda'
  AND COD_OFFERTA NOT LIKE 'S-%' AND COD_OFFERTA NOT LIKE '%F%'
  GROUP BY ALL
  ORDER BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, MESE
)
,

calcola_consumi_medi_unit as (
  SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, CODE_MIN_DATA_DELIVERY, 
  AVG(VOLUME_COPERTO_MC_MWH) AS VOLUME_COPERTO_MC_MWH,
  AVG(MARGINE_MP_EUR) AS MARGINE_MP_EUR, 
  AVG(QF_MARGINE_EUR) AS QF_MARGINE_EUR,
  AVG(QVD_FIX_PCV_EUR) AS QVD_FIX_PCV_EUR,
  AVG(QVD_VAR_EUR) AS QVD_VAR_EUR,
  AVG(CCR_EUR) AS CCR_EUR,
  AVG(QTT_CRV_CV_MARGINANTE_EUR) AS QTT_CRV_CV_MARGINANTE_EUR,
  AVG(QTINT_PSV_EUR) AS QTINT_PSV_EUR,
  AVG(MARGINE_ENVE_EUR) AS MARGINE_ENVE_EUR,
  AVG(BONUS_TOTALE_EUR) AS BONUS_TOTALE_EUR,
  AVG(MARGINE_EXTRA_EUR) AS MARGINE_EXTRA_EUR,
  AVG(MARGINE_TOTALE_EUR) AS MARGINE_TOTALE_EUR
  FROM calcola_consumi_medi_unit_appoggio
  GROUP BY ALL
)

SELECT  T.COMMODITY_G_E, C.CHIAVE_CLIENTE_FORECAST, C.CODE_MIN_DATA_DELIVERY, T.NUMERO_MESE AS MESE, C.VOLUME_COPERTO_MC_MWH, C.MARGINE_MP_EUR, C.MARGINE_TOTALE_EUR, C.QF_MARGINE_EUR, C.QVD_FIX_PCV_EUR,
  C.QVD_VAR_EUR, C.CCR_EUR, C.QTT_CRV_CV_MARGINANTE_EUR, C.QTINT_PSV_EUR, C.MARGINE_ENVE_EUR, C.BONUS_TOTALE_EUR, C.MARGINE_EXTRA_EUR, 'Media mensile perchè manca indicazione storica' AS PROIEZIONE_NOTE
FROM TABELLA T
LEFT JOIN calcola_consumi_medi_unit_appoggio M ON T.NUMERO_MESE = M.MESE AND T.CHIAVE_CLIENTE_FORECAST = M.CHIAVE_CLIENTE_FORECAST and t.commodity_g_e = M.COMMODITY_G_E
inner join calcola_consumi_medi_unit c on c.CHIAVE_CLIENTE_FORECAST = t.CHIAVE_CLIENTE_FORECAST and c.commodity_g_e = t.commodity_g_e
WHERE M.MESE IS NULL
ORDER BY T.COMMODITY_G_E, C.CHIAVE_CLIENTE_FORECAST, MESE
;




# 4.2 Proietto tutte le indicazioni di volume mensile del per tutti i mesi del calendario rolling.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_MESE_BUCHI`
AS (
SELECT distinct BP.*, c.DATA_DELIVERY, 'Proiezione' as NOTE_FORECAST
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CHIAVE_CLIENTE_MESE_BUCHI` bP
inner join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_CALENDARIO_PROIEZIONI` c on bp.mese = extract(month from date(c.DATA_DELIVERY))
left join `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` f on concat(f.data_delivery, f.CHIAVE_CLIENTE_FORECAST) = concat(C.data_delivery, BP.CHIAVE_CLIENTE_FORECAST)
WHERE F.ID_OFFERTA IS NULL AND C.DATA_DELIVERY >= bp.CODE_MIN_DATA_DELIVERY
ORDER BY BP.COMMODITY_G_E, BP.CHIAVE_CLIENTE_FORECAST, c.data_delivery asc
)
;

# 4.3. Accoda il risultato di 4.2 alla tabella di output `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
SET campi_comuni = (
  SELECT STRING_AGG(column_name, ', ')
  FROM (
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST'
    INTERSECT DISTINCT
    SELECT column_name
    FROM `a2a-labrrclab-prd.L1.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'DAR_MARGINI_FORECAST_PROIEZIONI_MESE_BUCHI'
  )
);


EXECUTE IMMEDIATE FORMAT("""
  INSERT INTO `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` (%s)
  SELECT %s
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_PROIEZIONI_MESE_BUCHI` ts
  ;
""", campi_comuni, campi_comuni);


# Cancello gli attributi di vendita delle proiezioni.

UPDATE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` MAR
SET
  MAR.MACROAREA_NEW = NULL,
  MAR.RESP_MACROAREA_NEW = NULL,
  MAR.AREA_NEW = NULL,
  MAR.RESP_AREA_NEW = NULL,
  MAR.SOTTOAREA_NEW = NULL,
  MAR.RESP_SOTTOAREA_NEW = NULL,
  MAR.ACCOUNT_NEW = NULL
WHERE MAR.NOTE_FORECAST NOT IN ('Coda', 'Coda di cliente cessato')
;



# Scrivo gli attributi dell'ultima coda più recente su ogni proiezione. 
MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
#Trovo il venditore prevalente per ultima competenza di ogni combinazione di commodity, chiave_cliente_forecast  
SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, ACCOUNT_NEW, MACROAREA_NEW, RESP_MACROAREA_NEW, AREA_NEW, RESP_AREA_NEW, SOTTOAREA_NEW, RESP_SOTTOAREA_NEW  
  FROM (
 #Calcolo il volume aggregato per venditore dell'ultima competenza disponibile per commodity e chiave
 SELECT DISTINCT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY, ACCOUNT_NEW, SUM(VOLUME_COPERTO_MC_MWH) AS VOLUME,
                 MACROAREA_NEW, RESP_MACROAREA_NEW,
                 AREA_NEW, RESP_AREA_NEW,
                 SOTTOAREA_NEW, RESP_SOTTOAREA_NEW,
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
WHERE NOTE_FORECAST = 'Coda'
GROUP BY ALL
QUALIFY DATA_DELIVERY = MAX(DATA_DELIVERY) OVER(PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST)
ORDER BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
  )
QUALIFY ROW_NUMBER() OVER(PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST ORDER BY VOLUME DESC) = 1
) AS C
ON  mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.NOTE_FORECAST NOT IN ('Coda', 'Coda di cliente cessato')
      WHEN MATCHED
        THEN
          UPDATE
SET 
  MAR.MACROAREA_NEW = C.MACROAREA_NEW,
  MAR.RESP_MACROAREA_NEW = C.RESP_MACROAREA_NEW,
  MAR.AREA_NEW = C.AREA_NEW,
  MAR.RESP_AREA_NEW = C.RESP_AREA_NEW,
  MAR.SOTTOAREA_NEW = C.SOTTOAREA_NEW,
  MAR.RESP_SOTTOAREA_NEW = C.RESP_SOTTOAREA_NEW,
  MAR.ACCOUNT_NEW = C.ACCOUNT_NEW
;



# Scrivo il cod_offerta dell'ultima coda più recente su ogni proiezione senza indicazione storica. 
MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
#Trovo il venditore prevalente per ultima competenza di ogni combinazione di commodity, chiave_cliente_forecast  
SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, COD_OFFERTA  
  FROM (
 #Calcolo il volume aggregato per venditore dell'ultima competenza disponibile per commodity e chiave
 SELECT DISTINCT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY, COD_OFFERTA, SUM(VOLUME_COPERTO_MC_MWH) AS VOLUME
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
WHERE NOTE_FORECAST = 'Coda'
GROUP BY ALL
QUALIFY DATA_DELIVERY = MAX(DATA_DELIVERY) OVER(PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST)
ORDER BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
  )
QUALIFY ROW_NUMBER() OVER(PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST ORDER BY VOLUME DESC) = 1
) AS C
ON  mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.PROIEZIONE_NOTE = 'Media mensile perchè manca indicazione storica'
      WHEN MATCHED
        THEN
          UPDATE
SET 
  MAR.COD_OFFERTA = C.COD_OFFERTA 
;


# Scrivo alcuni campi anagrafici dei record appena giunti passando dalla tabella d'apppoggio DAR_MARGINI_FORECAST_ARRICCHISCI_BUCHI
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_ARRICCHISCI_BUCHI` AS
SELECT distinct
  COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY,
  'S' AS FLG_PUBBLICATO_S_N,
  
  CASE WHEN TIPO_PIVA_CFISC_FORECAST = 'PIVA_CFISC_FORECAST ha sempre il pdp' THEN LAST_VALUE(m.PDP IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) else 'ND' END AS PDP, #SOLO SE TIPO HA SEMPRE PDP

  LAST_VALUE(m.RAG_SOC_OFFERTABILE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS RAG_SOC_OFFERTABILE,

  LAST_VALUE(m.COD_FISC_OFFERTABILE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS COD_FISC_OFFERTABILE,

  LAST_VALUE(m.P_IVA_OFFERTABILE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS P_IVA_OFFERTABILE,

  CASE WHEN TIPO_PIVA_CFISC_FORECAST = 'PIVA_CFISC_FORECAST ha sempre il pdp' THEN LAST_VALUE(m.RAG_SOC_TITOLARE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) ELSE 'ND' END AS RAG_SOC_TITOLARE,

  CASE WHEN TIPO_PIVA_CFISC_FORECAST = 'PIVA_CFISC_FORECAST ha sempre il pdp' THEN LAST_VALUE(m.P_IVA_TITOLARE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) ELSE 'ND' END AS P_IVA_TITOLARE,

  CASE WHEN TIPO_PIVA_CFISC_FORECAST = 'PIVA_CFISC_FORECAST ha sempre il pdp' THEN LAST_VALUE(m.COD_FISC_TITOLARE IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) ELSE 'ND' END AS COD_FISC_TITOLARE,

  LAST_VALUE(PIVA_CFISC_FORECAST IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS PIVA_CFISC_FORECAST,

  LAST_VALUE(NOTE_PIVA_CFISC_FORECAST IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS NOTE_PIVA_CFISC_FORECAST,

  LAST_VALUE(TIPO_PIVA_CFISC_FORECAST IGNORE NULLS) OVER (
    PARTITION BY COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST
    ORDER BY DATA_DELIVERY
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS TIPO_PIVA_CFISC_FORECAST  
  
FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` m
;


MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_ARRICCHISCI_BUCHI`
) AS C
ON  mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.DATA_DELIVERY = C.DATA_DELIVERY
  AND MAR.PROIEZIONE_NOTE = 'Media mensile perchè manca indicazione storica'
      WHEN MATCHED
        THEN
          UPDATE
SET 
  MAR.FLG_PUBBLICATO_S_N = C.FLG_PUBBLICATO_S_N,
  MAR.PDP = C.PDP,
  MAR.RAG_SOC_OFFERTABILE = C.RAG_SOC_OFFERTABILE,
  MAR.COD_FISC_OFFERTABILE = C.COD_FISC_OFFERTABILE,
  MAR.P_IVA_OFFERTABILE = C.P_IVA_OFFERTABILE,
  MAR.RAG_SOC_TITOLARE = C.RAG_SOC_TITOLARE,
  MAR.P_IVA_TITOLARE = C.P_IVA_TITOLARE,
  MAR.COD_FISC_TITOLARE = C.COD_FISC_TITOLARE,
  MAR.PIVA_CFISC_FORECAST = C.PIVA_CFISC_FORECAST,
  MAR.NOTE_PIVA_CFISC_FORECAST = C.NOTE_PIVA_CFISC_FORECAST,
  MAR.TIPO_PIVA_CFISC_FORECAST = C.TIPO_PIVA_CFISC_FORECAST 
;



# Cancello dalla tabella di output i buchi da NON proiettare
DELETE FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
WHERE NOTE_FORECAST = 'Proiezione' and concat(COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY) IN (
  SELECT concat(COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY)
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_BUCHI_CODE`
  WHERE TIPO_BUCHI = 'Buchi da NON proiettare'
);


# 6. Per i clienti che non hanno sempre il pdp o non l'hanno mai, seleziono i record che a parità di commodity, PIVA_CFISC_FORECAST, mese hanno sia code che proiezioni perchè solo una tra loro deve essere considerata nel risultato finale.
CREATE OR REPLACE TABLE `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_DA_CANC`
AS (
  WITH
appoggio_per_record_da_canc AS (
  SELECT F.COMMODITY_G_E, F.CHIAVE_CLIENTE_FORECAST, F.DATA_DELIVERY, COUNT(DISTINCT NOTE_FORECAST) as conteggio, SUM(case when NOTE_FORECAST='Coda' then VOLUME_COPERTO_MC_MWH else 0 end) as volume_coda, SUM(case when NOTE_FORECAST='Proiezione' then VOLUME_COPERTO_MC_MWH else 0 end) as volume_proiezione FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` F
  where note_forecast<>'Coda di cliente cessato' and TIPO_PIVA_CFISC_FORECAST<>'PIVA_CFISC_FORECAST ha sempre il pdp'
  group by all
  order by conteggio desc, data_delivery asc
)
SELECT COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY, case when volume_coda<volume_proiezione then 'Coda' else 'Proiezione' end as note_forecast FROM APPOGGIO_PER_RECORD_DA_CANC
  WHERE CONTEGGIO=2
)
;

# 7. Cancello dalla tabella di output i record di proiezione il cui volume è inferiore rispetto il volume della coda a parità di commodity, PIVA_CFISC_FORECAST, mese
DELETE FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`
WHERE concat(COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY, NOTE_FORECAST) IN (
  SELECT concat(COMMODITY_G_E, CHIAVE_CLIENTE_FORECAST, DATA_DELIVERY, note_forecast)
  FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_DA_CANC`
  WHERE NOTE_FORECAST='Proiezione'
);


# 8. Sovrascrivo 'Proiezione che sostituisce coda' nel campo NOTE_FORECAST della tabella di output per i record di proiezioni che sono preferibili alle code a parità di commodity, PIVA_CFISC_FORECAST, mese perchè il loro volume è maggiore. Probabilmente la coda è un rinnovo parziale.
MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_DA_CANC`
) AS C
ON  mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.DATA_DELIVERY = C.DATA_DELIVERY
  AND MAR.NOTE_FORECAST = 'Proiezione'
      WHEN MATCHED
        THEN
          UPDATE
SET NOTE_FORECAST = 'Proiezione che sostituisce coda'
;

# 9. Sovrascrivo 'Coda da sostituire con proiezione' nel campo NOTE_FORECAST della tabella di output per i record di coda che non sono preferibili alle proiezioni a parità di commodity, PIVA_CFISC_FORECAST, mese perchè il loro volume è minore. Probabilmente la coda è un rinnovo parziale.
MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_DA_CANC`
  WHERE NOTE_FORECAST='Coda'
) AS c
ON
      mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.NOTE_FORECAST = C.NOTE_FORECAST
  AND MAR.DATA_DELIVERY = C.DATA_DELIVERY
      WHEN MATCHED
        THEN
          UPDATE
SET
  mar.note_forecast = 'Coda da sostituire con proiezione';


MERGE
  INTO
    `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST` AS mar
USING (
  SELECT * FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_BUCHI_CODE`
  WHERE TIPO_BUCHI = 'Buchi da proiettare'
) AS c
ON
      mar.CHIAVE_CLIENTE_FORECAST = C.CHIAVE_CLIENTE_FORECAST
  AND mar.COMMODITY_G_E = C.COMMODITY_G_E
  AND MAR.DATA_DELIVERY = C.DATA_DELIVERY
      WHEN MATCHED
        THEN
          UPDATE
SET
  mar.note_forecast = 'Proiezione da buco';


# Per ogni record di proiezioni scrivo gli attributi di vendita disponibili 



# 10. Cancello tabelle superflue create durante il processo
drop table `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_DA_CANC`;
drop table `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST_ARRICCHISCI_BUCHI`;


# Accodo la tabella di output nella corrispondente tabella nell'L1 con una specifica DATA_LANCIO
INSERT INTO `a2a-labrrclab-prd.L2.DAR_MARGINI_FORECAST_L2`
(SELECT *, CURRENT_DATE() AS DATA_LANCIO FROM `a2a-labrrclab-prd.L1.DAR_MARGINI_FORECAST`)
;

END;
