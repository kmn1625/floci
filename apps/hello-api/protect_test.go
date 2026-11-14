package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestLimitInflightShedsOverLimitButNotProbes(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{}, 4)
	slow := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		started <- struct{}{}
		<-release
	})
	h := limitInflight(2, slow)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/", nil)) }()
	}
	<-started
	<-started

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("third request: got %d Retry-After=%q, want 503 with Retry-After", rec.Code, rec.Header().Get("Retry-After"))
	}

	probeDone := make(chan int)
	go func() {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/readyz", nil))
		probeDone <- rec.Code
	}()
	<-started // the probe reached the handler although the limit is full
	close(release)
	wg.Wait()
	if code := <-probeDone; code != http.StatusOK {
		t.Fatalf("probe: got %d", code)
	}
	if inflight.Load() != 0 {
		t.Fatalf("inflight leaked: %d", inflight.Load())
	}
}

func testCert(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func TestTLSListenerResetsOverHandshakeLimit(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &tls.Config{Certificates: []tls.Certificate{testCert(t)}, NextProtos: []string{"http/1.1"}}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}), ConnState: trackHandshake}
	go func() { _ = srv.Serve(&tlsListener{Listener: raw, cfg: cfg, max: 1}) }()
	defer srv.Close()
	addr := raw.Addr().String()

	// A client that connects and never starts its handshake holds the only slot.
	idle, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return handshaking.Load() == 1 })

	before := shedHandshake.Load()
	c, err := tls.DialWithDialer(&net.Dialer{Timeout: 2 * time.Second}, "tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err == nil {
		c.Close()
		t.Fatal("second connection completed a handshake over the limit")
	}
	if shedHandshake.Load() != before+1 {
		t.Fatalf("shed counter: got %d, want %d", shedHandshake.Load(), before+1)
	}

	// The slot frees when the idle connection closes; then a full request works.
	idle.Close()
	waitFor(t, func() bool { return handshaking.Load() == 0 })
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	resp, err := client.Get("https://" + addr + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	waitFor(t, func() bool { return handshaking.Load() == 0 }) // left the count once serving
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatal("condition not reached in 3 s")
}
