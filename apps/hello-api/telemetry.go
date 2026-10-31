package main

// Traces: OpenTelemetry over OTLP/HTTP, on only when OTEL_EXPORTER_OTLP_ENDPOINT
// is set (e.g. http://tempo.observability:4318). Service name and extra resource
// attributes come from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES.
// Logs: one JSON line per request with trace_id, so Grafana links Loki → Tempo.

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

var logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))

func setupTracing(ctx context.Context) (shutdown func(context.Context) error, err error) {
	noop := func(context.Context) error { return nil }
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		return noop, nil
	}
	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return noop, err
	}
	res, err := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK(),
		resource.WithAttributes(attribute.String("service.version", version)))
	if err != nil {
		return noop, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return tp.Shutdown, nil
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}

// instrument wraps the mux: tracing outside (span per request, probes and
// /metrics skipped), then metrics + a JSON access log carrying the trace id.
func instrument(mux *http.ServeMux) http.Handler {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		mux.ServeHTTP(rec, r)
		route := r.Pattern // set by ServeMux on this request after matching
		if route == "" {
			route = "unmatched"
		}
		d := time.Since(start)
		metrics.observe(route, rec.code, d)
		if route == "GET /healthz" || route == "GET /readyz" || route == "GET /metrics" {
			return
		}
		attrs := []any{"method", r.Method, "path", r.URL.Path, "route", route, "status", rec.code,
			"duration_ms", float64(d.Microseconds()) / 1000}
		if sc := trace.SpanContextFromContext(r.Context()); sc.IsValid() {
			attrs = append(attrs, "trace_id", sc.TraceID().String())
		}
		logger.Info("request", attrs...)
	})
	return otelhttp.NewHandler(inner, "hello-api",
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/healthz" && r.URL.Path != "/readyz" && r.URL.Path != "/metrics"
		}),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method + " " + r.URL.Path }))
}
