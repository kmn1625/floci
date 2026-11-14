package main

// Overload protection and the optional TLS and admin listeners. Every part is off unless
// configured, so one image runs both sides of the cascading-overload drill
// (vms/drills/outage/README.md):
//
//	TLS_PORT        serve HTTPS on this port too, with TLS_CERT_FILE / TLS_KEY_FILE
//	MAX_HANDSHAKES  TLS connections accepted but not yet serving a request. A new connection
//	                over the limit is reset at once, before any crypto work. 0 = no limit.
//	MAX_INFLIGHT    requests in progress on the public listeners. Over the limit: 503 with
//	                Retry-After, before any other work. Probes and /metrics are exempt. 0 = no limit.
//	ADMIN_PORT      plain-HTTP listener for /healthz, /readyz and /metrics only, outside both
//	                limits, so kubelet probes are not queued behind client handshakes.
//
// Why: an overloaded server that keeps accepting work finishes none of it. Clients time out,
// retry, and add more work, and health checks queued behind that work fail too. Rejecting the
// excess cheaply keeps the rest fast.

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

var (
	handshaking   atomic.Int64 // accepted TLS connections that have not reached a request yet
	inflight      atomic.Int64
	shedHandshake atomic.Uint64
	shedInflight  atomic.Uint64
	pendingTLS    sync.Map // *tls.Conn -> struct{}: counted in handshaking
)

func envInt(k string) int64 {
	n, err := strconv.ParseInt(getenv(k, "0"), 10, 64)
	if err != nil || n < 0 {
		logger.Error("bad setting, using 0 (no limit)", "env", k, "value", getenv(k, ""))
		return 0
	}
	return n
}

func isProbeOrMetrics(path string) bool {
	return path == "/healthz" || path == "/readyz" || path == "/metrics"
}

// limitInflight sheds requests over max with a 503 before they reach the handler.
func limitInflight(max int64, next http.Handler) http.Handler {
	if max == 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isProbeOrMetrics(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		if inflight.Add(1) > max {
			inflight.Add(-1)
			shedInflight.Add(1)
			w.Header().Set("Retry-After", "1")
			http.Error(w, "overloaded", http.StatusServiceUnavailable)
			return
		}
		defer inflight.Add(-1)
		next.ServeHTTP(w, r)
	})
}

// tlsListener does the TLS wrapping itself (instead of ServeTLS) so it can refuse a
// connection before the handshake. net/http runs the handshake for any *tls.Conn it is given.
type tlsListener struct {
	net.Listener
	cfg *tls.Config
	max int64
}

func (l *tlsListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if l.max > 0 && handshaking.Load() >= l.max {
			shedHandshake.Add(1)
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetLinger(0) // RST: the client fails in a millisecond, not at its timeout
			}
			_ = c.Close()
			continue
		}
		handshaking.Add(1)
		tc := tls.Server(c, l.cfg)
		pendingTLS.Store(tc, struct{}{})
		return tc, nil
	}
}

// trackHandshake is the TLS server's ConnState hook: a connection leaves the handshake count
// when it first reads a request, or closes (a failed or abandoned handshake).
func trackHandshake(c net.Conn, s http.ConnState) {
	if s == http.StateNew {
		return
	}
	if _, ok := pendingTLS.LoadAndDelete(c); ok {
		handshaking.Add(-1)
	}
}

func newTLSConfig(certFile, keyFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load TLS key pair: %w", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	}, nil
}

// writeProtectMetrics appends the protection counters to /metrics.
func writeProtectMetrics(b *strings.Builder) {
	fmt.Fprintf(b, "# HELP hello_api_shed_total Work refused by overload protection.\n# TYPE hello_api_shed_total counter\n")
	fmt.Fprintf(b, "hello_api_shed_total{reason=\"handshake\"} %d\nhello_api_shed_total{reason=\"inflight\"} %d\n",
		shedHandshake.Load(), shedInflight.Load())
	fmt.Fprintf(b, "# HELP hello_api_tls_handshaking TLS connections accepted and not yet serving a request.\n# TYPE hello_api_tls_handshaking gauge\nhello_api_tls_handshaking %d\n", handshaking.Load())
	fmt.Fprintf(b, "# HELP hello_api_inflight Requests in progress (probes and /metrics excluded when limited).\n# TYPE hello_api_inflight gauge\nhello_api_inflight %d\n", inflight.Load())
}
