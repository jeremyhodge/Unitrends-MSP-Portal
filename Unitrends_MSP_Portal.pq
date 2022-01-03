// This file contains your Data Connector logic
section Unitrends_MSP_Portal;

// *** Global Variables *** //

// Service baseUrl
ServiceURI = "https://public-api.backup.net/v1/";
AccessTokenEndpoint = "https://login.backup.net/connect/token";

Endpoints = #table({"Name", "Endpoint", "Schema"}, {
    { "Latest Agent",      "agents/latest",                null },
    { "Customers",         "customers",                    "Customers" },
    { "Appliances",        "appliances",                   "Appliances" },
    { "Assets",            "assets",                       "Assets" },
    { "Backups",           "backups",                      "Backups" },
    { "BackupIQ Alerts",   "backupiq/alerts?type=alert",   "BackupIQAlerts" }
});

accessToken = Unitrends.TokenMethod();

// *** DataSource Definition *** //
[DataSource.Kind="Unitrends_MSP_Portal", Publish="Unitrends_MSP_Portal.Publish"]
shared Unitrends_MSP_Portal.Contents = Value.ReplaceType(Unitrends_Nav_Table, type function () as any);

Unitrends_Nav_Table = () as table =>
    let 
        Source = Endpoints,
        withData = Table.AddColumn(Source, "Data", each if ([Endpoint] = "agents/latest") then Unitrends.GetAgentsTable([Endpoint]) else Unitrends.GetEntity([Endpoint], [Schema]), Table.Type),
        withoutEndpoint = Table.RemoveColumns(withData, { "Endpoint", "Schema" }),
        withItemKind = Table.AddColumn(withoutEndpoint, "ItemKind", each "Table", type text),
        withItemName = Table.AddColumn(withItemKind, "ItemName", each "Table", type text),
        withIsLeaf = Table.AddColumn(withItemName, "IsLeaf", each true, type logical),
        navTable = Table.ToNavigationTable(withIsLeaf, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable; 

Unitrends_MSP_Portal = [
    Authentication = [
        Key = [
            KeyLabel = Extension.LoadString("KeyLabel"),
            Label = Extension.LoadString("AuthenticationLabel")
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

Unitrends_MSP_Portal.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = Unitrends_MSP_Portal.Icons,
    SourceTypeImage = Unitrends_MSP_Portal.Icons
];

Unitrends_MSP_Portal.Icons = [
    Icon16 = { Extension.Contents("unitrends-16.png"), Extension.Contents("unitrends-20.png"), Extension.Contents("unitrends-24.png"), Extension.Contents("unitrends-32.png") },
    Icon32 = { Extension.Contents("unitrends-32.png"), Extension.Contents("unitrends-40.png"), Extension.Contents("unitrends-48.png"), Extension.Contents("unitrends-64.png") }
];

Unitrends.GetEntity = (endpoint as text, schema as text) as table =>
    let
        fullUrl = Uri.Combine(ServiceURI, endpoint),
        schemaTable = GetSchemaForEntity(schema),
        result = Unitrends.GetPagedTable(fullUrl, schemaTable)
    in
        result;

Unitrends.GetPagedTable = (endpoint as text, schema as table) => Table.GenerateByPage((previous) =>
    let
        pagingPageNumber = if (previous <> null) then Number.From(Value.Metadata(previous)[headers][#"Paging-Page-Number"]) else 0,
        pagingTotalPages = if (previous <> null) then Number.From(Value.Metadata(previous)[headers][#"Paging-Total-Pages"]) else null,
        urlToUse = (if Text.Contains(endpoint, "?") then endpoint & "&" else endpoint & "?") & "page_number=" & Text.From(pagingPageNumber + 1) & "&page_size=5000",
        current = if (pagingPageNumber = pagingTotalPages) then null else Unitrends.GetTable(urlToUse, schema),
        headers = if (current <> null) then Value.Metadata(current)[headers] else null
    in
        current meta [headers=headers]
);

Unitrends.GetTable = (endpoint as text, schema as table) as table =>
    let
        webDoc = Web.Contents(endpoint, [ Headers = [ #"User-Agent" = "PowerBI-Unitrends-Custom-Connector/1.0.0", #"Accept" = "application/json", #"Authorization" = "Bearer " & accessToken ], ManualCredentials = true ]),
        Source = Json.Document(webDoc),
        asTable = Table.FromList(Source, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        fields = Record.FieldNames(Table.FirstValue(asTable, [Empty = null])),
        expandAll = Table.ExpandRecordColumn(asTable, "Column1", fields),
        headers = Value.Metadata(webDoc)[Headers],
        withSchema = if (schema <> null) then SchemaTransformTable(expandAll, schema) else expandAll
    in
        withSchema meta [headers=headers];
			
Unitrends.GetAgentsTable = (url as text) as table =>       
    let
        RequestHeaders = Unitrends.TokenMethod(),
        Source = Json.Document(Web.Contents(url, [ Headers = [ #"User-Agent" = "PowerBI-Unitrends-Custom-Connector/1.0.0", #"Accept" = "application/json", #"Authorization" = "Bearer " & accessToken ], ManualCredentials = true ])),
        #"Converted to Table" = Record.ToTable(Source),
        #"Pivoted Column" = Table.Pivot(#"Converted to Table", List.Distinct(#"Converted to Table"[Name]), "Name", "Value")
    in
        #"Pivoted Column";

Unitrends.TokenMethod = () =>
    let
        LocalBearerToken = Json.Document(Web.Contents(AccessTokenEndpoint, [
            Content = Text.ToBinary(Uri.BuildQueryString([
                grant_type = "client_credentials"
            ])),
            Headers = [
                #"Content-type" = "application/x-www-form-urlencoded",
                #"Authorization" = "Basic " & Binary.ToText(Text.ToBinary(Extension.CurrentCredential()[Key] /*[Username] & ":" & Extension.CurrentCredential()[Password]*/, BinaryEncoding.Base64)),
                #"User-Agent" = "PowerBI-Unitrends-Custom-Connector/1.0.0", 
                #"Accept" = "*/*",
                #"Cache-Control" = "no-cache"
            ],
            ManualCredentials = true
        ]))[access_token]
    in
        LocalBearerToken;

// Table Class Extensions
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;

Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if (firstRow = null) then
            Table.FromRows({})
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

// Schema Definitions

Unitrends.Schemas.Customers = #table({"Name", "Type"}, {
    {"id", type text },
    {"name", type text }
});

Unitrends.Schemas.Appliances = #table({"Name", "Type"}, {
    {"customer_id", type text },
    {"asset_tag", type text },
    {"name", type text },
    {"is_online", type logical },
    {"total_mb_size", type number },
    {"total_mb_free", type number },
    {"version", type text },
    {"helix_status", type text }
});

Unitrends.Schemas.Assets = #table({"Name", "Type"}, {
    {"customer_id", type text },
    {"asset_tag", type text },
    {"name", type text },
    {"type", type text },
    {"key", type text }
});

Unitrends.Schemas.Backups = #table({"Name", "Type"}, {
    {"customer_id", type text },
    {"asset_tag", type text },
    {"start_time", type datetime },
    {"complete_time", type datetime },
    {"size", type number },
    {"type", type text },
    {"status", type text },
    {"replication_status", type text },
    {"asset_key", type text }
});

Unitrends.Schemas.BackupIQ.Alerts = #table({"Name", "Type"}, {
    { "type", type text },
    { "appliance_name", type text },
    { "asset_tag", type text },
    { "customer_id", type text },
    { "customer_name", type text },
    { "message", type text },
    { "severity", type text },
    { "created_time", type datetime },
    { "is_dismissed", type logical }
});

Unitrends.SchemaTable = #table({"Entity", "SchemaTable"}, {
    { "Customers", Unitrends.Schemas.Customers },
    { "Appliances", Unitrends.Schemas.Appliances },
    { "Assets", Unitrends.Schemas.Assets },
    { "Backups", Unitrends.Schemas.Backups },
    { "BackupIQAlerts", Unitrends.Schemas.BackupIQ.Alerts },
    { "Agents", null }
});

GetSchemaForEntity = (entity as text) as table => try Unitrends.SchemaTable{[Entity=entity]}[SchemaTable] otherwise error "Couldn't find entity: '" & entity &"'";

EnforceSchema.Strict = 1;               // Add any missing columns, remove extra columns, set table type
EnforceSchema.IgnoreExtraColumns = 2;   // Add missing columns, do not remove extra columns
EnforceSchema.IgnoreMissingColumns = 3; // Do not add or remove columns

SchemaTransformTable = (table as table, schema as table, optional enforceSchema as number) as table =>
    let
        // Default to EnforceSchema.Strict
        _enforceSchema = if (enforceSchema <> null) then enforceSchema else EnforceSchema.Strict,

        // Applies type transforms to a given table
        EnforceTypes = (table as table, schema as table) as table =>
            let
                map = (t) => if Type.Is(t, type list) or Type.Is(t, type record) or t = type any then null else t,
                mapped = Table.TransformColumns(schema, {"Type", map}),
                omitted = Table.SelectRows(mapped, each [Type] <> null),
                existingColumns = Table.ColumnNames(table),
                removeMissing = Table.SelectRows(omitted, each List.Contains(existingColumns, [Name])),
                primativeTransforms = Table.ToRows(removeMissing),
                changedPrimatives = Table.TransformColumnTypes(table, primativeTransforms)
            in
                changedPrimatives,

        // Returns the table type for a given schema
        SchemaToTableType = (schema as table) as type =>
            let
                toList = List.Transform(schema[Type], (t) => [Type=t, Optional=false]),
                toRecord = Record.FromList(toList, schema[Name]),
                toType = Type.ForRecord(toRecord, false)
            in
                type table (toType),

        // Determine if we have extra/missing columns.
        // The enforceSchema parameter determines what we do about them.
        schemaNames = schema[Name],
        foundNames = Table.ColumnNames(table),
        addNames = List.RemoveItems(schemaNames, foundNames),
        extraNames = List.RemoveItems(foundNames, schemaNames),
        tmp = Text.NewGuid(),
        added = Table.AddColumn(table, tmp, each []),
        expanded = Table.ExpandRecordColumn(added, tmp, addNames),
        result = if List.IsEmpty(addNames) then table else expanded,
        fullList =
            if (_enforceSchema = EnforceSchema.Strict) then
                schemaNames
            else if (_enforceSchema = EnforceSchema.IgnoreMissingColumns) then
                foundNames
            else
                schemaNames & extraNames,

        // Select the final list of columns.
        // These will be ordered according to the schema table.
        reordered = Table.SelectColumns(result, fullList, MissingField.Ignore),
        enforcedTypes = EnforceTypes(reordered, schema),
        withType = if (_enforceSchema = EnforceSchema.Strict) then Value.ReplaceType(enforcedTypes, SchemaToTableType(schema)) else enforcedTypes
    in
        withType;