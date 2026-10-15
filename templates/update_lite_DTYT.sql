{HEADER}

SET LOCK_TIMEOUT 30000;

UPDATE dbo.TarifaAduana
    SET ProcesadoEstadoTyT   = 0,
        ProcesadoMensajeTyT  = 'Regularizado manualmente - {FECHA_COMPACTA}',
        ProcesadoFechaTyT    = GETDATE(),
        ProcesadoEstadoEcho  = 0,
        ProcesadoMensajeEcho = 'Regularizado manualmente - {FECHA_COMPACTA}',
        ProcesadoFechaEcho   = GETDATE(),
        Modified_Time        = GETDATE()
WHERE ProcesadoEstadoTyT = 2
  AND Name IN (
<lista_tarifas_in>
  );

UPDATE dbo.TarifaAduana_Cliente_Honorario
    SET No_intentos = 0
WHERE Name IN (
<lista_tarifas_in>
  );
