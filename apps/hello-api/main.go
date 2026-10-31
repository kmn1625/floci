// hello-api: the lab's sample workload.
//
//	GET /         {"app":"hello-api","version":"...","host":"..."}
//	GET /healthz  liveness
//	GET /readyz   readiness (503 while shutting down)
//	GET /metrics  Prometheus metrics (metrics.go)
//
// Traces go to OTLP when OTEL_EXPORTER_OTLP_ENDPOINT is set; access logs are
// JSON with trace_id (telemetry.go).
//
// `hello-api -healthcheck` probes /healthz and exits 0/1 — the image's
// HEALTHCHECK (distroless has no shell or curl).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev" // set with -ldflags "-X main.version=..."

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe /healthz on this container and exit")
	flag.Parse()
	addr := ":" + getenv("PORT", "8080")
	if *healthcheck {
		client := http.Client{Timeout: 2 * time.Second}
		resp, err := client.Get("http://127.0.0.1" + addr + "/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	var shuttingDown atomic.Bool
	host, _ := os.Hostname()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"app": "hello-api", "version": version, "host": host,
			"env": getenv("APP_ENV", "dev"),
		})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if shuttingDown.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.Handle("GET /metrics", metrics)

	shutdownTracing, err := setupTracing(context.Background())
	if err != nil {
		logger.Error("tracing disabled", "error", err.Error())
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           instrument(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("listening", "version", version, "addr", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server", "error", err.Error())
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	shuttingDown.Store(true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("shutdown", "error", err.Error())
	}
	_ = shutdownTracing(ctx) // flush buffered spans
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
