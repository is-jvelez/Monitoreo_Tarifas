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

UPDATE TCS
    SET TCS.ProcesadoEstado  = 0,
        TCS.ProcesadoMensaje = @ProcesadoMensaje,
        TCS.ProcesadoFecha   = @FechaProceso,
        TCS.Modified_Time    = @FechaProceso
FROM dbo.TarifaCargaSuelta TCS
INNER JOIN @Tarifas T ON T.Name = TCS.Name
WHERE TCS.ProcesadoEstado = 2;

COMMIT TRANSACTION;
GO