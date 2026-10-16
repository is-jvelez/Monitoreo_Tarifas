SET NOCOUNT ON;
USE TyT_APICtrl;
GO

------------------------------------------------------------------------------
-- De las TSA en ERROR (ProcesadoEstado=2), cuantas ya estan ANULADAS en Dobra.
-- Solo lectura. Una fila por tarifa (sin JOINs que multipliquen filas): todo
-- lo de Dobra se mide con subconsultas COUNT.
------------------------------------------------------------------------------
DECLARE @fechaCreacion DATETIME = '2026-10-14 15:00:00.000';

IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;

SELECT
        TSA.Name                                                AS TarifaName,
        TSA.CabeceraName                                        AS Cotizacion,
        CASE WHEN TSA.Estado = '1-Inactivo' THEN 1 ELSE 0 END   AS TarifaAnuladaCRM,
        TSA.ProcesadoMensaje                                    AS ProcesadoMensaje,
        -- La tarifa en Dobra (por ZohoCrmId)
        (SELECT COUNT(*) FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES D
          WHERE D.ZohoCrmId = TSA.Name)                         AS DobraFilas,
        (SELECT COUNT(*) FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES D
          WHERE D.ZohoCrmId = TSA.Name AND D.Anulado = 1)       AS DobraAnuladas,
        -- El cliente en Dobra (RUC de la cuenta de la cotizacion)
        CASE WHEN EXISTS (
            SELECT 1 FROM dbo.Cotizacion CO
            JOIN dbo.Account_new A ON CO.ClienteId = A.ZohoId
            WHERE CO.Name = TSA.CabeceraName
              AND NULLIF(LTRIM(RTRIM(A.Nro_identificacion)),'') IS NOT NULL
        ) THEN 1 ELSE 0 END                                     AS TieneRucCRM,
        (SELECT COUNT(*) FROM dbo.Cotizacion CO
           JOIN dbo.Account_new A ON CO.ClienteId = A.ZohoId
           JOIN Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
          WHERE CO.Name = TSA.CabeceraName)                     AS CliFilas,
        (SELECT COUNT(*) FROM dbo.Cotizacion CO
           JOIN dbo.Account_new A ON CO.ClienteId = A.ZohoId
           JOIN Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
          WHERE CO.Name = TSA.CabeceraName AND CLI.Anulado = 0) AS CliActivos,
        CAST(NULL AS VARCHAR(30))                               AS EstadoTarifaDobra,
        CAST(NULL AS VARCHAR(30))                               AS EstadoClienteDobra
INTO #Err
FROM dbo.TarifaServiciosAdicionales TSA
WHERE TSA.ProcesadoEstado = 2
AND  (TSA.Created_Time >= @fechaCreacion OR TSA.Modified_Time >= @fechaCreacion);

UPDATE #Err
   SET EstadoTarifaDobra = CASE
            WHEN DobraFilas = 0              THEN 'NO_EXISTE_EN_DOBRA'
            WHEN DobraAnuladas = DobraFilas  THEN 'ANULADA_EN_DOBRA'
            WHEN DobraAnuladas = 0           THEN 'ACTIVA_EN_DOBRA'
            ELSE                                  'MIXTA_ACTIVA_Y_ANULADA'
       END,
       EstadoClienteDobra = CASE
            WHEN TieneRucCRM = 0             THEN 'SIN_RUC_EN_CRM'
            WHEN CliFilas = 0                THEN 'RUC_NO_EXISTE_EN_DOBRA'
            WHEN CliActivos = 0              THEN 'CLIENTE_ANULADO_EN_DOBRA'
            ELSE                                  'CLIENTE_ACTIVO_EN_DOBRA'
       END;

-- 1) Control: debe cuadrar con el ERROR de la foto general (una fila por tarifa)
SELECT COUNT(*) AS Filas, COUNT(DISTINCT TarifaName) AS TarifasDistintas FROM #Err;

-- 2) RESPUESTA: estado de la tarifa misma en Dobra
SELECT EstadoTarifaDobra, COUNT(*) AS Cantidad
FROM #Err GROUP BY EstadoTarifaDobra ORDER BY Cantidad DESC;

-- 3) Estado del cliente en Dobra (explica el "ClienteId faltante" de INCOMPLETA)
SELECT EstadoClienteDobra, COUNT(*) AS Cantidad
FROM #Err GROUP BY EstadoClienteDobra ORDER BY Cantidad DESC;

-- 4) Cruce tarifa x cliente
SELECT EstadoTarifaDobra, EstadoClienteDobra, TarifaAnuladaCRM, COUNT(*) AS Cantidad
FROM #Err
GROUP BY EstadoTarifaDobra, EstadoClienteDobra, TarifaAnuladaCRM
ORDER BY EstadoTarifaDobra, EstadoClienteDobra, TarifaAnuladaCRM;

-- 5) Detalle de las que ya estan anuladas en Dobra (quien/cuando/por que)
SELECT E.TarifaName, E.Cotizacion, E.TarifaAnuladaCRM, E.EstadoClienteDobra,
       D.pkID AS CodigoDobra, D.ClienteID, D.Anulado, D.AnuladoPor, D.AnuladoDate, D.AnuladoNota,
       E.ProcesadoMensaje
FROM #Err E
JOIN Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES D ON D.ZohoCrmId = E.TarifaName
WHERE E.EstadoTarifaDobra IN ('ANULADA_EN_DOBRA','MIXTA_ACTIVA_Y_ANULADA')
ORDER BY E.EstadoTarifaDobra, E.TarifaName, D.pkID;

IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;
GO
