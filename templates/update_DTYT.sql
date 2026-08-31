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

UPDATE TA
    SET TA.ProcesadoEstadoTyT   = 0,
        TA.ProcesadoMensajeTyT  = @ProcesadoMensaje,
        TA.ProcesadoFechaTyT    = @FechaProceso,
        TA.ProcesadoEstadoEcho  = 0,
        TA.ProcesadoMensajeEcho = @ProcesadoMensaje,
        TA.ProcesadoFechaEcho   = @FechaProceso,
        TA.Modified_Time        = @FechaProceso
FROM dbo.TarifaAduana TA
INNER JOIN @Tarifas T ON T.Name = TA.Name
WHERE TA.ProcesadoEstadoTyT = 2;

UPDATE TCH
    SET TCH.No_intentos = 0
FROM dbo.TarifaAduana_Cliente_Honorario TCH
INNER JOIN @Tarifas T ON T.Name = TCH.Name;

COMMIT TRANSACTION;
GO