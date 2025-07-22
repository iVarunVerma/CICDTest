-- =============================================
-- Description:	This procedure runs at the end of the process and manages the delta.


/*

exec [PriceFlattening].[Manage_Price_Delta] @FullRun = 1

*/
-- =============================================
ALTER   PROCEDURE [PriceFlattening].[Manage_Price_Delta]
(
	@FullRun bit
)
AS
BEGIN
	SET NOCOUNT ON;

	BEGIN TRY
        BEGIN TRANSACTION;

		DECLARE @TotalCount INT = 0;

			IF EXISTS (SELECT TOP 1 * FROM [PriceFlattening].[Stage_Pricing])
			BEGIN
			
				IF (@FullRun = 0)
				BEGIN

					UPDATE P
						SET
							p.[RecordAction] = 'Deleted',
							p.[ActionDate] = GETUTCDATE()					
					FROM [PriceFlattening].[RateDelta] RD
					JOIN [PriceFlattening].[Pricing] P
						ON P.[Key] Like  CAST(RD.RateId AS VARCHAR) + ':%' AND RD.IsRemoved = 1;

					UPDATE P
						SET
							p.[RecordAction] = 'Deleted',
							p.[ActionDate] = GETUTCDATE()
					FROM [PriceFlattening].[DrugDelta] DD
					JOIN [PriceFlattening].[Pricing] P
						ON P.[Key] Like  '%:' + DD.NDC AND DD.IsRemoved = 1;
				
					--DELETE P FROM [PriceFlattening].[RateDelta] RD
					--JOIN [PriceFlattening].[Pricing] P
					--	ON P.[Key] Like  CAST(RD.RateId AS VARCHAR) + ':%' AND RD.IsRemoved = 1;

					--DELETE P FROM [PriceFlattening].[DrugDelta] DD
					--JOIN [PriceFlattening].[Pricing] P
					--	ON P.[Key] Like  '%:' + DD.NDC AND DD.IsRemoved = 1;
						
					MERGE INTO [PriceFlattening].[Pricing] AS target
					USING [PriceFlattening].[Stage_Pricing] AS source
					ON target.[Key] = source.[Key]

					WHEN MATCHED AND (target.[Json] <> source.[Json]) THEN
						UPDATE SET 
							target.[Json] = source.[Json],
							target.[RecordAction] = 'Updated',
							target.[ActionDate] = GETUTCDATE()

					-- When the row doesn't exist in the target, insert the new data
					WHEN NOT MATCHED BY TARGET THEN
						INSERT ([Key], [Json], CreatedDate, [RecordAction], [ActionDate])
						VALUES (source.[Key], source.[Json], GETUTCDATE(), 'Inserted', GETUTCDATE());
				
				END --// IF (@FullRun = 0)
				ELSE
				BEGIN

					/* These are unchanged records */
					MERGE INTO [PriceFlattening].[Pricing] AS target
					USING [PriceFlattening].[Stage_Pricing] AS source
					ON target.[Key] = source.[Key]

					WHEN MATCHED AND (target.[Json] = source.[Json]) THEN
						UPDATE SET 
							target.[RecordAction] = 'Unchanged';


					MERGE INTO [PriceFlattening].[Pricing] AS target
					USING [PriceFlattening].[Stage_Pricing] AS source
					ON target.[Key] = source.[Key]

					WHEN MATCHED AND (target.[Json] <> source.[Json]) THEN
						UPDATE SET 
							target.[Json] = source.[Json],
							target.[RecordAction] = 'Updated',
							target.[ActionDate] = GETUTCDATE()

					-- When the row doesn't exist in the target, insert the new data
					WHEN NOT MATCHED BY TARGET THEN
						INSERT ([Key], [Json], CreatedDate, [RecordAction], [ActionDate])
						VALUES (source.[Key], source.[Json], GETUTCDATE(), 'Inserted', GETUTCDATE())

					-- Delete these records
					WHEN NOT MATCHED BY SOURCE THEN
						UPDATE SET 
							target.[RecordAction] = 'Deleted',
							target.[ActionDate] = GETUTCDATE();
					
				END --// ELSE OF IF (@FullRun = 0)

				SELECT @TotalCount = COUNT(0) FROM [PriceFlattening].[Pricing] WITH(NOLOCK);

				--// Return changed numbers
				SELECT
					COUNT(CASE WHEN [RecordAction] = 'Inserted' THEN 1 END) AS InsertedCount,
					COUNT(CASE WHEN [RecordAction] = 'Updated' THEN 1 END) AS UpdatedCount,
					COUNT(CASE WHEN [RecordAction] = 'Deleted' THEN 1 END) AS DeletedCount,
					@TotalCount AS TotalCount
				FROM 
					[PriceFlattening].[Pricing]
				WHERE 
					[ActionDate] >= CAST(GETUTCDATE() AS DATE);


				--// Now delete the records as we do not need deleted records in this table; -- Requirement
				DELETE FROM 
					[PriceFlattening].[Pricing]
				WHERE 
					[ActionDate] >= CAST(GETUTCDATE() AS DATE) AND [RecordAction] = 'Deleted';

			END
			ELSE
			BEGIN
				--// In case if there is nothing changed
				SELECT 0 AS InsertedCount, 0 AS UpdatedCount, 0 AS DeletedCount, COUNT(0) AS TotalCount 
				FROM [PriceFlattening].[Pricing];

			END

        -- Commit the transaction if all updates are successful
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Rollback the transaction if an error occurs
        ROLLBACK TRANSACTION;

        -- Log the error
        DECLARE @ErrorMessage NVARCHAR(4000);
        DECLARE @ErrorSeverity INT;
        DECLARE @ErrorState INT;

        SELECT @ErrorMessage = ERROR_MESSAGE(),
               @ErrorSeverity = ERROR_SEVERITY(),
               @ErrorState = ERROR_STATE();

        -- Raise the error so that it propagates back to the caller
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;

END