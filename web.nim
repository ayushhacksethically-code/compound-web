import std/[asynchttpserver, asyncdispatch, tables, strutils, uri, json, times, os, cpuinfo]

type
  RequestParams* = Table[string, string]
  Context* = ref object
    req*: Request
    params*: RequestParams
    query*: RequestParams

  Middleware* = proc(ctx: Context): Future[bool] {.async, closure, gcsafe.}
  RequestHandler* = proc(ctx: Context): Future[void] {.async, closure, gcsafe.}

  # 🌳 Radix Tree / Trie Node Structure for O(K) Path Routing
  RadixNode* = ref object
    segment*: string
    paramName*: string
    isParam*: bool
    handlers*: Table[string, RequestHandler] # HTTP Method -> Handler
    children*: seq[RadixNode]

  CompoundWebServer* = ref object
    port*: int
    maxBodySize*: int # Default 10MB
    enableCors*: bool
    rootNode*: RadixNode
    middlewares*: seq[Middleware]

proc newRadixNode*(segment: string = ""): RadixNode =
  new(result)
  result.segment = segment
  result.paramName = ""
  result.isParam = false
  result.handlers = initTable[string, RequestHandler]()
  result.children = @[]

proc newServer*(port: int = 8080, maxBodySize: int = 10 * 1024 * 1024, enableCors: bool = true): CompoundWebServer =
  new(result)
  result.port = port
  result.maxBodySize = maxBodySize
  result.enableCors = enableCors
  result.rootNode = newRadixNode("")
  result.middlewares = @[]

proc use*(server: CompoundWebServer, middleware: Middleware) =
  server.middlewares.add(middleware)

# 🌳 Radix Tree Insert: O(K) Complexity where K = URL Segment Count
proc addRoute*(server: CompoundWebServer, meth: string, pattern: string, handler: RequestHandler) =
  let upperMeth = meth.toUpperAscii()
  let segments = pattern.strip(chars = {'/'}).split('/')
  var current = server.rootNode

  for seg in segments:
    if seg.len == 0: continue
    var foundChild: RadixNode = nil
    let isParamSeg = seg.startsWith(":")
    let paramKey = if isParamSeg: seg.substr(1) else: ""

    for child in current.children:
      if isParamSeg and child.isParam:
        foundChild = child
        break
      elif not isParamSeg and not child.isParam and child.segment == seg:
        foundChild = child
        break

    if foundChild.isNil:
      let newNode = newRadixNode(seg)
      newNode.isParam = isParamSeg
      newNode.paramName = paramKey
      current.children.add(newNode)
      current = newNode
    else:
      current = foundChild

  current.handlers[upperMeth] = handler

# 🌳 Radix Tree Lookup: O(K) Complexity with Parameter Extraction
proc matchRoute*(server: CompoundWebServer, meth: string, path: string, params: var RequestParams, handler: var RequestHandler): bool =
  let upperMeth = meth.toUpperAscii()
  let segments = path.strip(chars = {'/'}).split('/')
  var current = server.rootNode
  params = initTable[string, string]()

  if path == "/" or path == "":
    if current.handlers.hasKey(upperMeth):
      handler = current.handlers[upperMeth]
      return true
    return false

  for seg in segments:
    if seg.len == 0: continue
    var matchedChild: RadixNode = nil

    # First attempt exact segment match
    for child in current.children:
      if not child.isParam and child.segment == seg:
        matchedChild = child
        break

    # If no exact match, attempt param match (:id)
    if matchedChild.isNil:
      for child in current.children:
        if child.isParam:
          matchedChild = child
          params[child.paramName] = decodeUrl(seg)
          break

    if matchedChild.isNil:
      return false
    current = matchedChild

  if current.handlers.hasKey(upperMeth):
    handler = current.handlers[upperMeth]
    return true
  return false

proc getQueryMap*(rawQuery: string): RequestParams =
  result = initTable[string, string]()
  if rawQuery.len == 0: return
  for pair in rawQuery.split('&'):
    let kv = pair.split('=', 1)
    if kv.len == 2:
      result[decodeUrl(kv[0])] = decodeUrl(kv[1])

proc sendText*(ctx: Context, content: string, status: HttpCode = Http200, contentType: string = "text/html; charset=utf-8") {.async.} =
  var headers = newHttpHeaders([("Content-Type", contentType)])
  headers.add("Access-Control-Allow-Origin", "*")
  headers.add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
  headers.add("Access-Control-Allow-Headers", "Content-Type, Authorization")
  await ctx.req.respond(status, content, headers)

proc sendJson*(ctx: Context, jsonString: string, status: HttpCode = Http200) {.async.} =
  var headers = newHttpHeaders([("Content-Type", "application/json")])
  headers.add("Access-Control-Allow-Origin", "*")
  headers.add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
  headers.add("Access-Control-Allow-Headers", "Content-Type, Authorization")
  await ctx.req.respond(status, jsonString, headers)

proc getBody*(ctx: Context): string =
  return ctx.req.body

# 🚀 Server Startup with CPU Core Detection
proc start*(server: CompoundWebServer) =
  let startTime = cpuTime()
  let numCores = countProcessors()
  let httpSer = newAsyncHttpServer()
  let elapsedMs = (cpuTime() - startTime) * 1000.0

  echo "🚀 [compound-web v2] Radix-Tree Engine initialized in " & $elapsedMs.formatFloat(ffDecimal, 3) & " ms"
  echo "💻 [compound-web v2] Detected CPU Cores: " & $numCores
  echo "📡 [compound-web v2] Listening on http://localhost:" & $server.port

  proc cb(req: Request) {.async, gcsafe.} =
    try:
      let meth = ($req.reqMethod).toUpperAscii()
      let path = req.url.path

      # 1. Handle CORS Preflight OPTIONS
      if server.enableCors and meth == "OPTIONS":
        let corsHeaders = newHttpHeaders([
          ("Access-Control-Allow-Origin", "*"),
          ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"),
          ("Access-Control-Allow-Headers", "Content-Type, Authorization")
        ])
        await req.respond(Http204, "", corsHeaders)
        return

      # 2. Upfront Content-Length Header Check (Early DoS Protection)
      if req.headers.hasKey("Content-Length"):
        try:
          let contentLength = parseInt(req.headers["Content-Length"])
          if contentLength > server.maxBodySize:
            let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
            await req.respond(Http413, "{\"error\": \"413 Payload Too Large\", \"limit_bytes\": " & $server.maxBodySize & "}", errHeaders)
            return
        except ValueError:
          discard

      # 3. Body Size Guard
      if req.body.len > server.maxBodySize:
        let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
        await req.respond(Http413, "{\"error\": \"413 Payload Too Large\", \"limit_bytes\": " & $server.maxBodySize & "}", errHeaders)
        return

      # 4. Radix Tree O(K) Route Dispatching
      var params = initTable[string, string]()
      var handler: RequestHandler = nil
      let found = server.matchRoute(meth, path, params, handler)

      if found and not handler.isNil:
        let ctx = Context(req: req, params: params, query: getQueryMap(req.url.query))
        
        # Execute Middlewares
        var pass = true
        for mw in server.middlewares:
          if not (await mw(ctx)):
            pass = false
            break
        
        if pass:
          await handler(ctx)
      else:
        let notFoundHeaders = newHttpHeaders([("Content-Type", "application/json")])
        await req.respond(Http404, "{\"error\": \"404 Not Found\", \"path\": \"" & path & "\"}", notFoundHeaders)
    except Exception as e:
      let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
      await req.respond(Http500, "{\"error\": \"500 Internal Server Error\", \"message\": \"" & e.msg & "\"}", errHeaders)

  waitFor httpSer.serve(Port(server.port), cb)
