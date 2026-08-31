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

UPDATE TCO
    SET TCO.ProcesadoEstado  = 0,
        TCO.ProcesadoMensaje = @ProcesadoMensaje,
        TCO.ProcesadoFecha   = @FechaProceso,
        TCO.Modified_Time    = @FechaProceso
FROM dbo.TarifaContenedor TCO
INNER JOIN @Tarifas T ON T.Name = TCO.Name
WHERE TCO.ProcesadoEstado = 2;

COMMIT TRANSACTION;
GO