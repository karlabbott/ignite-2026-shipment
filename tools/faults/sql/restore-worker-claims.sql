SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

USE shipping;
GO

CREATE OR ALTER PROCEDURE dbo.usp_claim_scan
    @worker NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE TOP (1) q
       SET q.claimed_by = @worker,
           q.claimed_at = SYSUTCDATETIME(),
           q.attempts   = q.attempts + 1
    OUTPUT inserted.queue_id, inserted.shipment_id, inserted.requested_by,
           inserted.attempts
      FROM dbo.scan_queue AS q WITH (ROWLOCK, READPAST, UPDLOCK)
      JOIN dbo.shipments AS s ON s.shipment_id = q.shipment_id
     WHERE q.processed_at IS NULL
       AND (q.claimed_at IS NULL OR q.claimed_at < DATEADD(minute, -2, SYSUTCDATETIME()))
       AND q.attempts < 5
       AND (s.demo_hold_status IS NULL OR s.status <> s.demo_hold_status);
END;
GO
