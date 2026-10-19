package hybridge

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/apernet/hysteria/core/v2/client"
	"github.com/apernet/hysteria/core/v2/server"
	"github.com/apernet/hysteria/extras/v2/obfs"
)

func TestUpstreamQUICSanity(t *testing.T) {
	cfg, roots := startServer(t, "", &testOutbound{})
	c, _, err := client.NewClient(&client.Config{ServerAddr: &net.UDPAddr{IP: net.ParseIP(cfg.Host), Port: cfg.Port}, Auth: cfg.Auth,
		TLSConfig: client.TLSConfig{ServerName: cfg.SNI, RootCAs: roots}, QUICConfig: client.QUICConfig{DisableGSO: true}, FastOpen: true})
	if err != nil {
		t.Fatal(err)
	}
	_ = c.Close()
}

type testAuth struct{}

func (testAuth) Authenticate(_ net.Addr, auth string, _ uint64) (bool, string) {
	return auth == "test-only-auth", "test-only"
}

type testOutbound struct {
	target string
	mu     sync.Mutex
	seen   []string
}

func (o *testOutbound) TCP(authority string) (net.Conn, error) {
	o.mu.Lock()
	o.seen = append(o.seen, authority)
	o.mu.Unlock()
	return net.DialTimeout("tcp", o.target, time.Second)
}
func (*testOutbound) UDP(string) (server.UDPConn, error) { return nil, fmt.Errorf("disabled") }
func (*testOutbound) CheckUDP(string) error              { return fmt.Errorf("disabled") }

func testCertificate(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-only"},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), DNSNames: []string{"localhost"},
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &private.PublicKey, private)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := x509.MarshalPKCS8PrivateKey(private)
	cert, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	parsed, _ := x509.ParseCertificate(der)
	roots.AddCert(parsed)
	return cert, roots
}

func startServer(t *testing.T, password string, outbound *testOutbound) (config, *x509.CertPool) {
	t.Helper()
	cert, roots := testCertificate(t)
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := udp.LocalAddr().(*net.UDPAddr).Port
	if password != "" {
		udp, err = obfs.WrapPacketConnSalamander(udp, []byte(password))
		if err != nil {
			t.Fatal(err)
		}
	}
	s, err := server.NewServer(&server.Config{Conn: udp, TLSConfig: server.TLSConfig{Certificates: []tls.Certificate{cert}},
		Authenticator: testAuth{}, Outbound: outbound, DisableUDP: true})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = s.Serve(); close(done) }()
	t.Cleanup(func() { _ = s.Close(); <-done })
	return config{Host: "127.0.0.1", Port: port, SNI: "localhost", Auth: "test-only-auth", ObfsPassword: password}, roots
}

func proxyURL(ep endpoint) *url.URL {
	return &url.URL{Scheme: "http", Host: net.JoinHostPort(ep.Host, strconv.Itoa(ep.Port)), User: url.UserPassword(ep.Username, ep.Password)}
}

func TestRealQUICConnectHTTPS(t *testing.T) {
	for _, password := range []string{"", "test-only-salamander"} {
		t.Run(fmt.Sprintf("obfs=%t", password != ""), func(t *testing.T) {
			payload := bytes.Repeat([]byte("test-only-payload"), 16384)
			target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Proxy-Authorization") != "" {
					t.Error("proxy credentials leaked into TLS")
				}
				_, _ = w.Write(payload)
			}))
			defer target.Close()
			outbound := &testOutbound{target: target.Listener.Addr().String()}
			cfg, roots := startServer(t, password, outbound)
			s := newSession(cfg, roots, 3*time.Second)
			defer s.close()
			ep, err := s.connect()
			if err != nil {
				t.Fatal(err)
			}
			targetRoots := x509.NewCertPool()
			targetRoots.AddCert(target.Certificate())
			transport := &http.Transport{Proxy: http.ProxyURL(proxyURL(ep)), TLSClientConfig: &tls.Config{RootCAs: targetRoots, ServerName: target.Certificate().DNSNames[0]}}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
			response, err := client.Get("https://only-on-server.invalid:443/test")
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(response.Body)
			_ = response.Body.Close()
			if err != nil || !bytes.Equal(payload, data) {
				t.Fatal("HTTPS payload mismatch", err)
			}
			outbound.mu.Lock()
			seen := append([]string(nil), outbound.seen...)
			outbound.mu.Unlock()
			if len(seen) != 1 || seen[0] != "only-on-server.invalid:443" {
				t.Fatal("destination not preserved")
			}
			s.close()
			connection, err := net.DialTimeout("tcp", proxyURL(ep).Host, 200*time.Millisecond)
			if err == nil {
				_ = connection.Close()
				t.Fatal("listener survived release")
			}
		})
	}
}

func TestRealQUICHTTPForwarding(t *testing.T) {
	var leaked bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked = r.Header.Get("Proxy-Authorization") != "" || r.Header.Get("X-Hop-Secret") != "" || r.Header.Get("Proxy-Connection") != ""
		if r.URL.Path != "/original" || r.Host != "only-on-server.invalid" {
			t.Error("original URL changed")
		}
		w.Header().Set("Location", "http://do-not-follow.invalid/")
		w.Header().Set("Connection", "X-Hop-Response")
		w.Header().Set("X-Hop-Response", "removed")
		w.WriteHeader(http.StatusFound)
		_, _ = io.WriteString(w, "redirect-body")
	}))
	defer target.Close()
	outbound := &testOutbound{target: target.Listener.Addr().String()}
	cfg, roots := startServer(t, "", outbound)
	s := newSession(cfg, roots, 3*time.Second)
	defer s.close()
	ep, err := s.connect()
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL(ep))}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, _ := http.NewRequest("GET", "http://only-on-server.invalid/original", nil)
	request.Header.Set("Connection", "X-Hop-Secret")
	request.Header.Set("X-Hop-Secret", "removed")
	request.Header.Set("Proxy-Connection", "keep-alive")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if err != nil || response.StatusCode != http.StatusFound || string(data) != "redirect-body" || leaked || response.Header.Get("X-Hop-Response") != "" {
		t.Fatal("HTTP forwarding contract failed")
	}
	outbound.mu.Lock()
	count := len(outbound.seen)
	outbound.mu.Unlock()
	if count != 1 {
		t.Fatal("proxy followed redirect")
	}
}

func TestRealQUICRejectsTLSAndAuth(t *testing.T) {
	cfg, roots := startServer(t, "", &testOutbound{})
	for _, test := range []struct {
		name   string
		roots  *x509.CertPool
		change func(*config)
		code   string
	}{
		{"untrusted", x509.NewCertPool(), func(*config) {}, "HYSTERIA_TLS"},
		{"hostname", roots, func(c *config) { c.SNI = "wrong.invalid" }, "HYSTERIA_TLS"},
		{"auth", roots, func(c *config) { c.Auth = "wrong-test-only-auth" }, "HYSTERIA_AUTH"},
	} {
		t.Run(test.name, func(t *testing.T) {
			changed := cfg
			test.change(&changed)
			s := newSession(changed, test.roots, 2*time.Second)
			defer s.close()
			_, err := s.connect()
			if err == nil || err.Error() != test.code {
				t.Fatalf("expected sanitized %s, got %v", test.code, err)
			}
			if s.proxy != nil {
				t.Fatal("listener opened for rejected handshake")
			}
		})
	}
}

func TestPendingDeadlineAndCancellation(t *testing.T) {
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	cfg := config{Host: "127.0.0.1", Port: udp.LocalAddr().(*net.UDPAddr).Port, SNI: "localhost", Auth: "test-only-auth"}
	s := newSession(cfg, nil, 100*time.Millisecond)
	start := time.Now()
	_, err = s.connect()
	s.close()
	if err == nil || err.Error() != "HYSTERIA_TIMEOUT" || time.Since(start) > time.Second {
		t.Fatal("handshake deadline failed")
	}
	s = newSession(cfg, nil, 5*time.Second)
	done := make(chan error, 1)
	go func() { _, err := s.connect(); done <- err }()
	time.Sleep(20 * time.Millisecond)
	s.close()
	select {
	case err = <-done:
		if err == nil || err.Error() != "HYSTERIA_CANCELLED" {
			t.Fatal("cancel failed")
		}
	case <-time.After(time.Second):
		t.Fatal("pending handshake leaked")
	}
	if s.proxy != nil {
		t.Fatal("cancelled listener leaked")
	}
}

type fakeCore struct{ calls int }

func (f *fakeCore) TCP(string) (net.Conn, error) {
	f.calls++
	return nil, fmt.Errorf("private upstream diagnostic")
}
func (*fakeCore) Close() error { return nil }

func TestProxyAuthenticationAndSanitizedErrors(t *testing.T) {
	core := &fakeCore{}
	p, err := newProxy(core)
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	for _, authorization := range []string{"", "Basic invalid", "Bearer test"} {
		r := httptest.NewRequest("CONNECT", "http://target.invalid:443", nil)
		r.Header.Set("Proxy-Authorization", authorization)
		w := httptest.NewRecorder()
		p.ServeHTTP(w, r)
		if w.Code != 407 || core.calls != 0 {
			t.Fatal("authentication bypass")
		}
	}
	connection, err := net.Dial("tcp", proxyURL(p.ep).Host)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(time.Second))
	authorization := base64.StdEncoding.EncodeToString([]byte(p.ep.Username + ":" + p.ep.Password))
	_, _ = fmt.Fprintf(connection, "CONNECT target.invalid:443 HTTP/1.1\r\nHost: target.invalid:443\r\nProxy-Authorization: Basic %s\r\n\r\n", authorization)
	response, err := http.ReadResponse(bufio.NewReader(connection), nil)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != 502 || strings.Contains(string(data), "private") {
		t.Fatal("raw upstream error leaked")
	}
}

func TestBridgeCloseIsIdempotent(t *testing.T) {
	id, err := NewSession(`{"host":"localhost","port":443,"auth":"test-only","sni":"localhost"}`)
	if err != nil {
		t.Fatal(err)
	}
	Close(id)
	Close(id)
	if _, err := Connect(id, ""); err == nil || err.Error() != "HYSTERIA_CANCELLED" {
		t.Fatal("stale handle accepted")
	}
	if safeConnectError(context.Background(), fmt.Errorf("secret")).Error() != "HYSTERIA_CONNECT" {
		t.Fatal("raw error leaked")
	}
}
