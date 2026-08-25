import std/[asynchttpserver, asyncdispatch, tables, strutils, uri, json, times, os]

type
  RequestParams* = Table[string, string]
  Context* = ref object
    req*: Request
    params*: RequestParams
    query*: RequestParams

  Middleware* = proc(ctx: Context): Future[bool] {.async, closure, gcsafe.}
  RequestHandler* = proc(ctx: Context): Future[void] {.async, closure, gcsafe.}

  RouteEntry* = object
    meth*: string
    pattern*: string
    paramKeys*: seq[string]
    handler*: RequestHandler

  CompoundWebServer* = ref object
    port*: int
    maxBodySize*: int # Default 10MB
    enableCors*: bool
    middlewares*: seq[Middleware]
    routes*: seq[RouteEntry]

proc newServer*(port: int = 8080, maxBodySize: int = 10 * 1024 * 1024, enableCors: bool = true): CompoundWebServer =
  new(result)
  result.port = port
  result.maxBodySize = maxBodySize
  result.enableCors = enableCors
  result.middlewares = @[]
  result.routes = @[]

proc use*(server: CompoundWebServer, middleware: Middleware) =
  server.middlewares.add(middleware)

proc parsePattern(pattern: string, paramKeys: var seq[string]): string =
  let parts = pattern.split('/')
  var resParts: seq[string] = @[]
  for part in parts:
    if part.startsWith(":"):
      paramKeys.add(part.substr(1))
      resParts.add("([^/]+)")
    else:
      resParts.add(part)
  result = resParts.join("/")

proc addRoute*(server: CompoundWebServer, meth: string, pattern: string, handler: RequestHandler) =
  var keys: seq[string] = @[]
  discard parsePattern(pattern, keys)
  server.routes.add(RouteEntry(meth: meth.toUpperAscii(), pattern: pattern, paramKeys: keys, handler: handler))

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

proc matchRoute(route: RouteEntry, meth: string, path: string, params: var RequestParams): bool =
  if route.meth != meth: return false
  
  let routeParts = route.pattern.split('/')
  let pathParts = path.split('/')
  
  if routeParts.len != pathParts.len: return false
  
  params = initTable[string, string]()
  for i in 0 ..< routeParts.len:
    if routeParts[i].startsWith(":"):
      let key = routeParts[i].substr(1)
      params[key] = decodeUrl(pathParts[i])
    elif routeParts[i] != pathParts[i]:
      return false
  return true

proc start*(server: CompoundWebServer) =
  let startTime = cpuTime()
  let httpSer = newAsyncHttpServer()
  let elapsedMs = (cpuTime() - startTime) * 1000.0
  echo "🚀 [compound-web] Server initialized in " & $elapsedMs.formatFloat(ffDecimal, 3) & " ms"
  echo "📡 [compound-web] Listening on http://localhost:" & $server.port

  proc cb(req: Request) {.async, gcsafe.} =
    try:
      let meth = ($req.reqMethod).toUpperAscii()
      let path = req.url.path

      # Handle CORS Preflight OPTIONS
      if server.enableCors and meth == "OPTIONS":
        let corsHeaders = newHttpHeaders([
          ("Access-Control-Allow-Origin", "*"),
          ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"),
          ("Access-Control-Allow-Headers", "Content-Type, Authorization")
        ])
        await req.respond(Http204, "", corsHeaders)
        return

      # Body Size Guard (413 Payload Too Large)
      if req.body.len > server.maxBodySize:
        let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
        await req.respond(Http413, "{\"error\": \"413 Payload Too Large\", \"limit_bytes\": " & $server.maxBodySize & "}", errHeaders)
        return

      var matched = false
      for route in server.routes:
        var params = initTable[string, string]()
        if matchRoute(route, meth, path, params):
          let ctx = Context(req: req, params: params, query: getQueryMap(req.url.query))
          
          # Execute Middlewares
          var pass = true
          for mw in server.middlewares:
            if not (await mw(ctx)):
              pass = false
              break
          
          if pass:
            await route.handler(ctx)
          matched = true
          break

      if not matched:
        let notFoundHeaders = newHttpHeaders([("Content-Type", "application/json")])
        await req.respond(Http404, "{\"error\": \"404 Not Found\", \"path\": \"" & path & "\"}", notFoundHeaders)
    except Exception as e:
      let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
      await req.respond(Http500, "{\"error\": \"500 Internal Server Error\", \"message\": \"" & e.msg & "\"}", errHeaders)

  waitFor httpSer.serve(Port(server.port), cb)
