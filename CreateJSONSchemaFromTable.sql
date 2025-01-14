CREATE OR ALTER PROCEDURE  #CreateJSONSchemaFromTable
/**
Summary: >
  This creates a JSON schema from a table that
  matches the JSON you will get from doing a 
  classic FOR JSON select * statemenmt on the entire table
Author: phil factor
Date: 26/10/2018
Examples: >
  DECLARE @Json NVARCHAR(MAX)
  EXECUTE #CreateJSONSchemaFromTable @database='pubs', @Schema ='dbo', @table= 'authors',@JSONSchema=@json OUTPUT
  PRINT @Json
  SELECT @json=''
  EXECUTE #CreateJSONSchemaFromTable @TableSpec='pubs.dbo.authors',@JSONSchema=@json OUTPUT
  PRINT @Json
Returns: >
  nothing
**/
    (@database sysname=null, @Schema sysname=NULL, @table sysname=null, @Tablespec sysname=NULL,@jsonSchema NVARCHAR(MAX) output)

--WITH ENCRYPTION|SCHEMABINDING, ...
AS

DECLARE @required NVARCHAR(MAX), @NoColumns INT, @properties NVARCHAR(MAX), @definitions NVARCHAR(MAX);
			
           IF Coalesce(@table,@Tablespec) IS NULL
			 OR Coalesce(@schema,@Tablespec) IS NULL
			   RAISERROR ('{"error":"must have the table details"}',16,1)
			
		   IF @table is NULL SELECT @table=ParseName(@Tablespec,1)
		   IF @Schema is NULL SELECT @schema=ParseName(@Tablespec,2)
		   IF @Database is NULL SELECT @Database=Coalesce(ParseName(@Tablespec,3),Db_Name())
		   IF @table IS NULL OR @schema IS NULL OR @database IS NULL
		      RAISERROR  ('{"error":"must have the table details"}',16,1)
           
           DECLARE @SourceCode NVARCHAR(255)=
           (SELECT 'SELECT * FROM '+QuoteName(@database)+ '.'+ QuoteName(@Schema)+'.'+QuoteName(@table))
            SELECT 
             @properties= String_Agg(
	             	(CASE WHEN array_type IS NOT NULL THEN
	             		'"'+f.name+
	             		'": {"type":["'+f.type+'"],'+
	             		'"items":{"$ref": "#/definitions/'+f.array_type+'"}'+'}'
		             WHEN one_of IS NULL THEN 
	               		'"'+f.name+'": {"type":["'+Replace(type,' ','","')+'"],'+
	               		(CASE WHEN format IS NOT NULL THEN '"format":"'+format+'",' ELSE '' END)+
	               		'"sqltype":"'+sqltype+'", "columnNo":'+ Convert(VARCHAR(3), f.column_ordinal)
	           			+', "nullable":'+Convert(CHAR(1),f.is_nullable)+', "Description":"'
	               		+String_Escape(Coalesce(Convert(NvARCHAR(875),EP.value),''),'json')+'"}'
					ELSE
						'"'+f.one_of+'": {"oneOf":[{"$ref": "#/definitions/'+f.one_of+'"}]'+'}'
					END
					), ','),
             @NoColumns=Max(f.column_ordinal),
             @required=String_Agg((CASE WHEN is_nullable = 0 THEN '"'+f.Name+'"' ELSE NULL END), ','),
             @definitions=String_Agg(
             		(CASE WHEN array_type IS NOT NULL THEN
						'"'+f.array_type+'": {}'
					WHEN one_of IS NOT NULL THEN
						'"'+f.one_of+'": {}'
					ELSE
						NULL
					END
					), ',')
             FROM
               ( --the basic columns we need. (the type is used more than once in the outer query) 
	               SELECT *
					FROM
					(SELECT 
					 r0.name, 
					 CASE WHEN r0.system_type_id IN (42, 58, 61) THEN 'date-time'
					WHEN system_type_id = 40 THEN 'date'
					WHEN system_type_id = 41 THEN 'time' ELSE NULL END AS format,
					 r0.system_type_name AS sqltype,
					 r0.source_column,
					 r0.is_nullable,
					 r0.column_ordinal,
					 CASE WHEN r0.system_type_id IN (48, 52, 56) THEN 'integer'
					WHEN r0.system_type_id IN (59, 60, 62, 106, 108, 122, 127) THEN 'number'
					   WHEN system_type_id = 104 THEN 'boolean' ELSE 'string' END
					 + CASE WHEN r0.is_nullable = 1 THEN ' null' ELSE '' END AS type,
					 (select object_name(fkc.referenced_object_id) from sys.foreign_key_columns fkc
						where fkc.parent_column_id = r0.column_ordinal AND
						fkc.parent_object_id = CAST(Object_Id(r0.source_database + '.' + r0.source_schema + '.' + r0.source_table) AS INT)) AS one_of,
					 NULL AS array_type,
					 Object_Id(r0.source_database + '.' + r0.source_schema + '.' + r0.source_table) AS table_id
					 FROM sys.dm_exec_describe_first_result_set(@sourcecode, NULL, 1) AS r0
					 UNION
					 SELECT 
					 (object_name(fkc.parent_object_id) + 'List') as name,
					 NULL AS format,
					 NULL AS sqltype,
					 NULL AS source_column,
					 0 AS is_nullable,
					 1000 AS column_ordinal,
					 'array' AS type,
					 NULL AS one_of,
					 object_name(fkc.parent_object_id) AS array_type,
					 Object_Id(r1.source_database + '.' + r1.source_schema + '.' + r1.source_table) AS table_id
					 FROM sys.dm_exec_describe_first_result_set(@sourcecode, NULL, 1) AS r1
						INNER JOIN sys.foreign_key_columns fkc
						ON fkc.parent_column_id = r1.column_ordinal AND
						fkc.referenced_object_id = CAST(Object_Id(r1.source_database + '.' + r1.source_schema + '.' + r1.source_table) AS INT)) AS r
               ) AS f
               LEFT OUTER JOIN sys.extended_properties AS EP -- to get the extended properties
                 ON EP.major_id = f.table_id
                AND EP.minor_id = ColumnProperty(f.table_id, f.source_column, 'ColumnId')
                AND EP.name = 'MS_Description'
                AND EP.class = 1
           
           IF @definitions IS NULL
           		SELECT @definitions = '';
           
           IF @required IS NULL
           		SELECT @required = '';
           	
           IF @NoColumns IS NULL
           		SELECT @NoColumns = 0;

           SELECT @JSONschema =
             Replace(
               Replace(
                Replace(
                 Replace(
                   Replace('{
						  "$id": "https://json-schema.com/<-schema->-<-table->.json",
						  "$schema": "http://json-schema.org/draft-07/schema#",
						  "title": "<-table->",
						  "SQLtablename":"'+quotename(@schema)+'.'+quotename(@table)+'",
						  "SQLschema":"<-schema->",
						  "type": "object",
						  "required": [<-Required->],
						  "maxProperties": <-MaxColumns->,
						  "minProperties": <-MinColumns->,
						  "properties":{'+@properties+'},
						  "definitions":{'+@definitions+'}
					   }', '<-minColumns->', Convert(VARCHAR(5),@NoColumns) COLLATE DATABASE_DEFAULT
           	         ) , '<-maxColumns->',Convert(VARCHAR(5),@NoColumns +1) COLLATE DATABASE_DEFAULT
           	         ) , '<-Required->',@required COLLATE DATABASE_DEFAULT
           		   ) ,'<-schema->',@Schema COLLATE DATABASE_DEFAULT
           	     ) ,'<-table->', @table COLLATE DATABASE_DEFAULT
                  );
           

           IF(IsJson(@jsonschema)=0) 
		    RAISERROR ('invalid schema "%s"',16,1,@jsonSchema)
           IF @jsonschema IS NULL RAISERROR ('Null schema',16,1)
           
           
GO


/**
  
  DECLARE @TheJSONSchema NVARCHAR(MAX);
  EXECUTE #CreateJSONSchemaForAllTables @jsonSchema = @TheJSONSchema OUTPUT;
  SELECT @TheJSONSchema;
  
 * */
CREATE OR ALTER PROCEDURE #CreateJSONSchemaForAllTables(@jsonSchema NVARCHAR(MAX) output)
AS

	DECLARE @Tablespec NVARCHAR(200)

	DECLARE MY_CURSOR CURSOR 
	  LOCAL STATIC READ_ONLY FORWARD_ONLY
	FOR 
		SELECT (DB_NAME()+'.'+schema_name(obj.schema_id)+'.'+obj.name) AS tablespec
		FROM sys.objects obj
		WHERE obj.type='u'
	
	OPEN MY_CURSOR
	FETCH NEXT FROM MY_CURSOR INTO @Tablespec
	WHILE @@FETCH_STATUS = 0
	BEGIN
		BEGIN TRY	
			DECLARE @jsonTablespec NVARCHAR(MAX)
		    EXECUTE #CreateJSONSchemaFromTable @Tablespec = @Tablespec,
	  			@jsonSchema = @jsonTablespec OUTPUT;
	  		
	  		IF LEN(@jsonSchema) <> 0
				SELECT @jsonSchema = CONCAT(@jsonSchema, ',');
	  		
	  		SELECT @jsonSchema = CONCAT(@jsonSchema, @jsonTablespec);
		END TRY
		BEGIN CATCH
			PRINT 'ErrorNumber: '+CAST(ERROR_NUMBER() AS NVARCHAR(200))+' ** ErrorMessage: '+ERROR_MESSAGE()+' ** Table: '+@Tablespec;
        END CATCH;
		
	  	FETCH NEXT FROM MY_CURSOR INTO @Tablespec
	END
	CLOSE MY_CURSOR
	DEALLOCATE MY_CURSOR
	
	SELECT @jsonSchema = CONCAT('[', @jsonSchema, ']');
	
GO
