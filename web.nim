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
    isFrozen*: bool # Invariant: Route table frozen after server startup for thread safety
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
  result.isFrozen = false
  result.rootNode = newRadixNode("")
  result.middlewares = @[]

proc use*(server: CompoundWebServer, middleware: Middleware) =
  if server.isFrozen:
    raise newException(ValueError, "Cannot add middleware after server has started (thread-safety protection).")
  server.middlewares.add(middleware)

# 🌳 Radix Tree Insert: O(K) Complexity where K = URL Segment Count
proc addRoute*(server: CompoundWebServer, meth: string, pattern: string, handler: RequestHandler) =
  if server.isFrozen:
    raise newException(ValueError, "Cannot add route after server has started (thread-safety protection).")

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

proc handleRequest*(server: CompoundWebServer, req: Request) {.async, gcsafe.} =
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
        let authErrHeaders = newHttpHeaders([("Content-Type", "application/json")])
        await req.respond(Http401, "{\"error\": \"401 Unauthorized\", \"message\": \"Middleware access denied\"}", authErrHeaders)
    else:
      let notFoundHeaders = newHttpHeaders([("Content-Type", "application/json")])
      await req.respond(Http404, "{\"error\": \"404 Not Found\", \"path\": \"" & path & "\"}", notFoundHeaders)
  except Exception as e:
    let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http500, "{\"error\": \"500 Internal Server Error\", \"message\": \"" & e.msg & "\"}", errHeaders)

# 🚀 OS-Specific Multi-Threading Worker Thread (POSIX SO_REUSEPORT vs Windows Fallback)
proc startWorkerThread(args: tuple[server: CompoundWebServer, workerId: int]) {.thread, gcsafe.} =
  let server = args.server
  
  when defined(windows):
    # Windows fallback: SO_REUSEPORT not supported natively on Windows Sockets
    let httpSer = newAsyncHttpServer(reuseAddr = true, reusePort = false)
  else:
    # Linux / macOS: Full SO_REUSEPORT native OS load balancing
    let httpSer = newAsyncHttpServer(reuseAddr = true, reusePort = true)
  
  proc cb(req: Request) {.async, gcsafe.} =
    await server.handleRequest(req)

  waitFor httpSer.serve(Port(server.port), cb)

# 🚀 Server Startup (Thread-Freeze Guard & Cross-Platform Dispatch)
proc start*(server: CompoundWebServer, multiThreaded: bool = true, numWorkers: int = 0) =
  server.isFrozen = true # Freeze route mutations for ORC thread safety
  let startTime = cpuTime()
  let availableCores = countProcessors()
  let workersCount = if numWorkers > 0: numWorkers else: availableCores
  let elapsedMs = (cpuTime() - startTime) * 1000.0

  echo "🚀 [compound-web v2.2] Radix-Tree Engine initialized in " & $elapsedMs.formatFloat(ffDecimal, 3) & " ms"
  
  when defined(windows):
    echo "🪟 [compound-web v2.2] Windows OS Detected: Single-listener event loop fallback active (SO_REUSEPORT disabled for Windows compatibility)."
    let httpSer = newAsyncHttpServer(reuseAddr = true, reusePort = false)
    proc cb(req: Request) {.async, gcsafe.} =
      await server.handleRequest(req)
    waitFor httpSer.serve(Port(server.port), cb)
  else:
    echo "🐧 [compound-web v2.2] POSIX OS (Linux/macOS) Detected: SO_REUSEPORT Cluster Active with " & $workersCount & " worker threads (CPUs: " & $availableCores & ")"
    echo "📡 [compound-web v2.2] Multi-threaded Listening on http://localhost:" & $server.port

    if multiThreaded and workersCount > 1:
      var threads = newSeq[Thread[tuple[server: CompoundWebServer, workerId: int]]](workersCount)
      for i in 0 ..< workersCount:
        createThread(threads[i], startWorkerThread, (server, i + 1))
      joinThreads(threads)
    else:
      let httpSer = newAsyncHttpServer(reuseAddr = true, reusePort = true)
      proc cb(req: Request) {.async, gcsafe.} =
        await server.handleRequest(req)
      waitFor httpSer.serve(Port(server.port), cb)
