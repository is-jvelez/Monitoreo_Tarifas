{HEADER}

SET NOCOUNT ON;
SET XACT_ABORT ON;

USE TyT_APICtrl;
GO

SET LOCK_TIMEOUT 30000;

DECLARE @RunGuid          UNIQUEIDENTIFIER = NEWID();
DECLARE @FechaProceso     DATETIME         = GETDATE();
DECLARE @ProcesadoMensaje VARCHAR(200)     = CONCAT('Regularizado manualmente - ', CONVERT(VARCHAR(36), @RunGuid));

DECLARE @Tarifas TABLE (Name VARCHAR(50) PRIMARY KEY);
INSERT INTO @Tarifas (Name) VALUES
    (<lista_tarifas>);

BEGIN TRANSACTION;

UPDATE TSA
    SET TSA.ProcesadoEstado  = 0,
        TSA.ProcesadoMensaje = @ProcesadoMensaje,
        TSA.ProcesadoFecha   = @FechaProceso,
        TSA.Modified_Time    = @FechaProceso
FROM dbo.TarifaServiciosAdicionales TSA
INNER JOIN @Tarifas T ON T.Name = TSA.Name
WHERE TSA.ProcesadoEstado = 2;

COMMIT TRANSACTION;
GO