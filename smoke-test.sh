#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="${IMAGE_NAME:-tabby-cpu:test}"
CONTAINER_NAME="tabby-smoke-test-$$"
TEST_PORT="${TEST_PORT:-8080}"
STARTUP_TIMEOUT=300  # seconds (increased for model download)
HEALTH_CHECK_INTERVAL=5  # seconds
SKIP_MODEL_TESTS="${SKIP_MODEL_TESTS:-false}"  # Set to true to skip tests requiring model download

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

# Test 1: Verify image exists
test_image_exists() {
    log_test "Verifying Docker image exists: $IMAGE_NAME"
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        log_info "Image exists"
        return 0
    else
        log_error "Image not found: $IMAGE_NAME"
        return 1
    fi
}

# Test 2: Start container
test_container_starts() {
    if [ "$SKIP_MODEL_TESTS" = "true" ]; then
        log_test "Skipping container start test (no model configured)"
        log_info "Container start test skipped"
        return 0
    fi

    log_test "Starting container: $CONTAINER_NAME"

    # Start with a small model
    if docker run -d \
        --name "$CONTAINER_NAME" \
        -p "${TEST_PORT}:8080" \
        --health-cmd "curl -f http://localhost:8080/v1/health || exit 1" \
        --health-interval=5s \
        --health-timeout=3s \
        --health-retries=3 \
        "$IMAGE_NAME" \
        serve --device cpu --model TabbyML/StarCoder-1B &>/dev/null; then
        log_info "Container started successfully"
        return 0
    else
        log_error "Failed to start container"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -20
        return 1
    fi
}

# Test 3: Wait for container to be healthy
test_container_healthy() {
    if [ "$SKIP_MODEL_TESTS" = "true" ]; then
        log_test "Skipping container health test (no model configured)"
        log_info "Container health test skipped"
        return 0
    fi

    log_test "Waiting for container to become healthy (timeout: ${STARTUP_TIMEOUT}s)"

    local elapsed=0
    while [ $elapsed -lt $STARTUP_TIMEOUT ]; do
        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

        if [ "$health_status" = "healthy" ]; then
            log_info "Container is healthy (took ${elapsed}s)"
            return 0
        elif [ "$health_status" = "unhealthy" ]; then
            log_error "Container became unhealthy"
            docker logs "$CONTAINER_NAME" 2>&1 | tail -20
            return 1
        fi

        echo -n "."
        sleep $HEALTH_CHECK_INTERVAL
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    done

    echo ""
    log_error "Container did not become healthy within ${STARTUP_TIMEOUT}s"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -30
    return 1
}

# Test 4: Verify health endpoint
test_health_endpoint() {
    log_test "Testing health endpoint"

    # Skip health endpoint test when running without model
    if [ "$SKIP_MODEL_TESTS" = "true" ]; then
        log_info "Skipping health endpoint test (no model loaded)"
        return 0
    fi

    local response
    if response=$(curl -s -f "http://localhost:${TEST_PORT}/v1/health" 2>&1); then
        log_info "Health endpoint responded: $response"
        return 0
    else
        log_error "Health endpoint failed"
        return 1
    fi
}

# Test 5: Verify API is responding
test_api_endpoints() {
    if [ "$SKIP_MODEL_TESTS" = "true" ]; then
        log_test "Skipping API endpoint test (no model configured)"
        log_info "API endpoint test skipped"
        return 0
    fi

    log_test "Testing API endpoints (with model)"

    # Test /v1/completions endpoint structure (should accept POST)
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:${TEST_PORT}/v1/completions" \
        -H "Content-Type: application/json" \
        -d '{"language":"python","segments":{"prefix":"def hello","suffix":""}}' 2>&1)

    # We expect either 200 (success) or 400/422 (validation error) - both indicate the API is responding
    if [ "$status_code" -ge 200 ] && [ "$status_code" -lt 500 ]; then
        log_info "API endpoint responding (status: $status_code)"
        return 0
    else
        log_error "API endpoint failed (status: $status_code)"
        return 1
    fi
}

# Test 6: Verify binaries are present
test_binaries_present() {
    log_test "Verifying required binaries are present in image"

    # Run a temporary container to check files
    if docker run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "test -f /opt/tabby/bin/tabby" 2>/dev/null; then
        log_info "tabby binary found"
    else
        log_error "tabby binary not found"
        return 1
    fi

    if docker run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "test -f /opt/tabby/bin/llama-server" 2>/dev/null; then
        log_info "llama-server binary found"
    else
        log_error "llama-server binary not found"
        return 1
    fi

    return 0
}

# Test 7: Verify tabby version
test_tabby_version() {
    log_test "Checking Tabby version"

    local version
    if version=$(docker run --rm "$IMAGE_NAME" --version 2>&1); then
        log_info "Tabby version: $version"
        return 0
    else
        log_error "Failed to get Tabby version"
        return 1
    fi
}

# Test 8: Check container logs for errors
test_no_critical_errors() {
    if [ "$SKIP_MODEL_TESTS" = "true" ]; then
        log_test "Skipping container log check (no container running)"
        log_info "Container log check skipped"
        return 0
    fi

    log_test "Checking container logs for critical errors"

    local logs
    logs=$(docker logs "$CONTAINER_NAME" 2>&1)

    if echo "$logs" | grep -iE "(panic|fatal|error.*failed to start)" &>/dev/null; then
        log_error "Found critical errors in logs:"
        echo "$logs" | grep -iE "(panic|fatal|error.*failed to start)"
        return 1
    else
        log_info "No critical errors found in logs"
        return 0
    fi
}

# Main test execution
main() {
    echo "========================================="
    echo "  Tabby Docker Image Smoke Tests"
    echo "========================================="
    echo "Image: $IMAGE_NAME"
    echo "Container: $CONTAINER_NAME"
    echo "Port: $TEST_PORT"
    echo "Skip Model Tests: $SKIP_MODEL_TESTS"
    echo "Startup Timeout: ${STARTUP_TIMEOUT}s"
    echo "========================================="
    echo ""

    local failed_tests=0
    local total_tests=0

    # Run all tests
    for test_func in \
        test_image_exists \
        test_container_starts \
        test_binaries_present \
        test_tabby_version \
        test_container_healthy \
        test_health_endpoint \
        test_api_endpoints \
        test_no_critical_errors; do

        total_tests=$((total_tests + 1))
        echo ""
        if ! $test_func; then
            failed_tests=$((failed_tests + 1))
            log_error "Test failed: $test_func"
        fi
    done

    echo ""
    echo "========================================="
    if [ $failed_tests -eq 0 ]; then
        log_info "All $total_tests smoke tests passed! ✓"
        echo "========================================="
        return 0
    else
        log_error "$failed_tests/$total_tests tests failed ✗"
        echo "========================================="
        return 1
    fi
}

main "$@"
