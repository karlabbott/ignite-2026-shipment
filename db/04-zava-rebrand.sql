/* Migrate an existing NinetyNine Freight estate to Zava Logistics.
   Idempotent: safe to apply to both existing and newly provisioned databases. */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

USE shipping;
GO

BEGIN TRANSACTION;

DECLARE @old_carrier_id INT =
    (SELECT carrier_id FROM dbo.carriers WHERE code = 'NNF');
DECLARE @zava_carrier_id INT =
    (SELECT carrier_id FROM dbo.carriers WHERE code = 'ZAV');

IF @old_carrier_id IS NOT NULL
BEGIN
    IF @zava_carrier_id IS NULL
    BEGIN
        UPDATE dbo.carriers
           SET code = 'ZAV',
               name = N'Zava Logistics'
         WHERE carrier_id = @old_carrier_id;

        SET @zava_carrier_id = @old_carrier_id;
    END
    ELSE
    BEGIN
        UPDATE dbo.shipments
           SET carrier_id = @zava_carrier_id
         WHERE carrier_id = @old_carrier_id;

        DELETE FROM dbo.carriers
         WHERE carrier_id = @old_carrier_id;
    END;
END;

UPDATE dbo.carriers
   SET name = N'Zava Logistics'
 WHERE code = 'ZAV';

DECLARE @pbs_carrier_id INT =
    (SELECT carrier_id FROM dbo.carriers WHERE code = 'PBS');
DECLARE @psx_carrier_id INT =
    (SELECT carrier_id FROM dbo.carriers WHERE code = 'PSX');

IF @pbs_carrier_id IS NOT NULL
BEGIN
    IF @psx_carrier_id IS NULL
        UPDATE dbo.carriers
           SET code = 'PSX'
         WHERE carrier_id = @pbs_carrier_id;
    ELSE
    BEGIN
        UPDATE dbo.shipments
           SET carrier_id = @psx_carrier_id
         WHERE carrier_id = @pbs_carrier_id;

        DELETE FROM dbo.carriers
         WHERE carrier_id = @pbs_carrier_id;
    END;
END;

IF EXISTS (
    SELECT 1
      FROM dbo.shipments AS old_number
      JOIN dbo.shipments AS new_number
        ON new_number.tracking_number =
           CONCAT('ZAV', SUBSTRING(old_number.tracking_number, 4, 17))
     WHERE old_number.tracking_number LIKE 'NNF%'
)
    THROW 51000, 'Cannot migrate NNF tracking numbers because a ZAV number already exists.', 1;

UPDATE dbo.shipments
   SET tracking_number = CONCAT('ZAV', SUBSTRING(tracking_number, 4, 17)),
       created_by = REPLACE(created_by, N'.99b.local', N'')
 WHERE tracking_number LIKE 'NNF%'
    OR created_by LIKE N'%.99b.local%';

UPDATE dbo.scan_events
   SET worker_host = REPLACE(worker_host, N'.99b.local', N'')
 WHERE worker_host LIKE N'%.99b.local%';

UPDATE dbo.status_history
   SET changed_by = REPLACE(changed_by, N'.99b.local', N'')
 WHERE changed_by LIKE N'%.99b.local%';

UPDATE dbo.scan_queue
   SET requested_by = REPLACE(requested_by, N'.99b.local', N''),
       claimed_by = CASE
           WHEN claimed_by IS NULL THEN NULL
           ELSE REPLACE(claimed_by, N'.99b.local', N'')
       END
 WHERE requested_by LIKE N'%.99b.local%'
    OR claimed_by LIKE N'%.99b.local%';

UPDATE dbo.tier_heartbeats
   SET hostname = REPLACE(hostname, N'.99b.local', N'')
 WHERE hostname LIKE N'%.99b.local%';

UPDATE dbo.scan_events
   SET worker_host = N'ciq-rocky-worker'
 WHERE worker_host = N'rocky-worker';

UPDATE dbo.status_history
   SET changed_by = N'worker:ciq-rocky-worker'
 WHERE changed_by = N'worker:rocky-worker';

UPDATE dbo.scan_queue
   SET claimed_by = N'ciq-rocky-worker'
 WHERE claimed_by = N'rocky-worker';

UPDATE dbo.tier_heartbeats
   SET hostname = N'ciq-rocky-worker'
 WHERE tier = 'worker'
   AND hostname = N'rocky-worker';

COMMIT TRANSACTION;
GO

SELECT code, name
  FROM dbo.carriers
 WHERE code = 'ZAV';

SELECT COUNT(*) AS legacy_tracking_numbers
  FROM dbo.shipments
 WHERE tracking_number LIKE 'NNF%';
GO
