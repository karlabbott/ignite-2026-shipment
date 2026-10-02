/* Multi-worker identity and audience-selected failure voting.

   The public application owns poll state and tally only. It deliberately has
   no infrastructure credentials and cannot inject a fault. A private presenter
   controller will later read the locked winner and invoke a bounded tool. */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE shipping;
GO

/* Existing estates originally keyed heartbeats by tier, which allowed only one
   worker row. Upgrade the primary key without discarding heartbeat history. */
IF NOT EXISTS (
    SELECT 1
      FROM sys.key_constraints kc
      JOIN sys.index_columns ic
        ON ic.object_id = kc.parent_object_id
       AND ic.index_id = kc.unique_index_id
     WHERE kc.parent_object_id = OBJECT_ID('dbo.tier_heartbeats')
       AND kc.type = 'PK'
     GROUP BY kc.name
    HAVING COUNT(*) = 2
       AND SUM(CASE WHEN COL_NAME(ic.object_id, ic.column_id) = 'tier' THEN 1 ELSE 0 END) = 1
       AND SUM(CASE WHEN COL_NAME(ic.object_id, ic.column_id) = 'hostname' THEN 1 ELSE 0 END) = 1
)
BEGIN
    DECLARE @heartbeat_pk SYSNAME;
    SELECT @heartbeat_pk = kc.name
      FROM sys.key_constraints kc
     WHERE kc.parent_object_id = OBJECT_ID('dbo.tier_heartbeats')
       AND kc.type = 'PK';

    IF @heartbeat_pk IS NOT NULL
    BEGIN
        DECLARE @drop_heartbeat_pk NVARCHAR(MAX) =
            N'ALTER TABLE dbo.tier_heartbeats DROP CONSTRAINT '
            + QUOTENAME(@heartbeat_pk);
        EXEC sp_executesql @drop_heartbeat_pk;
    END;

    ALTER TABLE dbo.tier_heartbeats
        ADD CONSTRAINT pk_tier_heartbeats PRIMARY KEY (tier, hostname);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_record_heartbeat
    @tier     VARCHAR(16),
    @hostname NVARCHAR(64),
    @distro   NVARCHAR(96),
    @kernel   NVARCHAR(64),
    @platform NVARCHAR(24),
    @location NVARCHAR(48),
    @vm_size  NVARCHAR(48) = NULL,
    @detail   NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dbo.tier_heartbeats WITH (HOLDLOCK) AS target
    USING (SELECT @tier AS tier, @hostname AS hostname) AS source
        ON target.tier = source.tier
       AND target.hostname = source.hostname
    WHEN MATCHED THEN UPDATE SET
        distro = @distro, kernel = @kernel, platform = @platform,
        location = @location, vm_size = @vm_size, detail = @detail,
        last_seen = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (tier, hostname, distro, kernel, platform, location, vm_size, detail)
        VALUES (@tier, @hostname, @distro, @kernel, @platform, @location,
                @vm_size, @detail);
END;
GO

IF OBJECT_ID('dbo.failure_polls', 'U') IS NULL
CREATE TABLE dbo.failure_polls (
    poll_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_failure_polls PRIMARY KEY,
    state         VARCHAR(16) NOT NULL
        CONSTRAINT ck_failure_polls_state
        CHECK (state IN ('closed', 'open', 'locked', 'injected', 'recovered')),
    winner_code   VARCHAR(24) NULL
        CONSTRAINT ck_failure_polls_winner
        CHECK (winner_code IS NULL OR winner_code IN (
            'freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims'
        )),
    opened_at     DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    locked_at     DATETIME2(0) NULL,
    injected_at   DATETIME2(0) NULL,
    recovered_at  DATETIME2(0) NULL,
    closed_at     DATETIME2(0) NULL
);
GO

IF OBJECT_ID('dbo.failure_votes', 'U') IS NULL
CREATE TABLE dbo.failure_votes (
    poll_id      BIGINT NOT NULL,
    voter_token VARCHAR(64) NOT NULL,
    choice_code VARCHAR(24) NOT NULL
        CONSTRAINT ck_failure_votes_choice
        CHECK (choice_code IN (
            'freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims'
        )),
    voted_at     DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_failure_votes PRIMARY KEY (poll_id, voter_token),
    CONSTRAINT fk_failure_votes_poll FOREIGN KEY (poll_id)
        REFERENCES dbo.failure_polls (poll_id) ON DELETE CASCADE
);
GO

/* Migrate polls created by the earlier placeholder scenarios. Drop the checks
   first so the durable codes can be translated without discarding votes. */
IF OBJECT_ID('dbo.failure_polls', 'U') IS NOT NULL
BEGIN
    IF OBJECT_ID('dbo.ck_failure_polls_winner', 'C') IS NOT NULL
        ALTER TABLE dbo.failure_polls DROP CONSTRAINT ck_failure_polls_winner;

    UPDATE dbo.failure_polls
       SET winner_code = CASE winner_code
           WHEN 'silence_worker' THEN 'freeze_azurelinux'
           WHEN 'cut_db_route' THEN 'degrade_worker_sql'
           WHEN 'crush_demand' THEN 'delay_worker_claims'
           ELSE winner_code
       END;

    ALTER TABLE dbo.failure_polls WITH CHECK
        ADD CONSTRAINT ck_failure_polls_winner
        CHECK (winner_code IS NULL OR winner_code IN (
            'freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims'
        ));
END;
GO

IF OBJECT_ID('dbo.failure_votes', 'U') IS NOT NULL
BEGIN
    IF OBJECT_ID('dbo.ck_failure_votes_choice', 'C') IS NOT NULL
        ALTER TABLE dbo.failure_votes DROP CONSTRAINT ck_failure_votes_choice;

    UPDATE dbo.failure_votes
       SET choice_code = CASE choice_code
           WHEN 'silence_worker' THEN 'freeze_azurelinux'
           WHEN 'cut_db_route' THEN 'degrade_worker_sql'
           WHEN 'crush_demand' THEN 'delay_worker_claims'
           ELSE choice_code
       END;

    ALTER TABLE dbo.failure_votes WITH CHECK
        ADD CONSTRAINT ck_failure_votes_choice
        CHECK (choice_code IN (
            'freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims'
        ));
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_open_failure_poll
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    UPDATE dbo.failure_polls
       SET state = 'closed',
           closed_at = SYSUTCDATETIME()
     WHERE state = 'open';

    INSERT dbo.failure_polls (state) VALUES ('open');
    DECLARE @poll_id BIGINT = SCOPE_IDENTITY();

    COMMIT TRANSACTION;
    SELECT @poll_id AS poll_id, CAST(1 AS BIT) AS opened;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_cast_failure_vote
    @poll_id BIGINT,
    @voter_token VARCHAR(64),
    @choice_code VARCHAR(24)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @choice_code NOT IN (
        'freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims'
    )
    BEGIN
        SELECT CAST(0 AS BIT) AS accepted, 'invalid_choice' AS reason;
        RETURN;
    END;

    BEGIN TRANSACTION;
    IF NOT EXISTS (
        SELECT 1
          FROM dbo.failure_polls WITH (UPDLOCK, HOLDLOCK)
         WHERE poll_id = @poll_id
           AND state = 'open'
    )
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT CAST(0 AS BIT) AS accepted, 'poll_not_open' AS reason;
        RETURN;
    END;

    MERGE dbo.failure_votes WITH (HOLDLOCK) AS target
    USING (
        SELECT @poll_id AS poll_id, @voter_token AS voter_token
    ) AS source
       ON target.poll_id = source.poll_id
      AND target.voter_token = source.voter_token
    WHEN MATCHED THEN UPDATE SET
        choice_code = @choice_code,
        voted_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (poll_id, voter_token, choice_code)
        VALUES (@poll_id, @voter_token, @choice_code);

    COMMIT TRANSACTION;
    SELECT CAST(1 AS BIT) AS accepted, 'accepted' AS reason;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_lock_failure_poll
    @poll_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    IF NOT EXISTS (
        SELECT 1
          FROM dbo.failure_polls WITH (UPDLOCK, HOLDLOCK)
         WHERE poll_id = @poll_id
           AND state = 'open'
    )
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT CAST(0 AS BIT) AS locked, NULL AS winner_code, 'poll_not_open' AS reason;
        RETURN;
    END;

    DECLARE @winner VARCHAR(24);
    WITH choices AS (
        SELECT choice_code, priority
          FROM (VALUES
              ('freeze_azurelinux', 1),
              ('degrade_worker_sql', 2),
              ('delay_worker_claims', 3)
          ) AS fixed(choice_code, priority)
    ),
    totals AS (
        SELECT c.choice_code, c.priority, COUNT(v.voter_token) AS vote_count
          FROM choices c
          LEFT JOIN dbo.failure_votes v
            ON v.poll_id = @poll_id
           AND v.choice_code = c.choice_code
         GROUP BY c.choice_code, c.priority
    )
    SELECT TOP (1) @winner = choice_code
      FROM totals
     ORDER BY vote_count DESC, priority ASC;

    UPDATE dbo.failure_polls
       SET state = 'locked',
           winner_code = @winner,
           locked_at = SYSUTCDATETIME()
     WHERE poll_id = @poll_id;

    COMMIT TRANSACTION;
    SELECT CAST(1 AS BIT) AS locked, @winner AS winner_code, 'locked' AS reason;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_set_failure_poll_state
    @poll_id BIGINT,
    @next_state VARCHAR(16)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.failure_polls
       SET state = @next_state,
           injected_at = CASE WHEN @next_state = 'injected' THEN SYSUTCDATETIME() ELSE injected_at END,
           recovered_at = CASE WHEN @next_state = 'recovered' THEN SYSUTCDATETIME() ELSE recovered_at END,
           closed_at = CASE WHEN @next_state = 'closed' THEN SYSUTCDATETIME() ELSE closed_at END
     WHERE poll_id = @poll_id
       AND (
           (state = 'locked' AND @next_state IN ('injected', 'closed'))
        OR (state = 'injected' AND @next_state IN ('recovered', 'closed'))
        OR (state = 'recovered' AND @next_state = 'closed')
        OR (state = 'open' AND @next_state = 'closed')
       );

    SELECT CAST(CASE WHEN @@ROWCOUNT = 1 THEN 1 ELSE 0 END AS BIT) AS updated;
END;
GO

/* Complete one queue item and its shipment transition atomically. Different
   workers may claim different queue rows for the same shipment; the expected
   status check serializes those transitions without globally locking workers. */
CREATE OR ALTER PROCEDURE dbo.usp_complete_scan
    @queue_id BIGINT,
    @shipment_id BIGINT,
    @worker NVARCHAR(64),
    @expected_status VARCHAR(20),
    @next_status VARCHAR(20),
    @location NVARCHAR(80),
    @scan_type VARCHAR(32),
    @notes NVARCHAR(200),
    @worker_site NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    IF NOT EXISTS (
        SELECT 1
          FROM dbo.scan_queue WITH (UPDLOCK, HOLDLOCK)
         WHERE queue_id = @queue_id
           AND shipment_id = @shipment_id
           AND claimed_by = @worker
           AND processed_at IS NULL
    )
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT CAST(0 AS BIT) AS applied, 'queue_not_claimed' AS reason;
        RETURN;
    END;

    DECLARE @actual_status VARCHAR(20);
    DECLARE @hold_status VARCHAR(20);
    SELECT @actual_status = status, @hold_status = demo_hold_status
      FROM dbo.shipments WITH (UPDLOCK, HOLDLOCK)
     WHERE shipment_id = @shipment_id;

    IF @actual_status IS NULL
    BEGIN
        UPDATE dbo.scan_queue
           SET processed_at = SYSUTCDATETIME(),
               last_error = N'unknown shipment'
         WHERE queue_id = @queue_id;
        COMMIT TRANSACTION;
        SELECT CAST(0 AS BIT) AS applied, 'unknown_shipment' AS reason;
        RETURN;
    END;

    IF @hold_status = @actual_status
    BEGIN
        UPDATE dbo.scan_queue
           SET claimed_by = NULL, claimed_at = NULL
         WHERE queue_id = @queue_id;
        COMMIT TRANSACTION;
        SELECT CAST(0 AS BIT) AS applied, 'held' AS reason;
        RETURN;
    END;

    IF @actual_status <> @expected_status
    BEGIN
        UPDATE dbo.scan_queue
           SET claimed_by = NULL, claimed_at = NULL
         WHERE queue_id = @queue_id;
        COMMIT TRANSACTION;
        SELECT CAST(0 AS BIT) AS applied, 'status_changed' AS reason;
        RETURN;
    END;

    INSERT INTO dbo.scan_events
        (shipment_id, scan_type, location, notes, worker_host, worker_site)
    VALUES
        (@shipment_id, @scan_type, @location, @notes, @worker, @worker_site);

    INSERT INTO dbo.status_history
        (shipment_id, from_status, to_status, changed_by)
    VALUES
        (@shipment_id, @expected_status, @next_status, N'worker:' + @worker);

    UPDATE dbo.shipments
       SET status = @next_status,
           updated_at = SYSUTCDATETIME()
     WHERE shipment_id = @shipment_id;

    UPDATE dbo.scan_queue
       SET processed_at = SYSUTCDATETIME(),
           last_error = NULL
     WHERE queue_id = @queue_id;

    COMMIT TRANSACTION;
    SELECT CAST(1 AS BIT) AS applied, 'applied' AS reason;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'shipping_app') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.usp_open_failure_poll TO shipping_app;
    GRANT EXECUTE ON dbo.usp_cast_failure_vote TO shipping_app;
    GRANT EXECUTE ON dbo.usp_lock_failure_poll TO shipping_app;
    GRANT EXECUTE ON dbo.usp_set_failure_poll_state TO shipping_app;
    GRANT EXECUTE ON dbo.usp_complete_scan TO shipping_app;
END;
GO
