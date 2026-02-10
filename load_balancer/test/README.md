# Load Balancer Failure & Stress Tests

This folder contains experiments that intentionally break the system to observe how a real L7 load balancer behaves under failure and stress.

⚠ Always watch two terminals.

---

## Terminal 1 — Logs

```bash
docker logs -f nginx-load-balancer
```

## Terminal 2 — Tests

Run commands in this terminal.

---

# Test 1 — Normal Load Distribution

**Goal:** Verify weighted + least connection balancing

```bash
for i in {1..15}; do curl -s http://localhost | grep SERVER; done
```

### Expected

Requests go mostly to **server1** because of `weight=95`, but not exclusively.

Example:

```
SERVER 1
SERVER 1
SERVER 2
SERVER 1
SERVER 3
SERVER 1
```

### Why

`least_conn` avoids busy servers even if weight prefers server1.

---

# Test 2 — Server Crash Detection (Passive Health Check)

**Goal:** Prove failure detection using `max_fails` and `fail_timeout`

Stop backend:

```bash
docker stop server2
```

Send traffic:

```bash
for i in {1..20}; do curl -s http://localhost | grep SERVER; done
```

### Expected

No responses from **SERVER 2** after a few failures.

Logs will show:

```
upstream server temporarily disabled
```

### Why

```
max_fails=2 fail_timeout=10s
```

After 10 seconds nginx will try the server again automatically.

---

# Test 3 — Slow Server Handling

**Goal:** Demonstrate timeout + retry behavior

Enter server3:

```bash
docker exec -it server3 sh
apk add busybox-extras
```

Replace response with a slow one:

```bash
while true; do
  printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nSLOW\n" | nc -l -p 80 -q 5
done
```

Now test latency:

```bash
for i in {1..10}; do time curl -s http://localhost > /dev/null; done
```

### Expected

Requests still return quickly.

### Why

```
proxy_read_timeout 10s
proxy_next_upstream_timeout 6s
```

Nginx abandons the slow upstream and retries a healthy one.

Without retry → user would wait for slow server.

---

# Test 4 — Mid‑Request Failure Recovery

**Goal:** Verify retry protection

```bash
docker pause server1
curl http://localhost
docker unpause server1
```

### Expected

User still receives response.

### Why

```
proxy_next_upstream error timeout http_500 http_502 http_503 http_504;
proxy_next_upstream_tries 3;
```

Nginx retries another backend automatically.

---

# Test 5 — Overload Protection

**Goal:** Prevent cascade failure

```bash
ab -n 5000 -c 200 http://localhost/
```

### Expected

Some `503` responses but system remains responsive.

### Why

```
limit_conn connlimit 20;
```

Load balancer protects backend instead of letting it crash.

---

# Test 6 — Recovery (Self‑Healing)

**Goal:** Confirm automatic rejoin

```bash
docker stop server2
sleep 10
docker start server2
for i in {1..30}; do curl -s http://localhost | grep SERVER; done
```

### Expected

Server2 gradually receives traffic again.

### Why

After `fail_timeout` expires nginx retries the upstream.

---

# What This Load Balancer Handles

• dead servers
• slow servers
• retries
• overload protection
• connection reuse
• weighted balancing
• automatic recovery

This represents the minimum be
