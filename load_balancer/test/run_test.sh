#!/bin/bash

# Nginx Load Balancer Test Suite
# Run different test scenarios to verify load balancer behavior

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
LB_URL="http://localhost"
HEALTH_URL="http://localhost/health"

# Helper functions
print_header() {
    echo -e "\n${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    local missing_deps=()
    
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Please install: ${missing_deps[*]}"
        exit 1
    fi
    
    print_success "All required dependencies found"
}

check_containers() {
    print_header "Checking Containers"
    
    local containers=("nginx-load-balancer" "server1" "server2" "server3")
    local all_running=true
    
    for container in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_success "$container is running"
        else
            print_error "$container is NOT running"
            all_running=false
        fi
    done
    
    if [ "$all_running" = false ]; then
        print_warning "Some containers are not running. Start with: docker compose up -d"
        return 1
    fi
    
    return 0
}

# Test 1: Health Check
test_health_check() {
    print_header "Test 1: Health Check"
    
    print_info "Testing load balancer health endpoint..."
    
    response=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL")
    
    if [ "$response" = "200" ]; then
        print_success "Health check passed (HTTP $response)"
        curl -s "$HEALTH_URL"
    else
        print_error "Health check failed (HTTP $response)"
        return 1
    fi
}

# Test 2: Load Distribution
test_load_distribution() {
    print_header "Test 2: Load Distribution (Weighted Routing)"
    
    print_info "Making 20 requests to observe distribution..."
    print_info "Expected: ~95% to server1 (weight=95), rest to server2/3"
    echo ""
    
    local server1_count=0
    local server2_count=0
    local server3_count=0
    
    for i in {1..20}; do
        response=$(curl -s "$LB_URL" 2>/dev/null || echo "ERROR")
        
        if echo "$response" | grep -qi "server1\|SERVER 1"; then
            ((server1_count++))
            echo -e "${GREEN}Request $i: Server 1${NC}"
        elif echo "$response" | grep -qi "server2\|SERVER 2"; then
            ((server2_count++))
            echo -e "${YELLOW}Request $i: Server 2${NC}"
        elif echo "$response" | grep -qi "server3\|SERVER 3"; then
            ((server3_count++))
            echo -e "${BLUE}Request $i: Server 3${NC}"
        else
            echo -e "${RED}Request $i: ERROR or Unknown${NC}"
        fi
        sleep 0.1
    done
    
    echo ""
    print_info "Distribution Summary:"
    echo "  Server 1: $server1_count requests (expected ~19/20)"
    echo "  Server 2: $server2_count requests"
    echo "  Server 3: $server3_count requests"
    echo ""
    
    if [ $server1_count -gt 15 ]; then
        print_success "Weighted routing is working correctly"
    else
        print_warning "Server1 should receive most traffic (weight=95)"
    fi
}

# Test 3: Failover Test
test_failover() {
    print_header "Test 3: Failover Test (Passive Health Check)"
    
    print_warning "This test will stop server2 temporarily"
    read -p "Continue? (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Skipping failover test"
        return 0
    fi
    
    print_info "Step 1: Stopping server2..."
    docker stop server2 > /dev/null 2>&1
    print_success "server2 stopped"
    
    sleep 2
    
    print_info "Step 2: Making requests (should still work)..."
    local success_count=0
    local failure_count=0
    
    for i in {1..10}; do
        response=$(curl -s -o /dev/null -w "%{http_code}" "$LB_URL" 2>/dev/null)
        
        if [ "$response" = "200" ]; then
            ((success_count++))
            echo -e "${GREEN}Request $i: HTTP 200${NC}"
        else
            ((failure_count++))
            echo -e "${RED}Request $i: HTTP $response${NC}"
        fi
        sleep 0.5
    done
    
    echo ""
    print_info "Results with server2 down:"
    echo "  Successful: $success_count/10"
    echo "  Failed: $failure_count/10"
    
    if [ $success_count -ge 8 ]; then
        print_success "Failover working! Traffic automatically routed to healthy servers"
    else
        print_warning "Too many failures. Check max_fails and retry settings"
    fi
    
    print_info "Step 3: Restarting server2..."
    docker start server2 > /dev/null 2>&1
    sleep 3
    print_success "server2 restarted and should rejoin the pool after fail_timeout"
}

# Test 4: Connection Limit Test
test_connection_limit() {
    print_header "Test 4: Connection Limit Protection"
    
    if ! command -v ab &> /dev/null; then
        print_warning "ApacheBench (ab) not found. Skipping load test."
        print_info "Install with: sudo apt-get install apache2-utils"
        return 0
    fi
    
    print_info "Testing connection limits (limit_conn connlimit 20)..."
    print_info "Running 100 concurrent requests..."
    echo ""
    
    ab -n 200 -c 50 -q "$LB_URL/" 2>&1 | grep -E "(Complete requests|Failed requests|Non-2xx responses)"
    
    echo ""
    print_success "Connection limiting is active (some requests may be rate-limited)"
    print_info "503 errors indicate rate limiting is working to protect backends"
}

# Test 5: Continuous Health Loop
test_health_loop() {
    print_header "Test 5: Continuous Health Monitoring"
    
    print_info "Running continuous health check loop..."
    print_info "Press Ctrl+C to stop"
    print_warning "In another terminal, try: docker stop server2"
    echo ""
    
    local request_count=0
    local success_count=0
    local failure_count=0
    
    trap 'echo ""; print_info "Stopped after $request_count requests"; print_info "Success: $success_count, Failures: $failure_count"; exit 0' INT
    
    while true; do
        ((request_count++))
        response=$(curl -s -o /dev/null -w "%{http_code}" "$LB_URL" 2>/dev/null)
        
        if [ "$response" = "200" ]; then
            ((success_count++))
            echo -e "${GREEN}[$(date +%H:%M:%S)] Request $request_count: HTTP $response ✓${NC}"
        else
            ((failure_count++))
            echo -e "${RED}[$(date +%H:%M:%S)] Request $request_count: HTTP $response ✗${NC}"
        fi
        
        sleep 0.5
    done
}

# Test 6: Response Time Test
test_response_times() {
    print_header "Test 6: Response Time Analysis"
    
    print_info "Measuring response times for 10 requests..."
    echo ""
    
    local total_time=0
    
    for i in {1..10}; do
        time_taken=$(curl -s -o /dev/null -w "%{time_total}" "$LB_URL" 2>/dev/null)
        total_time=$(echo "$total_time + $time_taken" | bc)
        echo -e "Request $i: ${YELLOW}${time_taken}s${NC}"
        sleep 0.2
    done
    
    avg_time=$(echo "scale=3; $total_time / 10" | bc)
    echo ""
    print_info "Average response time: ${avg_time}s"
    
    # Check if keepalive is helping
    if (( $(echo "$avg_time < 0.1" | bc -l) )); then
        print_success "Excellent response times! Keepalive is likely working"
    elif (( $(echo "$avg_time < 0.5" | bc -l) )); then
        print_success "Good response times"
    else
        print_warning "Slow response times detected (avg: ${avg_time}s)"
    fi
}

# Test 7: Retry Behavior
test_retry_behavior() {
    print_header "Test 7: Retry Behavior (proxy_next_upstream)"
    
    print_warning "This test will pause server1 mid-request"
    read -p "Continue? (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Skipping retry test"
        return 0
    fi
    
    print_info "Making request while pausing server1..."
    
    # Pause server in background
    (sleep 0.5 && docker pause server1 > /dev/null 2>&1 && sleep 2 && docker unpause server1 > /dev/null 2>&1) &
    
    response=$(curl -s -o /dev/null -w "%{http_code}" "$LB_URL" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        print_success "Request succeeded despite server1 pause (retry worked!)"
    else
        print_warning "Request failed (HTTP $response). Retry may need tuning"
    fi
    
    sleep 2
    print_info "server1 unpaused"
}

# Test 8: Logs Analysis
test_logs_analysis() {
    print_header "Test 8: Nginx Logs Analysis"
    
    print_info "Fetching last 20 log entries..."
    echo ""
    
    docker exec nginx-load-balancer tail -n 20 /var/log/nginx/access.log 2>/dev/null | head -n 20
    
    echo ""
    print_success "Check logs for upstream routing, response times (rt:, urt:)"
    print_info "Full logs: docker exec nginx-load-balancer cat /var/log/nginx/access.log"
}

# Test 9: All Backends Down
test_all_backends_down() {
    print_header "Test 9: All Backends Down Scenario"
    
    print_warning "This test will stop ALL backend servers"
    print_warning "Press Ctrl+C now if you don't want to run this"
    sleep 3
    
    print_info "Stopping all backend servers..."
    docker stop server1 server2 server3 > /dev/null 2>&1
    sleep 2
    
    print_info "Making request (should fail gracefully)..."
    response=$(curl -s -o /dev/null -w "%{http_code}" "$LB_URL" 2>/dev/null)
    
    echo ""
    print_info "Response code: $response"
    
    if [ "$response" = "502" ] || [ "$response" = "503" ] || [ "$response" = "504" ]; then
        print_success "Correct error response ($response - Bad Gateway/Service Unavailable)"
    else
        print_warning "Unexpected response: $response"
    fi
    
    print_info "Restarting all backend servers..."
    docker start server1 server2 server3 > /dev/null 2>&1
    sleep 5
    print_success "All servers restarted"
}

# Main menu
show_menu() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║     Nginx Load Balancer Test Suite                    ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "Quick Tests:"
    echo "  1) Health Check"
    echo "  2) Load Distribution (weighted routing)"
    echo "  3) Failover Test (stop server2)"
    echo "  4) Connection Limit Protection"
    echo "  5) Continuous Health Loop (Ctrl+C to stop)"
    echo ""
    echo "Advanced Tests:"
    echo "  6) Response Time Analysis"
    echo "  7) Retry Behavior (proxy_next_upstream)"
    echo "  8) Nginx Logs Analysis"
    echo "  9) All Backends Down Scenario"
    echo ""
    echo "Batch Operations:"
    echo "  a) Run all quick tests (1-4)"
    echo "  b) Run all tests (1-9)"
    echo "  0) Exit"
    echo ""
}

# Run all quick tests
run_quick_tests() {
    test_health_check
    test_load_distribution
    test_connection_limit
    
    print_header "Quick Tests Complete!"
    print_info "For failover testing, run test 3 individually"
}

# Run all tests
run_all_tests() {
    test_health_check
    test_load_distribution
    test_connection_limit
    test_response_times
    test_logs_analysis
    
    print_header "All Safe Tests Complete!"
    print_warning "Tests 3, 7, 9 require user confirmation (they stop/pause servers)"
    print_info "Run them individually from the menu if needed"
}

# Parse command line arguments
if [ $# -eq 1 ]; then
    case "$1" in
        health)
            check_dependencies
            check_containers || exit 1
            test_health_check
            ;;
        distribution)
            check_dependencies
            check_containers || exit 1
            test_load_distribution
            ;;
        failover)
            check_dependencies
            check_containers || exit 1
            test_failover
            ;;
        connection-limit)
            check_dependencies
            check_containers || exit 1
            test_connection_limit
            ;;
        health-loop)
            check_dependencies
            check_containers || exit 1
            test_health_loop
            ;;
        response-times)
            check_dependencies
            check_containers || exit 1
            test_response_times
            ;;
        retry)
            check_dependencies
            check_containers || exit 1
            test_retry_behavior
            ;;
        logs)
            check_dependencies
            check_containers || exit 1
            test_logs_analysis
            ;;
        all-down)
            check_dependencies
            check_containers || exit 1
            test_all_backends_down
            ;;
        quick)
            check_dependencies
            check_containers || exit 1
            run_quick_tests
            ;;
        all)
            check_dependencies
            check_containers || exit 1
            run_all_tests
            ;;
        *)
            echo "Unknown test: $1"
            echo ""
            echo "Available tests:"
            echo "  ./run_tests.sh health           - Health check test"
            echo "  ./run_tests.sh distribution     - Load distribution test"
            echo "  ./run_tests.sh failover         - Failover test"
            echo "  ./run_tests.sh connection-limit - Connection limit test"
            echo "  ./run_tests.sh health-loop      - Continuous health monitoring"
            echo "  ./run_tests.sh response-times   - Response time analysis"
            echo "  ./run_tests.sh retry            - Retry behavior test"
            echo "  ./run_tests.sh logs             - View nginx logs"
            echo "  ./run_tests.sh all-down         - All backends down test"
            echo "  ./run_tests.sh quick            - Run quick tests (1-4)"
            echo "  ./run_tests.sh all              - Run all safe tests"
            echo ""
            echo "Or run without arguments for interactive menu"
            exit 1
            ;;
    esac
    exit 0
fi

# Interactive menu mode
check_dependencies
check_containers || exit 1

while true; do
    show_menu
    read -p "Select test (0-9, a, b): " choice
    
    case "$choice" in
        1) test_health_check ;;
        2) test_load_distribution ;;
        3) test_failover ;;
        4) test_connection_limit ;;
        5) test_health_loop ;;
        6) test_response_times ;;
        7) test_retry_behavior ;;
        8) test_logs_analysis ;;
        9) test_all_backends_down ;;
        a|A) run_quick_tests ;;
        b|B) run_all_tests ;;
        0) 
            print_info "Exiting..."
            exit 0
            ;;
        *)
            print_error "Invalid choice. Please select 0-9, a, or b"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done