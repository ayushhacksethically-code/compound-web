import web, std/[asynchttpserver, asyncdispatch, json, times, tables, strutils]

let app = newServer(port = 8085, maxBodySize = 1 * 1024 * 1024, enableCors = true)
let serverStartTime = cpuTime()

# Test 1: Basic Routes & Health
app.addRoute("GET", "/", proc(ctx: Context): Future[void] {.async.} =
  await ctx.sendText("<h1>Welcome to Compound Web Server</h1>")
)

app.addRoute("GET", "/health", proc(ctx: Context): Future[void] {.async.} =
  let uptime = (cpuTime() - serverStartTime) * 1000.0
  let res = %*{"status": "healthy", "uptime_ms": uptime}
  await ctx.sendJson($res)
)

# Test 2 & Edge Cases: Malformed JSON, Body Echo & OOM Check
app.addRoute("POST", "/api/echo", proc(ctx: Context): Future[void] {.async.} =
  let bodyStr = ctx.getBody()
  try:
    let node = parseJson(bodyStr)
    let name = node.getOrDefault("name").getStr("Anonymous")
    let responseJson = %*{"greeting": "Namaste " & name, "original_body": node}
    await ctx.sendJson($responseJson)
  except JsonParsingError as e:
    await ctx.sendJson($ %*{"error": "400 Bad Request", "reason": "Malformed JSON payload", "details": e.msg}, Http400)
  except Exception as e:
    await ctx.sendJson($ %*{"error": "500 Internal Error", "details": e.msg}, Http500)
)

# Test Middleware Rejection (401 Unauthorized)
app.addRoute("GET", "/admin/dashboard", proc(ctx: Context): Future[void] {.async.} =
  await ctx.sendJson("{\"secret\": \"admin_data\"}")
)

# Protect /admin routes with authentication middleware
app.use(proc(ctx: Context): Future[bool] {.async.} =
  if ctx.req.url.path.startsWith("/admin"):
    let authHeader = ctx.req.headers.getOrDefault("Authorization")
    if authHeader != "Bearer secret_token":
      return false # Reject access -> 401 Unauthorized
  return true
)

# Test 2 Edge Case: Unicode & URL Params
app.addRoute("GET", "/users/:id", proc(ctx: Context): Future[void] {.async.} =
  let userId = ctx.params.getOrDefault("id", "0")
  let role = ctx.query.getOrDefault("role", "guest")
  let responseJson = %*{"user_id": userId, "role": role, "timestamp": epochTime()}
  await ctx.sendJson($responseJson)
)

# Test 3: High Throughput Benchmark Endpoint
app.addRoute("GET", "/benchmark", proc(ctx: Context): Future[void] {.async.} =
  await ctx.sendJson("{\"status\":\"ok\"}")
)

echo "Starting Enhanced Multi-Core Compound Web Server on port 8085..."
app.start(multiThreaded = true)
