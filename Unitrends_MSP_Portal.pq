section Unitrends_MSP;

Unitrends_MSP = [
    TestConnection = (dataSourcePath) => { "Unitrends_MSP.Contents" },
    Authentication = [
        Key = [
            KeyLabel = Extension.LoadString("KeyLabel"),
            Label = Extension.LoadString("AuthenticationLabel")
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

Unitrends_MSP.Publish = [
    Beta = true,
    Category = "MSP Power Platform Project",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://www.unitrendsmsp.com/",
    SourceImage = Unitrends_MSP.Icons,
    SourceTypeImage = Unitrends_MSP.Icons
];

Unitrends_MSP.Icons = [
    Icon16 = { Extension.Contents("unitrends-16.png"), Extension.Contents("unitrends-20.png"), Extension.Contents("unitrends-24.png"), Extension.Contents("unitrends-32.png") },
    Icon32 = { Extension.Contents("unitrends-32.png"), Extension.Contents("unitrends-40.png"), Extension.Contents("unitrends-48.png"), Extension.Contents("unitrends-64.png") }
];

//
// Implementation
//
[DataSource.Kind="Unitrends_MSP", Publish="Unitrends_MSP.Publish"]
shared Unitrends_MSP.Contents = () => Unitrends_MSP.NavTable() as table;

Unitrends_MSP.Endpoints = Extension.LoadFunction("Endpoints.pqm");
Unitrends_MSP.Schema = Extension.LoadFunction("Schema.pqm");

Unitrends_MSP.NavTable = () as table =>
    let 
        ServiceURI = "https://public-api.backup.net",
        accessToken = Unitrends_MSP.doAuthentication(),
        Source = Unitrends_MSP.Endpoints,
        withData = Table.AddColumn(Source, "Data", each Unitrends_MSP.View(Uri.Combine(ServiceURI, [Endpoint]), [Schema], accessToken), Table.Type),
        withoutEndpoint = Table.RemoveColumns(withData, { "Endpoint", "Schema" }),
        withItemKind = Table.AddColumn(withoutEndpoint, "ItemKind", each "Table", type text),
        withItemName = Table.AddColumn(withItemKind, "ItemName", each "Table", type text),
        withIsLeaf = Table.AddColumn(withItemName, "IsLeaf", each true, type logical),
        navTable = Table.ToNavigationTable(withIsLeaf, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable; 

Unitrends_MSP.View = (baseUrl as text, entity as text, accessToken as text) as table =>
    let
        View = (state as record) => Table.View(null, Diagnostics.WrapHandlers([
            GetType = () => CalculateSchema(state),

            GetRows = () => 
                let
                    finalSchema = CalculateSchema(state),
                    finalUrl = CalculateUrl(state),
                    allowPaging = (Unitrends_MSP.GetAllowPagingForEntity(state[Entity]) = "true"),

                    result = Unitrends_MSP.GetPagedTable(finalUrl, finalSchema, accessToken, allowPaging),
                    appliedType = Table.ChangeType(result, finalSchema)
                in
                    appliedType,

            //TODO: Implement OnTop to limit query size for table preview

            CalculateSchema = (state) as type =>
                if (state[Schema]? = null) then
                    Unitrends_MSP.GetSchemaForEntity(entity)
                else
                    state[Schema],

            CalculateUrl = (state) as text => 
                let
                    _params = Unitrends_MSP.GetParamsForEntity(state[Entity]),
                    params = if (_params = "") then "" else _params,
                    queryString = if (params <> "") then "?" & params else "",
                    urlWithEntity = Uri.Combine(state[Url], Unitrends_MSP.GetEndpointForEntity(state[Entity])) & queryString
                in
                    urlWithEntity
        ]))
    in
        View([Url = baseUrl, Entity = entity]);

Unitrends_MSP.GetPagedTable = (endpoint as text, schema as type, accessToken as text, allowPaging as logical) => Table.GenerateByPage((previous) =>
    let
        pagingPageNumber = if (previous <> null) and Record.HasFields(Value.Metadata(previous)[headers],"Paging-Page-Number") then Number.From(Value.Metadata(previous)[headers][#"Paging-Page-Number"]) else 0,
        pagingTotalPages = if (previous <> null) and Record.HasFields(Value.Metadata(previous)[headers],"Paging-Total-Pages") then Number.From(Value.Metadata(previous)[headers][#"Paging-Total-Pages"]) else null,
        urlToUse = 
            if (allowPaging) then
                (if Text.Contains(endpoint, "?") then endpoint & "&" else endpoint & "?") & "page_number=" & Text.From(pagingPageNumber + 1) & "&page_size=5000"
            else
                endpoint,
        current = if (pagingPageNumber = pagingTotalPages) or (allowPaging = false and previous <> null) then null else Unitrends_MSP.GetPage(urlToUse, schema, accessToken),
        headers = if (current <> null) then Value.Metadata(current)[headers] else null
    in
        current meta [headers=headers]
);

Unitrends_MSP.GetPage = (endpoint as text, schema as type, accessToken as text) as table =>
    let
        webDoc = Web.Contents(endpoint, [ Headers = [ #"User-Agent" = "Unitrends-Custom-Connector/1.0.0", #"Accept" = "application/json", #"Authorization" = "Bearer " & accessToken ], ManualCredentials = true ]),
        _body = Json.Document(webDoc),
        body =
            if (Value.Type(_body) <> type { any }) then
                { _body }
            else                
                _body,

        headers = Value.Metadata(webDoc)[Headers],
        data =
            if (schema = null) then 
                Diagnostics.LogFailure(
                    "Error converting response body. Are the records uniform?",
                    () => Table.FromRecords(body)
                )
            else
                let
                    asTable = Table.FromList(body, Splitter.SplitByNothing(), {"Column1"}),
                    fields = Record.FieldNames(Type.RecordFields(Type.TableRow(schema))),
                    expanded = Table.ExpandRecordColumn(asTable, "Column1", fields)  
                in
                    expanded
    in
        data meta [headers=headers];

Unitrends_MSP.doAuthentication = () =>
    let
        AccessTokenEndpoint = "https://login.backup.net/connect/token",
        LocalBearerToken = Json.Document(Web.Contents(AccessTokenEndpoint, [
            Content = Text.ToBinary(Uri.BuildQueryString([
                grant_type = "client_credentials"
            ])),
            Headers = [
                #"Content-type" = "application/x-www-form-urlencoded",
                #"Authorization" = "Basic " & Binary.ToText(Text.ToBinary(Extension.CurrentCredential()[Key], BinaryEncoding.Base64)),
                #"User-Agent" = "Unitrends-Custom-Connector/1.0.0", 
                #"Accept" = "*/*",
                #"Cache-Control" = "no-cache"
            ],
            ManualCredentials = true
        ]))[access_token]
    in
        LocalBearerToken;

Unitrends_MSP.GetSchemaForEntity = (entity as text) as type =>
    try
        Unitrends_MSP.Schema{[Entity=entity]}[Type]
    otherwise 
        let 
            message = Text.Format("Couldn't find entity: '#{0}'", {entity})
        in
            Diagnostics.Trace(TraceLevel.Error, message, () => error message, true);

Unitrends_MSP.GetEndpointForEntity = (entity as text) as text =>
    try
        Unitrends_MSP.Endpoints{[Schema=entity]}[Endpoint]
    otherwise 
        let 
            message = Text.Format("Couldn't find entity: '#{0}'", {entity})
        in
            Diagnostics.Trace(TraceLevel.Error, message, () => error message, true);

Unitrends_MSP.GetParamsForEntity = (entity as text) as text =>
    try
        Unitrends_MSP.Endpoints{[Schema=entity]}[Params]
    otherwise 
        let 
            message = Text.Format("Couldn't find entity: '#{0}'", {entity})
        in
            Diagnostics.Trace(TraceLevel.Error, message, () => error message, true);

Unitrends_MSP.GetAllowPagingForEntity = (entity as text) as text =>
    try
        Unitrends_MSP.Endpoints{[Schema=entity]}[AllowPaging]
    otherwise  
        let 
            message = Text.Format("Couldn't find entity: '#{0}'", {entity})
        in
            Diagnostics.Trace(TraceLevel.Error, message, () => error message, true);


//***********************************************************************************************//
//
// Common Library Functions
//
//
Extension.LoadFunction = (name as text) =>
    try
        let        
            binary = Extension.Contents(name),
            asText = Text.FromBinary(binary)
        in
            Expression.Evaluate(asText, #shared)
    otherwise
        error "Unable to load external resource: " & name;

Table.GenerateByPage = Extension.LoadFunction("Table.GenerateByPage.pqm");
Table.ToNavigationTable = Extension.LoadFunction("Table.ToNavigationTable.pqm");
Table.ChangeType = Extension.LoadFunction("Table.ChangeType.pqm");

Diagnostics = Extension.LoadFunction("Diagnostics.pqm");
Diagnostics.LogValue = Diagnostics[LogValue];
Diagnostics.LogFailure = Diagnostics[LogFailure];
Diagnostics.WrapHandlers = Diagnostics[WrapHandlers];
