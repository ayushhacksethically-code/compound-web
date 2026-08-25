import std/[asynchttpserver, asyncdispatch, tables, strutils, uri]

type
  RequestHandler* = proc(req: Request): Future[void] {.async, closure, gcsafe.}
  
  CompoundWebServer* = ref object
    port*: int
    routes*: Table[string, RequestHandler]

proc newServer*(port: int = 8080): CompoundWebServer =
  new(result)
  result.port = port
  result.routes = initTable[string, RequestHandler]()

proc addRoute*(server: CompoundWebServer, meth: string, path: string, handler: RequestHandler) =
  let key = meth.toUpperAscii() & ":" & path
  server.routes[key] = handler

proc sendText*(req: Request, content: string, status: HttpCode = Http200, contentType: string = "text/html; charset=utf-8") {.async.} =
  let headers = newHttpHeaders([("Content-Type", contentType)])
  await req.respond(status, content, headers)

proc sendJson*(req: Request, jsonString: string, status: HttpCode = Http200) {.async.} =
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  await req.respond(status, jsonString, headers)

proc start*(server: CompoundWebServer) =
  let httpSer = newAsyncHttpServer()
  echo "🚀 [compound-web] Server running on http://localhost:" & $server.port

  proc cb(req: Request) {.async, gcsafe.} =
    let key = ($req.reqMethod).toUpperAscii() & ":" & req.url.path
    if server.routes.hasKey(key):
      await server.routes[key](req)
    else:
      let notFoundHeaders = newHttpHeaders([("Content-Type", "text/html")])
      await req.respond(Http404, "<h1>404 Not Found</h1><p>Route " & req.url.path & " not registered on compound-web.</p>", notFoundHeaders)

  waitFor httpSer.serve(Port(server.port), cb)
