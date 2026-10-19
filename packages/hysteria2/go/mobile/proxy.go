package hybridge

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type proxy struct {
	ep       endpoint
	core     tcpCore
	listener net.Listener
	server   *http.Server
	forward  *http.Transport
	authHash [sha256.Size]byte
	slots    chan struct{}
	mu       sync.Mutex
	closed   bool
	conns    map[net.Conn]struct{}
	closeOne sync.Once
}

func randomToken(size int) (string, error) {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func newProxy(core tcpCore) (*proxy, error) {
	username, err := randomToken(18)
	if err != nil {
		return nil, err
	}
	password, err := randomToken(32)
	if err != nil {
		return nil, err
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p := &proxy{
		ep:   endpoint{"127.0.0.1", l.Addr().(*net.TCPAddr).Port, username, password},
		core: core, listener: l, conns: make(map[net.Conn]struct{}), slots: make(chan struct{}, 64),
		authHash: sha256.Sum256([]byte("Basic " + base64.StdEncoding.EncodeToString([]byte(username+":"+password)))),
	}
	p.server = &http.Server{
		Handler: p, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second,
		MaxHeaderBytes: 8192, ErrorLog: log.New(io.Discard, "", 0),
		ConnState: func(c net.Conn, state http.ConnState) {
			p.mu.Lock()
			defer p.mu.Unlock()
			if state == http.StateNew {
				if p.closed {
					_ = c.Close()
				} else {
					p.conns[c] = struct{}{}
				}
			} else if state == http.StateClosed {
				delete(p.conns, c)
			}
		},
	}
	p.forward = &http.Transport{
		Proxy: nil, DisableCompression: true, MaxIdleConns: 32,
		IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: 30 * time.Second,
		DialContext: func(ctx context.Context, network, authority string) (net.Conn, error) {
			return dialTCP(ctx, core, authority)
		},
	}
	go func() { _ = p.server.Serve(l) }()
	return p, nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Hashes have fixed length; never compare credentials with a plain string ==.
	got := sha256.Sum256([]byte(r.Header.Get("Proxy-Authorization")))
	if len(r.Header.Values("Proxy-Authorization")) != 1 || subtle.ConstantTimeCompare(got[:], p.authHash[:]) != 1 {
		w.Header().Set("Proxy-Authenticate", `Basic realm="hysteria2"`)
		w.Header().Set("Connection", "close")
		http.Error(w, "Proxy authentication required", http.StatusProxyAuthRequired)
		return
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		http.Error(w, "Proxy busy", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodConnect {
		p.forwardHTTP(w, r)
		return
	}
	if !validAuthority(r.RequestURI) || r.URL.Host != r.RequestURI || r.ContentLength > 0 || len(r.TransferEncoding) != 0 {
		http.Error(w, "Invalid CONNECT authority", http.StatusBadRequest)
		return
	}
	// The authority is forwarded unchanged to Hysteria. Only the server resolves
	// and dials the destination; no local net.Dial or DNS lookup is performed.
	remote, err := dialTCP(r.Context(), p.core, r.RequestURI)
	if err != nil {
		if remote != nil {
			_ = remote.Close()
		}
		http.Error(w, "Upstream connection failed", http.StatusBadGateway)
		return
	}
	defer remote.Close()
	local, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer func() {
		_ = local.Close()
		p.mu.Lock()
		delete(p.conns, local)
		p.mu.Unlock()
	}()
	_ = local.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err = buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	if buffered.Flush() != nil {
		return
	}
	_ = local.SetDeadline(time.Time{})
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(remote, buffered)
		_ = remote.Close()
		close(done)
	}()
	_, _ = io.Copy(local, remote)
	_ = local.Close()
	_ = remote.Close()
	<-done
}

func dialTCP(ctx context.Context, core tcpCore, authority string) (net.Conn, error) {
	if !validAuthority(authority) {
		return nil, errors.New("HYSTERIA_TARGET")
	}
	remote, err := core.TCP(authority)
	if err != nil {
		return nil, errors.New("HYSTERIA_DIAL")
	}
	stop := context.AfterFunc(ctx, func() { _ = remote.Close() })
	_ = remote.SetDeadline(time.Now().Add(10 * time.Second))
	// With upstream FastOpen, even an empty Read validates the dial response.
	_, err = remote.Read(nil)
	stopped := stop()
	if err != nil || !stopped || ctx.Err() != nil {
		_ = remote.Close()
		return nil, errors.New("HYSTERIA_DIAL")
	}
	_ = remote.SetDeadline(time.Time{})
	return remote, nil
}

func removeHopHeaders(header http.Header) {
	for _, value := range header.Values("Connection") {
		for _, token := range strings.Split(value, ",") {
			header.Del(strings.TrimSpace(token))
		}
	}
	for _, name := range []string{"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate",
		"Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
		header.Del(name)
	}
}

func (p *proxy) forwardHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Scheme != "http" || r.URL.Hostname() == "" || r.URL.User != nil || !validHost(r.URL.Hostname()) {
		http.Error(w, "Absolute HTTP URL required", http.StatusBadRequest)
		return
	}
	request := r.Clone(r.Context())
	request.RequestURI = ""
	request.Host = r.URL.Host
	request.Close = false
	request.TransferEncoding = nil
	request.Trailer = nil
	removeHopHeaders(request.Header)
	// RoundTrip performs exactly one request: Location is passed to the caller.
	response, err := p.forward.RoundTrip(request)
	if err != nil {
		http.Error(w, "Upstream request failed", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	removeHopHeaders(response.Header)
	for key, values := range response.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, response.Body)
}

func (p *proxy) close() {
	p.closeOne.Do(func() {
		p.mu.Lock()
		p.closed = true
		for c := range p.conns {
			_ = c.Close()
		}
		p.mu.Unlock()
		_ = p.server.Close()
		_ = p.listener.Close()
		p.forward.CloseIdleConnections()
	})
}
