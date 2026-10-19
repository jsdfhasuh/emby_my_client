// Package hybridge exposes only gomobile-compatible primitives and JSON.
package hybridge

import (
	"crypto/x509"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
)

var sessions = struct {
	sync.Mutex
	items map[int64]*session
}{items: make(map[int64]*session)}
var nextID atomic.Int64

// Version identifies the embedded upstream core, not an external executable.
func Version() string { return "core/v2.13.0@ca8fbd874fd6ca82413948de6dc5924405e103e1" }

// NewSession validates configuration without starting network I/O.
func NewSession(configJSON string) (int64, error) {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return 0, err
	}
	s := newSession(cfg, nil, handshakeTimeout)
	id := nextID.Add(1)
	sessions.Lock()
	sessions.items[id] = s
	sessions.Unlock()
	return id, nil
}

// Connect authenticates the QUIC core, then opens an authenticated loopback proxy.
func Connect(id int64, rootsPEM string) (string, error) {
	sessions.Lock()
	s := sessions.items[id]
	sessions.Unlock()
	if s == nil {
		return "", errors.New("HYSTERIA_CANCELLED")
	}
	if rootsPEM != "" {
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM([]byte(rootsPEM)) {
			return "", errors.New("HYSTERIA_TLS")
		}
		s.mu.Lock()
		if !s.started {
			s.roots = roots
		}
		s.mu.Unlock()
	}
	ep, err := s.connect()
	if err != nil {
		return "", err
	}
	data, _ := json.Marshal(ep)
	return string(data), nil
}

// Close cancels even an in-flight handshake and closes all listener connections.
func Close(id int64) {
	sessions.Lock()
	s := sessions.items[id]
	delete(sessions.items, id)
	sessions.Unlock()
	if s != nil {
		s.close()
	}
}
