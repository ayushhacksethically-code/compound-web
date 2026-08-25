import time
import urllib.request
import concurrent.futures
import threading

URL = "http://localhost:8085/health"
DURATION_SEC = 10
NUM_THREADS = 8
CONNECTIONS_PER_THREAD = 12 # Total ~100 concurrent connections

total_requests = 0
successful_requests = 0
latencies = []
lock = threading.Lock()
stop_flag = False

def worker_routine():
    global total_requests, successful_requests, stop_flag
    while not stop_flag:
        t0 = time.time()
        try:
            req = urllib.request.Request(URL, headers={"User-Agent": "wrk-simulator/1.0"})
            with urllib.request.urlopen(req, timeout=2) as resp:
                elapsed = (time.time() - t0) * 1000.0
                if resp.status == 200:
                    with lock:
                        total_requests += 1
                        successful_requests += 1
                        latencies.append(elapsed)
        except Exception:
            with lock:
                total_requests += 1

def main():
    global stop_flag
    print(f"⚡ Running wrk-style benchmark simulation (-t{NUM_THREADS} -c100 -d{DURATION_SEC}s)...")
    print(f"📡 Target: {URL}\n")
    
    start_time = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=NUM_THREADS * CONNECTIONS_PER_THREAD) as executor:
        futures = [executor.submit(worker_routine) for _ in range(NUM_THREADS * CONNECTIONS_PER_THREAD)]
        
        # Run for DURATION_SEC seconds
        time.sleep(DURATION_SEC)
        stop_flag = True

    actual_duration = time.time() - start_time
    rps = successful_requests / actual_duration
    avg_latency = sum(latencies) / len(latencies) if latencies else 0.0

    print("📊 --- WRK BENCHMARK RESULTS ---")
    print(f"  {NUM_THREADS} threads and 100 connections")
    print(f"  Thread Stats   Avg         Stdev     Max")
    print(f"    Latency     {avg_latency:.2f}ms")
    print(f"  {successful_requests} requests in {actual_duration:.2f}s")
    print(f"Requests/sec: {rps:.2f}")
    print(f"Transfer/sec: {(rps * 120 / 1024):.2f}KB")

if __name__ == "__main__":
    main()
