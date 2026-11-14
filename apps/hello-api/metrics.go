package main

// Prometheus text exposition, standard library only: request count and latency
// per route and status, plus build info. Scraped at GET /metrics.

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

var buckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}

type series struct {
	count   uint64
	sum     float64
	buckets []uint64 // cumulative per bound, +Inf = count
}

type registry struct {
	mu       sync.Mutex
	requests map[[2]string]uint64 // {route, code}
	latency  map[string]*series   // route
}

var metrics = &registry{requests: map[[2]string]uint64{}, latency: map[string]*series{}}

func (m *registry) observe(route string, code int, d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[[2]string{route, fmt.Sprint(code)}]++
	s := m.latency[route]
	if s == nil {
		s = &series{buckets: make([]uint64, len(buckets))}
		m.latency[route] = s
	}
	sec := d.Seconds()
	s.count++
	s.sum += sec
	for i, b := range buckets {
		if sec <= b {
			s.buckets[i]++
		}
	}
}

func (m *registry) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var b strings.Builder
	fmt.Fprintf(&b, "# HELP hello_api_build_info Build version.\n# TYPE hello_api_build_info gauge\nhello_api_build_info{version=%q} 1\n", version)

	b.WriteString("# HELP http_requests_total Requests by route and status code.\n# TYPE http_requests_total counter\n")
	keys := make([][2]string, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i][0]+keys[i][1] < keys[j][0]+keys[j][1] })
	for _, k := range keys {
		fmt.Fprintf(&b, "http_requests_total{route=%q,code=%q} %d\n", k[0], k[1], m.requests[k])
	}

	b.WriteString("# HELP http_request_duration_seconds Request latency by route.\n# TYPE http_request_duration_seconds histogram\n")
	routes := make([]string, 0, len(m.latency))
	for r := range m.latency {
		routes = append(routes, r)
	}
	sort.Strings(routes)
	for _, r := range routes {
		s := m.latency[r]
		for i, bound := range buckets {
			fmt.Fprintf(&b, "http_request_duration_seconds_bucket{route=%q,le=%q} %d\n", r, fmt.Sprint(bound), s.buckets[i])
		}
		fmt.Fprintf(&b, "http_request_duration_seconds_bucket{route=%q,le=\"+Inf\"} %d\n", r, s.count)
		fmt.Fprintf(&b, "http_request_duration_seconds_sum{route=%q} %g\nhttp_request_duration_seconds_count{route=%q} %d\n", r, s.sum, r, s.count)
	}
	writeProtectMetrics(&b)
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(b.String()))
}
